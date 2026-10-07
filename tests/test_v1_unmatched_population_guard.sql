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
relevant AS (
  SELECT i.ticker
  FROM income_tickers i
  INNER JOIN balance_tickers b USING (ticker)
),
counts AS (
  SELECT
    COUNT(*) AS relevant_tickers,
    COUNTIF(e.security_master_match_status = 'UNMATCHED') AS unmatched_tickers
  FROM relevant r
  LEFT JOIN {{ ref('int_v1_fundamental_eligibility') }} e USING (ticker)
)
SELECT *
FROM counts
WHERE SAFE_DIVIDE(unmatched_tickers, relevant_tickers) > 0.005
   OR unmatched_tickers > 11  -- C1 baseline 6 plus approved review delta 5.
