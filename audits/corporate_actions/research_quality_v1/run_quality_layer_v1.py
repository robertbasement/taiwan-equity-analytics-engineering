#!/usr/bin/env python3
"""Build and evaluate the local, quality-aware monthly research dataset."""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import pandas as pd
import statsmodels.api as sm
from google.cloud import bigquery
import pyarrow.parquet as pq

from research_quality_v1 import apply_quality_layer, assign_revenue_yoy_quintiles, load_anomalies


HERE = Path(__file__).resolve().parent
INPUT = HERE / "input" / "research_price_anomalies_v1.csv"
OUT = HERE / "output"
PROJECT = "stock-backtest-491815"
FORBIDDEN_SQL = ("CREATE ", "REPLACE ", "INSERT ", "UPDATE ", "DELETE ", "MERGE ", "DROP ", "ALTER ")


def anomaly_cte(anomalies: pd.DataFrame) -> str:
    structs = []
    for anomaly_id, row in enumerate(anomalies.itertuples(index=False), 1):
        values = {
            "source": str(row.anomaly_source).replace("'", "''"),
            "reason": str(row.anomaly_reason).replace("'", "''"),
            "ticker": str(row.ticker).replace("'", "''"),
        }
        structs.append(
            "STRUCT("
            f"{anomaly_id} AS anomaly_id, '{values['ticker']}' AS ticker, "
            f"DATE '{row.prev_quote_date:%Y-%m-%d}' AS prev_quote_date, "
            f"DATE '{row.quote_date:%Y-%m-%d}' AS quote_date, "
            f"{float(row.adjusted_return):.17g} AS anomaly_return, "
            f"'{values['source']}' AS anomaly_source, '{values['reason']}' AS quality_reason, "
            f"{str(bool(row.is_material_gt50)).upper()} AS is_material_gt50)"
        )
    return "anomalies AS (SELECT * FROM UNNEST([\n    " + ",\n    ".join(structs) + "\n  ]))"


def relationships_sql(anomalies: pd.DataFrame) -> str:
    return f"""
WITH
{anomaly_cte(anomalies)},
research AS (
  SELECT rebalance_date, next_rebalance_date, ticker
  FROM `{PROJECT}.stock_analytics.mart_factor_research_monthly`
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
  LEFT JOIN price_positions p
    ON p.ticker = a.ticker AND p.date = a.quote_date
),
research_positions AS (
  SELECT r.*, p.price_row AS research_price_row
  FROM research r
  LEFT JOIN price_positions p
    ON p.ticker = r.ticker AND p.date = r.rebalance_date
),
direct AS (
  SELECT r.rebalance_date, r.ticker, 'FORWARD_RETURN' AS quality_component,
         a.anomaly_id, a.ticker AS anomaly_ticker, a.quote_date AS anomaly_date,
         a.anomaly_return, a.anomaly_source, a.quality_reason,
         CAST(NULL AS INT64) AS rows_after_anomaly, a.is_material_gt50
  FROM research r
  JOIN anomalies a USING (ticker)
  WHERE r.rebalance_date < a.quote_date
    AND a.quote_date <= r.next_rebalance_date
),
ma20 AS (
  SELECT r.rebalance_date, r.ticker, 'MA20' AS quality_component,
         a.anomaly_id, a.ticker AS anomaly_ticker, a.quote_date AS anomaly_date,
         a.anomaly_return, a.anomaly_source, a.quality_reason,
         r.research_price_row - a.anomaly_price_row AS rows_after_anomaly, a.is_material_gt50
  FROM research_positions r
  JOIN anomaly_positions a USING (ticker)
  WHERE r.research_price_row BETWEEN a.anomaly_price_row AND a.anomaly_price_row + 18
),
ma60 AS (
  SELECT r.rebalance_date, r.ticker, 'MA60' AS quality_component,
         a.anomaly_id, a.ticker AS anomaly_ticker, a.quote_date AS anomaly_date,
         a.anomaly_return, a.anomaly_source, a.quality_reason,
         r.research_price_row - a.anomaly_price_row AS rows_after_anomaly, a.is_material_gt50
  FROM research_positions r
  JOIN anomaly_positions a USING (ticker)
  WHERE r.research_price_row BETWEEN a.anomaly_price_row AND a.anomaly_price_row + 58
)
SELECT * FROM direct
UNION ALL SELECT * FROM ma20
UNION ALL SELECT * FROM ma60
ORDER BY rebalance_date, ticker, quality_component, anomaly_id
"""


