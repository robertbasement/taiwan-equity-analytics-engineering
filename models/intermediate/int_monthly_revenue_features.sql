{{ config(materialized='view') }}

WITH base AS (
  SELECT
    *,
    PARSE_DATE('%Y-%m', year_month) AS revenue_month_date,
    IF(yoy_growth_pct > 0, 1, 0) AS is_positive
  FROM {{ ref('stg_monthly_revenue') }}
),

sequenced AS (
  SELECT
    *,
    LAG(revenue_month_date, 1) OVER(PARTITION BY ticker ORDER BY revenue_month_date) AS month_lag1,
    LAG(revenue_month_date, 2) OVER(PARTITION BY ticker ORDER BY revenue_month_date) AS month_lag2,
    LAG(is_positive) OVER(PARTITION BY ticker ORDER BY revenue_month_date) AS is_positive_lag1,
    LAG(yoy_growth_pct, 1) OVER(PARTITION BY ticker ORDER BY revenue_month_date) AS yoy_lag1,
    LAG(yoy_growth_pct, 2) OVER(PARTITION BY ticker ORDER BY revenue_month_date) AS yoy_lag2
  FROM base
),

check_change AS (
  SELECT
    *,
    IF(
      month_lag1 IS NULL
      OR DATE_DIFF(revenue_month_date, month_lag1, MONTH) != 1
      OR is_positive != is_positive_lag1,
      1,
      0
    ) AS state_changed
  FROM sequenced
),

streak_groups AS (
  SELECT
    *,
    IFNULL(
      SUM(state_changed) OVER(PARTITION BY ticker ORDER BY year_month),
      0
    ) AS streak_id
  FROM check_change
),

calc_features AS (
  SELECT 
    *,
    CASE
      WHEN is_positive = 1
      THEN ROW_NUMBER() OVER(PARTITION BY ticker, streak_id ORDER BY revenue_month_date)
      ELSE 0
    END AS yoy_positive_streak_count,
    IF(
      DATE_DIFF(revenue_month_date, month_lag1, MONTH) = 1
      AND DATE_DIFF(month_lag1, month_lag2, MONTH) = 1
      AND yoy_growth_pct > yoy_lag1
      AND yoy_lag1 > yoy_lag2,
      1,
      0
    ) AS yoy_triple_increase_signal
  FROM streak_groups
)

SELECT 
  * EXCEPT(
    revenue_month_date,
    is_positive,
    is_positive_lag1,
    month_lag1,
    month_lag2,
    yoy_lag1,
    yoy_lag2,
    state_changed,
    streak_id
  ),

  CASE 
    WHEN SUBSTR(year_month, 6, 2) IN ('01', '02')
      THEN CONCAT(CAST(CAST(SUBSTR(year_month, 1, 4) AS INT64)-1 AS STRING), '-3')
    WHEN SUBSTR(year_month, 6, 2) IN ('03', '04')
      THEN CONCAT(CAST(CAST(SUBSTR(year_month, 1, 4) AS INT64)-1 AS STRING), '-4')
    WHEN SUBSTR(year_month, 6, 2) IN ('05', '06', '07')
      THEN CONCAT(SUBSTR(year_month, 1, 4), '-1')
    WHEN SUBSTR(year_month, 6, 2) IN ('08', '09', '10')
      THEN CONCAT(SUBSTR(year_month, 1, 4), '-2')
    WHEN SUBSTR(year_month, 6, 2) IN ('11', '12')
      THEN CONCAT(SUBSTR(year_month, 1, 4), '-3')
  END AS map_to_quarter
FROM calc_features
