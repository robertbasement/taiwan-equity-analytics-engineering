{{ config(severity='error') }}

-- One diagnostic row per expected market plus one per unexpected market value.
-- Ticker/key uniqueness remains covered by dim_security_master.yml.
WITH expected_markets AS (
  SELECT market
  FROM UNNEST(['TWSE', 'TPEX']) AS market
),

source_summary AS (
  SELECT
    market,
    COUNT(*) AS row_count,
    COUNT(DISTINCT source_as_of_date) AS source_date_count,
    MIN(source_as_of_date) AS min_source_as_of_date,
    MAX(source_as_of_date) AS max_source_as_of_date,
    COUNTIF(source_as_of_date IS NULL) AS null_source_date_rows,
    COUNT(DISTINCT source_retrieved_at) AS retrieval_count,
    MIN(source_retrieved_at) AS min_source_retrieved_at,
    MAX(source_retrieved_at) AS max_source_retrieved_at,
    COUNTIF(source_retrieved_at IS NULL) AS null_retrieval_rows,
    COUNTIF(NOT COALESCE(source_contract_valid, FALSE)) AS invalid_contract_rows,
    COUNTIF(source_system IS NULL OR source_system != market) AS invalid_source_system_rows,
    COUNTIF(source_interface IS NULL OR TRIM(source_interface) = '') AS missing_interface_rows
  FROM {{ ref('dim_security_master') }}
  WHERE market IN ('TWSE', 'TPEX')
  GROUP BY market
),

expected_market_diagnostics AS (
  SELECT
    expected.market,
    COALESCE(actual.row_count, 0) AS row_count,
    actual.min_source_as_of_date,
    actual.max_source_as_of_date,
    actual.min_source_retrieved_at,
    actual.max_source_retrieved_at,
    ARRAY_TO_STRING(ARRAY(
      SELECT reason
      FROM UNNEST([
        IF(COALESCE(actual.row_count, 0) = 0, 'MISSING_SOURCE', NULL),
        IF(COALESCE(actual.null_source_date_rows, 0) > 0, 'NULL_SOURCE_DATE', NULL),
        IF(COALESCE(actual.source_date_count, 0) != 1, 'INCONSISTENT_SOURCE_DATE', NULL),
        IF(actual.max_source_as_of_date > CURRENT_DATE('Asia/Taipei'), 'FUTURE_SOURCE_DATE', NULL),
        IF(COALESCE(actual.null_retrieval_rows, 0) > 0, 'NULL_RETRIEVAL_TIMESTAMP', NULL),
        IF(COALESCE(actual.retrieval_count, 0) != 1, 'INCONSISTENT_RETRIEVAL_TIMESTAMP', NULL),
        IF(actual.max_source_retrieved_at > CURRENT_TIMESTAMP(), 'FUTURE_RETRIEVAL_TIMESTAMP', NULL),
        IF(
          DATE(actual.min_source_retrieved_at, 'Asia/Taipei') < actual.max_source_as_of_date,
          'RETRIEVAL_BEFORE_SOURCE_DATE',
          NULL
        ),
        IF(COALESCE(actual.invalid_contract_rows, 0) > 0, 'INVALID_SOURCE_CONTRACT', NULL),
        IF(COALESCE(actual.invalid_source_system_rows, 0) > 0, 'SOURCE_SYSTEM_MISMATCH', NULL),
        IF(COALESCE(actual.missing_interface_rows, 0) > 0, 'MISSING_SOURCE_INTERFACE', NULL)
      ]) AS reason
      WHERE reason IS NOT NULL
    ), ',') AS failure_reasons
  FROM expected_markets AS expected
  LEFT JOIN source_summary AS actual USING (market)
),

unexpected_market_diagnostics AS (
  SELECT
    COALESCE(market, '<NULL>') AS market,
    COUNT(*) AS row_count,
    MIN(source_as_of_date) AS min_source_as_of_date,
    MAX(source_as_of_date) AS max_source_as_of_date,
    MIN(source_retrieved_at) AS min_source_retrieved_at,
    MAX(source_retrieved_at) AS max_source_retrieved_at,
    'INVALID_MARKET_METADATA' AS failure_reasons
  FROM {{ ref('dim_security_master') }}
  WHERE market IS NULL OR market NOT IN ('TWSE', 'TPEX')
  GROUP BY market
)

SELECT *
FROM expected_market_diagnostics
WHERE failure_reasons != ''

UNION ALL

SELECT *
FROM unexpected_market_diagnostics