PANEL_SQL = f"""
SELECT
  research_month,
  rebalance_date,
  next_rebalance_date,
  ticker,
  market,
  issuer_origin,
  is_v1_fundamental_eligible,
  effective_close,
  d_close,
  current_raw_close,
  next_raw_close,
  current_adjusted_close,
  next_adjusted_close,
  current_endpoint_observed,
  next_endpoint_observed,
  forward_return_eligible,
  forward_return,
  market_return,
  yoy_growth,
  mom_growth_pct,
  market_cap,
  price_ma20_gap,
  price_ma60_gap
FROM `{PROJECT}.stock_analytics.mart_factor_research_monthly`
ORDER BY rebalance_date, ticker
"""


def ensure_select_only(sql: str) -> None:
    normalized = sql.upper()
    if not normalized.lstrip().startswith(("SELECT", "WITH")) or any(token in normalized for token in FORBIDDEN_SQL):
        raise ValueError("non-read-only SQL rejected")


def run_query(client, sql: str, *, dry_run: bool):
    ensure_select_only(sql)
    config = bigquery.QueryJobConfig(dry_run=dry_run, use_query_cache=False) if dry_run else None
    return client.query(sql, job_config=config)


def normalize_dates(frame: pd.DataFrame) -> pd.DataFrame:
    """Remove BigQuery dbdate extension metadata so local Parquet is portable."""
    result = frame.copy()
    for column in ("research_month", "rebalance_date", "next_rebalance_date", "anomaly_date"):
        if column in result:
            result[column] = pd.to_datetime(result[column], errors="coerce")
    return result


def read_local_parquet(path: Path) -> pd.DataFrame:
    # ignore_metadata also recovers artifacts written by the first interrupted run.
    return normalize_dates(pq.read_table(path).to_pandas(ignore_metadata=True))


def monthly_ic(frame: pd.DataFrame, return_col: str, min_stocks: int = 30) -> pd.Series:
    def one_month(group):
        use = group[["yoy_growth", return_col]].replace([np.inf, -np.inf], np.nan).dropna()
        if len(use) < min_stocks:
            return np.nan
        return use["yoy_growth"].corr(use[return_col], method="spearman")
    return frame.groupby("rebalance_date", sort=True).apply(one_month, include_groups=False).rename("ic")


def ic_summary(series: pd.Series) -> dict:
    values = series.replace([np.inf, -np.inf], np.nan).dropna()
    std = values.std()
    return {
        "mean_ic": float(values.mean()), "std_ic": float(std),
        "icir": float(values.mean() / std) if std else None,
        "positive_ic_pct": float((values > 0).mean()), "n_months": int(len(values)),
    }


def portfolio_returns(frame: pd.DataFrame, return_col: str) -> pd.DataFrame:
    eligible = frame[np.isfinite(pd.to_numeric(frame[return_col], errors="coerce"))].copy()
    monthly = eligible.groupby(["rebalance_date", "portfolio"], sort=True)[return_col].mean().unstack("portfolio")
    monthly = monthly.reindex(columns=[f"Q{i}" for i in range(1, 6)])
    monthly["H-L"] = monthly["Q5"] - monthly["Q1"]
    return monthly


def nw_stats(series: pd.Series, maxlags: int = 3) -> dict:
    values = series.replace([np.inf, -np.inf], np.nan).dropna().astype(float)
    model = sm.OLS(values.to_numpy(), np.ones((len(values), 1))).fit(
        cov_type="HAC", cov_kwds={"maxlags": maxlags}
    )
    return {
        "mean": float(model.params[0]), "nw_se": float(model.bse[0]),
        "nw_tstat": float(model.tvalues[0]), "nw_pvalue": float(model.pvalues[0]),
        "positive_spread_pct": float((values > 0).mean()), "n_months": int(len(values)),
    }


