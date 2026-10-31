import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ELIGIBILITY = (ROOT / 'models/intermediate/int_v1_fundamental_eligibility.sql').read_text()
DAILY = (ROOT / 'models/marts/research/mart_factor_research_daily.sql').read_text()
MONTHLY = (ROOT / 'models/marts/research/mart_factor_research_monthly.sql').read_text()
MASTER = (ROOT / 'models/marts/core/mart_vbt_master_dataset.sql').read_text()


def classify_security_master(row):
    """Mirror the model's classification boundary for focused local cases."""
    if row is None:
        return {
            'match_status': 'UNMATCHED',
            'issuer_origin': 'UNKNOWN',
            'market': None,
            'financial_schema_class': None,
            'eligible': True,
            'reason': 'ELIGIBLE_UNCLASSIFIED',
        }
    if not row.get('source_contract_valid'):
        return {
            **row,
            'match_status': 'MATCHED',
            'eligible': False,
            'reason': 'SOURCE_CONTRACT_INVALID',
        }
    if row.get('market') not in {'TWSE', 'TPEX'}:
        return {
            **row,
            'match_status': 'MATCHED',
            'eligible': False,
            'reason': 'MARKET_MISMATCH',
        }
    if row.get('issuer_origin') in {None, 'UNKNOWN'}:
        return {
            **row,
            'match_status': 'MATCHED',
            'eligible': False,
            'reason': 'UNKNOWN_ISSUER_ORIGIN',
        }
    if row.get('issuer_origin') == 'FOREIGN_REGISTERED':
        return {
            **row,
            'match_status': 'MATCHED',
            'eligible': False,
            'reason': 'FOREIGN_REGISTERED',
        }
    if row.get('financial_schema_class') is None:
        return {
            **row,
            'match_status': 'MATCHED',
            'eligible': False,
            'reason': 'FINANCIAL_SCHEMA_UNMATCHED',
        }
    if row.get('financial_schema_class') != 'ci':
        return {
            **row,
            'match_status': 'MATCHED',
            'eligible': False,
            'reason': 'NON_GENERAL_INDUSTRY_SCHEMA',
        }
    if row.get('issuer_origin') == 'DOMESTIC':
        return {**row, 'match_status': 'MATCHED', 'eligible': True, 'reason': 'ELIGIBLE'}
    return {
        **row,
        'match_status': 'MATCHED',
        'eligible': False,
        'reason': 'UNKNOWN_ISSUER_ORIGIN',
    }


def included_in_monthly(row, *, has_income=True, has_balance=True):
    if not has_income or not has_balance:
        return False
    return classify_security_master(row)['eligible']


class IssuerEligibilityContractTest(unittest.TestCase):
    def test_no_company_name_or_ky_heuristic(self):
        self.assertNotIn('company_name', ELIGIBILITY.lower())
        self.assertNotIn('-ky', ELIGIBILITY.lower())

    def test_known_unknown_and_foreign_fail_closed(self):
        self.assertIn("s.issuer_origin = 'DOMESTIC'", ELIGIBILITY)
        self.assertIn("'FOREIGN_REGISTERED'", ELIGIBILITY)
        self.assertIn("WHEN s.ticker IS NULL THEN TRUE", ELIGIBILITY)
        self.assertIn("'ELIGIBLE_UNCLASSIFIED'", ELIGIBILITY)

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

    def test_valid_eligible_company_is_included(self):
        row = {
            'source_contract_valid': True,
            'market': 'TWSE',
            'issuer_origin': 'DOMESTIC',
            'financial_schema_class': 'ci',
        }
        result = classify_security_master(row)
        self.assertTrue(included_in_monthly(row))
        self.assertEqual(result['reason'], 'ELIGIBLE')

    def test_known_foreign_company_is_excluded(self):
        row = {
            'source_contract_valid': True,
            'market': 'TWSE',
            'issuer_origin': 'FOREIGN_REGISTERED',
            'financial_schema_class': 'ci',
        }
        result = classify_security_master(row)
        self.assertFalse(included_in_monthly(row))
        self.assertEqual(result['reason'], 'FOREIGN_REGISTERED')

    def test_known_special_schema_is_excluded(self):
        row = {
            'source_contract_valid': True,
            'market': 'TPEX',
            'issuer_origin': 'DOMESTIC',
            'financial_schema_class': 'basi',
        }
        result = classify_security_master(row)
        self.assertFalse(included_in_monthly(row))
        self.assertEqual(result['reason'], 'NON_GENERAL_INDUSTRY_SCHEMA')

    def test_missing_security_master_is_included_but_unclassified(self):
        result = classify_security_master(None)
        self.assertTrue(included_in_monthly(None))
        self.assertEqual(result['match_status'], 'UNMATCHED')
        self.assertEqual(result['issuer_origin'], 'UNKNOWN')
        self.assertIsNone(result['market'])
        self.assertIsNone(result['financial_schema_class'])
        self.assertEqual(result['reason'], 'ELIGIBLE_UNCLASSIFIED')

    def test_missing_required_research_data_still_excludes(self):
        self.assertFalse(included_in_monthly(None, has_income=False))
        self.assertFalse(included_in_monthly(None, has_balance=False))

    def test_matched_invalid_classification_is_not_treated_as_eligible(self):
        row = {
            'source_contract_valid': False,
            'market': 'TWSE',
            'issuer_origin': 'DOMESTIC',
            'financial_schema_class': 'ci',
        }
        result = classify_security_master(row)
        self.assertFalse(included_in_monthly(row))
        self.assertEqual(result['reason'], 'SOURCE_CONTRACT_INVALID')


if __name__ == '__main__':
    unittest.main(verbosity=2)
