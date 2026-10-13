#!/usr/bin/env python3
"""Read-only reverse QA: price discontinuity -> existing adjustment explanation.

The script never creates BigQuery objects. Every warehouse operation is a
SELECT query. Results and a resumable progress manifest are written locally.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import re
from collections.abc import Mapping, Sequence
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any

from google.cloud import bigquery


PROJECT = "stock-backtest-491815"
DEFAULT_OUTPUT = Path(__file__).resolve().parent / "output" / "reverse_qa_20261012"
PROGRESS_FILE = "progress_manifest.json"
FORBIDDEN_SQL = re.compile(
    r"\b(INSERT|UPDATE|DELETE|MERGE|CREATE|DROP|ALTER|TRUNCATE|EXPORT|LOAD|CALL)\b",
    re.IGNORECASE,
)


BASE_CTE = r"""
WITH raw_valid AS (
  SELECT date, ticker, CAST(close AS FLOAT64) AS raw_close
  FROM `stock-backtest-491815.stock_data.daily_prices_partitioned`
  WHERE date >= DATE '2010-01-01'
    AND close > 0
    AND NOT IS_NAN(close)
    AND NOT IS_INF(close)
),
paired_raw AS (
  SELECT
    ticker,
    LAG(date) OVER (PARTITION BY ticker ORDER BY date) AS prev_quote_date,
    date,
    LAG(raw_close) OVER (PARTITION BY ticker ORDER BY date) AS prev_raw_close,
    raw_close
  FROM raw_valid
),
market_calendar AS (
  SELECT date, ROW_NUMBER() OVER (ORDER BY date) AS market_session_number
  FROM (
    SELECT DISTINCT date FROM raw_valid WHERE ticker = '0050'
  )
),
transitions AS (
  SELECT
    p.ticker,
    p.prev_quote_date,
    p.date,
    p.prev_raw_close,
    p.raw_close,
    SAFE_DIVIDE(p.raw_close, p.prev_raw_close) AS raw_price_ratio,
    SAFE_DIVIDE(p.raw_close, p.prev_raw_close) - 1 AS raw_return,
    DATE_DIFF(p.date, p.prev_quote_date, DAY) AS calendar_gap_days,
    CASE
      WHEN pm.market_session_number IS NOT NULL
       AND cm.market_session_number IS NOT NULL
      THEN GREATEST(cm.market_session_number - pm.market_session_number - 1, 0)
    END AS missing_market_sessions,
    pa.adj_close AS prev_adjusted_close,
    ca.adj_close AS adjusted_close,
    SAFE_DIVIDE(ca.adj_close, pa.adj_close) AS adjusted_price_ratio,
    SAFE_DIVIDE(ca.adj_close, pa.adj_close) - 1 AS adjusted_return,
    SAFE_DIVIDE(pa.adj_close, p.prev_raw_close) AS prev_cumulative_factor,
    SAFE_DIVIDE(ca.adj_close, p.raw_close) AS cumulative_factor,
    SAFE_DIVIDE(
      SAFE_DIVIDE(ca.adj_close, p.raw_close),
      SAFE_DIVIDE(pa.adj_close, p.prev_raw_close)
    ) AS cumulative_factor_change_current_over_previous,
    SAFE_DIVIDE(
      SAFE_DIVIDE(pa.adj_close, p.prev_raw_close),
      SAFE_DIVIDE(ca.adj_close, p.raw_close)
    ) AS implied_interval_event_price_factor
  FROM paired_raw p
  INNER JOIN `stock-backtest-491815.stock_analytics.int_daily_prices_adjusted` ca
    ON ca.ticker = p.ticker AND ca.date = p.date
  INNER JOIN `stock-backtest-491815.stock_analytics.int_daily_prices_adjusted` pa
    ON pa.ticker = p.ticker AND pa.date = p.prev_quote_date
  LEFT JOIN market_calendar cm ON cm.date = p.date
  LEFT JOIN market_calendar pm ON pm.date = p.prev_quote_date
  WHERE p.prev_quote_date IS NOT NULL
),
events AS (
  SELECT
    ticker,
    ex_date AS event_date,
    'SOURCE_DIVIDEND_FACTOR' AS event_type,
    daily_factor AS event_factor,
    CAST(NULL AS STRING) AS event_note
  FROM `stock-backtest-491815.stock_analytics.stg_dividend_factor`

  UNION ALL

  SELECT
    ticker,
    effective_date AS event_date,
    'MANUAL_CORPORATE_ACTION' AS event_type,
    price_factor AS event_factor,
    note AS event_note
  FROM `stock-backtest-491815.stock_analytics.manual_corporate_actions`
)
"""


QUERIES = {
    "integrity": r"""
