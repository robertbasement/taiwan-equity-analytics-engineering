"""Warehouse-free regression fixtures for cumulative-to-quarter conversion."""

import math
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODEL = (ROOT / "models/intermediate/int_income_statement_features.sql").read_text()


def quarter_index(period):
    year, quarter = period
    return year * 4 + quarter


def per_share_factor_between(events, previous_period, current_period):
    previous = quarter_index(previous_period)
    current = quarter_index(current_period)
    return math.prod(
        factor
        for event_period, factor in events
        if previous < quarter_index(event_period) <= current
    )


def standalone_ytd(current_period, current_ytd, previous=None, *, events=()):
    if current_period[1] == 1:
        return current_ytd
    if previous is None:
        return None
    previous_period, previous_ytd = previous
    if quarter_index(previous_period) != quarter_index(current_period) - 1:
        return None
    return current_ytd - previous_ytd * per_share_factor_between(
        events, previous_period, current_period
    )


def ttm(period_values):
    if len(period_values) != 4 or any(value is None for _, value in period_values):
        return None
    indexes = [quarter_index(period) for period, _ in period_values]
    if indexes[-1] - indexes[0] != 3:
        return None
    if any(current - previous != 1 for previous, current in zip(indexes, indexes[1:])):
        return None
    return sum(value for _, value in period_values)


class IncomeQuarterAdjacencyTests(unittest.TestCase):
    def test_q1_to_q2_normal_subtraction(self):
        self.assertEqual(
            standalone_ytd((2025, 2), 8, ((2025, 1), 2)),
            6,
        )

    def test_q1_missing_q2_then_q3_is_null(self):
        self.assertIsNone(
            standalone_ytd((2025, 3), 8, ((2025, 1), 2))
        )

    def test_first_observation_q2_is_null(self):
        self.assertIsNone(standalone_ytd((2025, 2), 8))

    def test_missing_q3_then_q4_is_null(self):
        self.assertIsNone(
            standalone_ytd((2025, 4), 12, ((2025, 2), 8))
        )

    def test_year_boundary_q1_is_not_subtracted(self):
        self.assertEqual(
            standalone_ytd((2026, 1), 3, ((2025, 4), 12)),
            3,
        )

    def test_four_consecutive_quarters_produce_ttm(self):
        self.assertEqual(
            ttm([
                ((2025, 2), 1),
                ((2025, 3), 2),
                ((2025, 4), 3),
                ((2026, 1), 4),
            ]),
            10,
        )

    def test_four_rows_with_missing_calendar_quarter_reject_ttm(self):
        self.assertIsNone(
            ttm([
                ((2025, 1), 1),
                ((2025, 2), 2),
                ((2025, 4), 3),
                ((2026, 1), 4),
            ])
        )

    def test_2327_corporate_action_regression(self):
        result = standalone_ytd(
            (2025, 3),
            8.22,
            ((2025, 2), 20.51),
            events=(((2025, 3), 0.25),),
        )
        self.assertAlmostEqual(result, 3.0925)

    def test_production_sql_guards_every_subtraction_and_ttm_window(self):
        self.assertGreaterEqual(
            MODEL.count("previous_fiscal_quarter_index = fiscal_quarter_index - 1"),
            4,
        )
        self.assertEqual(
            len(re.findall(r"LAG\(fiscal_quarter_index, 3\).*?= fiscal_quarter_index - 3", MODEL, re.S)),
            4,
        )
        self.assertIn("= fiscal_quarter_index - 4", MODEL)


if __name__ == "__main__":
    unittest.main()
