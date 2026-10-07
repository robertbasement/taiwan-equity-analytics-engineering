{{ config(materialized='view') }}

SELECT
  ticker,
  market,
  issuer_origin,
  foreign_registration_raw,
  foreign_registration_code,
  foreign_registration_name,
  listing_date,
  financial_schema_class,
  source_as_of_date,
  source_system,
  source_interface,
  source_retrieved_at,
  source_sha256,
  financial_schema_source_sha256,
  schema_contract_version,
  source_contract_valid
FROM {{ source('stock_data', 'security_master') }}
