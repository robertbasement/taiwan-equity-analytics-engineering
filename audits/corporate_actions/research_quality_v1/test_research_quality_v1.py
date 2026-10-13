#!/usr/bin/env python3

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import numpy as np
import pandas as pd

from research_quality_v1 import (
    apply_quality_layer,
    assign_revenue_yoy_quintiles,
    build_relationships_python,
    load_anomalies,
)
from run_quality_layer_v1 import PANEL_SQL, ensure_select_only, relationships_sql


HERE = Path(__file__).resolve().parent
INPUT = HERE / "input" / "research_price_anomalies_v1.csv"


def anomaly(ticker="T", previous="2024-01-10", current="2024-01-20", adjusted=1.0):
    return pd.DataFrame([{
        "ticker": ticker, "prev_quote_date": pd.Timestamp(previous), "quote_date": pd.Timestamp(current),
        "raw_return": adjusted, "adjusted_return": adjusted, "missing_market_sessions": 2,
        "anomaly_reason": "TEST", "anomaly_source": "SYNTHETIC", "source_audit_version": "TEST",
        "is_material_gt50": abs(adjusted) > 0.50,
    }])


def panel(rows):
    result = pd.DataFrame(rows)
    defaults = {
        "yoy_growth": 1.0, "forward_return": 0.1, "forward_return_eligible": True,
        "price_ma20_gap": 0.01, "price_ma60_gap": 0.02, "d_close": 10.0,
    }
    for key, value in defaults.items():
        if key not in result:
            result[key] = value
    return result


