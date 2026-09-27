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

endpoint_prices AS (

  SELECT
    date,
    ticker,
    raw_close,
    adj_close

  FROM {{ ref('int_daily_prices_adjusted') }}

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

    -- ==================================================
    -- Price / volume
    -- ==================================================

    d.effective_close,
    d.d_close,
    d.d_vol,

    endpoint.raw_close AS current_raw_close,
    endpoint.adj_close AS current_adjusted_close,

    -- ==================================================
    -- Research characteristics
    -- ==================================================

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

    -- ==================================================
    -- Revenue PIT lineage
    -- ==================================================

    d.revenue_month,
    d.revenue_deadline_date,
    d.revenue_aligned_date,

    -- ==================================================
    -- Income-statement PIT lineage
    -- ==================================================

    d.report_quarter,
    d.financial_deadline_date,
    d.financial_aligned_date,

    -- ==================================================
    -- Balance-sheet PIT lineage
    -- ==================================================

    d.balance_sheet_quarter,
    d.balance_sheet_deadline_date,
    d.balance_sheet_aligned_date,

    -- ==================================================
    -- Eligibility / denominator diagnostics
    -- ==================================================

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

    d.shares_outstanding

  FROM calendar_with_next c

  INNER JOIN research_daily d
    ON d.date = c.rebalance_date

  LEFT JOIN endpoint_prices endpoint
    ON endpoint.date = c.rebalance_date
   AND endpoint.ticker = d.ticker

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
    d.raw_close AS next_raw_close,
    d.adj_close AS next_adjusted_close

  FROM calendar_with_next c

  INNER JOIN endpoint_prices d
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
-- 5. Return endpoint eligibility
--
-- Formation happens in current_panel before
-- this eligibility gate. Invalid endpoints
-- remain in the monthly formation dataset.
-- ==========================================

return_panel AS (

  SELECT
    p.*,

    n.next_raw_close,
    n.next_adjusted_close,

    COALESCE(p.current_raw_close > 0, FALSE) AS current_endpoint_observed,
    COALESCE(n.next_raw_close > 0, FALSE) AS next_endpoint_observed,

    COALESCE(
      p.current_raw_close > 0
      AND n.next_raw_close > 0
      AND p.current_adjusted_close > 0
      AND NOT IS_NAN(p.current_adjusted_close)
      AND NOT IS_INF(p.current_adjusted_close)
      AND n.next_adjusted_close > 0
      AND NOT IS_NAN(n.next_adjusted_close)
      AND NOT IS_INF(n.next_adjusted_close),
      FALSE
    ) AS forward_return_eligible

  FROM current_panel p

  LEFT JOIN next_price n
    ON p.rebalance_date = n.rebalance_date
   AND p.ticker = n.ticker

),

-- ==========================================
-- 6. Final research panel
-- ==========================================

final AS (

  SELECT
    p.research_month,
    p.rebalance_date,
    p.next_rebalance_date,

    p.ticker,

    -- ==================================================
    -- Price / return
    -- ==================================================

    p.effective_close,
    p.d_close,
    p.d_vol,

    p.current_raw_close,
    p.next_raw_close,
    p.current_adjusted_close,
    p.next_adjusted_close,
    p.current_endpoint_observed,
    p.next_endpoint_observed,
    p.forward_return_eligible,

    CASE
      WHEN p.forward_return_eligible
      THEN SAFE_DIVIDE(
        p.next_adjusted_close,
        p.current_adjusted_close
      ) - 1
    END AS forward_return,

    b.market_return,

    -- ==================================================
    -- Characteristics known at rebalance date
    -- ==================================================

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

    -- ==================================================
    -- PIT lineage
    -- ==================================================

    p.revenue_month,
    p.revenue_deadline_date,
    p.revenue_aligned_date,

    p.report_quarter,
    p.financial_deadline_date,
    p.financial_aligned_date,

    p.balance_sheet_quarter,
    p.balance_sheet_deadline_date,
    p.balance_sheet_aligned_date,

    -- ==================================================
    -- Eligibility / denominator diagnostics
    -- ==================================================

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

    p.shares_outstanding

  FROM return_panel p

  LEFT JOIN benchmark_return b
    ON p.rebalance_date = b.rebalance_date

)

SELECT *
FROM final
