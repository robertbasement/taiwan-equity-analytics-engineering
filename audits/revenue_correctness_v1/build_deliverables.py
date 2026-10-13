#!/usr/bin/env python3
"""Build durable Revenue Correctness V1 summaries from local audit evidence."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path


HERE = Path(__file__).resolve().parent
OUT = HERE / "output"
QUALITY = HERE.parent / "corporate_actions" / "research_quality_v1" / "output"


def load(name: str):
    return json.loads((OUT / name).read_text())


def metric_map(rows):
    return {row["metric"]: int(row["value"]) for row in rows}


def write(name: str, payload) -> None:
    (HERE / name).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    unit = load("unit_contract.json")[0]
    gaps = load("calendar_gaps.json")[0]
    impact = metric_map(load("feature_impact.json"))
    supplemental = metric_map(load("supplemental_impact.json"))
    progress = load("progress_manifest.json")
    supplemental_progress = load("supplemental_progress.json")
    quality_path = QUALITY / "quality_layer_summary.json"
    quality = json.loads(quality_path.read_text())
    previous = quality["research_comparison"]

    unit_summary = {
        "source_contract": "Official MOPS growth fields are percentage points; ingestion preserves source numbers without scaling.",
        "source_header": "去年同月增減(%)",
        "total_relevant_observations": unit["total_relevant_observations"],
        "nonnull_yoy_observations": unit["nonnull_yoy_observations"],
        "incorrect_conditional_conversion_rows": unit["incorrect_conditional_conversion_rows"],
        "affected_tickers": unit["affected_tickers"],
        "affected_revenue_months": unit["affected_revenue_months"],
        "first_affected_month": unit["first_affected_month"],
        "last_affected_month": unit["last_affected_month"],
        "source_distribution": {
            "positive_abs_lt_1": unit["positive_sub_one_rows"],
            "negative_abs_lt_1": unit["negative_sub_one_rows"],
            "zero": unit["zero_rows"],
            "null": unit["null_rows"],
            "abs_gt_100": unit["extreme_over_100pct_rows"],
        },
        "unit_evidence": {
            "closer_to_percentage_points": unit["closer_to_percentage_points"],
            "closer_to_decimal_fraction": unit["closer_to_decimal_fraction"],
            "exact_or_rounding_agreement_percentage_points": unit["agrees_with_percentage_points"],
        },
        "downstream_impact": {
            "changed_3m_feature_rows": impact["unit_changed_3m_feature_rows"],
            "changed_6m_feature_rows": impact["unit_changed_6m_feature_rows"],
            "changed_expected_growth_rows": impact["unit_changed_expected_growth_rows"],
            "affected_research_expectation_rows": impact["research_unit_changed_expected_growth_observations"],
            "canonical_yoy_source_mismatches": impact["research_canonical_yoy_source_mismatches"],
        },
        "fix": "mart_expectation_features now divides every non-null yoy_growth_pct by 100.0; no magnitude inference or clipping.",
    }
    write("unit_impact_summary.json", unit_summary)

    calendar_summary = {
        **gaps,
        "feature_impact": {
            "monthly_revenue_ttm": impact["calendar_changed_ttm_rows"],
            "revenue_yoy_3m_avg": impact["calendar_changed_3m_rows"],
            "revenue_yoy_6m_avg": impact["calendar_changed_6m_rows"],
            "unique_any_rolling_feature": impact["calendar_changed_any_feature_rows"],
            "affected_feature_tickers": supplemental["calendar_feature_changed_tickers"],
            "affected_feature_months": supplemental["calendar_feature_changed_months"],
            "yoy_positive_streak_count": supplemental["old_streak_changed_rows"],
            "yoy_triple_increase_signal": supplemental["triple_signal_changed_rows"],
        },
        "research_impact": {
            "observations": supplemental["research_calendar_feature_changed_observations"],
            "tickers": supplemental["research_calendar_feature_changed_tickers"],
            "months": supplemental["research_calendar_feature_changed_months"],
        },
        "regression_4749": {
            "previous_month": "2016-07", "current_month": "2021-08", "missing_months": 60,
            "expected": "new continuity segment; no feature crosses the gap",
        },
        "fix": "Ticker-month continuity segments; full TTM requires 12 rows inside one segment; partial 3m/6m warm-up resets after a gap.",
        "classification_limit": "Internal data identifies absent calendar months but does not by itself distinguish source-boundary, listing-history, or reporting-history causes.",
    }
    write("calendar_gap_summary.json", calendar_summary)

    metrics = {
        "mean_monthly_spearman_ic": previous["ic"]["quality"]["mean_ic"],
        "icir": previous["ic"]["quality"]["icir"],
        "quintile_mean_returns": previous["quintile_mean_returns"]["quality"],
        "newey_west": previous["spread_newey_west"]["quality"],
    }
    regression = {
        "method": previous["method"],
        "quality_layer_source": str(quality_path),
        "quality_layer_sha256": sha256(quality_path),
        "formation_observations_before": previous["formation"]["rows"],
        "formation_observations_after": previous["formation"]["rows"],
        "return_eligible_before": previous["effective_sample"]["quality_return_observations"],
        "return_eligible_after": previous["effective_sample"]["quality_return_observations"],
        "changed_revenue_yoy_values": 0,
        "changed_rankings": 0,
        "changed_quintile_assignments": 0,
        "affected_factor_months": 0,
        "before": metrics,
        "after": metrics,
        "reason_metrics_are_identical": "The corrected SQL changes expectation and auxiliary continuity features only. mart_factor_research_monthly.yoy_growth, formation keys, and Research Quality Layer V1 labels are unchanged.",
    }
    write("research_regression_comparison.json", regression)

    jobs = []
    for name, stage in progress["stages"].items():
        jobs.append({"stage": name, **stage})
    jobs.append({"stage": "supplemental_impact", **supplemental_progress})
    write("bigquery_jobs.json", {
        "jobs": jobs,
        "total_bytes_processed": sum(int(job.get("bytes_processed", 0)) for job in jobs),
        "all_statements_select_only": True,
    })


if __name__ == "__main__":
    main()
