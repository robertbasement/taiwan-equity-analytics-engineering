#!/usr/bin/env python3
"""Read-only baseline diagnostics for Revenue Data Correctness V1."""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

from google.cloud import bigquery


PROJECT = "stock-backtest-491815"
OUT = Path(__file__).resolve().parent / "output"
FORBIDDEN = ("CREATE ", "REPLACE ", "INSERT ", "UPDATE ", "DELETE ", "MERGE ", "DROP ", "ALTER ")

SOURCE_CTE = f"""
source_monthly AS (
  SELECT * EXCEPT(source_rank)
  FROM (
    SELECT
      CAST(ticker AS STRING) AS ticker,
      year_month,
      SAFE.PARSE_DATE('%Y-%m', year_month) AS revenue_month_date,
      CAST(revenue AS INT64) AS revenue,
      CAST(revenue_last_year AS INT64) AS revenue_last_year,
      SAFE_CAST(yoy_growth_pct AS FLOAT64) AS yoy_growth_pct,
      ROW_NUMBER() OVER (
        PARTITION BY ticker, year_month ORDER BY revenue DESC
      ) AS source_rank
    FROM `{PROJECT}.stock_data.monthly_revenue`
  )
  WHERE source_rank = 1
)
"""

UNIT_CONTRACT_SQL = f"""
WITH
{SOURCE_CTE},
evaluated AS (
  SELECT
    *,
    100.0 * SAFE_DIVIDE(revenue - revenue_last_year, revenue_last_year) AS recomputed_pct,
    SAFE_DIVIDE(revenue - revenue_last_year, revenue_last_year) AS recomputed_decimal,
    CASE WHEN ABS(yoy_growth_pct) > 1 THEN yoy_growth_pct / 100.0 ELSE yoy_growth_pct END AS old_decimal,
    yoy_growth_pct / 100.0 AS correct_decimal
  FROM source_monthly
)
SELECT
  COUNT(*) AS total_relevant_observations,
  COUNTIF(yoy_growth_pct IS NOT NULL) AS nonnull_yoy_observations,
  COUNTIF(yoy_growth_pct IS NOT NULL AND yoy_growth_pct != 0 AND ABS(yoy_growth_pct) <= 1) AS incorrect_conditional_conversion_rows,
  COUNT(DISTINCT IF(yoy_growth_pct IS NOT NULL AND yoy_growth_pct != 0 AND ABS(yoy_growth_pct) <= 1, ticker, NULL)) AS affected_tickers,
  COUNT(DISTINCT IF(yoy_growth_pct IS NOT NULL AND yoy_growth_pct != 0 AND ABS(yoy_growth_pct) <= 1, year_month, NULL)) AS affected_revenue_months,
  MIN(IF(yoy_growth_pct IS NOT NULL AND yoy_growth_pct != 0 AND ABS(yoy_growth_pct) <= 1, revenue_month_date, NULL)) AS first_affected_month,
  MAX(IF(yoy_growth_pct IS NOT NULL AND yoy_growth_pct != 0 AND ABS(yoy_growth_pct) <= 1, revenue_month_date, NULL)) AS last_affected_month,
  COUNTIF(yoy_growth_pct = 0) AS zero_rows,
  COUNTIF(yoy_growth_pct IS NULL) AS null_rows,
  COUNTIF(yoy_growth_pct > 0 AND ABS(yoy_growth_pct) < 1) AS positive_sub_one_rows,
  COUNTIF(yoy_growth_pct < 0 AND ABS(yoy_growth_pct) < 1) AS negative_sub_one_rows,
  COUNTIF(ABS(yoy_growth_pct) > 100) AS extreme_over_100pct_rows,
  COUNTIF(recomputed_pct IS NOT NULL AND ABS(yoy_growth_pct - recomputed_pct) <= 0.011) AS agrees_with_percentage_points,
  COUNTIF(recomputed_pct IS NOT NULL AND ABS(yoy_growth_pct * 100.0 - recomputed_pct) <= 0.011) AS agrees_with_decimal_fraction,
  COUNTIF(recomputed_pct IS NOT NULL AND ABS(yoy_growth_pct - recomputed_pct) < ABS(yoy_growth_pct * 100.0 - recomputed_pct)) AS closer_to_percentage_points,
  COUNTIF(recomputed_pct IS NOT NULL AND ABS(yoy_growth_pct - recomputed_pct) > ABS(yoy_growth_pct * 100.0 - recomputed_pct)) AS closer_to_decimal_fraction,
  AVG(ABS(yoy_growth_pct - recomputed_pct)) AS mean_abs_error_as_percentage_points,
  AVG(ABS(yoy_growth_pct * 100.0 - recomputed_pct)) AS mean_abs_error_as_decimal_fraction
FROM evaluated
"""