class ResearchQualityV1Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.anomalies = load_anomalies(INPUT)

    def test_anomaly_input_exact_population_and_regressions(self):
        self.assertEqual(len(self.anomalies), 361)
        material = self.anomalies[self.anomalies["is_material_gt50"]]
        self.assertEqual(len(material), 360)
        self.assertEqual(material["ticker"].nunique(), 262)
        keys = set(zip(self.anomalies.ticker, self.anomalies.quote_date.dt.strftime("%Y-%m-%d")))
        self.assertIn(("6294", "2010-02-22"), keys)
        self.assertIn(("5364", "2013-12-10"), keys)
        self.assertIn(("2429", "2024-07-02"), keys)
        control = self.anomalies[(self.anomalies.ticker == "2429") & (self.anomalies.quote_date == pd.Timestamp("2024-07-02"))].iloc[0]
        self.assertFalse(control.is_material_gt50)
        self.assertEqual(control.anomaly_reason, "CONFIRMED_PAID_RIGHTS_ADJUSTMENT_ERROR")

    def test_forward_interval_boundaries_are_start_open_end_closed(self):
        research = panel([
            {"rebalance_date": "2024-01-20", "next_rebalance_date": "2024-02-20", "ticker": "T"},
            {"rebalance_date": "2023-12-20", "next_rebalance_date": "2024-01-20", "ticker": "T"},
        ])
        prices = pd.DataFrame({"ticker": ["T", "T"], "date": ["2024-01-20", "2024-02-20"]})
        rel = build_relationships_python(research, prices, anomaly(current="2024-01-20"))
        direct = rel[rel.quality_component == "FORWARD_RETURN"]
        self.assertEqual(len(direct), 1)
        self.assertEqual(direct.iloc[0].rebalance_date, pd.Timestamp("2023-12-20"))

    def test_ma_windows_use_price_rows_not_calendar_days(self):
        dates = pd.date_range("2024-01-01", periods=61, freq="7D")
        prices = pd.DataFrame({"ticker": "T", "date": dates})
        research = panel([
            {"rebalance_date": dates[19], "next_rebalance_date": dates[20], "ticker": "T"},
            {"rebalance_date": dates[20], "next_rebalance_date": dates[21], "ticker": "T"},
            {"rebalance_date": dates[60], "next_rebalance_date": pd.NaT, "ticker": "T"},
        ])
        rel = build_relationships_python(research, prices, anomaly(current=str(dates[0].date())))
        ma20 = rel[rel.quality_component == "MA20"]
        ma60 = rel[rel.quality_component == "MA60"]
        self.assertEqual(set(ma20.rows_after_anomaly), set())
        self.assertEqual(set(ma60.rows_after_anomaly), {19, 20})

    def test_multiple_anomalies_are_preserved(self):
        research = panel([{"rebalance_date": "2024-01-01", "next_rebalance_date": "2024-02-01", "ticker": "T"}])
        prices = pd.DataFrame({"ticker": ["T", "T", "T"], "date": ["2024-01-10", "2024-01-20", "2024-02-01"]})
        anomalies = pd.concat([anomaly(current="2024-01-10"), anomaly(previous="2024-01-20", current="2024-01-20")], ignore_index=True)
        rel = build_relationships_python(research, prices, anomalies)
        self.assertEqual(len(rel[rel.quality_component == "FORWARD_RETURN"]), 2)
        quality, normalized = apply_quality_layer(research, rel)
        self.assertEqual(quality.iloc[0].forward_return_quality, "INVALID")
        self.assertEqual(normalized.anomaly_id.nunique(), 2)

    def test_row_factor_and_quintile_invariance(self):
        rows = []
        for i in range(20):
            rows.append({
                "rebalance_date": "2024-01-15", "next_rebalance_date": "2024-02-15",
                "ticker": f"T{i:02d}", "yoy_growth": float(i), "forward_return": i / 100,
            })
        research = panel(rows)
        relation = pd.DataFrame([{
            "rebalance_date": "2024-01-15", "ticker": "T18", "quality_component": "FORWARD_RETURN",
            "anomaly_id": 1, "anomaly_ticker": "T18", "anomaly_date": "2024-02-01",
            "anomaly_return": 1.0, "anomaly_source": "TEST", "quality_reason": "TEST",
            "rows_after_anomaly": np.nan,
        }])
        quality, _ = apply_quality_layer(research, relation)
        self.assertEqual(len(quality), len(research))
        pd.testing.assert_series_equal(quality.yoy_growth, research.yoy_growth)
        before = assign_revenue_yoy_quintiles(research)[["ticker", "group"]].sort_values("ticker").reset_index(drop=True)
        after = assign_revenue_yoy_quintiles(quality)[["ticker", "group"]].sort_values("ticker").reset_index(drop=True)
        pd.testing.assert_frame_equal(before, after)
        self.assertIn("T18", set(after.ticker))
        self.assertTrue(pd.isna(quality.loc[quality.ticker == "T18", "forward_return_research"].iloc[0]))

    def test_unknown_is_not_silently_valid(self):
        research = panel([{"rebalance_date": "2024-01-15", "next_rebalance_date": pd.NaT, "ticker": "T", "forward_return": np.nan, "forward_return_eligible": False, "price_ma20_gap": np.nan}])
        quality, _ = apply_quality_layer(research, pd.DataFrame())
        self.assertEqual(quality.iloc[0].forward_return_quality, "UNKNOWN")
        self.assertEqual(quality.iloc[0].ma20_quality, "UNKNOWN")
        self.assertTrue(pd.isna(quality.iloc[0].forward_return_research))

    def test_duplicate_research_key_fails(self):
        research = panel([
            {"rebalance_date": "2024-01-15", "next_rebalance_date": "2024-02-15", "ticker": "T"},
            {"rebalance_date": "2024-01-15", "next_rebalance_date": "2024-02-15", "ticker": "T"},
        ])
        with self.assertRaisesRegex(ValueError, "duplicate research observation key"):
            apply_quality_layer(research, pd.DataFrame())

    def test_missing_and_malformed_input_fail_closed(self):
        with self.assertRaises(FileNotFoundError):
            load_anomalies("/definitely/missing/research_quality.csv")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.csv"
            path.write_text("ticker,quote_date\nT,2024-01-01\n")
            with self.assertRaisesRegex(ValueError, "malformed anomaly input"):
                load_anomalies(path)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad_flag.csv"
            bad = self.anomalies.head(1).copy()
            bad["is_material_gt50"] = "not-a-boolean"
            bad.to_csv(path, index=False)
            with self.assertRaisesRegex(ValueError, "must be boolean"):
                load_anomalies(path)

    def test_reproducible_flags(self):
        research = panel([{"rebalance_date": "2024-01-01", "next_rebalance_date": "2024-02-01", "ticker": "T"}])
        prices = pd.DataFrame({"ticker": ["T", "T"], "date": ["2024-01-20", "2024-02-01"]})
        anomalies = anomaly(current="2024-01-20")
        one = build_relationships_python(research, prices, anomalies)
        two = build_relationships_python(research, prices, anomalies)
        pd.testing.assert_frame_equal(one, two)
        pd.testing.assert_frame_equal(apply_quality_layer(research, one)[0], apply_quality_layer(research, two)[0])

    def test_queries_are_select_only_and_do_not_mutate_production(self):
        ensure_select_only(PANEL_SQL)
        ensure_select_only(relationships_sql(self.anomalies.head(2)))
        for sql in (PANEL_SQL, relationships_sql(self.anomalies.head(2))):
            upper = sql.upper()
            for token in ("CREATE ", "INSERT ", "UPDATE ", "DELETE ", "MERGE ", "DROP ", "ALTER "):
                self.assertNotIn(token, upper)


if __name__ == "__main__":
    unittest.main()
