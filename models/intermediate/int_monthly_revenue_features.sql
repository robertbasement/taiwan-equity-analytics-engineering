{{ config(materialized='view') }}

WITH base AS (
  SELECT
    *,
    IF(yoy_growth_pct > 0, 1, 0) AS is_positive
  FROM {{ ref('stg_monthly_revenue') }}
),

check_change AS (
  SELECT
    *,
    IF(
      is_positive != LAG(is_positive) OVER(PARTITION BY ticker ORDER BY year_month),
      1,
      0
    ) AS state_changed,
    -- OVER + PARTITION 代表 對ticker 這個分群並用year_month排序, 之後對每一個做  LAG(yoy_growth_pct, 1) 的計算
    -- 也就是找到該ticker 上一個year_month的yoy_growth_pct 並在每個一個rows上輸出結果
    -- 所以 OVER + PARTITION 並不會壓縮最後輸出的rows
    LAG(yoy_growth_pct, 1) OVER(PARTITION BY ticker ORDER BY year_month) AS yoy_lag1,
    LAG(yoy_growth_pct, 2) OVER(PARTITION BY ticker ORDER BY year_month) AS yoy_lag2
  FROM base
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
      THEN ROW_NUMBER() OVER(PARTITION BY ticker, streak_id ORDER BY year_month)
      ELSE 0
    END AS yoy_positive_streak_count,
    IF(yoy_growth_pct > yoy_lag1 AND yoy_lag1 > yoy_lag2, 1, 0) AS yoy_triple_increase_signal
  FROM streak_groups
)

SELECT 
  * EXCEPT(is_positive, state_changed, streak_id),

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