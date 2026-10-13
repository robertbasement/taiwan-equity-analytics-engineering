#!/usr/bin/env python3
"""One read-only query for distinct blast-radius and trend-signal counts."""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

from google.cloud import bigquery

from run_prechange_diagnostics import PROJECT, SOURCE_CTE, check_read_only


OUT = Path(__file__).resolve().parent / "output"

SQL = f"""
WITH
{SOURCE_CTE},
sequenced AS (
  SELECT
    *,
    IF(yoy_growth_pct > 0, 1, 0) AS is_positive,
    LAG(revenue_month_date, 1) OVER (PARTITION BY ticker ORDER BY revenue_month_date) AS month_lag1,
    LAG(revenue_month_date, 2) OVER (PARTITION BY ticker ORDER BY revenue_month_date) AS month_lag2,
    LAG(IF(yoy_growth_pct > 0, 1, 0)) OVER (PARTITION BY ticker ORDER BY revenue_month_date) AS positive_lag1,
    LAG(yoy_growth_pct, 1) OVER (PARTITION BY ticker ORDER BY revenue_month_date) AS yoy_lag1,
    LAG(yoy_growth_pct, 2) OVER (PARTITION BY ticker ORDER BY revenue_month_date) AS yoy_lag2
  FROM source_monthly
  WHERE revenue_month_date IS NOT NULL
),
states AS (
  SELECT
    *,
    IF(is_positive != positive_lag1, 1, 0) AS old_state_change,
    IF(
      month_lag1 IS NULL
      OR DATE_DIFF(revenue_month_date, month_lag1, MONTH) != 1
      OR is_positive != positive_lag1,
      1,
      0
    ) AS fixed_state_change,
    IF(yoy_growth_pct > yoy_lag1 AND yoy_lag1 > yoy_lag2, 1, 0) AS old_triple,
    IF(
      DATE_DIFF(revenue_month_date, month_lag1, MONTH) = 1
      AND DATE_DIFF(month_lag1, month_lag2, MONTH) = 1
      AND yoy_growth_pct > yoy_lag1
      AND yoy_lag1 > yoy_lag2,
      1,
      0
    ) AS fixed_triple,
    SUM(IF(month_lag1 IS NULL OR DATE_DIFF(revenue_month_date, month_lag1, MONTH) != 1, 1, 0))
      OVER (PARTITION BY ticker ORDER BY revenue_month_date) AS continuity_segment
  FROM sequenced
),
streak_groups AS (
  SELECT
    *,
    SUM(old_state_change) OVER (PARTITION BY ticker ORDER BY revenue_month_date) AS old_streak_group,
    SUM(fixed_state_change) OVER (PARTITION BY ticker ORDER BY revenue_month_date) AS fixed_streak_group
  FROM states
),
trend_features AS (
  SELECT
    *,
    IF(is_positive = 1, ROW_NUMBER() OVER (PARTITION BY ticker, old_streak_group ORDER BY revenue_month_date), 0) AS old_streak,
    IF(is_positive = 1, ROW_NUMBER() OVER (PARTITION BY ticker, fixed_streak_group ORDER BY revenue_month_date), 0) AS fixed_streak,
    AVG(CASE WHEN ABS(yoy_growth_pct) > 1 THEN yoy_growth_pct / 100.0 ELSE yoy_growth_pct END)
      OVER (PARTITION BY ticker ORDER BY revenue_month_date ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS old_3m,
    AVG(CASE WHEN ABS(yoy_growth_pct) > 1 THEN yoy_growth_pct / 100.0 ELSE yoy_growth_pct END)
      OVER (PARTITION BY ticker ORDER BY revenue_month_date ROWS BETWEEN 5 PRECEDING AND CURRENT ROW) AS old_6m,
    AVG(yoy_growth_pct / 100.0)
      OVER (PARTITION BY ticker, continuity_segment ORDER BY revenue_month_date ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS fixed_3m,
    AVG(yoy_growth_pct / 100.0)
      OVER (PARTITION BY ticker, continuity_segment ORDER BY revenue_month_date ROWS BETWEEN 5 PRECEDING AND CURRENT ROW) AS fixed_6m,
    CASE WHEN COUNT(revenue) OVER (PARTITION BY ticker ORDER BY revenue_month_date ROWS BETWEEN 11 PRECEDING AND CURRENT ROW) = 12
      THEN SUM(revenue) OVER (PARTITION BY ticker ORDER BY revenue_month_date ROWS BETWEEN 11 PRECEDING AND CURRENT ROW) END AS old_ttm,
    CASE WHEN COUNT(revenue) OVER (PARTITION BY ticker, continuity_segment ORDER BY revenue_month_date ROWS BETWEEN 11 PRECEDING AND CURRENT ROW) = 12
      THEN SUM(revenue) OVER (PARTITION BY ticker, continuity_segment ORDER BY revenue_month_date ROWS BETWEEN 11 PRECEDING AND CURRENT ROW) END AS fixed_ttm
  FROM streak_groups
),
features AS (
  SELECT
    *,
    GREATEST(-0.5, LEAST(1.0, old_6m + 0.5 * (old_3m - old_6m))) AS old_expected_growth,
    GREATEST(-0.5, LEAST(1.0, fixed_6m + 0.5 * (fixed_3m - fixed_6m))) AS fixed_expected_growth,
    old_ttm IS DISTINCT FROM fixed_ttm
      OR (AVG(yoy_growth_pct / 100.0) OVER (PARTITION BY ticker ORDER BY revenue_month_date ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)) IS DISTINCT FROM fixed_3m
      OR (AVG(yoy_growth_pct / 100.0) OVER (PARTITION BY ticker ORDER BY revenue_month_date ROWS BETWEEN 5 PRECEDING AND CURRENT ROW)) IS DISTINCT FROM fixed_6m
      AS calendar_feature_changed
  FROM trend_features
),
research AS (
  SELECT rebalance_date, ticker, revenue_month
  FROM `{PROJECT}.stock_analytics.mart_factor_research_monthly`
),
research_joined AS (
  SELECT r.*, f.* EXCEPT(ticker)
  FROM research r
  LEFT JOIN features f ON f.ticker = r.ticker AND f.year_month = r.revenue_month
)
SELECT metric, value
FROM UNNEST([
  STRUCT('calendar_feature_changed_rows' AS metric, (SELECT COUNTIF(calendar_feature_changed) FROM features) AS value),
  STRUCT('calendar_feature_changed_tickers', (SELECT COUNT(DISTINCT IF(calendar_feature_changed, ticker, NULL)) FROM features)),
  STRUCT('calendar_feature_changed_months', (SELECT COUNT(DISTINCT IF(calendar_feature_changed, year_month, NULL)) FROM features)),
  STRUCT('combined_expected_growth_changed_rows', (SELECT COUNTIF(old_expected_growth IS DISTINCT FROM fixed_expected_growth) FROM features)),
  STRUCT('combined_expected_growth_changed_tickers', (SELECT COUNT(DISTINCT IF(old_expected_growth IS DISTINCT FROM fixed_expected_growth, ticker, NULL)) FROM features)),
  STRUCT('old_streak_changed_rows', (SELECT COUNTIF(old_streak != fixed_streak) FROM features)),
  STRUCT('old_streak_changed_tickers', (SELECT COUNT(DISTINCT IF(old_streak != fixed_streak, ticker, NULL)) FROM features)),
  STRUCT('triple_signal_changed_rows', (SELECT COUNTIF(old_triple != fixed_triple) FROM features)),
  STRUCT('triple_signal_changed_tickers', (SELECT COUNT(DISTINCT IF(old_triple != fixed_triple, ticker, NULL)) FROM features)),
  STRUCT('research_combined_expected_growth_changed_observations', (SELECT COUNTIF(old_expected_growth IS DISTINCT FROM fixed_expected_growth) FROM research_joined)),
  STRUCT('research_combined_expected_growth_changed_tickers', (SELECT COUNT(DISTINCT IF(old_expected_growth IS DISTINCT FROM fixed_expected_growth, ticker, NULL)) FROM research_joined)),
  STRUCT('research_combined_expected_growth_changed_months', (SELECT COUNT(DISTINCT IF(old_expected_growth IS DISTINCT FROM fixed_expected_growth, rebalance_date, NULL)) FROM research_joined)),
  STRUCT('research_calendar_feature_changed_observations', (SELECT COUNTIF(calendar_feature_changed) FROM research_joined)),
  STRUCT('research_calendar_feature_changed_tickers', (SELECT COUNT(DISTINCT IF(calendar_feature_changed, ticker, NULL)) FROM research_joined)),
  STRUCT('research_calendar_feature_changed_months', (SELECT COUNT(DISTINCT IF(calendar_feature_changed, rebalance_date, NULL)) FROM research_joined))
])
ORDER BY metric
"""


def main() -> None:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--dry-run", action="store_true")
    mode.add_argument("--execute", action="store_true")
    args = parser.parse_args()
    check_read_only(SQL)
    client = bigquery.Client(project=PROJECT)
    dry = client.query(SQL, job_config=bigquery.QueryJobConfig(dry_run=True, use_query_cache=False))
    report = {
        "started_at": datetime.now(timezone.utc).isoformat(),
        "statement_type": "SELECT_ONLY",
        "dry_run_bytes": int(dry.total_bytes_processed),
        "status": "DRY_RUN_OK",
    }
    if args.execute:
        job = client.query(SQL)
        rows = [dict(row.items()) for row in job.result()]
        (OUT / "supplemental_impact.json").write_text(json.dumps(rows, indent=2, sort_keys=True) + "\n")
        report.update({
            "status": "COMPLETED", "job_id": job.job_id,
            "bytes_processed": int(job.total_bytes_processed),
            "bytes_billed": int(job.total_bytes_billed), "row_count": len(rows),
        })
    (OUT / "supplemental_progress.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
