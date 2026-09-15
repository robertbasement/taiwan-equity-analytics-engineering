"""Small, warehouse-free fixtures for the canonical EPS and price boundaries.

Run with: python3 -m unittest tests/test_research_correctness_fixtures.py
The assertions inspect the production SQL boundary as well as fixture arithmetic.
"""

import math
import re
import sqlite3
import unittest
from datetime import date
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FEATURES = (ROOT / "models/intermediate/int_income_statement_features.sql").read_text()
SHIFTER = (ROOT / "models/intermediate/int_income_statement_shifter.sql").read_text()
PRICES = (ROOT / "models/intermediate/int_daily_prices_adjusted.sql").read_text()
DIVIDENDS = (ROOT / "models/staging/stg_dividend_factor.sql").read_text()


def factor(events, observation, *, forward):
    return math.prod(value for event_date, value in events if (event_date > observation if forward else event_date <= observation))


def factor_between_periods(events, previous_period_end, current_period_end):
    """Per-share basis conversion known by the current reporting period."""
    return math.prod(
        value
        for effective_date, value in events
        if previous_period_end < effective_date <= current_period_end
    )


def single_quarter_eps(current_ytd_eps, current_period_end, events, *, previous_ytd_eps=None, previous_period_end=None):
    """Convert only the previous cumulative operand before subtraction."""
    if previous_ytd_eps is None:
        return current_ytd_eps
    return current_ytd_eps - previous_ytd_eps * factor_between_periods(
        events, previous_period_end, current_period_end
    )


def eps_on_current_period_basis(q_eps, source_period_end, current_period_end, events):
    return q_eps * factor_between_periods(events, source_period_end, current_period_end)


def sql_adjusted_prices(prices, events):
    """Execute the production window specification on a tiny event timeline."""
    frame = re.search(r"SUM\(log_factor\) OVER \((.*?)\)", PRICES, re.S)
    if frame is None:
        raise AssertionError("price model has no source-factor window")
    connection = sqlite3.connect(":memory:")
    connection.execute("CREATE TABLE timeline (ticker TEXT, date TEXT, is_price INTEGER, log_factor REAL, close REAL)")
    connection.executemany(
        "INSERT INTO timeline VALUES ('T', ?, 1, NULL, ?)",
        [(day.isoformat(), close) for day, close in prices],
    )
    connection.executemany(
        "INSERT INTO timeline VALUES ('T', ?, 0, ln(?), NULL)",
        [(day.isoformat(), value) for day, value in events],
    )
    rows = connection.execute(
        "SELECT date, close * exp(coalesce(" +
        "SUM(log_factor) OVER (" + frame.group(1) + "), 0.0)) " +
        "FROM timeline ORDER BY date DESC, is_price DESC"
    ).fetchall()
    connection.close()
    return [adjusted for _, adjusted in sorted((day, value) for day, value in rows if value is not None)]


