-- Confirmed corporate-action return discontinuity and equal-weight portfolio impact.

WITH formation AS (
  SELECT
    ticker,
    yoy_growth,
    forward_return,
    NTILE(5) OVER (ORDER BY yoy_growth, ticker) AS revenue_yoy_quintile
  FROM {{ ref('mart_factor_research_monthly') }}
  WHERE rebalance_date = DATE '2018-05-15'
    AND ticker != '0050'
    AND yoy_growth IS NOT NULL
),

eligible AS (
  SELECT *
  FROM formation
  WHERE forward_return IS NOT NULL
)

SELECT
  revenue_yoy_quintile,
  COUNT(*) AS n,
  AVG(forward_return) AS portfolio_return,
  AVG(IF(ticker = '8913', NULL, forward_return)) AS return_excluding_8913,
  MAX(IF(ticker = '8913', forward_return, NULL)) AS ticker_8913_return,
  COUNTIF(ticker = '8913') AS includes_8913
FROM eligible
GROUP BY revenue_yoy_quintile
ORDER BY revenue_yoy_quintile
