{{ config(materialized='view') }}

WITH income_tickers AS (

  SELECT DISTINCT ticker
  FROM {{ ref('stg_income_statement') }}
  WHERE SAFE_CAST(SUBSTR(year_quarter, 1, 4) AS INT64) >= 2013

),

balance_tickers AS (

  SELECT DISTINCT ticker
  FROM {{ ref('stg_balance_sheet') }}
  WHERE SAFE_CAST(SUBSTR(year_quarter, 1, 4) AS INT64) >= 2013

),

financial_tickers AS (

  -- Income and balance coverage is the minimum research-data requirement.
  -- Security Master classifies this population when a reference row exists,
  -- but missing reference metadata alone must not remove a data-complete ticker.
  SELECT i.ticker
  FROM income_tickers i
  INNER JOIN balance_tickers b USING (ticker)

),

classified AS (

  SELECT
    f.ticker,
    s.market,
    COALESCE(s.issuer_origin, 'UNKNOWN') AS issuer_origin,
    s.financial_schema_class,

    CASE
      WHEN s.ticker IS NULL THEN 'UNMATCHED'
      ELSE 'MATCHED'
    END AS security_master_match_status,

    CASE
      WHEN s.ticker IS NULL THEN TRUE
      ELSE COALESCE(
        s.source_contract_valid
        AND s.market IN ('TWSE', 'TPEX')
        AND s.financial_schema_class = 'ci'
        AND s.issuer_origin = 'DOMESTIC',
        FALSE
      )
    END AS is_v1_fundamental_eligible,

    CASE
      WHEN s.ticker IS NULL THEN 'ELIGIBLE_UNCLASSIFIED'
      WHEN NOT COALESCE(s.source_contract_valid, FALSE) THEN 'SOURCE_CONTRACT_INVALID'
      WHEN s.market IS NULL OR s.market NOT IN ('TWSE', 'TPEX') THEN 'MARKET_MISMATCH'
      WHEN s.issuer_origin IS NULL OR s.issuer_origin = 'UNKNOWN' THEN 'UNKNOWN_ISSUER_ORIGIN'
      WHEN s.issuer_origin = 'FOREIGN_REGISTERED' THEN 'FOREIGN_REGISTERED'
      WHEN s.financial_schema_class IS NULL THEN 'FINANCIAL_SCHEMA_UNMATCHED'
      WHEN s.financial_schema_class != 'ci' THEN 'NON_GENERAL_INDUSTRY_SCHEMA'
      WHEN s.issuer_origin = 'DOMESTIC' THEN 'ELIGIBLE'
      ELSE 'UNKNOWN_ISSUER_ORIGIN'
    END AS ineligibility_reason,

    s.source_as_of_date

  FROM financial_tickers f
  LEFT JOIN {{ ref('dim_security_master') }} s USING (ticker)

)

SELECT *
FROM classified
