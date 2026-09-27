WITH rebalance_calendar AS (

  SELECT
    DATE_TRUNC(date, MONTH) AS research_month,
    MIN(date) AS rebalance_date

  FROM {{ ref('mart_factor_research_daily') }}

  WHERE ticker = '0050'
    AND EXTRACT(DAY FROM date) >= 15

  GROUP BY 1

),

expected_formation AS (

  SELECT
    c.rebalance_date,
    d.ticker,
    d.yoy_growth

  FROM rebalance_calendar c

  INNER JOIN {{ ref('mart_factor_research_daily') }} d
    ON d.date = c.rebalance_date

),

actual_formation AS (

  SELECT
    rebalance_date,
    ticker,
    yoy_growth

  FROM {{ ref('mart_factor_research_monthly') }}

),

missing_or_changed AS (

  SELECT * FROM expected_formation
  EXCEPT DISTINCT
  SELECT * FROM actual_formation

),

unexpected_or_changed AS (

  SELECT * FROM actual_formation
  EXCEPT DISTINCT
  SELECT * FROM expected_formation

)

SELECT * FROM missing_or_changed
UNION ALL
SELECT * FROM unexpected_or_changed
