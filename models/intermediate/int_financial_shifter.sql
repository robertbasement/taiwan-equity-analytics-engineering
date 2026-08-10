{{ config(materialized='view') }}

WITH raw_financial AS (
  SELECT 
    ticker,

    CASE 
      WHEN ENDS_WITH(year_quarter, '-1')
        THEN PARSE_DATE('%Y-%m-%d', CONCAT(LEFT(year_quarter, 4), '-05-16'))
      WHEN ENDS_WITH(year_quarter, '-2')
        THEN PARSE_DATE('%Y-%m-%d', CONCAT(LEFT(year_quarter, 4), '-08-15'))
      WHEN ENDS_WITH(year_quarter, '-3')
        THEN PARSE_DATE('%Y-%m-%d', CONCAT(LEFT(year_quarter, 4), '-11-15'))
      ELSE PARSE_DATE(
        '%Y-%m-%d',
        CONCAT(CAST(CAST(LEFT(year_quarter, 4) AS INT64) + 1 AS STRING), '-04-01')
      )
    END AS deadline_date,

    -- STRUCT(
    --   operating_margin,
    --   ebit_volatility,
    --   eps,
    --   eps_ttm,
    --   eps_yoy_growth,
    --   EBIT_signal,
    --   EPS_signal,
    --   EBIT_diff_signal,
    --   EBIT_vol_signal,
    --   year_quarter
    -- ) AS fin_box

    STRUCT(
      q_revenue AS q_revenue,
      revenue_ttm AS revenue_ttm,

      q_operating_income AS q_operating_income,
      operating_income_ttm AS operating_income_ttm,

      q_net_income AS q_net_income,
      net_income_ttm AS net_income_ttm,

      operating_margin AS operating_margin,
      operating_margin_ttm AS operating_margin_ttm,

      net_margin AS net_margin,
      net_margin_ttm AS net_margin_ttm,

      ebit_volatility AS ebit_volatility,
      net_margin_volatility AS net_margin_volatility,

      eps AS eps,
      eps_ttm AS eps_ttm,
      last_year_q_eps AS last_year_q_eps,
      eps_yoy_growth AS eps_yoy_growth,

      EBIT_signal AS EBIT_signal,
      net_income_signal AS net_income_signal,
      EPS_signal AS EPS_signal,

      EBIT_diff_signal AS EBIT_diff_signal,
      net_margin_diff_signal AS net_margin_diff_signal,

      EBIT_vol_signal AS EBIT_vol_signal,
      net_margin_vol_signal AS net_margin_vol_signal,

      year_quarter AS year_quarter
    ) AS fin_box

  FROM {{ ref('int_financial_features') }}
),

market_dates AS (
  SELECT DISTINCT date
  FROM {{ ref('int_daily_indicators') }}
),

aligned_historical AS (
  SELECT 
    f.ticker,
    f.fin_box,
    MIN(m.date) AS aligned_date
  FROM raw_financial f
  JOIN market_dates m
    ON m.date >= f.deadline_date
  GROUP BY f.ticker, f.fin_box
)

SELECT 
  COALESCE(a.aligned_date, f.deadline_date) AS date,
  f.ticker,
  f.fin_box
FROM raw_financial f
LEFT JOIN aligned_historical a 
  ON f.ticker = a.ticker
 AND f.fin_box = a.fin_box

 