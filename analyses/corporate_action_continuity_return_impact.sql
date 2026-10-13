-- READ-ONLY linkage from diagnostically suspicious corporate-action events to
-- production daily and monthly return labels and Revenue YoY quintiles.
--
-- This intentionally repeats the classification in the event-level audit so
-- the analysis remains independently executable: analyses are not dbt refs.

WITH source_rows AS (

  SELECT
    'TWSE' AS market,
    'sii_dividend' AS source_table,
    CAST(ticker AS STRING) AS ticker,
    DATE(ex_dividend_date) AS event_date,
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
    SAFE_CAST(REPLACE(CAST(close_price_pre_adjust AS STRING), ',', '') AS FLOAT64),
    SAFE_CAST(REPLACE(CAST(reference_price_ex_dividend AS STRING), ',', '') AS FLOAT64)
  FROM {{ source('stock_data', 'otc_dividend') }}

),

events AS (

  SELECT DISTINCT
    *,
    SAFE_DIVIDE(source_reference_price, source_pre_close) AS source_factor
  FROM source_rows

),

prices AS (

  SELECT
    DATE(date) AS date,
    CAST(ticker AS STRING) AS ticker,
    SAFE_CAST(close AS FLOAT64) AS raw_close
  FROM {{ source('stock_data', 'daily_prices_partitioned') }}
  WHERE SAFE_CAST(close AS FLOAT64) > 0

),

pre_event AS (

  SELECT
    e.*,
    ARRAY_AGG(
      STRUCT(p.date AS quote_date, p.raw_close AS quote_close)
      ORDER BY p.date DESC LIMIT 1
    )[SAFE_OFFSET(0)] AS quote
  FROM events e
  LEFT JOIN prices p
    ON p.ticker = e.ticker
   AND p.date < e.event_date
  GROUP BY 1, 2, 3, 4, 5, 6, 7

),

reconstructed AS (

  SELECT
    pre.* EXCEPT (quote),
    pre.quote.quote_date AS warehouse_pre_date,
    pre.quote.quote_close AS warehouse_pre_close,
    post.quote.quote_date AS first_post_date,
    post.quote.quote_close AS first_post_close,
    SAFE_DIVIDE(pre.quote.quote_close, pre.source_pre_close)
      AS warehouse_pre_to_source_pre,
    SAFE_DIVIDE(pre.quote.quote_close, pre.source_reference_price)
      AS warehouse_pre_to_source_reference,
    SAFE_DIVIDE(post.quote.quote_close, pre.source_reference_price)
      AS first_post_to_source_reference,
    SAFE_DIVIDE(post.quote.quote_close, pre.quote.quote_close)
      AS warehouse_unadjusted_step_ratio,
    SAFE_DIVIDE(
      post.quote.quote_close,
      pre.quote.quote_close * pre.source_factor
    ) AS continuity_ratio
  FROM pre_event pre
  LEFT JOIN (
    SELECT
      e.market,
      e.source_table,
      e.ticker,
      e.event_date,
      e.source_pre_close,
      e.source_reference_price,
      ARRAY_AGG(
        STRUCT(p.date AS quote_date, p.raw_close AS quote_close)
        ORDER BY p.date LIMIT 1
      )[SAFE_OFFSET(0)] AS quote
    FROM events e
    LEFT JOIN prices p
      ON p.ticker = e.ticker
     AND p.date >= e.event_date
    GROUP BY 1, 2, 3, 4, 5, 6
  ) post
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
      WHEN ABS(warehouse_pre_to_source_reference - 1.0) <= 0.02
        AND ABS(source_factor - 1.0) > 0.05
        THEN 'POSSIBLE_BASIS_MISMATCH'
      WHEN (warehouse_pre_to_source_pre < 0.80 OR warehouse_pre_to_source_pre > 1.20)
        AND (continuity_ratio < 0.80 OR continuity_ratio > 1.20)
        AND warehouse_unadjusted_step_ratio BETWEEN 0.80 AND 1.20
        THEN 'POSSIBLE_BASIS_MISMATCH'
      WHEN ABS(warehouse_pre_to_source_pre - 1.0) <= 0.05
        AND (continuity_ratio < 0.80 OR continuity_ratio > 1.20)
        AND (first_post_to_source_reference < 0.80
          OR first_post_to_source_reference > 1.20)
        THEN 'POSSIBLE_SOURCE_ANOMALY'
      WHEN continuity_ratio BETWEEN 0.80 AND 1.20 THEN 'CONTINUOUS'
      ELSE 'REVIEW_REQUIRED'
    END AS diagnostic_classification
  FROM reconstructed

),

suspect_events AS (

  SELECT
    c.*,
    c.first_post_date = c.event_date AS materialized_event_date_price_present,
    (
      SELECT MIN(p.date)
      FROM prices p
      WHERE p.ticker = c.ticker
        AND p.date > c.event_date
    ) AS first_strictly_after_event_date
  FROM classified c
  WHERE diagnostic_classification = 'POSSIBLE_BASIS_MISMATCH'

),

formation AS (

  SELECT
    m.*,
    NTILE(5) OVER (
      PARTITION BY rebalance_date
      ORDER BY yoy_growth, ticker
    ) AS revenue_yoy_quintile
  FROM {{ ref('mart_factor_research_monthly') }} m
  WHERE ticker != '0050'
    AND yoy_growth IS NOT NULL

),

