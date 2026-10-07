import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ELIGIBILITY = (ROOT / 'models/intermediate/int_v1_fundamental_eligibility.sql').read_text()
DAILY = (ROOT / 'models/marts/research/mart_factor_research_daily.sql').read_text()
MONTHLY = (ROOT / 'models/marts/research/mart_factor_research_monthly.sql').read_text()
MASTER = (ROOT / 'models/marts/core/mart_vbt_master_dataset.sql').read_text()


class IssuerEligibilityContractTest(unittest.TestCase):
    def test_no_company_name_or_ky_heuristic(self):
        self.assertNotIn('company_name', ELIGIBILITY.lower())
        self.assertNotIn('-ky', ELIGIBILITY.lower())

    def test_unknown_and_foreign_fail_closed(self):
        self.assertIn("s.issuer_origin = 'DOMESTIC'", ELIGIBILITY)
        self.assertIn("'FOREIGN_REGISTERED'", ELIGIBILITY)
        self.assertIn("'SECURITY_MASTER_UNMATCHED'", ELIGIBILITY)

    def test_daily_attaches_but_does_not_filter(self):
        self.assertIn("ref('int_v1_fundamental_eligibility')", DAILY)
        self.assertNotIn('WHERE m.is_v1_fundamental_eligible', DAILY)

    def test_monthly_filters_formation_after_calendar_construction(self):
        self.assertIn('WHERE d.is_v1_fundamental_eligible', MONTHLY)
        self.assertIn('SUBSTR(d.report_quarter, 1, 4)', MONTHLY)
        self.assertIn('SUBSTR(d.balance_sheet_quarter, 1, 4)', MONTHLY)
        self.assertIn("WHERE ticker = '0050'", MONTHLY)
        self.assertLess(
            MONTHLY.index("WHERE ticker = '0050'"),
            MONTHLY.index('WHERE d.is_v1_fundamental_eligible'),
        )

    def test_broad_master_is_not_filtered(self):
        self.assertNotIn('issuer_origin', MASTER.lower())
        self.assertNotIn('fundamental_eligible', MASTER.lower())


if __name__ == '__main__':
    unittest.main(verbosity=2)
