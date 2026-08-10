{{ config(
    materialized='table',
    partition_by={
      "field": "date",
      "data_type": "date",
      "granularity": "month"
    },
    cluster_by=["ticker"]
) }}

WITH master AS (

  SELECT
    date,
    ticker,

    -- Price / volume
    d_close,
    d_vol,
    ma20,
    ma60,

    -- Monthly revenue
    revenue,
    revenue_month,
    yoy_growth,
    mom_growth_pct,
    revenue_last_year,

    -- Financial statement
    financial_q_revenue,
    financial_q_operating_income,

    eps,
    eps_ttm,
    eps_yoy_growth,
    op_margin,
    last_year_q_eps,

    -- Valuation
    pe_ttm,
    pb_ratio,
    book_value_per_share,

    -- Balance sheet
    current_assets,
    current_liabilities,
    total_assets,

    shares_outstanding,
    debt_ratio,
    equity_ratio,
    current_ratio

  FROM {{ ref('mart_vbt_master_dataset') }}

  WHERE d_close > 0

),

expectation AS (

  SELECT
    date,
    ticker,

    -- Canonical expectation fields
    expected_revenue_growth,
    forward_constant_growth,
    implied_growth,
    implied_growth_pct,
    expectation_gap

  FROM {{ ref('mart_expectation_dataset') }}

),

final AS (

  SELECT
    m.date,
    m.ticker,

    m.d_close,
    m.d_vol,

    -- ==================================================
    -- Research characteristics
    -- ==================================================

    m.yoy_growth,
    m.mom_growth_pct,
    m.eps_yoy_growth,
    m.op_margin,

    m.pe_ttm,
    m.pb_ratio,

    m.debt_ratio,
    m.equity_ratio,
    m.current_ratio,

    -- ==================================================
    -- Eligibility / denominator diagnostics
    -- ==================================================

    -- PE denominator
    m.eps_ttm,

    -- Current monthly revenue used by revenue research
    m.revenue AS revenue_current,
    m.revenue_last_year AS revenue_prior_year,

    -- Quarter EPS used by eps_yoy_growth
    m.eps AS eps_current,
    m.last_year_q_eps AS eps_prior_year,

    -- Operating-margin inputs
    m.financial_q_revenue AS op_margin_revenue,
    m.financial_q_operating_income AS op_margin_operating_income,

    -- PB denominator
    m.book_value_per_share,

    -- Balance-sheet denominators
    m.current_assets,
    m.current_liabilities,
    m.total_assets,

    -- ==================================================
    -- Size
    -- ==================================================

    m.shares_outstanding,

    m.d_close * m.shares_outstanding AS market_cap,

    CASE
      WHEN m.d_close > 0
       AND m.shares_outstanding > 0
      THEN LN(m.d_close * m.shares_outstanding)
    END AS log_market_cap,

    -- ==================================================
    -- Technical
    -- ==================================================

    SAFE_DIVIDE(
      m.d_close,
      NULLIF(m.ma20, 0)
    ) - 1 AS price_ma20_gap,

    SAFE_DIVIDE(
      m.d_close,
      NULLIF(m.ma60, 0)
    ) - 1 AS price_ma60_gap,

    -- ==================================================
    -- Expectation
    -- ==================================================

    e.expected_revenue_growth,
    e.forward_constant_growth,
    e.implied_growth,
    e.implied_growth_pct,
    e.expectation_gap

  FROM master m

  LEFT JOIN expectation e
    ON m.date = e.date
   AND m.ticker = e.ticker

)


SELECT *
FROM final