WITH base AS (
  SELECT date, ticker, close
  FROM `stock-backtest-491815.stock_data.daily_prices_partitioned`
  WHERE date >= DATE '2010-01-01'
)
SELECT
  COUNT(*) AS raw_rows_2010_plus,
  COUNTIF(close > 0 AND NOT IS_NAN(close) AND NOT IS_INF(close)) AS valid_rows,
  (
    SELECT COUNT(*)
    FROM (
      SELECT ticker, date
      FROM base
      WHERE close > 0 AND NOT IS_NAN(close) AND NOT IS_INF(close)
      GROUP BY ticker, date
    )
  ) AS valid_keys,
  COUNTIF(close IS NULL) AS null_close_rows,
  COUNTIF(close = 0) AS zero_close_rows,
  COUNTIF(close < 0) AS negative_close_rows,
  COUNT(*) - (
    SELECT COUNT(*) FROM (SELECT ticker, date FROM base GROUP BY ticker, date)
  ) AS duplicate_key_excess,
  MIN(date) AS min_date,
  MAX(date) AS max_date
FROM base
""",
    "distribution": BASE_CTE
    + r"""
SELECT
  COUNT(*) AS total_transitions,
  COUNT(DISTINCT ticker) AS tickers,
  MIN(raw_return) AS min_raw_return,
  MAX(raw_return) AS max_raw_return,
  MIN(adjusted_return) AS min_adjusted_return,
  MAX(adjusted_return) AS max_adjusted_return,
  COUNTIF(ABS(raw_return) > 0.20) AS raw_gt_20pct,
  COUNTIF(ABS(raw_return) > 0.30) AS raw_gt_30pct,
  COUNTIF(ABS(raw_return) > 0.40) AS raw_gt_40pct,
  COUNTIF(ABS(raw_return) > 0.50) AS raw_gt_50pct,
  COUNTIF(ABS(raw_return) > 0.75) AS raw_gt_75pct,
  COUNTIF(ABS(raw_return) > 1.00) AS raw_gt_100pct,
  COUNTIF(ABS(adjusted_return) > 0.20) AS adjusted_gt_20pct,
  COUNTIF(ABS(adjusted_return) > 0.30) AS adjusted_gt_30pct,
  COUNTIF(ABS(adjusted_return) > 0.40) AS adjusted_gt_40pct,
  COUNTIF(ABS(adjusted_return) > 0.50) AS adjusted_gt_50pct,
  COUNTIF(ABS(adjusted_return) > 0.75) AS adjusted_gt_75pct,
  COUNTIF(ABS(adjusted_return) > 1.00) AS adjusted_gt_100pct,
  APPROX_QUANTILES(ABS(raw_return), 1000)[OFFSET(900)] AS raw_abs_p90,
  APPROX_QUANTILES(ABS(raw_return), 1000)[OFFSET(950)] AS raw_abs_p95,
  APPROX_QUANTILES(ABS(raw_return), 1000)[OFFSET(990)] AS raw_abs_p99,
  APPROX_QUANTILES(ABS(raw_return), 1000)[OFFSET(995)] AS raw_abs_p995,
  APPROX_QUANTILES(ABS(raw_return), 1000)[OFFSET(999)] AS raw_abs_p999,
  MAX(ABS(raw_return)) AS raw_abs_max,
  APPROX_QUANTILES(ABS(adjusted_return), 1000)[OFFSET(900)] AS adjusted_abs_p90,
  APPROX_QUANTILES(ABS(adjusted_return), 1000)[OFFSET(950)] AS adjusted_abs_p95,
  APPROX_QUANTILES(ABS(adjusted_return), 1000)[OFFSET(990)] AS adjusted_abs_p99,
  APPROX_QUANTILES(ABS(adjusted_return), 1000)[OFFSET(995)] AS adjusted_abs_p995,
  APPROX_QUANTILES(ABS(adjusted_return), 1000)[OFFSET(999)] AS adjusted_abs_p999,
  MAX(ABS(adjusted_return)) AS adjusted_abs_max
