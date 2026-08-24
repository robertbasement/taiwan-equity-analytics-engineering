{{ config(materialized='view') }}

SELECT 
  date,
  ticker,
  open,
  high,
  low,
  raw_close,
  adj_close,
  effective_close,
  volume,

  AVG(adj_close) OVER(
    PARTITION BY ticker
    ORDER BY date
    ROWS BETWEEN 19 PRECEDING AND CURRENT ROW
  ) AS ma20,

  AVG(adj_close) OVER(
    PARTITION BY ticker
    ORDER BY date
    ROWS BETWEEN 59 PRECEDING AND CURRENT ROW
  ) AS ma60,

  SAFE_DIVIDE(
    adj_close - AVG(adj_close) OVER(
      PARTITION BY ticker
      ORDER BY date
      ROWS BETWEEN 19 PRECEDING AND CURRENT ROW
    ),
    AVG(adj_close) OVER(
      PARTITION BY ticker
      ORDER BY date
      ROWS BETWEEN 19 PRECEDING AND CURRENT ROW
    )
  ) AS bias20,

  SAFE_DIVIDE(high - low, low) AS day_amplitude



FROM {{ ref('int_daily_prices_adjusted') }}
WHERE date >= DATE '2009-01-01'