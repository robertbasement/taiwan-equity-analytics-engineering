{{ config(materialized='view') }}

WITH dividend_union AS (

  SELECT 
    ticker,
    DATE(ex_dividend_date) AS ex_date,
    SAFE_CAST(REPLACE(CAST(reference_price_ex_dividend AS STRING), ',', '') AS FLOAT64) AS ref_price,
    SAFE_CAST(REPLACE(CAST(close_price_pre_adjust AS STRING), ',', '') AS FLOAT64) AS pre_close
  FROM {{ source('stock_data', 'sii_dividend') }}

  UNION ALL

  SELECT 
    ticker,
    DATE(ex_dividend_date) AS ex_date,
    SAFE_CAST(REPLACE(CAST(reference_price_ex_dividend AS STRING), ',', '') AS FLOAT64) AS ref_price,
    SAFE_CAST(REPLACE(CAST(close_price_pre_adjust AS STRING), ',', '') AS FLOAT64) AS pre_close
  FROM {{ source('stock_data', 'otc_dividend') }}

),
valid_factors AS (
  SELECT ticker, ex_date, SAFE_DIVIDE(ref_price, pre_close) AS daily_factor
  FROM dividend_union
  WHERE pre_close > 0
    AND ref_price > 0
    AND ex_date >= DATE '2000-01-01'
),
checked AS (
  SELECT *, COUNT(*) OVER (PARTITION BY ticker, ex_date) AS event_count
  FROM valid_factors
)

SELECT ticker, ex_date,
  CASE WHEN event_count > 1 THEN ERROR(CONCAT(
    'duplicate dividend factor: ', ticker, ' ', CAST(ex_date AS STRING)
  )) ELSE daily_factor END AS daily_factor
FROM checked
