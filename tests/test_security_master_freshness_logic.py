"""Local contracts for split Security Master integrity and freshness tests."""

from __future__ import annotations

import unittest
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo


TODAY = date(2026, 10, 17)
NOW = datetime(2026, 10, 16, 20, 0, tzinfo=timezone.utc)
EXPECTED_MARKETS = ("TWSE", "TPEX")


def source_rows(market: str, **overrides):
    row = {
        "market": market,
        "source_as_of_date": date(2026, 10, 16),
        "source_retrieved_at": datetime(2026, 10, 16, 1, 0, tzinfo=timezone.utc),
        "source_contract_valid": True,
        "source_system": market,
        "source_interface": "official-api",
    }
    row.update(overrides)
    return [dict(row), dict(row)]


def integrity_failures(rows):
    results = {}
    unexpected = sorted(
        {row.get("market") for row in rows} - set(EXPECTED_MARKETS), key=str
    )
    for market in unexpected:
        results[str(market)] = {"INVALID_MARKET_METADATA"}
    for market in EXPECTED_MARKETS:
        selected = [row for row in rows if row.get("market") == market]
        reasons = set()
        if not selected:
            results[market] = {"MISSING_SOURCE"}
            continue
        dates = {
            row["source_as_of_date"]
            for row in selected
            if row["source_as_of_date"] is not None
        }
        retrievals = {
            row["source_retrieved_at"]
            for row in selected
            if row["source_retrieved_at"] is not None
        }
        if any(row["source_as_of_date"] is None for row in selected):
            reasons.add("NULL_SOURCE_DATE")
        if len(dates) != 1:
            reasons.add("INCONSISTENT_SOURCE_DATE")
        if dates and max(dates) > TODAY:
            reasons.add("FUTURE_SOURCE_DATE")
        if any(row["source_retrieved_at"] is None for row in selected):
            reasons.add("NULL_RETRIEVAL_TIMESTAMP")
        if len(retrievals) != 1:
            reasons.add("INCONSISTENT_RETRIEVAL_TIMESTAMP")
        if retrievals and max(retrievals) > NOW:
            reasons.add("FUTURE_RETRIEVAL_TIMESTAMP")
        if dates and retrievals and (
            min(retrievals).astimezone(ZoneInfo("Asia/Taipei")).date() < max(dates)
        ):
            reasons.add("RETRIEVAL_BEFORE_SOURCE_DATE")
        if any(not row["source_contract_valid"] for row in selected):
            reasons.add("INVALID_SOURCE_CONTRACT")
        if any(row["source_system"] != market for row in selected):
            reasons.add("SOURCE_SYSTEM_MISMATCH")
        if any(
            not str(row.get("source_interface") or "").strip() for row in selected
        ):
            reasons.add("MISSING_SOURCE_INTERFACE")
        if reasons:
            results[market] = reasons
    return results


def freshness_failures(rows):
    results = {}
    for market in EXPECTED_MARKETS:
        dates = {
            row["source_as_of_date"]
            for row in rows
            if row.get("market") == market and row["source_as_of_date"] is not None
        }
        if dates and min(dates) < TODAY - timedelta(days=7):
            results[market] = {"STALE_SOURCE_DATE"}
    return results


