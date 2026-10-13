#!/usr/bin/env python3
"""Freeze the material anomaly population and deterministic evidence sample."""

from __future__ import annotations

import csv
import json
from collections import Counter, defaultdict
from pathlib import Path


HERE = Path(__file__).resolve().parent
SOURCE = HERE.parent / "output" / "reverse_qa_20261012" / "05_candidates_gt30.json"
OUT = HERE / "output"
OUT.mkdir(parents=True, exist_ok=True)


def key(row):
    return row["ticker"], row["prev_quote_date"], row["date"]


def write_json(name, value):
    (OUT / name).write_text(
        json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


def write_csv(name, rows):
    if not rows:
        return
    with (OUT / name).open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


candidates = json.loads(SOURCE.read_text(encoding="utf-8"))
material = [row for row in candidates if abs(row["adjusted_return"]) > 0.50]
assert len(candidates) == 571
assert len(material) == 360
assert len({key(row) for row in material}) == 360

year_counts = Counter(row["date"][:4] for row in material)
ticker_counts = Counter(row["ticker"] for row in material)
positive = [row for row in material if row["adjusted_return"] > 0]
negative = [row for row in material if row["adjusted_return"] < 0]
gap = [row for row in material if (row["missing_market_sessions"] or 0) > 0]
no_gap = [row for row in material if row["missing_market_sessions"] == 0]
with_event = [row for row in material if row["corporate_action_found"]]
unchanged_factor = [
    row
    for row in material
    if abs(row["cumulative_factor_change_current_over_previous"] - 1.0) < 1e-10
]

ratio_bands = {}
for ratio in (2, 4, 5, 10):
    ratio_bands[str(ratio)] = sum(
        abs(row["raw_price_ratio"] - ratio) / ratio <= 0.05 for row in material
    )

summary = {
    "source_candidate_rows": len(candidates),
    "material_filter": "abs(adjusted_return) > 0.50",
    "material_transitions": len(material),
    "material_tickers": len({row["ticker"] for row in material}),
    "positive": len(positive),
    "negative": len(negative),
    "with_existing_event": len(with_event),
    "after_missing_market_sessions": len(gap),
    "without_missing_market_sessions": len(no_gap),
    "unchanged_cumulative_factor": len(unchanged_factor),
    "repeated_anomaly_tickers": sum(count > 1 for count in ticker_counts.values()),
    "max_anomalies_single_ticker": max(ticker_counts.values()),
    "raw_price_ratio_min": min(row["raw_price_ratio"] for row in material),
    "raw_price_ratio_max": max(row["raw_price_ratio"] for row in material),
    "raw_ratio_within_5pct_of_positive_multiple": ratio_bands,
    "by_year": dict(sorted(year_counts.items())),
}
write_json("material_population_summary.json", summary)
write_json("material_population_360.json", material)
write_csv(
    "material_by_year.csv",
    [{"calendar_year": year, "count": count} for year, count in sorted(year_counts.items())],
)
write_csv(
    "material_ticker_repetitions.csv",
    [
        {"ticker": ticker, "material_anomaly_count": count}
        for ticker, count in sorted(ticker_counts.items(), key=lambda item: (-item[1], item[0]))
    ],
)

selected = {}
categories = defaultdict(set)


def add(rows, category):
    for row in rows:
        selected[key(row)] = row
        categories[key(row)].add(category)


add(sorted(positive, key=lambda row: (-row["adjusted_return"], key(row)))[:10], "TOP_10_POSITIVE")
add(sorted(negative, key=lambda row: (row["adjusted_return"], key(row)))[:5], "TOP_5_NEGATIVE")
add(
    sorted(
        gap,
        key=lambda row: (
            -(row["missing_market_sessions"] or 0),
            -row["calendar_gap_days"],
            -abs(row["adjusted_return"]),
            key(row),
        ),
    )[:5],
    "TOP_5_LONGEST_SESSION_GAPS",
)
add(
    sorted(no_gap, key=lambda row: (-abs(row["adjusted_return"]), key(row)))[:5],
    "NO_MISSING_MARKET_SESSION",
)

event_controls = sorted(
    [row for row in candidates if row["corporate_action_found"]],
    key=lambda row: (-abs(row["adjusted_return"]), key(row)),
)
control_2429 = next(row for row in candidates if row["ticker"] == "2429" and row["date"] == "2024-07-02")
event_controls = [control_2429] + [row for row in event_controls if key(row) != key(control_2429)]
add(event_controls[:5], "EXISTING_EVENT_CONTROL_NON_MATERIAL")

for ticker, event_date in (("6294", "2010-02-22"), ("5364", "2013-12-10")):
    row = next(row for row in material if row["ticker"] == ticker and row["date"] == event_date)
    add([row], "KNOWN_REGRESSION_CASE")

remaining = sorted(material, key=lambda row: (-abs(row["adjusted_return"]), key(row)))
for row in remaining:
    if len(selected) >= 30:
        break
    if key(row) not in selected:
        add([row], "MAGNITUDE_FILL_TO_30")

sample = []
for transition_key, row in sorted(
    selected.items(), key=lambda item: (-abs(item[1]["adjusted_return"]), item[0])
):
    output = {
        "ticker": row["ticker"],
        "prev_quote_date": row["prev_quote_date"],
        "quote_date": row["date"],
        "prev_raw_close": row["prev_raw_close"],
        "raw_close": row["raw_close"],
        "raw_price_ratio": row["raw_price_ratio"],
        "raw_return": row["raw_return"],
        "adjusted_return": row["adjusted_return"],
        "calendar_gap_days": row["calendar_gap_days"],
        "missing_market_sessions": row["missing_market_sessions"],
        "corporate_action_found": row["corporate_action_found"],
        "existing_actions": row["corporate_actions"],
        "is_material_gt50": abs(row["adjusted_return"]) > 0.50,
        "selection_categories": sorted(categories[transition_key]),
        "classification": "UNRESOLVED",
        "evidence_source": "",
        "evidence_url": "",
        "evidence_date": "",
        "evidence_summary": "",
        "confidence": "",
        "remaining_uncertainty": "Authoritative investigation pending",
    }
    sample.append(output)

assert len(sample) == 30
assert any(row["ticker"] == "6294" and row["quote_date"] == "2010-02-22" for row in sample)
assert any(row["ticker"] == "5364" and row["quote_date"] == "2013-12-10" for row in sample)
assert any(row["ticker"] == "2429" and row["quote_date"] == "2024-07-02" and not row["is_material_gt50"] for row in sample)

write_json("root_cause_sample_30.json", sample)
csv_rows = []
for row in sample:
    flat = dict(row)
    flat["existing_actions"] = json.dumps(row["existing_actions"], ensure_ascii=False, sort_keys=True)
    flat["selection_categories"] = ";".join(row["selection_categories"])
    csv_rows.append(flat)
write_csv("root_cause_sample_30.csv", csv_rows)

print(json.dumps(summary, indent=2, sort_keys=True))
print(f"sample_transitions={len(sample)}")