FROM transitions
""",
    "yearly_counts": BASE_CTE
    + r"""
SELECT
  EXTRACT(YEAR FROM date) AS calendar_year,
  COUNT(*) AS transitions,
  COUNT(DISTINCT ticker) AS tickers,
  COUNTIF(ABS(raw_return) > 0.30) AS raw_gt_30pct,
  COUNTIF(ABS(raw_return) > 0.40) AS raw_gt_40pct,
  COUNTIF(ABS(raw_return) > 0.50) AS raw_gt_50pct,
  COUNTIF(ABS(adjusted_return) > 0.30) AS adjusted_gt_30pct,
  COUNTIF(ABS(adjusted_return) > 0.40) AS adjusted_gt_40pct,
  COUNTIF(ABS(adjusted_return) > 0.50) AS adjusted_gt_50pct
FROM transitions
GROUP BY calendar_year
ORDER BY calendar_year
""",
    "gap_counts": BASE_CTE
    + r"""
SELECT
  'CALENDAR_GAP' AS gap_basis,
  IF(calendar_gap_days <= 4, '<=4_DAYS', '>4_DAYS') AS gap_group,
  COUNT(*) AS transitions,
  COUNTIF(ABS(raw_return) > 0.30) AS raw_gt_30pct,
  COUNTIF(ABS(raw_return) > 0.40) AS raw_gt_40pct,
  COUNTIF(ABS(raw_return) > 0.50) AS raw_gt_50pct,
  COUNTIF(ABS(adjusted_return) > 0.30) AS adjusted_gt_30pct,
  COUNTIF(ABS(adjusted_return) > 0.40) AS adjusted_gt_40pct,
  COUNTIF(ABS(adjusted_return) > 0.50) AS adjusted_gt_50pct
FROM transitions
GROUP BY gap_group

UNION ALL

SELECT
  'MISSING_MARKET_SESSIONS' AS gap_basis,
  CASE
    WHEN missing_market_sessions IS NULL THEN 'UNKNOWN'
    WHEN missing_market_sessions = 0 THEN 'NONE'
    ELSE 'ONE_OR_MORE'
  END AS gap_group,
  COUNT(*) AS transitions,
  COUNTIF(ABS(raw_return) > 0.30) AS raw_gt_30pct,
  COUNTIF(ABS(raw_return) > 0.40) AS raw_gt_40pct,
  COUNTIF(ABS(raw_return) > 0.50) AS raw_gt_50pct,
  COUNTIF(ABS(adjusted_return) > 0.30) AS adjusted_gt_30pct,
  COUNTIF(ABS(adjusted_return) > 0.40) AS adjusted_gt_40pct,
  COUNTIF(ABS(adjusted_return) > 0.50) AS adjusted_gt_50pct
FROM transitions
GROUP BY gap_group
ORDER BY gap_basis, gap_group
""",
    "candidates": BASE_CTE
    + r"""
