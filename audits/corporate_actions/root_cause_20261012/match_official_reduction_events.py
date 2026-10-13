#!/usr/bin/env python3
"""Match frozen reverse-QA anomalies to official TWSE/TPEx reduction records.

Read-only network client.  It does not infer events from prices and does not
write any production system. Official endpoint coverage begins in 2011 (TWSE)
and 2013 (TPEx), so a non-match is never classified as a genuine market move.
"""

from __future__ import annotations

import html
import json
import re
import time
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

import requests


HERE = Path(__file__).resolve().parent
OUT = HERE / "output"
MATERIAL_PATH = OUT / "material_population_360.json"
SAMPLE_PATH = OUT / "root_cause_sample_30.json"
OFFICIAL_PATH = OUT / "official_reduction_events_2011_2026.json"
MATCH_PATH = OUT / "official_reduction_matches.json"
PROGRESS_PATH = OUT / "official_evidence_progress.json"
UA = "Taiwan-equity-research-read-only-corporate-action-audit/1.0"


def roc_slash_to_iso(value: str) -> str:
    year, month, day = value.strip().split("/")
    return f"{int(year) + 1911:04d}-{int(month):02d}-{int(day):02d}"


def roc_compact_to_iso(value: str) -> str:
    value = value.strip()
    return f"{int(value[:3]) + 1911:04d}-{int(value[3:5]):02d}-{int(value[5:7]):02d}"


def clean_html(value: str) -> str:
    value = re.sub(r"<br\s*/?>", "; ", value, flags=re.I)
    value = re.sub(r"<[^>]+>", " ", value)
    return re.sub(r"\s+", " ", html.unescape(value)).strip()


session = requests.Session()
session.headers.update({"User-Agent": UA})
events = []
requests_log = []

for year in range(2011, 2027):
    url = (
        "https://www.twse.com.tw/rwd/zh/reducation/TWTAUU"
        f"?startDate={year}0101&endDate={year}1231&response=json"
    )
    response = session.get(url, timeout=90)
    response.raise_for_status()
    payload = response.json()
    requests_log.append({"provider": "TWSE", "year": year, "url": url, "status": response.status_code})
    for row in payload.get("data", []):
        events.append({
            "provider": "TWSE", "event_category": "CAPITAL_REDUCTION",
            "effective_date": roc_slash_to_iso(row[0]), "ticker": row[1].strip(),
            "name": row[2], "pre_close": row[3], "reference_price": row[4],
            "reason": row[9], "details": row[10], "evidence_url": url,
        })
    time.sleep(0.15)

for year in range(2013, 2027):
    url = (
        "https://www.tpex.org.tw/www/zh-tw/bulletin/revivt"
        f"?startDate={year}/01/01&endDate={year}/12/31"
    )
    response = session.get(url, timeout=90)
    response.raise_for_status()
    payload = response.json()
    requests_log.append({"provider": "TPEx", "year": year, "url": url, "status": response.status_code})
    tables = payload.get("tables", [])
    for row in tables[0].get("data", []) if tables else []:
        events.append({
            "provider": "TPEx", "event_category": "CAPITAL_REDUCTION",
            "effective_date": roc_compact_to_iso(row[0]), "ticker": row[1].strip(),
            "name": row[2], "pre_close": row[3], "reference_price": row[4],
            "reason": row[9], "details": clean_html(row[10]), "evidence_url": url,
        })
    time.sleep(0.15)

events.sort(key=lambda row: (row["effective_date"], row["ticker"], row["provider"]))
OFFICIAL_PATH.write_text(json.dumps(events, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
event_index = {(row["ticker"], row["effective_date"]): row for row in events}
material = json.loads(MATERIAL_PATH.read_text(encoding="utf-8"))
sample = json.loads(SAMPLE_PATH.read_text(encoding="utf-8"))

matches = []
for anomaly in material:
    event = event_index.get((anomaly["ticker"], anomaly["date"]))
    if event:
        matches.append({
            "ticker": anomaly["ticker"], "prev_quote_date": anomaly["prev_quote_date"],
            "quote_date": anomaly["date"], "adjusted_return": anomaly["adjusted_return"],
            "official_event": event,
        })
MATCH_PATH.write_text(json.dumps(matches, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

for row in sample:
    event = event_index.get((row["ticker"], row["quote_date"]))
    if not event:
        continue
    row.update({
        "classification": "CONFIRMED_MISSING_CORPORATE_ACTION",
        "evidence_source": f"{event['provider']} official capital-reduction reference-price record",
        "evidence_url": event["evidence_url"],
        "evidence_date": event["effective_date"],
        "evidence_summary": (
            f"Official {event['provider']} record lists {event['ticker']} on {event['effective_date']} "
            f"as {event['reason']}; pre-suspension close {event['pre_close']}, "
            f"reduction reference price {event['reference_price']}. {event['details']}"
        ),
        "confidence": "HIGH",
        "remaining_uncertainty": "No event exists in the current adjustment ledger; production factor not inferred here.",
    })
(OUT / "root_cause_sample_30_classified.json").write_text(
    json.dumps(sample, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
)

over_100 = [row for row in material if abs(row["adjusted_return"]) > 1.0]
summary = {
    "generated_at": datetime.now(timezone.utc).isoformat(),
    "official_events_downloaded": len(events),
    "official_events_by_provider": dict(Counter(row["provider"] for row in events)),
    "material_anomalies": len(material),
    "material_exact_reduction_matches": len(matches),
    "material_match_pct": len(matches) / len(material),
    "over_100_anomalies": len(over_100),
    "over_100_exact_reduction_matches": sum(
        (row["ticker"], row["date"]) in event_index for row in over_100
    ),
    "over_100_match_pct": sum(
        (row["ticker"], row["date"]) in event_index for row in over_100
    ) / len(over_100),
    "sample_cases": len(sample),
    "sample_confirmed_missing_reduction": sum(
        row["classification"] == "CONFIRMED_MISSING_CORPORATE_ACTION" for row in sample
    ),
    "sample_unresolved_after_reduction_match": sum(row["classification"] == "UNRESOLVED" for row in sample),
    "coverage_limits": {
        "TWSE": "Official page states data available from 2011-01-01.",
        "TPEx": "Official page states data available from 2013-01.",
        "interpretation": "Non-matches, especially before coverage starts, remain UNRESOLVED.",
    },
}
(OUT / "official_reduction_match_summary.json").write_text(
    json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
)
PROGRESS_PATH.write_text(json.dumps({
    "stage": "official_capital_reduction_match", "status": "COMPLETED",
    "execution_timestamp": datetime.now(timezone.utc).isoformat(),
    "output_files": [str(OFFICIAL_PATH), str(MATCH_PATH), str(OUT / "root_cause_sample_30_classified.json")],
    "row_counts": {"official_events": len(events), "material_matches": len(matches), "sample_rows": len(sample)},
    "http_requests": requests_log, "bigquery_job_ids": [],
}, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
print(json.dumps(summary, indent=2, ensure_ascii=False))