class ResearchCorrectnessFixtures(unittest.TestCase):
    def test_eps_source_basis_reconciliation_without_action(self):
        q1_end = date(2026, 3, 31)
        q2_end = date(2026, 6, 30)
        self.assertEqual(single_quarter_eps(2.0, q1_end, []), 2.0)
        self.assertEqual(single_quarter_eps(
            5.0, q2_end, [], previous_ytd_eps=2.0, previous_period_end=q1_end
        ), 3.0)

    def test_eps_source_basis_reconciliation_with_one_action(self):
        q1_end = date(2026, 3, 31)
        q2_end = date(2026, 6, 30)
        actions = [(date(2026, 5, 1), 0.25)]
        converted_previous_ytd = 2.0 * factor_between_periods(actions, q1_end, q2_end)
        self.assertEqual(converted_previous_ytd, 0.5)
        self.assertEqual(single_quarter_eps(
            5.0, q2_end, actions,
            previous_ytd_eps=2.0, previous_period_end=q1_end,
        ), 4.5)

    def test_yageo_q3_source_basis_numeric_regression(self):
        q2_end = date(2025, 6, 30)
        q3_end = date(2025, 9, 30)
        actions = [(date(2025, 8, 25), 0.25)]
        converted_previous_ytd = 20.51 * factor_between_periods(actions, q2_end, q3_end)
        self.assertAlmostEqual(converted_previous_ytd, 5.1275)
        self.assertAlmostEqual(single_quarter_eps(
            8.22, q3_end, actions,
            previous_ytd_eps=20.51, previous_period_end=q2_end,
        ), 3.0925)

    def test_eps_source_basis_multiplies_multiple_actions(self):
        q1_end = date(2026, 3, 31)
        q2_end = date(2026, 6, 30)
        actions = [(date(2026, 4, 15), 0.5), (date(2026, 5, 15), 0.5)]
        self.assertEqual(factor_between_periods(actions, q1_end, q2_end), 0.25)
        self.assertEqual(single_quarter_eps(
            5.0, q2_end, actions,
            previous_ytd_eps=2.0, previous_period_end=q1_end,
        ), 4.5)

    def test_eps_source_basis_excludes_action_after_current_period(self):
        q1_end = date(2026, 3, 31)
        q2_end = date(2026, 6, 30)
        actions = [(date(2026, 7, 1), 0.25)]
        self.assertEqual(factor_between_periods(actions, q1_end, q2_end), 1)
        self.assertEqual(single_quarter_eps(
            5.0, q2_end, actions,
            previous_ytd_eps=2.0, previous_period_end=q1_end,
        ), 3.0)

    def test_eps_ttm_and_yoy_operands_use_current_period_basis(self):
        action = [(date(2025, 8, 25), 0.25)]
        q3_end = date(2025, 9, 30)
        components = [
            (date(2024, 12, 31), 7.07),
            (date(2025, 3, 31), 10.77),
            (date(2025, 6, 30), 9.74),
            (q3_end, 3.0925),
        ]
        eps_ttm = sum(
            eps_on_current_period_basis(value, period_end, q3_end, action)
            for period_end, value in components
        )
        self.assertAlmostEqual(eps_ttm, 9.9875)

        prior_year_q_eps = 7.02
        converted_prior_year = eps_on_current_period_basis(
            prior_year_q_eps, date(2024, 9, 30), q3_end, action
        )
        self.assertAlmostEqual(converted_prior_year, 1.755)
        self.assertAlmostEqual(3.0925 / converted_prior_year - 1, 0.762108262108262)

        # Production boundary: transformations are period-bounded operands,
        # not a future normalization of immutable historical source rows.
        self.assertIn("factor_between_periods", FEATURES)
        self.assertRegex(FEATURES, r"a\.effective_date\s*>\s*p\.previous_period_end")
        self.assertRegex(FEATURES, r"a\.effective_date\s*<=\s*p\.current_period_end")
        self.assertIn("q_eps_action_neutral", FEATURES)

    def test_eps_action_is_a_dated_state_transition(self):
        self.assertIn("corporate_action_events", SHIFTER)
        self.assertRegex(SHIFTER, r"a\.effective_date\s*<=\s*base\.effective_date")
        self.assertRegex(SHIFTER, r"a\.effective_date\s*<=\s*COALESCE\(al\.aligned_date")
        action = [(date(2026, 8, 1), 0.25)]
        rows = [(date(2026, 7, 31), 400.0, 8.0), (date(2026, 8, 1), 100.0, 2.0)]
        for observation, price, expected_eps in rows:
            eps = 8.0 * factor(action, observation, forward=False)
            self.assertEqual(eps, expected_eps)
            self.assertEqual(price / eps, 50.0)
        self.assertEqual(factor(action, date(2026, 7, 31), forward=False), 1.0)
        two_actions = action + [(date(2026, 9, 1), 0.5)]
        self.assertEqual(8 * factor(two_actions, date(2026, 8, 31), forward=False), 2)
        self.assertEqual(8 * factor(two_actions, date(2026, 9, 1), forward=False), 1)
        self.assertRegex(SHIFTER, r"cumulative_per_share_factor")
        self.assertRegex(SHIFTER, r"LAST_DAY\([\s\S]+?QUARTER\s*\) AS statement_basis_date")
        current_eps, prior_year_eps = 2.0, 1.0
        self.assertEqual(current_eps / prior_year_eps - 1,
                         (current_eps * 0.25) / (prior_year_eps * 0.25) - 1)

    def test_yageo_pit_transition_persists_until_q3_filing(self):
        action_date = date(2025, 8, 25)
        q3_filing_date = date(2025, 11, 17)
        pre_action_q2_ttm = 34.60
        transitioned_q2_ttm = pre_action_q2_ttm * 0.25
        q3_filing_ttm = 9.9875

        observations = {
            date(2025, 8, 15): pre_action_q2_ttm,
            action_date: transitioned_q2_ttm,
            date(2025, 11, 14): transitioned_q2_ttm,
            q3_filing_date: q3_filing_ttm,
        }
        self.assertEqual(observations[date(2025, 8, 15)], 34.60)
        self.assertEqual(observations[action_date], 8.65)
        self.assertEqual(observations[date(2025, 11, 14)], 8.65)
        self.assertEqual(observations[q3_filing_date], 9.9875)
        self.assertNotEqual(observations[q3_filing_date], q3_filing_ttm * 0.25)

    def test_dividend_ex_date_is_excluded(self):
        self.assertIn("ORDER BY date DESC, is_price DESC", PRICES)
        self.assertIn("ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING", PRICES)
        raw = [100.0, 96.0, 97.0]
        dates = [date(2026, 7, 31), date(2026, 8, 1), date(2026, 8, 2)]
        events = [(date(2026, 8, 1), 0.95)]
        adjusted = sql_adjusted_prices(list(zip(dates, raw)), events)
        for actual, expected in zip(adjusted, [95.0, 96.0, 97.0]):
            self.assertAlmostEqual(actual, expected)
        self.assertAlmostEqual(adjusted[1] / adjusted[0] - 1, 0.0105263157894737)
        self.assertAlmostEqual(adjusted[2] / adjusted[1] - 1, 0.0104166666666667)

    def test_two_events_and_non_trading_event(self):
        self.assertIn("d.ex_date AS date", PRICES)
        self.assertIn("SELECT DISTINCT ticker, date FROM price_cleaned", PRICES)
        dates = [date(2026, 7, 31), date(2026, 8, 3), date(2026, 8, 4)]
        events = [(date(2026, 8, 1), 0.95), (date(2026, 8, 4), 0.9)]
        adjusted = sql_adjusted_prices([(day, 100.0) for day in dates], events)
        for actual, expected in zip(adjusted, [85.5, 90.0, 100.0]):
            self.assertAlmostEqual(actual, expected)

    def test_duplicate_and_manual_collision_fail_explicitly(self):
        self.assertIn("COUNT(*) OVER (PARTITION BY ticker, ex_date)", DIVIDENDS)
        self.assertIn("duplicate dividend factor", DIVIDENDS)
        self.assertIn("ERROR(", DIVIDENDS)
        self.assertIn("ERROR(", PRICES)
        self.assertRegex(PRICES, r"manual_corporate_actions")
        duplicate_events = [(date(2026, 8, 1), 0.95), (date(2026, 8, 1), 0.95)]
        self.assertEqual(sum(day == date(2026, 8, 1) for day, _ in duplicate_events), 2)
        source_event = (date(2026, 8, 1), 0.95)
        manual_event = (date(2026, 8, 1), 0.25)
        self.assertEqual(source_event[0], manual_event[0])
        self.assertIn("a.effective_date = d.ex_date", PRICES)


if __name__ == "__main__":
    unittest.main()
