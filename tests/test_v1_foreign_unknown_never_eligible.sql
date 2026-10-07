SELECT *
FROM {{ ref('int_v1_fundamental_eligibility') }}
WHERE issuer_origin IN ('FOREIGN_REGISTERED', 'UNKNOWN')
  AND is_v1_fundamental_eligible
