SELECT *
FROM {{ ref('int_v1_fundamental_eligibility') }}
WHERE security_master_match_status = 'MATCHED'
  AND issuer_origin IN ('FOREIGN_REGISTERED', 'UNKNOWN')
  AND is_v1_fundamental_eligible