UNIT_SAMPLES_SQL = f"""
WITH
{SOURCE_CTE}
SELECT
  ticker, year_month, revenue, revenue_last_year, yoy_growth_pct,
  100.0 * SAFE_DIVIDE(revenue - revenue_last_year, revenue_last_year) AS recomputed_pct,
  yoy_growth_pct / 100.0 AS correct_decimal
FROM source_monthly
WHERE yoy_growth_pct IS NULL
   OR yoy_growth_pct = 0
   OR (ABS(yoy_growth_pct) < 1 AND yoy_growth_pct != 0)
   OR ABS(yoy_growth_pct) > 100
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY
    CASE
      WHEN yoy_growth_pct IS NULL THEN 'NULL'
      WHEN yoy_growth_pct = 0 THEN 'ZERO'
      WHEN ABS(yoy_growth_pct) < 1 THEN 'SUB_ONE'
      ELSE 'EXTREME'
    END
  ORDER BY year_month, ticker
) <= 8
ORDER BY year_month, ticker
"""

CALENDAR_GAPS_SQL = f"""
WITH
{SOURCE_CTE},
ordered AS (
  SELECT *, LAG(revenue_month_date) OVER (PARTITION BY ticker ORDER BY revenue_month_date) AS previous_month
  FROM source_monthly
  WHERE revenue_month_date IS NOT NULL
),
gaps AS (
  SELECT *, DATE_DIFF(revenue_month_date, previous_month, MONTH) - 1 AS missing_months
  FROM ordered
  WHERE DATE_DIFF(revenue_month_date, previous_month, MONTH) > 1
),
raw_duplicates AS (
  SELECT ticker, year_month, COUNT(*) AS row_count
  FROM `{PROJECT}.stock_data.monthly_revenue`
  GROUP BY 1, 2 HAVING COUNT(*) > 1
)
SELECT
  (SELECT COUNT(*) FROM source_monthly) AS unique_monthly_observations,
  (SELECT COUNT(*) FROM raw_duplicates) AS duplicate_ticker_month_keys_before_staging_policy,
  COUNT(*) AS gap_count,
  COUNT(DISTINCT ticker) AS gap_tickers,
  MIN(missing_months) AS min_missing_months,
  MAX(missing_months) AS max_missing_months,
  APPROX_QUANTILES(missing_months, 100)[OFFSET(50)] AS median_missing_months,
  COUNTIF(missing_months = 1) AS gaps_missing_1_month,
  COUNTIF(missing_months BETWEEN 2 AND 5) AS gaps_missing_2_to_5_months,
  COUNTIF(missing_months BETWEEN 6 AND 11) AS gaps_missing_6_to_11_months,
  COUNTIF(missing_months >= 12) AS gaps_missing_12plus_months
FROM gaps
"""

