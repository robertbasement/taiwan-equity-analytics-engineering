WITH benchmark_calendar AS (

  SELECT
    DATE_TRUNC(date, MONTH) AS research_month,
    MIN(date) AS rebalance_date

  FROM {{ ref('mart_factor_research_daily') }}

  WHERE ticker = '0050'
    AND EXTRACT(DAY FROM date) >= 15

  GROUP BY 1

),

calendar_with_next AS (

  SELECT
    research_month,
    rebalance_date,
    LEAD(rebalance_date) OVER (ORDER BY research_month) AS next_rebalance_date

  FROM benchmark_calendar

),

expected AS (

  SELECT
    c.rebalance_date,
    c.next_rebalance_date,
    SAFE_DIVIDE(next_benchmark.d_close, current_benchmark.d_close) - 1 AS market_return

  FROM calendar_with_next c

  LEFT JOIN {{ ref('mart_factor_research_daily') }} current_benchmark
    ON current_benchmark.date = c.rebalance_date
   AND current_benchmark.ticker = '0050'

  LEFT JOIN {{ ref('mart_factor_research_daily') }} next_benchmark
    ON next_benchmark.date = c.next_rebalance_date
   AND next_benchmark.ticker = '0050'

),

actual AS (

  SELECT DISTINCT
    rebalance_date,
    next_rebalance_date,
    market_return

  FROM {{ ref('mart_factor_research_monthly') }}

),

missing_or_changed AS (

  SELECT * FROM expected
  WHERE rebalance_date >= (SELECT MIN(rebalance_date) FROM actual)
  EXCEPT DISTINCT
  SELECT * FROM actual

),

unexpected_or_changed AS (

  SELECT * FROM actual
  EXCEPT DISTINCT
  SELECT * FROM expected

)

SELECT * FROM missing_or_changed
UNION ALL
SELECT * FROM unexpected_or_changed
