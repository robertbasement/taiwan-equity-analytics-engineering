#!/usr/bin/env python3
"""Read-only, resumable blast-radius measurement for material price anomalies.

This script embeds the already-frozen 360-row reverse-QA population into SELECT
queries.  It never creates a BigQuery object.  Run --dry-run before --execute.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path

from google.cloud import bigquery


HERE = Path(__file__).resolve().parent
INPUT = HERE / "output" / "material_population_360.json"
OUT = HERE / "output"
PROGRESS = OUT / "blast_radius_progress.json"
PROJECT = "stock-backtest-491815"


def now_utc() -> str:
    return datetime.now(timezone.utc).isoformat()


def load_progress() -> dict:
    if PROGRESS.exists():
        return json.loads(PROGRESS.read_text(encoding="utf-8"))
    return {"created_at": now_utc(), "stages": {}}


def save_progress(progress: dict) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    PROGRESS.write_text(json.dumps(progress, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def anomaly_cte(rows: list[dict]) -> str:
    structs = []
    for i, row in enumerate(rows, 1):
        ticker = str(row["ticker"]).replace("'", "''")
        structs.append(
            "STRUCT("
            f"{i} AS anomaly_id, '{ticker}' AS ticker, "
            f"DATE '{row['prev_quote_date']}' AS prev_quote_date, "
            f"DATE '{row['date']}' AS quote_date, "
            f"{float(row['adjusted_return']):.17g} AS adjusted_return)"
        )
    return "anomalies AS (SELECT * FROM UNNEST([\n    " + ",\n    ".join(structs) + "\n  ]))"


def common_sql(rows: list[dict]) -> str:
    return f"""
WITH
{anomaly_cte(rows)},
research AS (
  SELECT *
  FROM `{PROJECT}.stock_analytics.mart_factor_research_monthly`
),
research_span AS (
  SELECT MIN(rebalance_date) AS min_date,
         MAX(next_rebalance_date) AS max_date
  FROM research
),
research_tickers AS (
  SELECT DISTINCT ticker FROM research
),
direct_rel AS (
  SELECT
    r.rebalance_date, r.next_rebalance_date, r.ticker,
    r.forward_return_eligible, r.forward_return, r.yoy_growth,
    a.anomaly_id, a.prev_quote_date, a.quote_date, a.adjusted_return
  FROM research r
  JOIN anomalies a USING (ticker)
  WHERE a.quote_date > r.rebalance_date
    AND a.quote_date <= r.next_rebalance_date
),
price_positions AS (
  SELECT ticker, date,
         ROW_NUMBER() OVER (PARTITION BY ticker ORDER BY date) AS price_row
  FROM `{PROJECT}.stock_analytics.int_daily_prices_adjusted`
  WHERE date >= DATE '2009-01-01'
),
anomaly_positions AS (
  SELECT a.*, p.price_row AS anomaly_price_row
  FROM anomalies a
  JOIN price_positions p
    ON p.ticker = a.ticker AND p.date = a.quote_date
),
research_positions AS (
  SELECT r.rebalance_date, r.next_rebalance_date, r.ticker,
         r.forward_return_eligible, r.forward_return, r.yoy_growth,
         r.price_ma20_gap, r.price_ma60_gap, p.price_row AS research_price_row
  FROM research r
  JOIN price_positions p
    ON p.ticker = r.ticker AND p.date = r.rebalance_date
),
feature_rel AS (
  SELECT
    r.rebalance_date, r.ticker, a.anomaly_id, a.quote_date,
    r.research_price_row - a.anomaly_price_row AS rows_after_anomaly,
    (r.research_price_row BETWEEN a.anomaly_price_row AND a.anomaly_price_row + 19) AS ma20_exposed,
    (r.research_price_row BETWEEN a.anomaly_price_row AND a.anomaly_price_row + 59) AS ma60_exposed
  FROM research_positions r
  JOIN anomaly_positions a USING (ticker)
  WHERE r.research_price_row BETWEEN a.anomaly_price_row AND a.anomaly_price_row + 59
),
evaluation_base AS (
  SELECT r.*,
         PERCENTILE_CONT(yoy_growth, 0.01) OVER (PARTITION BY rebalance_date) AS p01,
         PERCENTILE_CONT(yoy_growth, 0.99) OVER (PARTITION BY rebalance_date) AS p99
  FROM research r
  WHERE rebalance_date BETWEEN DATE '2018-01-01' AND DATE '2025-12-31'
    AND d_close > 0
    AND ticker != '0050'
    AND yoy_growth IS NOT NULL
    AND NOT IS_NAN(yoy_growth)
    AND NOT IS_INF(yoy_growth)
),
evaluation_trimmed AS (
  SELECT *
  FROM evaluation_base
  WHERE yoy_growth BETWEEN p01 AND p99
),
evaluation_dates AS (
  SELECT rebalance_date
  FROM evaluation_trimmed
  GROUP BY rebalance_date
  HAVING COUNT(*) >= 10 AND COUNT(DISTINCT yoy_growth) >= 5
),
evaluation_formation AS (
  SELECT e.rebalance_date, e.ticker, e.forward_return_eligible
  FROM evaluation_trimmed e
  JOIN evaluation_dates USING (rebalance_date)
),
direct_keys AS (
  SELECT DISTINCT rebalance_date, ticker FROM direct_rel
),
direct_eligible_keys AS (
  SELECT DISTINCT rebalance_date, ticker FROM direct_rel WHERE forward_return_eligible
),
feature_keys AS (
  SELECT DISTINCT rebalance_date, ticker FROM feature_rel
),
ma20_keys AS (
  SELECT DISTINCT rebalance_date, ticker FROM feature_rel WHERE ma20_exposed
),
ma60_keys AS (
  SELECT DISTINCT rebalance_date, ticker FROM feature_rel WHERE ma60_exposed
)
"""


def metrics_sql(rows: list[dict]) -> str:
    return common_sql(rows) + """
