"""Local contracts for the static Security Master integrity test."""

from __future__ import annotations

import unittest
from datetime import date, datetime, timezone
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


class SecurityMasterIntegrityLogicTests(unittest.TestCase):
    def valid_rows(self):
        return source_rows("TWSE") + source_rows("TPEX")

    def test_both_markets_are_structurally_valid(self):
        self.assertEqual(integrity_failures(self.valid_rows()), {})

    def test_missing_market_is_integrity_error(self):
        self.assertEqual(
            integrity_failures(source_rows("TWSE"))["TPEX"], {"MISSING_SOURCE"}
        )

    def test_future_source_date_is_integrity_error(self):
        rows = source_rows("TWSE", source_as_of_date=date(2026, 10, 18))
        rows += source_rows("TPEX")
        self.assertIn("FUTURE_SOURCE_DATE", integrity_failures(rows)["TWSE"])

    def test_null_source_date_is_integrity_error(self):
        rows = source_rows("TWSE", source_as_of_date=None) + source_rows("TPEX")
        self.assertIn("NULL_SOURCE_DATE", integrity_failures(rows)["TWSE"])

    def test_inconsistent_source_dates_are_integrity_error(self):
        rows = self.valid_rows()
        rows[0]["source_as_of_date"] = date(2026, 10, 15)
        self.assertIn("INCONSISTENT_SOURCE_DATE", integrity_failures(rows)["TWSE"])

    def test_invalid_retrieval_timestamps_are_integrity_errors(self):
        cases = (
            (None, "NULL_RETRIEVAL_TIMESTAMP"),
            (
                datetime(2026, 10, 16, 20, 0, 1, tzinfo=timezone.utc),
                "FUTURE_RETRIEVAL_TIMESTAMP",
            ),
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

    def test_integrity_sql_remains_enabled(self):
        directory = Path(__file__).parent
        integrity = (directory / "test_security_master_source_integrity.sql").read_text()
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
