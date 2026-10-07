SELECT *
FROM {{ ref('dim_security_master') }}
WHERE NOT source_contract_valid
   OR source_sha256 IS NULL
   OR schema_contract_version != 'issuer_origin_v1'
