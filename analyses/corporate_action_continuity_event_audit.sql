-- READ-ONLY event-level corporate-action continuity audit.
--
-- Diagnostic thresholds (descriptive, not universal economic truths):
--   plausible event continuity / raw one-step move: [0.80, 1.20]
--   close match: within 2%
--   broad source-basis match: within 5%
--   material source factor: more than 5% away from 1.0
--   material warehouse/source basis mismatch: more than 20%
--
-- The source schema exposes only ticker, date, pre-close and reference price.
-- Event type is therefore explicitly unavailable rather than inferred.

WITH source_rows AS (

  SELECT
    'TWSE' AS market,
    'sii_dividend' AS source_table,
    CAST(ticker AS STRING) AS ticker,
    DATE(ex_dividend_date) AS event_date,
    'UNAVAILABLE_IN_SOURCE_SCHEMA' AS event_type,
    SAFE_CAST(REPLACE(CAST(close_price_pre_adjust AS STRING), ',', '') AS FLOAT64)
      AS source_pre_close,
    SAFE_CAST(REPLACE(CAST(reference_price_ex_dividend AS STRING), ',', '') AS FLOAT64)
      AS source_reference_price
  FROM {{ source('stock_data', 'sii_dividend') }}

  UNION ALL

  SELECT
    'TPEX',
    'otc_dividend',
    CAST(ticker AS STRING),
    DATE(ex_dividend_date),
    'UNAVAILABLE_IN_SOURCE_SCHEMA',
    SAFE_CAST(REPLACE(CAST(close_price_pre_adjust AS STRING), ',', '') AS FLOAT64),
    SAFE_CAST(REPLACE(CAST(reference_price_ex_dividend AS STRING), ',', '') AS FLOAT64)
  FROM {{ source('stock_data', 'otc_dividend') }}

),

-- Preserve conflicting source rows as separate audit events, while collapsing
-- byte-for-byte duplicates and exposing their multiplicity.
events AS (

  SELECT
    market,
    source_table,
    ticker,
    event_date,
    event_type,
    source_pre_close,
    source_reference_price,
    COUNT(*) AS identical_source_row_count,
    SAFE_DIVIDE(source_reference_price, source_pre_close) AS source_factor
  FROM source_rows
  GROUP BY 1, 2, 3, 4, 5, 6, 7

),

prices AS (

  SELECT
    DATE(date) AS date,
    CAST(ticker AS STRING) AS ticker,
    SAFE_CAST(close AS FLOAT64) AS raw_close
  FROM {{ source('stock_data', 'daily_prices_partitioned') }}
  WHERE SAFE_CAST(close AS FLOAT64) > 0

),

market_calendar AS (

  SELECT DISTINCT date
  FROM prices

),

pre_event AS (

  SELECT
    e.market,
    e.source_table,
    e.ticker,
    e.event_date,
    e.source_pre_close,
    e.source_reference_price,
    ARRAY_AGG(
      STRUCT(p.date AS quote_date, p.raw_close AS quote_close)
      ORDER BY p.date DESC
      LIMIT 1
    )[SAFE_OFFSET(0)] AS quote
  FROM events e
  LEFT JOIN prices p
    ON p.ticker = e.ticker
   AND p.date < e.event_date
  GROUP BY 1, 2, 3, 4, 5, 6

),

post_event AS (

  SELECT
    e.market,
    e.source_table,
    e.ticker,
    e.event_date,
    e.source_pre_close,
    e.source_reference_price,
    ARRAY_AGG(
      STRUCT(p.date AS quote_date, p.raw_close AS quote_close)
      ORDER BY p.date
      LIMIT 1
    )[SAFE_OFFSET(0)] AS quote
  FROM events e
  LEFT JOIN prices p
    ON p.ticker = e.ticker
   AND p.date >= e.event_date
  GROUP BY 1, 2, 3, 4, 5, 6

),