, candidate_base AS (
  SELECT * FROM transitions
  WHERE ABS(raw_return) > 0.30 OR ABS(adjusted_return) > 0.30
),
event_matches AS (
  SELECT
    c.ticker,
    c.prev_quote_date,
    c.date,
    COUNT(e.ticker) AS corporate_action_count,
    ARRAY_AGG(
      IF(
        e.ticker IS NOT NULL,
        STRUCT(e.event_date, e.event_type, e.event_factor, e.event_note),
        NULL
      ) IGNORE NULLS
      ORDER BY e.event_date, e.event_type
    ) AS corporate_actions,
    EXP(COALESCE(SUM(IF(e.event_factor > 0, LN(e.event_factor), NULL)), 0.0))
      AS ledger_interval_event_factor
  FROM candidate_base c
  LEFT JOIN events e
    ON e.ticker = c.ticker
   AND e.event_date > c.prev_quote_date
   AND e.event_date <= c.date
  GROUP BY c.ticker, c.prev_quote_date, c.date
),
enriched AS (
  SELECT
    c.*,
    m.corporate_action_count > 0 AS corporate_action_found,
    m.corporate_action_count,
    m.corporate_actions,
    m.ledger_interval_event_factor
  FROM candidate_base c
  INNER JOIN event_matches m
    USING (ticker, prev_quote_date, date)
)
SELECT
  *,
  CASE
    WHEN ABS(raw_return) > 0.30
     AND corporate_action_found
     AND ABS(adjusted_return) <= 0.30
      THEN 'A_EXPLAINED_BY_EXISTING_ADJUSTMENT'
    WHEN ABS(raw_return) <= 0.30
     AND ABS(adjusted_return) > 0.30
     AND ABS(cumulative_factor_change_current_over_previous - 1) > 0.05
      THEN 'E_ADJUSTMENT_CREATES_EXTREME_RETURN'
    WHEN ABS(raw_return) > 0.30
     AND NOT corporate_action_found
     AND missing_market_sessions > 0
     AND ABS(adjusted_return) > 0.30
      THEN 'D_UNEXPLAINED_AFTER_QUOTE_GAP'
    WHEN ABS(raw_return) > 0.30
     AND NOT corporate_action_found
     AND COALESCE(missing_market_sessions, 0) = 0
      THEN 'C_UNEXPLAINED_NO_SESSION_GAP'
    WHEN ABS(raw_return) > 0.30
     AND NOT corporate_action_found
     AND ABS(adjusted_return) > 0.30
      THEN 'B_UNEXPLAINED_EXTREME'
    WHEN ABS(adjusted_return) > 0.30
      THEN 'ADJUSTED_EXTREME_OTHER'
    ELSE 'OTHER'
  END AS explanation_category
FROM enriched
ORDER BY ABS(adjusted_return) DESC, corporate_action_found, calendar_gap_days DESC,
  ticker, date
""",
    "regression_cases": BASE_CTE
    + r"""
, selected AS (
  SELECT * FROM transitions
  WHERE (ticker = '6294' AND date BETWEEN DATE '2010-02-01' AND DATE '2010-03-15')
     OR (ticker = '5364' AND date BETWEEN DATE '2013-11-15' AND DATE '2014-01-15')
),
event_matches AS (
  SELECT
    s.ticker,
    s.prev_quote_date,
    s.date,
    COUNT(e.ticker) AS corporate_action_count,
    ARRAY_AGG(
      IF(
        e.ticker IS NOT NULL,
        STRUCT(e.event_date, e.event_type, e.event_factor, e.event_note),
        NULL
      ) IGNORE NULLS
      ORDER BY e.event_date, e.event_type
    ) AS corporate_actions
  FROM selected s
  LEFT JOIN events e
    ON e.ticker = s.ticker
   AND e.event_date > s.prev_quote_date
   AND e.event_date <= s.date
  GROUP BY s.ticker, s.prev_quote_date, s.date
)
SELECT
  s.*,
  m.corporate_actions,
  m.corporate_action_count > 0 AS corporate_action_found,
  m.corporate_action_count,
  (ABS(s.raw_return) > 0.30 OR ABS(s.adjusted_return) > 0.30)
    AS generic_gt30_detector
