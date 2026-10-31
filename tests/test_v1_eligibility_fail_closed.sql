SELECT *
FROM {{ ref('int_v1_fundamental_eligibility') }}
WHERE is_v1_fundamental_eligible
  AND NOT COALESCE(
    (
      security_master_match_status = 'UNMATCHED'
      AND (
        issuer_origin = 'UNKNOWN'
        AND market IS NULL
        AND financial_schema_class IS NULL
        AND ineligibility_reason = 'ELIGIBLE_UNCLASSIFIED'
      )
    )
    OR (
      security_master_match_status = 'MATCHED'
      AND (
        issuer_origin = 'DOMESTIC'
        AND financial_schema_class = 'ci'
        AND market IN ('TWSE', 'TPEX')
        AND ineligibility_reason = 'ELIGIBLE'
      )
    ),
    FALSE
  )