affected_labels AS (

  SELECT DISTINCT
    f.rebalance_date,
    f.next_rebalance_date,
    f.ticker,
    f.revenue_yoy_quintile
  FROM formation f
  INNER JOIN suspect_events s
    ON s.ticker = f.ticker
   AND s.materialized_event_date_price_present
   AND f.rebalance_date < s.event_date
   AND f.next_rebalance_date >= s.first_post_date
  WHERE f.forward_return IS NOT NULL

),

portfolio_comparison AS (

  SELECT
    f.rebalance_date,
    f.revenue_yoy_quintile,
    COUNTIF(f.forward_return IS NOT NULL) AS current_n,
    AVG(f.forward_return) AS current_equal_weight_return,
    COUNTIF(
      f.forward_return IS NOT NULL AND a.ticker IS NULL
    ) AS diagnostic_n,
    AVG(IF(a.ticker IS NULL, f.forward_return, NULL))
      AS diagnostic_equal_weight_return_ex_suspect,
    COUNTIF(a.ticker IS NOT NULL) AS suspect_observations_excluded
  FROM formation f
  LEFT JOIN affected_labels a
    USING (rebalance_date, next_rebalance_date, ticker, revenue_yoy_quintile)
  WHERE f.forward_return IS NOT NULL
  GROUP BY 1, 2

),

overall_quintile_comparison AS (

  SELECT
    revenue_yoy_quintile,
    COUNT(*) AS portfolio_months,
    AVG(current_equal_weight_return) AS current_mean_monthly_return,
    AVG(diagnostic_equal_weight_return_ex_suspect)
      AS diagnostic_mean_monthly_return_ex_suspect,
    AVG(
      current_equal_weight_return
      - diagnostic_equal_weight_return_ex_suspect
    ) AS mean_monthly_difference
  FROM portfolio_comparison
  GROUP BY 1

),

monthly_spreads AS (

  SELECT
    rebalance_date,
    MAX(IF(revenue_yoy_quintile = 5, current_equal_weight_return, NULL))
      - MAX(IF(revenue_yoy_quintile = 1, current_equal_weight_return, NULL))
      AS current_q5_minus_q1,
    MAX(IF(
      revenue_yoy_quintile = 5,
      diagnostic_equal_weight_return_ex_suspect,
      NULL
    ))
      - MAX(IF(
        revenue_yoy_quintile = 1,
        diagnostic_equal_weight_return_ex_suspect,
        NULL
      )) AS diagnostic_q5_minus_q1
  FROM portfolio_comparison
  GROUP BY 1

),

overall_spread_comparison AS (

  SELECT
    AVG(current_q5_minus_q1) AS current_mean_q5_minus_q1,
    AVG(diagnostic_q5_minus_q1) AS diagnostic_mean_q5_minus_q1,
    AVG(current_q5_minus_q1 - diagnostic_q5_minus_q1)
      AS mean_q5_minus_q1_difference
  FROM monthly_spreads

)

SELECT
  s.market,
  s.source_table,
  s.ticker,
  s.event_date,
  s.source_factor,
  s.warehouse_pre_date,
  s.warehouse_pre_close,
  s.first_post_date,
  s.first_post_close,
  s.continuity_ratio,
  s.materialized_event_date_price_present,
  s.first_strictly_after_event_date AS materialized_transition_date,
  daily.stock_return AS production_transition_daily_return,
  s.continuity_ratio - 1.0 AS reconstructed_event_daily_return,
  f.rebalance_date,
  f.next_rebalance_date,
  f.yoy_growth,
  f.revenue_yoy_quintile,
  f.forward_return AS production_monthly_forward_return,
  p.current_n AS current_quintile_n,
  p.current_equal_weight_return,
  p.diagnostic_n,
  p.diagnostic_equal_weight_return_ex_suspect,
  p.current_equal_weight_return
    - p.diagnostic_equal_weight_return_ex_suspect AS portfolio_return_difference,
  p.suspect_observations_excluded,
  oq.portfolio_months AS all_research_portfolio_months,
  oq.current_mean_monthly_return AS overall_current_quintile_mean,
  oq.diagnostic_mean_monthly_return_ex_suspect
    AS overall_diagnostic_quintile_mean,
  oq.mean_monthly_difference AS overall_quintile_mean_difference,
  os.current_mean_q5_minus_q1,
  os.diagnostic_mean_q5_minus_q1,
  os.mean_q5_minus_q1_difference
FROM suspect_events s
LEFT JOIN {{ ref('mart_factor_research_daily') }} daily
  ON daily.ticker = s.ticker
 AND daily.date = s.first_strictly_after_event_date
 AND s.materialized_event_date_price_present
LEFT JOIN formation f
  ON f.ticker = s.ticker
 AND s.materialized_event_date_price_present
 AND f.rebalance_date < s.event_date
 AND f.next_rebalance_date >= s.first_post_date
 AND f.forward_return IS NOT NULL
LEFT JOIN portfolio_comparison p
  ON p.rebalance_date = f.rebalance_date
 AND p.revenue_yoy_quintile = f.revenue_yoy_quintile
LEFT JOIN overall_quintile_comparison oq
  ON oq.revenue_yoy_quintile = f.revenue_yoy_quintile
CROSS JOIN overall_spread_comparison os
ORDER BY s.event_date, s.market, s.ticker, f.rebalance_date
