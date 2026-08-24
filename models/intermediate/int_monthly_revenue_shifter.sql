{{ config(materialized='view') }}

WITH raw_revenue AS (

  SELECT 
    DATE_ADD(
      DATE_ADD(
        PARSE_DATE('%Y-%m', year_month),
        INTERVAL 1 MONTH
      ),
      INTERVAL 10 DAY
    ) AS deadline_date,
    -- 2025-03 經過 PARSE_DATE 的拆解後會變成 2025-03-01, 再往後加上一個月又10天
    -- 最終會輸出 2025-04-11

    ticker,

    year_month AS data_month_label,

    revenue,
    revenue_last_year,
    yoy_growth_pct,
    mom_growth_pct,
    ytd_growth_pct,
    yoy_triple_increase_signal,
    yoy_positive_streak_count

  FROM {{ ref('int_monthly_revenue_features') }}

),

market_dates AS (

  SELECT DISTINCT date
  FROM {{ ref('int_daily_indicators') }}

),

aligned_historical AS (

  SELECT 
    r.ticker,
    r.data_month_label,

    MIN(m.date) AS aligned_date

  FROM raw_revenue r

  JOIN market_dates m 
    ON m.date >= r.deadline_date

  GROUP BY
    r.ticker,
    r.data_month_label
  -- GROUP BY 將r.ticker, r.data_month_label 分組後, aggregate function -> MIN, 會將這一個組裡面 取出 date 最少的輸出
  -- GROUP + MIN 會壓縮最後輸出的rows 
  -- GROUP BY r.ticker, r.data_month_label 代表 將相同 (ticker, data_month_label) 的所有 rows 合成一個 group, 舉例來說就會將 (2330, 2025-03)的資料合成一組

),

final AS (

  SELECT

    COALESCE(
      a.aligned_date,
      r.deadline_date
    ) AS date,
    -- COALESCE(A, B) 代表如果A非null就回傳A, 要不就回傳B
    -- 其實更廣義來說 為從左到右 回傳第一個非null的值, 故也可以COALESCE(A, B, C, D ....)

    r.ticker,

    STRUCT(
      r.revenue AS revenue,
      r.revenue_last_year AS revenue_last_year,
      r.yoy_growth_pct AS yoy_growth_pct,
      r.mom_growth_pct AS mom_growth_pct,
      r.ytd_growth_pct AS ytd_growth_pct,
      r.yoy_triple_increase_signal AS yoy_triple_increase_signal,
      r.yoy_positive_streak_count AS yoy_positive_streak_count,

      -- PIT lineage
      r.data_month_label AS data_month_label,
      r.deadline_date AS deadline_date,
      a.aligned_date AS aligned_date

    ) AS rev_box

  FROM raw_revenue r

  LEFT JOIN aligned_historical a 
    ON r.ticker = a.ticker
   AND r.data_month_label = a.data_month_label

)

SELECT *
FROM final