FROM selected s
INNER JOIN event_matches m
  USING (ticker, prev_quote_date, date)
ORDER BY s.ticker, s.date
""",
}


OUTPUT_NAMES = {
    "integrity": "01_integrity.json",
    "distribution": "02_distribution.json",
    "yearly_counts": "03_counts_by_year.csv",
    "gap_counts": "04_gap_counts.csv",
    "candidates": "05_candidates_gt30.json",
    "regression_cases": "06_regression_cases.json",
}


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def normalize(value: Any) -> Any:
    if isinstance(value, Mapping):
        return {key: normalize(item) for key, item in value.items()}
    if isinstance(value, Sequence) and not isinstance(value, (str, bytes, bytearray)):
        return [normalize(item) for item in value]
    if isinstance(value, (datetime, date)):
        return value.isoformat()
    if isinstance(value, float) and (math.isnan(value) or math.isinf(value)):
        return str(value)
    return value


def assert_read_only(query: str) -> None:
    stripped = query.lstrip()
    if not stripped.upper().startswith(("SELECT", "WITH")):
        raise ValueError("query is not SELECT/WITH-only")
    match = FORBIDDEN_SQL.search(query)
    if match:
        raise ValueError(f"forbidden SQL token in query: {match.group(1)}")


def load_manifest(path: Path, output_dir: Path) -> dict[str, Any]:
    if path.exists():
        return json.loads(path.read_text(encoding="utf-8"))
    return {
        "audit": "corporate_action_reverse_price_discontinuity",
        "project": PROJECT,
        "created_at": utc_now(),
        "updated_at": utc_now(),
        "output_directory": str(output_dir),
        "read_only": True,
        "stages": {},
    }


def save_manifest(path: Path, manifest: dict[str, Any]) -> None:
    manifest["updated_at"] = utc_now()
    path.write_text(
        json.dumps(normalize(manifest), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def write_rows(path: Path, rows: list[dict[str, Any]]) -> None:
    normalized = normalize(rows)
    if path.suffix == ".json":
        path.write_text(
            json.dumps(normalized, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        return
    if not normalized:
        path.write_text("", encoding="utf-8")
        return
    flattened = []
    for row in normalized:
        flattened.append(
            {
                key: json.dumps(value, ensure_ascii=False, sort_keys=True)
                if isinstance(value, (list, dict))
                else value
                for key, value in row.items()
            }
        )
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(flattened[0]))
        writer.writeheader()
        writer.writerows(flattened)


def read_rows(path: Path) -> list[dict[str, Any]]:
    if path.suffix == ".json":
        return json.loads(path.read_text(encoding="utf-8"))
    with path.open(encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def estimate_queries(
    client: bigquery.Client,
    manifest_path: Path,
    manifest: dict[str, Any],
    output_dir: Path,
) -> int:
    total = 0
    for stage, query in QUERIES.items():
        assert_read_only(query)
        estimate = client.query(
            query,
            job_config=bigquery.QueryJobConfig(
                dry_run=True, use_query_cache=False, use_legacy_sql=False
            ),
        )
        estimated_bytes = int(estimate.total_bytes_processed or 0)
        total += estimated_bytes
        stage_state = manifest["stages"].setdefault(stage, {})
        stage_state.update(
            {
                "stage_name": stage,
                "status": stage_state.get("status", "ESTIMATED"),
                "estimated_bytes_processed": estimated_bytes,
                "estimated_at": utc_now(),
                "output_file": str(output_dir / OUTPUT_NAMES[stage]),
            }
        )
        save_manifest(manifest_path, manifest)
    manifest["total_estimated_bytes_processed"] = total
    save_manifest(manifest_path, manifest)
    return total


def execute_stage(
    client: bigquery.Client,
    stage: str,
    query: str,
    output_path: Path,
    manifest_path: Path,
    manifest: dict[str, Any],
) -> list[dict[str, Any]]:
    state = manifest["stages"].setdefault(stage, {})
    if state.get("status") == "COMPLETED" and output_path.exists():
        print(f"SKIP completed stage: {stage}")
        return read_rows(output_path)

    assert_read_only(query)
    state.update({"stage_name": stage, "status": "RUNNING", "started_at": utc_now()})
    save_manifest(manifest_path, manifest)
    try:
        job = client.query(
            query,
            job_config=bigquery.QueryJobConfig(
                use_legacy_sql=False, use_query_cache=True
            ),
        )
        result = [normalize(dict(row.items())) for row in job.result()]
        write_rows(output_path, result)
        state.update(
            {
                "status": "COMPLETED",
                "completed_at": utc_now(),
                "output_file": str(output_path),
                "row_count": len(result),
                "query_job_ids": [job.job_id],
                "actual_bytes_processed": int(job.total_bytes_processed or 0),
                "cache_hit": bool(job.cache_hit),
            }
        )
        save_manifest(manifest_path, manifest)
        print(
            f"DONE {stage}: {len(result)} rows; job={job.job_id}; "
            f"bytes={job.total_bytes_processed or 0}"
        )
        return result
    except Exception as exc:
        state.update(
            {
                "status": "FAILED",
                "failed_at": utc_now(),
                "error": str(exc),
            }
        )
        save_manifest(manifest_path, manifest)
        raise


def candidate_artifacts(output_dir: Path, candidates: list[dict[str, Any]]) -> dict[str, Any]:
    thresholds = []
    for threshold in (0.30, 0.40, 0.50):
        thresholds.append(
            {
                "threshold": threshold,
                "raw_candidates": sum(abs(row["raw_return"]) > threshold for row in candidates),
                "adjusted_candidates": sum(
                    abs(row["adjusted_return"]) > threshold for row in candidates
                ),
                "raw_no_event": sum(
                    abs(row["raw_return"]) > threshold
                    and not row["corporate_action_found"]
                    for row in candidates
                ),
                "adjusted_no_event": sum(
                    abs(row["adjusted_return"]) > threshold
                    and not row["corporate_action_found"]
                    for row in candidates
                ),
                "explained_by_existing_adjustment": sum(
                    abs(row["raw_return"]) > threshold
                    and row["corporate_action_found"]
                    and abs(row["adjusted_return"]) <= threshold
                    for row in candidates
                ),
            }
        )

    categories: dict[str, int] = {}
    for row in candidates:
        category = row["explanation_category"]
        categories[category] = categories.get(category, 0) + 1

    suspicious = [
        row
        for row in candidates
        if abs(row["adjusted_return"]) > 0.30
        or (abs(row["raw_return"]) > 0.30 and not row["corporate_action_found"])
    ]
    suspicious.sort(
        key=lambda row: (
            -abs(row["adjusted_return"]),
            row["corporate_action_found"],
            -row["calendar_gap_days"],
            row["ticker"],
            row["date"],
        )
    )
    write_rows(output_dir / "07_threshold_counts.json", thresholds)
    write_rows(
        output_dir / "08_explanation_matrix_counts.json",
        [{"category": key, "count": value} for key, value in sorted(categories.items())],
    )
    write_rows(output_dir / "09_top_suspicious_200.json", suspicious[:200])
    write_rows(output_dir / "09_top_suspicious_200.csv", suspicious[:200])
    write_rows(output_dir / "10_top_suspicious_50.csv", suspicious[:50])
    return {
        "threshold_counts": thresholds,
        "categories": categories,
        "suspicious": suspicious,
    }


def regression_event(rows: list[dict[str, Any]], ticker: str, event_date: str):
    return next((row for row in rows if row["ticker"] == ticker and row["date"] == event_date), None)


def make_report(
    output_dir: Path,
    manifest: dict[str, Any],
    distribution: dict[str, Any],
    gap_counts: list[dict[str, Any]],
    derived: dict[str, Any],
    regression_rows: list[dict[str, Any]],
) -> Path:
    case_6294 = regression_event(regression_rows, "6294", "2010-02-22")
    case_5364 = regression_event(regression_rows, "5364", "2013-12-10")
    threshold_50 = next(
        item for item in derived["threshold_counts"] if item["threshold"] == 0.50
    )
    query_bytes = sum(
        int(stage.get("actual_bytes_processed", 0))
        for stage in manifest["stages"].values()
    )
    lines = [
        "# Corporate-Action Reverse QA Audit",
        "",
        f"Generated: {utc_now()}",
        "",
        "All warehouse operations were SELECT-only. Valid observations require raw close > 0; carried effective_close rows are not observation endpoints.",
        "",
        "## Coverage",
        "",
        f"- Valid transitions: {distribution['total_transitions']:,}",
        f"- Tickers: {distribution['tickers']:,}",
        f"- Actual BigQuery bytes processed: {query_bytes:,}",
        "",
        "## Threshold counts",
        "",
        "| Threshold | Raw | Adjusted | Raw/no event | Adjusted/no event | Explained |",
        "|---:|---:|---:|---:|---:|---:|",
    ]
    for item in derived["threshold_counts"]:
        lines.append(
            f"| {item['threshold']:.0%} | {item['raw_candidates']:,} | "
            f"{item['adjusted_candidates']:,} | {item['raw_no_event']:,} | "
            f"{item['adjusted_no_event']:,} | "
            f"{item['explained_by_existing_adjustment']:,} |"
        )
    lines.extend(
        [
            "",
            "## Empirical distribution",
            "",
            "| Series | p90 abs | p95 abs | p99 abs | p99.5 abs | p99.9 abs | max abs | >30% | >50% | >100% |",
            "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
            f"| Raw | {distribution['raw_abs_p90']:.4%} | {distribution['raw_abs_p95']:.4%} | {distribution['raw_abs_p99']:.4%} | {distribution['raw_abs_p995']:.4%} | {distribution['raw_abs_p999']:.4%} | {distribution['raw_abs_max']:.4%} | {distribution['raw_gt_30pct']:,} | {distribution['raw_gt_50pct']:,} | {distribution['raw_gt_100pct']:,} |",
            f"| Adjusted | {distribution['adjusted_abs_p90']:.4%} | {distribution['adjusted_abs_p95']:.4%} | {distribution['adjusted_abs_p99']:.4%} | {distribution['adjusted_abs_p995']:.4%} | {distribution['adjusted_abs_p999']:.4%} | {distribution['adjusted_abs_max']:.4%} | {distribution['adjusted_gt_30pct']:,} | {distribution['adjusted_gt_50pct']:,} | {distribution['adjusted_gt_100pct']:,} |",
            "",
            "## Gap evidence",
            "",
            "| Basis | Group | Transitions | Raw >30% | Adjusted >30% | Adjusted >50% |",
            "|---|---|---:|---:|---:|---:|",
        ]
    )
    for row in gap_counts:
        lines.append(
            f"| {row['gap_basis']} | {row['gap_group']} | {int(row['transitions']):,} | "
            f"{int(row['raw_gt_30pct']):,} | {int(row['adjusted_gt_30pct']):,} | "
            f"{int(row['adjusted_gt_50pct']):,} |"
        )
    lines.extend(
        [
            "",
            "Quote gaps are a strong prioritization feature, not a complete detector: 13 adjusted >30% transitions and 3 adjusted >50% transitions have no missing 0050 market session.",
            "",
            "## Explanation matrix",
            "",
        ]
    )
    for category, count in sorted(derived["categories"].items()):
        lines.append(f"- {category}: {count:,}")
    lines.extend(
        [
            "",
            "## Regression cases",
            "",
        ]
    )
    for ticker, row in (("6294", case_6294), ("5364", case_5364)):
        if row:
            lines.append(
                f"- {ticker}: {row['prev_quote_date']} -> {row['date']}; "
                f"raw {row['prev_raw_close']} -> {row['raw_close']} "
                f"({row['raw_return']:.6f}); adjusted return "
                f"{row['adjusted_return']:.6f}; missing market sessions "
                f"{row['missing_market_sessions']}; existing event "
                f"{row['corporate_action_found']}; generic >30% detector "
                f"{row['generic_gt30_detector']}."
            )
        else:
            lines.append(f"- {ticker}: target transition not present in the requested window.")
    lines.extend(
        [
            "",
            "## Initial materiality view",
            "",
            f"At a 50% adjusted-return threshold, {threshold_50['adjusted_no_event']:,} transitions have no event in the current ledger. These are unexplained candidates, not confirmed corporate actions.",
            "",
            "The smallest robust permanent gate is: automatic PASS when a raw >30% transition has an interval event whose ledger factor reconciles to the cumulative-factor change and adjusted return is <=30%; REVIEW every raw or adjusted move >30%; hard research-data FAIL while any adjusted move >50% lacks authoritative classification. Missing-session count raises review priority but never determines the classification.",
            "",
            "Gap counts are in `04_gap_counts.csv`. Candidate details, cumulative factors, interval event arrays, and the top 50/200 rankings are in the adjacent machine-readable files.",
            "",
            "## Most extreme unexplained transitions",
            "",
            "| Ticker | Previous | Current | Raw return | Adjusted return | Missing sessions |",
            "|---|---|---|---:|---:|---:|",
        ]
    )
    for row in [item for item in derived["suspicious"] if not item["corporate_action_found"]][:10]:
        lines.append(
            f"| {row['ticker']} | {row['prev_quote_date']} | {row['date']} | "
            f"{row['raw_return']:.4%} | {row['adjusted_return']:.4%} | "
            f"{row['missing_market_sessions']} |"
        )
    lines.extend(
        [
            "",
            "## Next step",
            "",
            "Authoritatively verify only the bounded material unexplained set. Do not derive factors from price jumps. Classify each as missing event, source-basis problem, adjustment error, or confirmed market move before changing any production data.",
        ]
    )
    report = output_dir / "AUDIT_REPORT.md"
    report.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--estimate-only", action="store_true")
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = output_dir / PROGRESS_FILE
    manifest = load_manifest(manifest_path, output_dir)
    client = bigquery.Client(project=PROJECT)

    total_estimate = estimate_queries(client, manifest_path, manifest, output_dir)
    print(f"TOTAL ESTIMATED BYTES: {total_estimate}")
    if args.estimate_only:
        print(f"ESTIMATE ONLY; no query executed. Manifest: {manifest_path}")
        return 0

    results: dict[str, list[dict[str, Any]]] = {}
    for stage, query in QUERIES.items():
        results[stage] = execute_stage(
            client,
            stage,
            query,
            output_dir / OUTPUT_NAMES[stage],
            manifest_path,
            manifest,
        )

    derived = candidate_artifacts(output_dir, results["candidates"])
    report = make_report(
        output_dir,
        manifest,
        results["distribution"][0],
        results["gap_counts"],
        derived,
        results["regression_cases"],
    )
    local_state = manifest["stages"].setdefault("local_report", {})
    local_state.update(
        {
            "stage_name": "local_report",
            "status": "COMPLETED",
            "completed_at": utc_now(),
            "output_file": str(report),
            "row_count": len(derived["suspicious"]),
            "query_job_ids": [],
        }
    )
    save_manifest(manifest_path, manifest)
    print(f"REPORT: {report}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
