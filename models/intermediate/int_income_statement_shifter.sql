{{ config(materialized='view') }}

WITH raw_income_statement AS (

  SELECT 
    ticker,
    year_quarter,

    -- PIT policy:
    -- 在沒有 historical announcement timestamp 的情況下，
    -- 依研究規則定義各季度財報最早可使用日期
    CASE 
      WHEN ENDS_WITH(year_quarter, '-1')
        THEN PARSE_DATE(
          '%Y-%m-%d',
          CONCAT(LEFT(year_quarter, 4), '-05-16')
        )

      WHEN ENDS_WITH(year_quarter, '-2')
        THEN PARSE_DATE(
          '%Y-%m-%d',
          CONCAT(LEFT(year_quarter, 4), '-08-15')
        )

      WHEN ENDS_WITH(year_quarter, '-3')
        THEN PARSE_DATE(
          '%Y-%m-%d',
          CONCAT(LEFT(year_quarter, 4), '-11-15')
        )

      ELSE PARSE_DATE(
        '%Y-%m-%d',
        CONCAT(
          CAST(
            CAST(LEFT(year_quarter, 4) AS INT64) + 1
            AS STRING
          ),
          '-04-01'
        )
      )
    END AS deadline_date,

    q_revenue,
    revenue_ttm,

    q_operating_income,
    operating_income_ttm,

    q_net_income,
    net_income_ttm,

    operating_margin,
    operating_margin_ttm,

    net_margin,
    net_margin_ttm,

    ebit_volatility,
    net_margin_volatility,

    eps,
    eps_ttm,
    last_year_q_eps,
    eps_yoy_growth,

    EBIT_signal,
    net_income_signal,
    EPS_signal,

    EBIT_diff_signal,
    net_margin_diff_signal,

    EBIT_vol_signal,
    net_margin_vol_signal

  FROM {{ ref('int_income_statement_features') }}

),

market_dates AS (

  SELECT DISTINCT date
  FROM {{ ref('int_daily_indicators') }}

),

aligned_historical AS (

  SELECT 
    f.ticker,
    f.year_quarter,

    MIN(m.date) AS aligned_date

  FROM raw_income_statement f

  JOIN market_dates m
    ON m.date >= f.deadline_date

  GROUP BY
    f.ticker,
    f.year_quarter

),

final AS (

  SELECT 

    -- Dashboard / operational event date
    COALESCE(
      a.aligned_date,
      f.deadline_date
    ) AS date,

    f.ticker,

    STRUCT(
      f.q_revenue AS q_revenue,
      f.revenue_ttm AS revenue_ttm,

      f.q_operating_income AS q_operating_income,
      f.operating_income_ttm AS operating_income_ttm,

      f.q_net_income AS q_net_income,
      f.net_income_ttm AS net_income_ttm,

      f.operating_margin AS operating_margin,
      f.operating_margin_ttm AS operating_margin_ttm,

      f.net_margin AS net_margin,
      f.net_margin_ttm AS net_margin_ttm,

      f.ebit_volatility AS ebit_volatility,
      f.net_margin_volatility AS net_margin_volatility,

      f.eps AS eps,
      f.eps_ttm AS eps_ttm,
      f.last_year_q_eps AS last_year_q_eps,
      f.eps_yoy_growth AS eps_yoy_growth,

      f.EBIT_signal AS EBIT_signal,
      f.net_income_signal AS net_income_signal,
      f.EPS_signal AS EPS_signal,

      f.EBIT_diff_signal AS EBIT_diff_signal,
      f.net_margin_diff_signal AS net_margin_diff_signal,

      f.EBIT_vol_signal AS EBIT_vol_signal,
      f.net_margin_vol_signal AS net_margin_vol_signal,

      -- Source lineage
      f.year_quarter AS year_quarter,

      -- PIT lineage
      f.deadline_date AS deadline_date,
      a.aligned_date AS aligned_date

    ) AS fin_box

  FROM raw_income_statement f

  LEFT JOIN aligned_historical a
    ON f.ticker = a.ticker
   AND f.year_quarter = a.year_quarter

)

SELECT *
FROM final