FEATURE_IMPACT_SQL = f"""
WITH
{SOURCE_CTE},
ordered AS (
  SELECT
    *,
    LAG(revenue_month_date) OVER (PARTITION BY ticker ORDER BY revenue_month_date) AS previous_month
  FROM source_monthly
  WHERE revenue_month_date IS NOT NULL
),
segmented AS (
  SELECT
    *,
    SUM(IF(previous_month IS NULL OR DATE_DIFF(revenue_month_date, previous_month, MONTH) != 1, 1, 0))
      OVER (PARTITION BY ticker ORDER BY revenue_month_date) AS continuity_segment
  FROM ordered
),
windowed AS (
  SELECT
    *,
    CASE WHEN COUNT(revenue) OVER (PARTITION BY ticker ORDER BY revenue_month_date ROWS BETWEEN 11 PRECEDING AND CURRENT ROW) = 12
      THEN SUM(revenue) OVER (PARTITION BY ticker ORDER BY revenue_month_date ROWS BETWEEN 11 PRECEDING AND CURRENT ROW) END AS old_ttm,
    CASE WHEN COUNT(revenue) OVER (PARTITION BY ticker, continuity_segment ORDER BY revenue_month_date ROWS BETWEEN 11 PRECEDING AND CURRENT ROW) = 12
      THEN SUM(revenue) OVER (PARTITION BY ticker, continuity_segment ORDER BY revenue_month_date ROWS BETWEEN 11 PRECEDING AND CURRENT ROW) END AS fixed_ttm,
    AVG(CASE WHEN ABS(yoy_growth_pct) > 1 THEN yoy_growth_pct / 100.0 ELSE yoy_growth_pct END)
      OVER (PARTITION BY ticker ORDER BY revenue_month_date ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS old_3m,
    AVG(CASE WHEN ABS(yoy_growth_pct) > 1 THEN yoy_growth_pct / 100.0 ELSE yoy_growth_pct END)
      OVER (PARTITION BY ticker ORDER BY revenue_month_date ROWS BETWEEN 5 PRECEDING AND CURRENT ROW) AS old_6m,
    AVG(yoy_growth_pct / 100.0)
      OVER (PARTITION BY ticker ORDER BY revenue_month_date ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS unit_fixed_3m,
    AVG(yoy_growth_pct / 100.0)
      OVER (PARTITION BY ticker ORDER BY revenue_month_date ROWS BETWEEN 5 PRECEDING AND CURRENT ROW) AS unit_fixed_6m,
    AVG(yoy_growth_pct / 100.0)
      OVER (PARTITION BY ticker, continuity_segment ORDER BY revenue_month_date ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS combined_fixed_3m,
    AVG(yoy_growth_pct / 100.0)
      OVER (PARTITION BY ticker, continuity_segment ORDER BY revenue_month_date ROWS BETWEEN 5 PRECEDING AND CURRENT ROW) AS combined_fixed_6m
  FROM segmented
),
features AS (
  SELECT
    *,
    GREATEST(-0.5, LEAST(1.0, old_6m + 0.5 * (old_3m - old_6m))) AS old_expected_growth,
    GREATEST(-0.5, LEAST(1.0, unit_fixed_6m + 0.5 * (unit_fixed_3m - unit_fixed_6m))) AS unit_fixed_expected_growth,
    GREATEST(-0.5, LEAST(1.0, combined_fixed_6m + 0.5 * (combined_fixed_3m - combined_fixed_6m))) AS combined_fixed_expected_growth,
    old_ttm IS DISTINCT FROM fixed_ttm AS ttm_changed_by_continuity,
    unit_fixed_3m IS DISTINCT FROM combined_fixed_3m AS avg3_changed_by_continuity,
    unit_fixed_6m IS DISTINCT FROM combined_fixed_6m AS avg6_changed_by_continuity
  FROM windowed
),
research AS (
  SELECT rebalance_date, ticker, revenue_month, yoy_growth
  FROM `{PROJECT}.stock_analytics.mart_factor_research_monthly`
),
joined AS (
  SELECT
    r.rebalance_date,
    r.ticker,
    r.revenue_month,
    r.yoy_growth,
    f.* EXCEPT(ticker)
  FROM research r
  LEFT JOIN features f
    ON f.ticker = r.ticker AND f.year_month = r.revenue_month
)
SELECT metric, value
FROM UNNEST([
  STRUCT('monthly_feature_rows' AS metric, (SELECT COUNT(*) FROM features) AS value),
  STRUCT('unit_changed_source_rows', (SELECT COUNTIF(yoy_growth_pct IS NOT NULL AND yoy_growth_pct != 0 AND ABS(yoy_growth_pct) <= 1) FROM features)),
  STRUCT('unit_changed_3m_feature_rows', (SELECT COUNTIF(old_3m IS DISTINCT FROM unit_fixed_3m) FROM features)),
  STRUCT('unit_changed_6m_feature_rows', (SELECT COUNTIF(old_6m IS DISTINCT FROM unit_fixed_6m) FROM features)),
  STRUCT('unit_changed_expected_growth_rows', (SELECT COUNTIF(old_expected_growth IS DISTINCT FROM unit_fixed_expected_growth) FROM features)),
  STRUCT('calendar_changed_ttm_rows', (SELECT COUNTIF(ttm_changed_by_continuity) FROM features)),
  STRUCT('calendar_changed_3m_rows', (SELECT COUNTIF(avg3_changed_by_continuity) FROM features)),
  STRUCT('calendar_changed_6m_rows', (SELECT COUNTIF(avg6_changed_by_continuity) FROM features)),
  STRUCT('calendar_changed_any_feature_rows', (SELECT COUNTIF(ttm_changed_by_continuity OR avg3_changed_by_continuity OR avg6_changed_by_continuity) FROM features)),
  STRUCT('research_observations', (SELECT COUNT(*) FROM research)),
  STRUCT('research_unit_changed_expected_growth_observations', (SELECT COUNTIF(old_expected_growth IS DISTINCT FROM unit_fixed_expected_growth) FROM joined)),
  STRUCT('research_calendar_changed_feature_observations', (SELECT COUNTIF(ttm_changed_by_continuity OR avg3_changed_by_continuity OR avg6_changed_by_continuity) FROM joined)),
  STRUCT('research_canonical_yoy_source_mismatches', (SELECT COUNTIF(yoy_growth IS DISTINCT FROM yoy_growth_pct) FROM joined WHERE yoy_growth_pct IS NOT NULL OR yoy_growth IS NOT NULL))
])
ORDER BY metric
"""

