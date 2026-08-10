{{ config(materialized='view') }}

WITH raw_revenue AS (
  SELECT 
    DATE_ADD(
      DATE_ADD(PARSE_DATE('%Y-%m', year_month), INTERVAL 1 MONTH),
      INTERVAL 10 DAY
    ) AS deadline_date,

    ticker,

    STRUCT(
      revenue,
      revenue_last_year,
      yoy_growth_pct,
      mom_growth_pct,
      ytd_growth_pct,
      yoy_triple_increase_signal,
      yoy_positive_streak_count,
      year_month AS data_month_label
    ) AS rev_box

  FROM {{ ref('int_monthly_revenue_features') }}
),

market_dates AS (
  SELECT DISTINCT date
  FROM {{ ref('int_daily_indicators') }}
),

aligned_historical AS (
  SELECT 
    r.ticker,
    r.rev_box,
    MIN(m.date) AS aligned_date
  FROM raw_revenue r
  JOIN market_dates m 
    ON m.date >= r.deadline_date
  GROUP BY r.ticker, r.rev_box
)

SELECT 
  COALESCE(a.aligned_date, r.deadline_date) AS date,
  r.ticker,
  r.rev_box
FROM raw_revenue r
LEFT JOIN aligned_historical a 
  ON r.ticker = a.ticker
 AND r.rev_box = a.rev_box