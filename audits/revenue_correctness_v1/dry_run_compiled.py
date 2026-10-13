#!/usr/bin/env python3
"""BigQuery dry-run the corrected compiled models and focused singular tests."""

from __future__ import annotations

import json
from pathlib import Path

from google.cloud import bigquery


ROOT = Path(__file__).resolve().parents[2]
COMPILED = ROOT / "target" / "compiled" / "bq_dbt_analytics"
FILES = {
    "int_monthly_revenue_features": COMPILED / "models/intermediate/int_monthly_revenue_features.sql",
    "mart_expectation_features": COMPILED / "models/marts/expectation/mart_expectation_features.sql",
    "test_stg_monthly_revenue_unique": COMPILED / "tests/test_stg_monthly_revenue_unique.sql",
    "test_revenue_trend_requires_calendar_continuity": COMPILED / "tests/test_revenue_trend_requires_calendar_continuity.sql",
    "test_expectation_revenue_features_contract": COMPILED / "tests/test_expectation_revenue_features_contract.sql",
}


def main() -> None:
    client = bigquery.Client(project="stock-backtest-491815")
    results = {}
    for name, path in FILES.items():
        sql = path.read_text()
        if not sql.lstrip().upper().startswith(("SELECT", "WITH")):
            raise ValueError(f"compiled {name} is not read-only")
        job = client.query(sql, job_config=bigquery.QueryJobConfig(dry_run=True, use_query_cache=False))
        results[name] = {"status": "DRY_RUN_OK", "estimated_bytes": int(job.total_bytes_processed)}
    output = ROOT / "audits/revenue_correctness_v1/output/compiled_dry_runs.json"
    output.write_text(json.dumps(results, indent=2, sort_keys=True) + "\n")
    print(json.dumps(results, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