def research_comparison(quality_panel: pd.DataFrame) -> tuple[dict, pd.DataFrame]:
    subset = quality_panel[
        quality_panel["rebalance_date"].between(pd.Timestamp("2018-01-01"), pd.Timestamp("2025-12-31"))
        & (pd.to_numeric(quality_panel["d_close"], errors="coerce") > 0)
        & quality_panel["ticker"].ne("0050")
    ].copy()
    assigned_baseline = assign_revenue_yoy_quintiles(subset)
    assigned_quality = assign_revenue_yoy_quintiles(subset)
    invariant_cols = ["rebalance_date", "ticker", "yoy_growth", "group", "portfolio"]
    left = assigned_baseline[invariant_cols].sort_values(["rebalance_date", "ticker"]).reset_index(drop=True)
    right = assigned_quality[invariant_cols].sort_values(["rebalance_date", "ticker"]).reset_index(drop=True)
    formation_identical = left.equals(right)
    baseline_returns = portfolio_returns(assigned_baseline, "forward_return")
    quality_returns = portfolio_returns(assigned_quality, "forward_return_research")
    baseline_ic = monthly_ic(assigned_baseline, "forward_return")
    quality_ic = monthly_ic(assigned_quality, "forward_return_research")
    comparison = {
        "method": {
            "period": "2018-01-01 through 2025-12-31", "factor": "yoy_growth",
            "benchmark_excluded": "0050", "trim": [0.01, 0.99], "quintiles": 5,
            "tie_break": "ticker ascending", "weighting": "equal weight", "nw_lags": 3,
        },
        "formation": {
            "rows": int(len(assigned_baseline)), "identical": bool(formation_identical),
            "membership_differences": int(len(left.merge(right, how="outer", indicator=True).query("_merge != 'both'"))),
            "factor_value_changes": int((left["yoy_growth"].to_numpy() != right["yoy_growth"].to_numpy()).sum()),
            "quintile_changes": int((left["group"].to_numpy() != right["group"].to_numpy()).sum()),
        },
        "effective_sample": {
            "baseline_return_observations": int(np.isfinite(pd.to_numeric(assigned_baseline["forward_return"], errors="coerce")).sum()),
            "quality_return_observations": int(np.isfinite(pd.to_numeric(assigned_quality["forward_return_research"], errors="coerce")).sum()),
            "excluded_labels": int((assigned_quality["forward_return_quality"].eq("INVALID") & np.isfinite(pd.to_numeric(assigned_quality["forward_return"], errors="coerce"))).sum()),
            "affected_months": int(assigned_quality.loc[assigned_quality["forward_return_quality"].eq("INVALID"), "rebalance_date"].nunique()),
        },
        "ic": {"baseline": ic_summary(baseline_ic), "quality": ic_summary(quality_ic)},
        "quintile_mean_returns": {
            "baseline": {col: float(baseline_returns[col].mean()) for col in baseline_returns.columns},
            "quality": {col: float(quality_returns[col].mean()) for col in quality_returns.columns},
        },
        "spread_newey_west": {
            "baseline": nw_stats(baseline_returns["H-L"]),
            "quality": nw_stats(quality_returns["H-L"]),
        },
    }
    comparison["conclusion_stability"] = {
        "mean_ic_sign_same": bool(np.sign(comparison["ic"]["baseline"]["mean_ic"]) == np.sign(comparison["ic"]["quality"]["mean_ic"])),
        "spread_sign_same": bool(np.sign(comparison["spread_newey_west"]["baseline"]["mean"]) == np.sign(comparison["spread_newey_west"]["quality"]["mean"])),
        "spread_5pct_significance_same": bool(
            (comparison["spread_newey_west"]["baseline"]["nw_pvalue"] < 0.05)
            == (comparison["spread_newey_west"]["quality"]["nw_pvalue"] < 0.05)
        ),
    }
    monthly = baseline_returns.add_prefix("baseline_").join(quality_returns.add_prefix("quality_"), how="outer")
    return comparison, monthly.reset_index()


