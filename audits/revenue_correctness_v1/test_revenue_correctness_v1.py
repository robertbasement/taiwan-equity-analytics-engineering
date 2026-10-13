#!/usr/bin/env python3

from __future__ import annotations

import unittest
from pathlib import Path

from revenue_reference import calculate_features, yoy_percentage_points_to_decimal


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
EXPECTATION_SQL = (ROOT / "models/marts/expectation/mart_expectation_features.sql").read_text()
REVENUE_FEATURE_SQL = (ROOT / "models/intermediate/int_monthly_revenue_features.sql").read_text()


def months(start_year: int, start_month: int, count: int, ticker: str = "T") -> list[dict]:
    rows = []
    year, month = start_year, start_month
    for index in range(count):
        rows.append({
            "ticker": ticker,
            "year_month": f"{year:04d}-{month:02d}",
            "revenue": index + 1,
            "yoy_growth_pct": float(index),
        })
        month += 1
        if month == 13:
            year += 1
            month = 1
    return rows


class RevenueCorrectnessV1Tests(unittest.TestCase):
    def test_percentage_point_contract(self):
        cases = [(25.0, 0.25), (5.0, 0.05), (0.5, 0.005), (-0.8, -0.008), (0.0, 0.0), (None, None)]
        for source, expected in cases:
            self.assertEqual(yoy_percentage_points_to_decimal(source), expected)

    def test_twelve_consecutive_months_produce_ttm(self):
        result = calculate_features(months(2020, 1, 12))
        self.assertEqual(result[-1]["monthly_revenue_ttm"], sum(range(1, 13)))

    def test_missing_month_invalidates_full_window(self):
        rows = months(2020, 1, 12)
        rows.pop(5)
        result = calculate_features(rows)
        self.assertIsNone(result[-1]["monthly_revenue_ttm"])

    def test_large_gap_does_not_cross(self):
        rows = [
            {"ticker": "4749", "year_month": "2016-07", "revenue": 100, "yoy_growth_pct": 25.0},
            {"ticker": "4749", "year_month": "2021-08", "revenue": 200, "yoy_growth_pct": 0.5},
        ]
        result = calculate_features(rows)
        self.assertEqual(result[-1]["revenue_yoy_3m_avg"], 0.005)
        self.assertIsNone(result[-1]["monthly_revenue_ttm"])

    def test_first_month_preserves_partial_average_warmup(self):
        result = calculate_features(months(2020, 1, 1))
        self.assertEqual(result[0]["revenue_yoy_3m_avg"], 0.0)
        self.assertIsNone(result[0]["monthly_revenue_ttm"])

    def test_duplicate_ticker_month_fails(self):
        row = months(2020, 1, 1)[0]
        with self.assertRaisesRegex(ValueError, "duplicate ticker-month"):
            calculate_features([row, row.copy()])

    def test_null_yoy_is_ignored_but_null_revenue_blocks_ttm(self):
        rows = months(2020, 1, 12)
        rows[-1]["yoy_growth_pct"] = None
        rows[-1]["revenue"] = None
        result = calculate_features(rows)
        self.assertIsNotNone(result[-1]["revenue_yoy_3m_avg"])
        self.assertIsNone(result[-1]["monthly_revenue_ttm"])

    def test_complete_new_window_recovers_after_gap(self):
        rows = months(2018, 1, 1) + months(2021, 1, 12)
        result = calculate_features(rows)
        self.assertIsNone(result[-2]["monthly_revenue_ttm"])
        self.assertIsNotNone(result[-1]["monthly_revenue_ttm"])

    def test_production_sql_uses_explicit_unit_and_calendar_contracts(self):
        self.assertIn("yoy_growth_pct / 100.0", EXPECTATION_SQL)
        self.assertNotIn("WHEN ABS(yoy_growth)", EXPECTATION_SQL)
        self.assertIn("PARTITION BY ticker, continuity_segment", EXPECTATION_SQL)
        self.assertIn("DATE_DIFF(revenue_month_date, month_lag1, MONTH) = 1", REVENUE_FEATURE_SQL)


if __name__ == "__main__":
    unittest.main()
