"""Independent small-fixture reference for the Revenue Correctness V1 contract."""

from __future__ import annotations

from collections import Counter
from datetime import date


def yoy_percentage_points_to_decimal(value):
    return None if value is None else value / 100.0


def month_index(value: str) -> int:
    parsed = date.fromisoformat(f"{value}-01")
    return parsed.year * 12 + parsed.month


def validate_unique(rows: list[dict]) -> None:
    counts = Counter((row["ticker"], row["year_month"]) for row in rows)
    duplicates = [key for key, count in counts.items() if count != 1]
    if duplicates:
        raise ValueError(f"duplicate ticker-month keys: {duplicates}")


def calculate_features(rows: list[dict]) -> list[dict]:
    """Partial 3/6-month averages reset at gaps; TTM requires 12 full months."""
    validate_unique(rows)
    result = []
    by_ticker: dict[str, list[dict]] = {}
    for row in rows:
        by_ticker.setdefault(row["ticker"], []).append(row)
    for ticker_rows in by_ticker.values():
        ticker_rows.sort(key=lambda row: month_index(row["year_month"]))
        segment: list[dict] = []
        previous_index = None
        for row in ticker_rows:
            current_index = month_index(row["year_month"])
            if previous_index is None or current_index - previous_index != 1:
                segment = []
            segment.append(row)
            decimals = [
                yoy_percentage_points_to_decimal(item.get("yoy_growth_pct"))
                for item in segment
            ]
            valid_3 = [value for value in decimals[-3:] if value is not None]
            valid_6 = [value for value in decimals[-6:] if value is not None]
            revenues_12 = [item.get("revenue") for item in segment[-12:]]
            result.append({
                **row,
                "revenue_yoy_3m_avg": sum(valid_3) / len(valid_3) if valid_3 else None,
                "revenue_yoy_6m_avg": sum(valid_6) / len(valid_6) if valid_6 else None,
                "monthly_revenue_ttm": (
                    sum(revenues_12)
                    if len(revenues_12) == 12 and all(value is not None for value in revenues_12)
                    else None
                ),
            })
            previous_index = current_index
    return result