GAP_DETAILS_SQL = f"""
WITH
{SOURCE_CTE},
ordered AS (
  SELECT
    *,
    LAG(revenue_month_date) OVER (PARTITION BY ticker ORDER BY revenue_month_date) AS previous_month
  FROM source_monthly
  WHERE revenue_month_date IS NOT NULL
)
SELECT
  ticker,
  FORMAT_DATE('%Y-%m', previous_month) AS previous_revenue_month,
  year_month AS current_revenue_month,
  DATE_DIFF(revenue_month_date, previous_month, MONTH) - 1 AS missing_months
FROM ordered
WHERE DATE_DIFF(revenue_month_date, previous_month, MONTH) > 1
ORDER BY missing_months DESC, ticker, current_revenue_month
"""

QUERIES = {
    "unit_contract": UNIT_CONTRACT_SQL,
    "unit_samples": UNIT_SAMPLES_SQL,
    "calendar_gaps": CALENDAR_GAPS_SQL,
    "feature_impact": FEATURE_IMPACT_SQL,
    "gap_details": GAP_DETAILS_SQL,
}


def check_read_only(sql: str) -> None:
    upper = sql.upper()
    if not upper.lstrip().startswith(("SELECT", "WITH")) or any(token in upper for token in FORBIDDEN):
        raise ValueError("non-read-only SQL rejected")


def json_safe(value):
    if hasattr(value, "isoformat"):
        return value.isoformat()
    return value


def main() -> None:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--dry-run", action="store_true")
    mode.add_argument("--execute", action="store_true")
    args = parser.parse_args()

    client = bigquery.Client(project=PROJECT)
    OUT.mkdir(parents=True, exist_ok=True)
    manifest = {
        "started_at": datetime.now(timezone.utc).isoformat(),
        "statement_type": "SELECT_ONLY",
        "stages": {},
    }
    for name, sql in QUERIES.items():
        check_read_only(sql)
        dry_job = client.query(sql, job_config=bigquery.QueryJobConfig(dry_run=True, use_query_cache=False))
        stage = {"dry_run_bytes": int(dry_job.total_bytes_processed), "status": "DRY_RUN_OK"}
        if args.execute:
            job = client.query(sql)
            rows = [dict(row.items()) for row in job.result()]
            path = OUT / f"{name}.json"
            path.write_text(json.dumps(rows, default=json_safe, indent=2, sort_keys=True) + "\n")
            stage.update({
                "status": "COMPLETED",
                "job_id": job.job_id,
                "bytes_processed": int(job.total_bytes_processed),
                "bytes_billed": int(job.total_bytes_billed),
                "row_count": len(rows),
                "output": str(path.relative_to(OUT.parent)),
            })
        manifest["stages"][name] = stage
        (OUT / "progress_manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    manifest["total_dry_run_bytes"] = sum(stage["dry_run_bytes"] for stage in manifest["stages"].values())
    (OUT / "progress_manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(json.dumps(manifest, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
