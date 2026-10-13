-- Independent 2025-08-15 Revenue YoY quintile and price-return reconstruction.

WITH formation AS (
  SELECT
    rebalance_date,
    next_rebalance_date,
    ticker,
    yoy_growth,
    market_cap,
    d_close,
    forward_return,
    NTILE(5) OVER (ORDER BY yoy_growth, ticker) AS revenue_yoy_quintile
  FROM {{ ref('mart_factor_research_monthly') }}
  WHERE rebalance_date = DATE '2025-08-15'
    AND ticker != '0050'
    AND yoy_growth IS NOT NULL
),

eligible AS (
  SELECT
    f.*,
    f.d_close AS entry_price,
    d.d_close AS exit_price
  FROM formation f
  LEFT JOIN {{ ref('mart_factor_research_daily') }} d
    ON d.date = f.next_rebalance_date
   AND d.ticker = f.ticker
  WHERE f.forward_return IS NOT NULL
)

SELECT
  revenue_yoy_quintile,
  COUNT(*) AS n,
  COUNT(*) * (1.0 / COUNT(*)) AS equal_weight_sum,
  AVG(forward_return) AS reported_equal_return,
  AVG(SAFE_DIVIDE(exit_price, entry_price) - 1) AS recomputed_equal_return,
  SAFE_DIVIDE(SUM(market_cap * forward_return), SUM(market_cap))
    AS reported_value_return,
  SAFE_DIVIDE(
    SUM(market_cap * (SAFE_DIVIDE(exit_price, entry_price) - 1)),
    SUM(market_cap)
  ) AS recomputed_value_return
FROM eligible
GROUP BY revenue_yoy_quintile
ORDER BY revenue_yoy_quintile
