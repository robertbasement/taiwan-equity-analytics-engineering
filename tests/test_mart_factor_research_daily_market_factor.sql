WITH benchmark AS (

  SELECT
    date,
    stock_return AS expected_market_factor_return

  FROM {{ ref('mart_factor_research_daily') }}

  WHERE ticker = '0050'

)

SELECT daily.*
FROM {{ ref('mart_factor_research_daily') }} daily
LEFT JOIN benchmark
  ON daily.date = benchmark.date
WHERE
  (daily.market_factor_return IS NULL)
    != (benchmark.expected_market_factor_return IS NULL)
  OR (
    daily.market_factor_return IS NOT NULL
    AND benchmark.expected_market_factor_return IS NOT NULL
    AND ABS(
      daily.market_factor_return - benchmark.expected_market_factor_return
    ) >= 1e-12
  )