class SecurityMasterFreshnessLogicTests(unittest.TestCase):
    def valid_rows(self):
        return source_rows("TWSE") + source_rows("TPEX")

    def test_both_markets_fresh(self):
        rows = self.valid_rows()
        self.assertEqual(integrity_failures(rows), {})
        self.assertEqual(freshness_failures(rows), {})

    def test_twse_stale_only(self):
        rows = source_rows("TWSE", source_as_of_date=date(2026, 10, 9))
        rows += source_rows("TPEX")
        self.assertEqual(freshness_failures(rows), {"TWSE": {"STALE_SOURCE_DATE"}})

    def test_tpex_stale_only(self):
        rows = source_rows("TWSE")
        rows += source_rows("TPEX", source_as_of_date=date(2026, 10, 9))
        self.assertEqual(freshness_failures(rows), {"TPEX": {"STALE_SOURCE_DATE"}})

    def test_both_markets_stale(self):
        rows = source_rows("TWSE", source_as_of_date=date(2026, 10, 9))
        rows += source_rows("TPEX", source_as_of_date=date(2026, 10, 9))
        self.assertEqual(set(freshness_failures(rows)), set(EXPECTED_MARKETS))

    def test_exactly_seven_days_is_fresh(self):
        rows = source_rows("TWSE", source_as_of_date=TODAY - timedelta(days=7))
        rows += source_rows("TPEX", source_as_of_date=TODAY - timedelta(days=7))
        self.assertEqual(freshness_failures(rows), {})

    def test_eight_days_is_stale(self):
        rows = source_rows("TWSE", source_as_of_date=TODAY - timedelta(days=8))
        rows += source_rows("TPEX")
        self.assertEqual(freshness_failures(rows), {"TWSE": {"STALE_SOURCE_DATE"}})

    def test_missing_market_is_integrity_error_not_freshness_warning(self):
        rows = source_rows("TWSE")
        self.assertEqual(integrity_failures(rows)["TPEX"], {"MISSING_SOURCE"})
        self.assertEqual(freshness_failures(rows), {})

    def test_future_source_date_is_integrity_error(self):
        rows = source_rows(
            "TWSE", source_as_of_date=TODAY + timedelta(days=1)
        ) + source_rows("TPEX")
        self.assertIn("FUTURE_SOURCE_DATE", integrity_failures(rows)["TWSE"])
        self.assertEqual(freshness_failures(rows), {})

    def test_null_source_date_is_integrity_error(self):
        rows = source_rows("TWSE", source_as_of_date=None) + source_rows("TPEX")
        self.assertIn("NULL_SOURCE_DATE", integrity_failures(rows)["TWSE"])
        self.assertEqual(freshness_failures(rows), {})

    def test_inconsistent_source_dates_are_integrity_error(self):
        rows = self.valid_rows()
        rows[0]["source_as_of_date"] = date(2026, 10, 15)
        self.assertIn("INCONSISTENT_SOURCE_DATE", integrity_failures(rows)["TWSE"])

    def test_invalid_retrieval_timestamps_are_integrity_errors(self):
        cases = (
            (None, "NULL_RETRIEVAL_TIMESTAMP"),
            (NOW + timedelta(seconds=1), "FUTURE_RETRIEVAL_TIMESTAMP"),
        )
        for value, expected in cases:
            with self.subTest(expected=expected):
                rows = source_rows("TWSE", source_retrieved_at=value)
                rows += source_rows("TPEX")
                self.assertIn(expected, integrity_failures(rows)["TWSE"])

    def test_inconsistent_retrieval_timestamp_is_integrity_error(self):
        rows = self.valid_rows()
        rows[0]["source_retrieved_at"] = datetime(
            2026, 10, 16, 2, 0, tzinfo=timezone.utc
        )
        self.assertIn(
            "INCONSISTENT_RETRIEVAL_TIMESTAMP", integrity_failures(rows)["TWSE"]
        )

    def test_source_system_mismatch_is_integrity_error(self):
        rows = source_rows("TWSE", source_system="TPEX") + source_rows("TPEX")
        self.assertIn("SOURCE_SYSTEM_MISMATCH", integrity_failures(rows)["TWSE"])

    def test_missing_source_interface_is_integrity_error(self):
        rows = source_rows("TWSE", source_interface="") + source_rows("TPEX")
        self.assertIn("MISSING_SOURCE_INTERFACE", integrity_failures(rows)["TWSE"])

    def test_invalid_source_contract_is_integrity_error(self):
        rows = source_rows("TWSE", source_contract_valid=False)
        rows += source_rows("TPEX")
        self.assertIn("INVALID_SOURCE_CONTRACT", integrity_failures(rows)["TWSE"])

    def test_invalid_market_metadata_is_integrity_error(self):
        rows = self.valid_rows() + source_rows("NYSE")
        self.assertIn("INVALID_MARKET_METADATA", integrity_failures(rows)["NYSE"])

    def test_taipei_midnight_boundary(self):
        source_date = date(2026, 10, 16)
        after_midnight = datetime(2026, 10, 15, 16, 30, tzinfo=timezone.utc)
        before_midnight = datetime(2026, 10, 15, 15, 30, tzinfo=timezone.utc)
        valid = source_rows(
            "TWSE", source_as_of_date=source_date, source_retrieved_at=after_midnight
        ) + source_rows("TPEX")
        self.assertNotIn("TWSE", integrity_failures(valid))
        invalid = source_rows(
            "TWSE", source_as_of_date=source_date, source_retrieved_at=before_midnight
        ) + source_rows("TPEX")
        self.assertIn(
            "RETRIEVAL_BEFORE_SOURCE_DATE", integrity_failures(invalid)["TWSE"]
        )

    def test_sql_severity_and_scope_contracts(self):
        directory = Path(__file__).parent
        freshness = (directory / "test_security_master_source_freshness.sql").read_text()
        integrity = (directory / "test_security_master_source_integrity.sql").read_text()
        runner = (directory.parent / "run_dbt.sh").read_text()
        self.assertIn("config(severity='warn')", freshness)
        self.assertIn("STALE_SOURCE_DATE", freshness)
        self.assertNotIn("INVALID_SOURCE_CONTRACT", freshness)
        self.assertIn("config(severity='error')", integrity)
        for token in (
            "MISSING_SOURCE",
            "FUTURE_SOURCE_DATE",
            "source_retrieved_at",
            "DATE(actual.min_source_retrieved_at, 'Asia/Taipei')",
            "INVALID_SOURCE_CONTRACT",
            "SOURCE_SYSTEM_MISMATCH",
            "MISSING_SOURCE_INTERFACE",
            "INVALID_MARKET_METADATA",
        ):
            self.assertIn(token, integrity)
        self.assertIn("CURRENT_DATE('Asia/Taipei')", freshness + integrity)
        self.assertNotIn("--warn-error", runner)
        self.assertNotIn("--warn-error-options", runner)


if __name__ == "__main__":
    unittest.main()