def main() -> None:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--dry-run", action="store_true")
    mode.add_argument("--execute", action="store_true")
    mode.add_argument("--from-local", action="store_true", help="resume post-processing from saved raw Parquet; no BigQuery access")
    args = parser.parse_args()
    anomalies = load_anomalies(INPUT)
    queries = {"relationships": relationships_sql(anomalies), "monthly_panel": PANEL_SQL}
    OUT.mkdir(parents=True, exist_ok=True)
    if args.from_local:
        progress = json.loads((OUT / "progress_manifest.json").read_text())
        frames = {
            name: read_local_parquet(OUT / f"raw_{name}.parquet")
            for name in queries
        }
    else:
        client = bigquery.Client(project=PROJECT)
        dry = {}
        for name, sql in queries.items():
            job = run_query(client, sql, dry_run=True)
            dry[name] = int(job.total_bytes_processed)
        progress = {
            "started_at": datetime.now(timezone.utc).isoformat(), "statement_type": "SELECT_ONLY",
            "dry_run_estimated_bytes": dry, "total_estimated_bytes": sum(dry.values()), "stages": {},
        }
        (OUT / "progress_manifest.json").write_text(json.dumps(progress, indent=2, sort_keys=True) + "\n")
        print(json.dumps(progress, indent=2, sort_keys=True))
        if args.dry_run:
            return

        frames = {}
        for name, sql in queries.items():
            raw_path = OUT / f"raw_{name}.parquet"
            try:
                job = run_query(client, sql, dry_run=False)
                frames[name] = normalize_dates(job.result().to_dataframe(create_bqstorage_client=False))
                frames[name].to_parquet(raw_path, index=False)
                progress["stages"][name] = {
                    "status": "COMPLETED", "job_id": job.job_id,
                    "bytes_processed": int(job.total_bytes_processed), "bytes_billed": int(job.total_bytes_billed),
                    "row_count": int(len(frames[name])), "output_file": str(raw_path.relative_to(HERE)),
                    "completed_at": datetime.now(timezone.utc).isoformat(),
                }
            except Exception as error:
                progress["stages"][name] = {
                    "status": "FAILED", "error": repr(error),
                    "completed_at": datetime.now(timezone.utc).isoformat(),
                }
                (OUT / "progress_manifest.json").write_text(json.dumps(progress, indent=2, sort_keys=True) + "\n")
                raise
            (OUT / "progress_manifest.json").write_text(json.dumps(progress, indent=2, sort_keys=True) + "\n")

    quality_panel, relationships = apply_quality_layer(frames["monthly_panel"], frames["relationships"])
    quality_panel.to_parquet(OUT / "mart_factor_research_monthly_quality_v1.parquet", index=False)
    relationships.to_csv(OUT / "quality_relationships_v1.csv", index=False)
    comparison, monthly = research_comparison(quality_panel)
    monthly.to_csv(OUT / "revenue_yoy_monthly_comparison.csv", index=False)
    material_relationships = relationships[relationships["is_material_gt50"]]
    control_relationships = relationships[~relationships["is_material_gt50"]]
    canonical = assign_revenue_yoy_quintiles(quality_panel[
        quality_panel["rebalance_date"].between(pd.Timestamp("2018-01-01"), pd.Timestamp("2025-12-31"))
        & (pd.to_numeric(quality_panel["d_close"], errors="coerce") > 0)
        & quality_panel["ticker"].ne("0050")
    ])
    canonical_keys = canonical[["rebalance_date", "ticker"]]
    canonical_material_relationships = material_relationships.merge(
        canonical_keys, on=["rebalance_date", "ticker"], how="inner"
    )
    canonical_control_relationships = control_relationships.merge(
        canonical_keys, on=["rebalance_date", "ticker"], how="inner"
    )
    counts = {
        "total_research_observations": int(len(quality_panel)),
        "invalid_forward_return": int(quality_panel["forward_return_quality"].eq("INVALID").sum()),
        "invalid_ma20": int(quality_panel["ma20_quality"].eq("INVALID").sum()),
        "invalid_ma60": int(quality_panel["ma60_quality"].eq("INVALID").sum()),
        "unknown_forward_return": int(quality_panel["forward_return_quality"].eq("UNKNOWN").sum()),
        "unknown_ma20": int(quality_panel["ma20_quality"].eq("UNKNOWN").sum()),
        "unknown_ma60": int(quality_panel["ma60_quality"].eq("UNKNOWN").sum()),
        "unique_affected_observations": int(len(relationships[["rebalance_date", "ticker"]].drop_duplicates())),
        "unique_affected_tickers": int(relationships["ticker"].nunique()),
        "unique_affected_months": int(relationships["rebalance_date"].nunique()),
        "invalid_existing_forward_return_labels": int((
            quality_panel["forward_return_quality"].eq("INVALID")
            & np.isfinite(pd.to_numeric(quality_panel["forward_return"], errors="coerce"))
        ).sum()),
        "material_unique_affected_observations": int(len(material_relationships[["rebalance_date", "ticker"]].drop_duplicates())),
        "control_2429_unique_affected_observations": int(len(control_relationships[["rebalance_date", "ticker"]].drop_duplicates())),
        "material_only": {
            component: int(relationships[relationships["is_material_gt50"] & relationships["quality_component"].eq(component)][["rebalance_date", "ticker"]].drop_duplicates().shape[0])
            for component in ("FORWARD_RETURN", "MA20", "MA60")
        },
        "control_2429": {
            component: int(relationships[(~relationships["is_material_gt50"]) & relationships["quality_component"].eq(component)][["rebalance_date", "ticker"]].drop_duplicates().shape[0])
            for component in ("FORWARD_RETURN", "MA20", "MA60")
        },
        "canonical_revenue_yoy_2018_2025": {
            "formation_observations": int(len(canonical)),
            "invalid_forward_observations": int(canonical["forward_return_quality"].eq("INVALID").sum()),
            "invalid_existing_forward_return_labels": int((canonical["forward_return_quality"].eq("INVALID") & np.isfinite(pd.to_numeric(canonical["forward_return"], errors="coerce"))).sum()),
            "invalid_ma20_observations": int(canonical["ma20_quality"].eq("INVALID").sum()),
            "invalid_ma60_observations": int(canonical["ma60_quality"].eq("INVALID").sum()),
            "invalid_ma_union_observations": int((canonical["ma20_quality"].eq("INVALID") | canonical["ma60_quality"].eq("INVALID")).sum()),
            "material_invalid_forward_observations": int(canonical_material_relationships[canonical_material_relationships["quality_component"].eq("FORWARD_RETURN")][["rebalance_date", "ticker"]].drop_duplicates().shape[0]),
            "material_invalid_ma_union_observations": int(canonical_material_relationships[canonical_material_relationships["quality_component"].isin(["MA20", "MA60"])][["rebalance_date", "ticker"]].drop_duplicates().shape[0]),
            "control_2429_invalid_forward_observations": int(canonical_control_relationships[canonical_control_relationships["quality_component"].eq("FORWARD_RETURN")][["rebalance_date", "ticker"]].drop_duplicates().shape[0]),
            "control_2429_invalid_ma_union_observations": int(canonical_control_relationships[canonical_control_relationships["quality_component"].isin(["MA20", "MA60"])][["rebalance_date", "ticker"]].drop_duplicates().shape[0]),
        },
        "prior_impact_reconciliation": {
            "prior_material_forward": 155,
            "exact_material_forward": int(material_relationships[material_relationships["quality_component"].eq("FORWARD_RETURN")][["rebalance_date", "ticker"]].drop_duplicates().shape[0]),
            "prior_material_ma20": 235,
            "exact_material_ma20": int(material_relationships[material_relationships["quality_component"].eq("MA20")][["rebalance_date", "ticker"]].drop_duplicates().shape[0]),
            "prior_material_ma60_or_union": 680,
            "exact_material_ma60_or_union": int(material_relationships[material_relationships["quality_component"].eq("MA60")][["rebalance_date", "ticker"]].drop_duplicates().shape[0]),
            "difference_reason": "V1 uses exact inclusive ROWS frames: the transition stops crossing MA20/MA60 at offsets 19/59; the prior audit conservatively included those clean endpoint rows.",
        },
    }
    source_columns = list(frames["monthly_panel"].columns)
    regression = {}
    for ticker, date in (("6294", "2010-02-22"), ("5364", "2013-12-10"), ("2429", "2024-07-02")):
        matches = relationships[
            relationships["anomaly_ticker"].eq(ticker)
            & relationships["anomaly_date"].eq(pd.Timestamp(date))
        ]
        regression[f"{ticker}_{date}"] = {
            "present_in_anomaly_input": bool(((anomalies["ticker"].eq(ticker)) & anomalies["quote_date"].eq(pd.Timestamp(date))).any()),
            "research_relationships": int(len(matches)),
            "components": {str(k): int(v) for k, v in matches.groupby("quality_component").size().items()},
        }
    acceptance = {
        "input_rows": int(len(anomalies)),
        "input_material_rows": int(anomalies["is_material_gt50"].sum()),
        "input_material_tickers": int(anomalies.loc[anomalies["is_material_gt50"], "ticker"].nunique()),
        "source_rows": int(len(frames["monthly_panel"])),
        "quality_rows": int(len(quality_panel)),
        "duplicate_quality_keys": int(quality_panel.duplicated(["rebalance_date", "ticker"]).sum()),
        "all_original_columns_preserved_exactly": bool(quality_panel[source_columns].equals(frames["monthly_panel"][source_columns])),
        "formation_membership_differences": comparison["formation"]["membership_differences"],
        "revenue_yoy_factor_value_changes": comparison["formation"]["factor_value_changes"],
        "quintile_changes": comparison["formation"]["quintile_changes"],
        "regression_cases": regression,
    }
    progress["stages"]["local_quality_layer"] = {
        "status": "COMPLETED", "job_id": None, "bytes_processed": 0, "bytes_billed": 0,
        "row_count": int(len(quality_panel)),
        "output_file": "output/mart_factor_research_monthly_quality_v1.parquet",
        "completed_at": datetime.now(timezone.utc).isoformat(),
    }
    (OUT / "progress_manifest.json").write_text(json.dumps(progress, indent=2, sort_keys=True) + "\n")
    summary = {"acceptance": acceptance, "quality_counts": counts, "research_comparison": comparison, "bigquery": progress}
    (OUT / "quality_layer_summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    print(json.dumps(summary, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
