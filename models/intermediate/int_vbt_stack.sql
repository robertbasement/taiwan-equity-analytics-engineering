-- models/intermediate/int_vbt_stack.sql

{{ config(materialized='view') }}

WITH empty_boxes AS (

  SELECT
    CAST(NULL AS STRUCT<
      revenue INT64,
      revenue_last_year INT64,
      yoy_growth_pct FLOAT64,
      mom_growth_pct FLOAT64,
      ytd_growth_pct FLOAT64,
      yoy_triple_increase_signal INT64,
      yoy_positive_streak_count INT64,
      -- PIT lineage
      data_month_label STRING,
      deadline_date DATE,
      aligned_date DATE
    >) AS empty_rev_box,

    -- CAST(NULL AS STRUCT<
    --   operating_margin FLOAT64,
    --   ebit_volatility FLOAT64,
    --   eps FLOAT64,
    --   eps_ttm FLOAT64,
    --   eps_yoy_growth FLOAT64,
    --   EBIT_signal INT64,
    --   EPS_signal INT64,
    --   EBIT_diff_signal INT64,
    --   EBIT_vol_signal INT64,
    --   year_quarter STRING
    -- >) AS empty_fin_box,

    CAST(NULL AS STRUCT<

      q_revenue FLOAT64,
      revenue_ttm FLOAT64,
      q_operating_income FLOAT64,
      operating_income_ttm FLOAT64,
      q_net_income FLOAT64,
      net_income_ttm FLOAT64,
      operating_margin FLOAT64,
      operating_margin_ttm FLOAT64,
      net_margin FLOAT64,
      net_margin_ttm FLOAT64,
      ebit_volatility FLOAT64,
      net_margin_volatility FLOAT64,
      eps FLOAT64,
      eps_ttm FLOAT64,
      last_year_q_eps FLOAT64,
      eps_yoy_growth FLOAT64,
      EBIT_signal INT64,
      net_income_signal INT64,
      EPS_signal INT64,
      EBIT_diff_signal INT64,
      net_margin_diff_signal INT64,
      EBIT_vol_signal INT64,
      net_margin_vol_signal INT64,
      year_quarter STRING,
      deadline_date DATE,
      aligned_date DATE

    >) AS empty_fin_box,


    CAST(NULL AS STRUCT<
      current_assets FLOAT64,
      non_current_assets FLOAT64,
      total_assets FLOAT64,
      current_liabilities FLOAT64,
      non_current_liabilities FLOAT64,
      total_liabilities FLOAT64,
      share_capital FLOAT64,
      share_capital_ntd FLOAT64,
      shares_outstanding FLOAT64,
      adjusted_shares_outstanding FLOAT64,

      capital_surplus FLOAT64,
      retained_earnings FLOAT64,
      total_equity FLOAT64,

      book_value_per_share FLOAT64,
      adjusted_book_value_per_share FLOAT64,

      debt_ratio FLOAT64,
      equity_ratio FLOAT64,
      current_ratio FLOAT64,

      year_quarter STRING,
      deadline_date DATE,
      aligned_date DATE
  >) AS empty_bs_box

),

daily_part AS (

  SELECT 
    d.date,
    d.ticker,
    d.open,
    d.high,
    d.low,
    d.raw_close,
    d.adj_close,
    d.effective_close,
    d.volume,
    d.ma20,
    d.ma60,
    d.bias20,
    d.day_amplitude,
    e.empty_rev_box AS rev_box,
    e.empty_fin_box AS fin_box,
    e.empty_bs_box AS bs_box
  FROM {{ ref('int_daily_indicators') }} d
  CROSS JOIN empty_boxes e

),

revenue_part AS (

  SELECT
    r.date,
    r.ticker,
    NULL AS open,
    NULL AS high,
    NULL AS low,
    NULL AS raw_close,
    NULL AS adj_close,
    NULL AS effective_close,
    NULL AS volume,
    NULL AS ma20,
    NULL AS ma60,
    NULL AS bias20,
    NULL AS day_amplitude,
    r.rev_box,
    e.empty_fin_box AS fin_box,
    e.empty_bs_box AS bs_box
  FROM {{ ref('int_monthly_revenue_shifter') }} r
  CROSS JOIN empty_boxes e

),

financial_part AS (

  SELECT
    f.date,
    f.ticker,
    NULL AS open,
    NULL AS high,
    NULL AS low,
    NULL AS raw_close,
    NULL AS adj_close,
    NULL AS effective_close,
    NULL AS volume,
    NULL AS ma20,
    NULL AS ma60,
    NULL AS bias20,
    NULL AS day_amplitude,
    e.empty_rev_box AS rev_box,
    f.fin_box,
    e.empty_bs_box AS bs_box
  FROM {{ ref('int_income_statement_shifter') }} f
  CROSS JOIN empty_boxes e

),

balance_sheet_part AS (

  SELECT
    b.date,
    b.ticker,
    NULL AS open,
    NULL AS high,
    NULL AS low,
    NULL AS raw_close,
    NULL AS adj_close,
    NULL AS effective_close,
    NULL AS volume,
    NULL AS ma20,
    NULL AS ma60,
    NULL AS bias20,
    NULL AS day_amplitude,
    e.empty_rev_box AS rev_box,
    e.empty_fin_box AS fin_box,
    b.bs_box
  FROM {{ ref('int_balance_sheet_shifter') }} b
  CROSS JOIN empty_boxes e

)

SELECT * FROM daily_part
UNION ALL
SELECT * FROM revenue_part
UNION ALL
SELECT * FROM financial_part
UNION ALL
SELECT * FROM balance_sheet_part