reconstructed AS (

  SELECT
    e.*,
    pre.quote.quote_date AS warehouse_pre_date,
    pre.quote.quote_close AS warehouse_pre_close,
    pre.quote.quote_close * e.source_factor AS expected_adjusted_pre_close,
    post.quote.quote_date AS first_post_date,
    post.quote.quote_close AS first_post_close,
    DATE_DIFF(post.quote.quote_date, pre.quote.quote_date, DAY)
      AS calendar_days_pre_to_post,
    (
      SELECT COUNT(*)
      FROM market_calendar c
      WHERE c.date > pre.quote.quote_date
        AND c.date <= post.quote.quote_date
    ) AS market_sessions_pre_to_post,
    SAFE_DIVIDE(pre.quote.quote_close, e.source_pre_close)
      AS warehouse_pre_to_source_pre,
    SAFE_DIVIDE(pre.quote.quote_close, e.source_reference_price)
      AS warehouse_pre_to_source_reference,
    SAFE_DIVIDE(post.quote.quote_close, e.source_reference_price)
      AS first_post_to_source_reference,
    SAFE_DIVIDE(post.quote.quote_close, pre.quote.quote_close)
      AS warehouse_unadjusted_step_ratio,
    SAFE_DIVIDE(
      post.quote.quote_close,
      pre.quote.quote_close * e.source_factor
    ) AS continuity_ratio
  FROM events e
  LEFT JOIN pre_event pre
    USING (
      market,
      source_table,
      ticker,
      event_date,
      source_pre_close,
      source_reference_price
    )
  LEFT JOIN post_event post
    USING (
      market,
      source_table,
      ticker,
      event_date,
      source_pre_close,
      source_reference_price
    )

),

classified AS (

  SELECT
    *,
    CASE
      WHEN source_pre_close IS NULL
        OR source_reference_price IS NULL
        OR source_pre_close <= 0
        OR source_reference_price <= 0
        OR warehouse_pre_close IS NULL
        OR first_post_close IS NULL
        THEN 'INSUFFICIENT_DATA'

      -- Strong double-adjustment signature: warehouse pre-close is already
      -- approximately the source's post-action reference basis.
      WHEN ABS(warehouse_pre_to_source_reference - 1.0) <= 0.02
        AND ABS(source_factor - 1.0) > 0.05
        THEN 'POSSIBLE_BASIS_MISMATCH'

      -- More general mixed-basis signature: source/warehouse pre-event levels
      -- disagree, applying the factor breaks continuity, but the warehouse's
      -- own adjacent sequence remains economically plausible.
      WHEN (warehouse_pre_to_source_pre < 0.80 OR warehouse_pre_to_source_pre > 1.20)
        AND (continuity_ratio < 0.80 OR continuity_ratio > 1.20)
        AND warehouse_unadjusted_step_ratio BETWEEN 0.80 AND 1.20
        THEN 'POSSIBLE_BASIS_MISMATCH'

      -- The warehouse agrees with the reported pre-close but neither applying
      -- the reference ratio nor comparing the post quote to the reference
      -- yields plausible continuity. This flags the source row for review; it
      -- does not assert that the source is wrong.
      WHEN ABS(warehouse_pre_to_source_pre - 1.0) <= 0.05
        AND (continuity_ratio < 0.80 OR continuity_ratio > 1.20)
        AND (first_post_to_source_reference < 0.80
          OR first_post_to_source_reference > 1.20)
        THEN 'POSSIBLE_SOURCE_ANOMALY'

      WHEN continuity_ratio BETWEEN 0.80 AND 1.20
        THEN 'CONTINUOUS'

      ELSE 'REVIEW_REQUIRED'
    END AS diagnostic_classification,
    ABS(warehouse_pre_to_source_reference - 1.0) <= 0.02
      AND ABS(source_factor - 1.0) > 0.05
      AS strong_double_adjustment_signature,
    CASE
      WHEN event_date < DATE '2010-01-01' THEN '2000-2009'
      WHEN event_date < DATE '2015-01-01' THEN '2010-2014'
      WHEN event_date < DATE '2020-01-01' THEN '2015-2019'
      WHEN event_date < DATE '2024-01-01' THEN '2020-2023'
      ELSE '2024+'
    END AS historical_era
  FROM reconstructed

)

SELECT *
FROM classified
ORDER BY event_date, market, ticker, source_pre_close, source_reference_price
