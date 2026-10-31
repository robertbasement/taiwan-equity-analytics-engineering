SELECT *
FROM {{ ref('int_v1_fundamental_eligibility') }}
WHERE security_master_match_status = 'UNMATCHED'
  AND (
    NOT is_v1_fundamental_eligible
    OR issuer_origin != 'UNKNOWN'
    OR market IS NOT NULL
    OR financial_schema_class IS NOT NULL
    OR source_as_of_date IS NOT NULL
    OR ineligibility_reason != 'ELIGIBLE_UNCLASSIFIED'
  )