SELECT
  (SELECT COUNT(*) FROM research) AS total_research_observations,
  (SELECT COUNT(DISTINCT ticker) FROM research) AS total_research_tickers,
  (SELECT COUNT(DISTINCT rebalance_date) FROM research) AS total_research_months,
  (SELECT min_date FROM research_span) AS research_min_date,
  (SELECT max_date FROM research_span) AS research_max_endpoint_date,
  (SELECT COUNT(*) FROM anomalies a CROSS JOIN research_span s
    WHERE a.quote_date BETWEEN s.min_date AND s.max_date) AS anomalies_in_research_span,
  (SELECT COUNT(*) FROM anomalies a JOIN research_tickers r USING (ticker)) AS anomalies_with_research_ticker,
  (SELECT COUNT(DISTINCT a.ticker) FROM anomalies a JOIN research_tickers r USING (ticker)) AS anomaly_research_tickers,
  (SELECT COUNT(*) FROM direct_rel) AS direct_relationships,
  (SELECT COUNT(*) FROM direct_keys) AS direct_observations,
  (SELECT COUNT(*) FROM direct_eligible_keys) AS direct_forward_return_eligible_observations,
  (SELECT COUNT(DISTINCT ticker) FROM direct_keys) AS direct_tickers,
  (SELECT COUNT(DISTINCT rebalance_date) FROM direct_keys) AS direct_months,
  (SELECT COUNT(*) FROM feature_rel) AS feature_relationships,
  (SELECT COUNT(*) FROM feature_keys) AS any_ma_feature_observations,
  (SELECT COUNT(*) FROM ma20_keys) AS ma20_feature_observations,
  (SELECT COUNT(*) FROM ma60_keys) AS ma60_feature_observations,
  (SELECT COUNT(DISTINCT ticker) FROM feature_keys) AS feature_tickers,
  (SELECT COUNT(DISTINCT rebalance_date) FROM feature_keys) AS feature_months,
  (SELECT COUNT(*) FROM evaluation_formation) AS yoy_evaluation_formation_observations,
  (SELECT COUNT(*) FROM evaluation_formation WHERE forward_return_eligible) AS yoy_evaluation_return_observations,
  (SELECT COUNT(*) FROM evaluation_formation e JOIN direct_keys d USING (rebalance_date, ticker)) AS yoy_eval_direct_formation_observations,
  (SELECT COUNT(*) FROM evaluation_formation e JOIN direct_eligible_keys d USING (rebalance_date, ticker)
    WHERE e.forward_return_eligible) AS yoy_eval_direct_return_observations,
  (SELECT COUNT(*) FROM evaluation_formation e JOIN feature_keys f USING (rebalance_date, ticker)) AS yoy_eval_feature_observations,
  SAFE_DIVIDE((SELECT COUNT(*) FROM direct_keys), (SELECT COUNT(*) FROM research)) AS direct_observation_pct,
  SAFE_DIVIDE((SELECT COUNT(*) FROM feature_keys), (SELECT COUNT(*) FROM research)) AS feature_observation_pct,
  SAFE_DIVIDE(
    (SELECT COUNT(*) FROM evaluation_formation e JOIN direct_eligible_keys d USING (rebalance_date, ticker) WHERE e.forward_return_eligible),
    (SELECT COUNT(*) FROM evaluation_formation WHERE forward_return_eligible)
  ) AS yoy_eval_direct_return_pct,
  SAFE_DIVIDE(
    (SELECT COUNT(*) FROM evaluation_formation e JOIN feature_keys f USING (rebalance_date, ticker)),
    (SELECT COUNT(*) FROM evaluation_formation)
  ) AS yoy_eval_feature_pct
