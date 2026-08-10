{{ config(
    materialized='table',
    partition_by={
      "field": "rebalance_date",
      "data_type": "date",
      "granularity": "month"
    },
    cluster_by=["ticker"]
) }}

WITH research_daily AS (

  SELECT *
  FROM {{ ref('mart_factor_research_daily') }}

),

-- ==========================================
-- 1. Research rebalance calendar
-- First benchmark trading day on/after 15th
-- ==========================================

rebalance_calendar AS (

  SELECT
    DATE_TRUNC(date, MONTH) AS research_month,
    MIN(date) AS rebalance_date

  FROM research_daily

  WHERE ticker = '0050'
    AND EXTRACT(DAY FROM date) >= 15

  GROUP BY 1

),

calendar_with_next AS (

  SELECT
    research_month,
    rebalance_date,

    LEAD(rebalance_date) OVER (
      ORDER BY research_month
    ) AS next_rebalance_date

  FROM rebalance_calendar

),

-- ==========================================
-- 2. Current-date stock characteristics
-- ==========================================

current_panel AS (

  SELECT
    c.research_month,
    c.rebalance_date,
    c.next_rebalance_date,

    d.ticker,

    d.d_close,
    d.d_vol,

    d.yoy_growth,
    d.mom_growth_pct,
    d.eps_yoy_growth,
    d.op_margin,

    d.pe_ttm,
    d.pb_ratio,

    d.debt_ratio,
    d.equity_ratio,
    d.current_ratio,

    d.market_cap,
    d.log_market_cap,

    d.price_ma20_gap,
    d.price_ma60_gap,

    d.expected_revenue_growth,
    d.forward_constant_growth,
    d.implied_growth,
    d.implied_growth_pct,
    d.expectation_gap,

    d.eps_ttm,

    d.revenue_current,
    d.revenue_prior_year,

    d.eps_current,
    d.eps_prior_year,

    d.op_margin_revenue,
    d.op_margin_operating_income,

    d.book_value_per_share,

    d.current_assets,
    d.current_liabilities,
    d.total_assets,

  FROM calendar_with_next c

  INNER JOIN research_daily d
    ON d.date = c.rebalance_date

),

-- ==========================================
-- 3. Price exactly at next rebalance date
--
-- IMPORTANT:
-- Do NOT use LEAD(price) by ticker.
-- A missing next month must not accidentally
-- skip forward two months.
-- ==========================================

next_price AS (

  SELECT
    c.rebalance_date,
    c.next_rebalance_date,
    d.ticker,
    d.d_close AS next_d_close

  FROM calendar_with_next c

  INNER JOIN research_daily d
    ON d.date = c.next_rebalance_date

),

-- ==========================================
-- 4. Benchmark forward return
-- ==========================================

benchmark_return AS (

  SELECT
    c.rebalance_date,

    SAFE_DIVIDE(
      next_market.d_close,
      current_market.d_close
    ) - 1 AS market_return

  FROM calendar_with_next c

  LEFT JOIN research_daily current_market
    ON current_market.date = c.rebalance_date
   AND current_market.ticker = '0050'

  LEFT JOIN research_daily next_market
    ON next_market.date = c.next_rebalance_date
   AND next_market.ticker = '0050'

),

-- ==========================================
-- 5. Final research panel
-- ==========================================

final AS (

  SELECT
    p.research_month,
    p.rebalance_date,
    p.next_rebalance_date,

    p.ticker,

    p.d_close,
    p.d_vol,

    -- Forward stock return
    SAFE_DIVIDE(
      n.next_d_close,
      p.d_close
    ) - 1 AS forward_return,

    -- Benchmark forward return
    b.market_return,

    -- Characteristics known at rebalance date
    p.yoy_growth,
    p.mom_growth_pct,
    p.eps_yoy_growth,
    p.op_margin,

    p.pe_ttm,
    p.pb_ratio,

    p.debt_ratio,
    p.equity_ratio,
    p.current_ratio,

    p.market_cap,
    p.log_market_cap,

    p.price_ma20_gap,
    p.price_ma60_gap,

    p.expected_revenue_growth,
    p.forward_constant_growth,

    p.implied_growth,
    p.implied_growth_pct,
    p.expectation_gap,

    p.eps_ttm,

    p.revenue_current,
    p.revenue_prior_year,

    p.eps_current,
    p.eps_prior_year,

    p.op_margin_revenue,
    p.op_margin_operating_income,

    p.book_value_per_share,

    p.current_assets,
    p.current_liabilities,
    p.total_assets,

  FROM current_panel p

  LEFT JOIN next_price n
    ON p.rebalance_date = n.rebalance_date
   AND p.ticker = n.ticker

  LEFT JOIN benchmark_return b
    ON p.rebalance_date = b.rebalance_date

)

SELECT *
FROM final
