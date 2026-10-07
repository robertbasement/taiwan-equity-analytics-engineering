SELECT *
FROM {{ ref('int_v1_fundamental_eligibility') }}
WHERE is_v1_fundamental_eligible
  AND (
    issuer_origin != 'DOMESTIC'
    OR security_master_match_status != 'MATCHED'
    OR financial_schema_class != 'ci'
    OR market NOT IN ('TWSE', 'TPEX')
  )