"""


def detail_sql(rows: list[dict]) -> str:
    return common_sql(rows) + """
SELECT 'DIRECT_FORWARD_RETURN' AS exposure_type,
       rebalance_date, ticker, anomaly_id, quote_date,
       CAST(NULL AS INT64) AS rows_after_anomaly,
       CAST(NULL AS BOOL) AS ma20_exposed,
       CAST(NULL AS BOOL) AS ma60_exposed,
       forward_return_eligible,
       EXISTS(SELECT 1 FROM evaluation_formation e
              WHERE e.rebalance_date = d.rebalance_date AND e.ticker = d.ticker) AS in_yoy_evaluation_formation
FROM direct_rel d
UNION ALL
SELECT 'PRICE_FEATURE_LOOKBACK',
       rebalance_date, ticker, anomaly_id, quote_date,
       rows_after_anomaly, ma20_exposed, ma60_exposed,
       CAST(NULL AS BOOL),
       EXISTS(SELECT 1 FROM evaluation_formation e
              WHERE e.rebalance_date = f.rebalance_date AND e.ticker = f.ticker)
FROM feature_rel f
ORDER BY exposure_type, rebalance_date, ticker, anomaly_id
"""


def serialize_row(row) -> dict:
    result = {}
    for key, value in dict(row).items():
        result[key] = value.isoformat() if hasattr(value, "isoformat") else value
    return result


def write_csv(path: Path, rows: list[dict]) -> None:
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def main() -> None:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--dry-run", action="store_true")
    mode.add_argument("--execute", action="store_true")
    args = parser.parse_args()

    anomalies = json.loads(INPUT.read_text(encoding="utf-8"))
    if len(anomalies) != 360:
        raise RuntimeError(f"Expected frozen 360-row material population, got {len(anomalies)}")
    client = bigquery.Client(project=PROJECT)
    queries = {"metrics": metrics_sql(anomalies), "exposure_details": detail_sql(anomalies)}
    progress = load_progress()
    progress["input_path"] = str(INPUT)
    progress["input_sha256"] = hashlib.sha256(INPUT.read_bytes()).hexdigest()
    progress["material_anomaly_rows"] = len(anomalies)

    dry_results = {}
    for name, sql in queries.items():
        if not sql.lstrip().upper().startswith("WITH") or any(
            token in sql.upper() for token in ("CREATE ", "REPLACE ", "INSERT ", "UPDATE ", "DELETE ", "MERGE ")
        ):
            raise RuntimeError(f"Non-read-only SQL rejected for {name}")
        job = client.query(sql, job_config=bigquery.QueryJobConfig(dry_run=True, use_query_cache=False))
        dry_results[name] = {"estimated_bytes": job.total_bytes_processed}
    progress["stages"]["dry_run"] = {
        "status": "COMPLETED", "timestamp": now_utc(), "queries": dry_results,
        "total_estimated_bytes": sum(item["estimated_bytes"] for item in dry_results.values()),
    }
    save_progress(progress)
    print(json.dumps(progress["stages"]["dry_run"], indent=2, sort_keys=True))
    if args.dry_run:
        return

    for name, sql in queries.items():
        output_json = OUT / f"research_{name}.json"
        output_csv = OUT / f"research_{name}.csv"
        job = client.query(sql)
        rows = [serialize_row(row) for row in job.result()]
        output_json.write_text(json.dumps(rows, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        write_csv(output_csv, rows)
        progress["stages"][name] = {
            "status": "COMPLETED", "timestamp": now_utc(), "query_job_id": job.job_id,
            "bytes_processed": job.total_bytes_processed, "bytes_billed": job.total_bytes_billed,
            "row_count": len(rows), "output_json": str(output_json), "output_csv": str(output_csv),
        }
        save_progress(progress)
    print(json.dumps(progress, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
