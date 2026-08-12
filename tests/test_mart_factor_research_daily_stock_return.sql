WITH expected AS (

  SELECT
    date,
    ticker,
    stock_return,
    SAFE_DIVIDE(
      d_close,
      LAG(d_close) OVER (
        PARTITION BY ticker
        ORDER BY date
      )
    ) - 1 AS expected_stock_return

  FROM {{ ref('mart_factor_research_daily') }}

)

SELECT *
FROM expected
WHERE
  (stock_return IS NULL) != (expected_stock_return IS NULL)
  OR (
    stock_return IS NOT NULL
    AND expected_stock_return IS NOT NULL
    AND ABS(stock_return - expected_stock_return) >= 1e-12
  )
