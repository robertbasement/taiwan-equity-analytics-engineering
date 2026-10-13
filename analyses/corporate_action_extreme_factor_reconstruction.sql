-- SELECT-only reconstruction of every source factor outside [0.5, 1.5].
--
-- `local_adjusted_pre_price` deliberately applies only the event under review.
-- This avoids mixing later hindsight factors into the continuity diagnostic.

WITH source_events AS (

  SELECT
    'SII' AS source_table,
    ex_dividend_date,
    ticker,
    reference_price_ex_dividend AS source_reference_raw,
    close_price_pre_adjust AS source_pre_close_raw,
    SAFE_CAST(REPLACE(reference_price_ex_dividend, ',', '') AS FLOAT64)
      AS source_reference_price,
    SAFE_CAST(REPLACE(close_price_pre_adjust, ',', '') AS FLOAT64)
      AS source_pre_close
  FROM {{ source('stock_data', 'sii_dividend') }}

  UNION ALL

  SELECT
    'OTC',
    ex_dividend_date,
    ticker,
    reference_price_ex_dividend,
    close_price_pre_adjust,
    SAFE_CAST(REPLACE(reference_price_ex_dividend, ',', '') AS FLOAT64),
    SAFE_CAST(REPLACE(close_price_pre_adjust, ',', '') AS FLOAT64)
  FROM {{ source('stock_data', 'otc_dividend') }}

),

extreme AS (

  SELECT
    *,
    DATE(ex_dividend_date) AS event_date,
    SAFE_DIVIDE(source_reference_price, source_pre_close) AS calculated_factor
  FROM source_events
  WHERE source_pre_close > 0
    AND source_reference_price > 0
    AND (
      SAFE_DIVIDE(source_reference_price, source_pre_close) < 0.5
      OR SAFE_DIVIDE(source_reference_price, source_pre_close) > 1.5
    )

),

prices AS (

  SELECT
    date,
    CAST(ticker AS STRING) AS ticker,
    SAFE_CAST(close AS FLOAT64) AS raw_close
  FROM {{ source('stock_data', 'daily_prices_partitioned') }}
  WHERE SAFE_CAST(close AS FLOAT64) > 0

),

pre_event AS (

  SELECT
    e.source_table,
    e.ticker,
    e.event_date,
    ARRAY_AGG(
      STRUCT(p.date, p.raw_close)
      ORDER BY p.date DESC
      LIMIT 1
    )[SAFE_OFFSET(0)] AS quote
  FROM extreme e
  LEFT JOIN prices p
    ON p.ticker = e.ticker
   AND p.date < e.event_date
  GROUP BY 1, 2, 3

),

on_or_after_event AS (

  SELECT
    e.source_table,
    e.ticker,
    e.event_date,
    ARRAY_AGG(
      STRUCT(p.date, p.raw_close)
      ORDER BY p.date
      LIMIT 1
    )[SAFE_OFFSET(0)] AS quote
  FROM extreme e
  LEFT JOIN prices p
    ON p.ticker = e.ticker
   AND p.date >= e.event_date
  GROUP BY 1, 2, 3

)

SELECT
  e.source_table,
  e.ticker,
  e.event_date,
  e.source_reference_raw,
  e.source_pre_close_raw,
  e.source_reference_price,
  e.source_pre_close,
  e.calculated_factor,
  pre.quote.date AS pre_market_date,
  pre.quote.raw_close AS pre_market_raw_close,
  pre.quote.raw_close * e.calculated_factor AS local_adjusted_pre_price,
  IF(post.quote.date = e.event_date, post.quote.raw_close, NULL)
    AS event_date_raw_close,
  post.quote.date AS first_quote_date,
  post.quote.raw_close AS first_quote_raw_close,
  SAFE_DIVIDE(
    post.quote.raw_close,
    pre.quote.raw_close * e.calculated_factor
  ) AS continuity_ratio,
  SAFE_DIVIDE(post.quote.raw_close, pre.quote.raw_close) AS observed_price_ratio,
  SAFE_DIVIDE(e.source_pre_close, pre.quote.raw_close) AS source_vs_market_pre_ratio
FROM extreme e
LEFT JOIN pre_event pre
  USING (source_table, ticker, event_date)
LEFT JOIN on_or_after_event post
  USING (source_table, ticker, event_date)
ORDER BY event_date, ticker
