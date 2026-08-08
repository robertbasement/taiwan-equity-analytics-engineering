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

    -- Revenue / financial
    yoy_growth,
    mom_growth_pct,
    eps_yoy_growth,
    op_margin,

    -- Valuation
    pe_ttm,
    pb_ratio,

    -- Balance sheet
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

    -- ==========================================
    -- Price / volume
    -- ==========================================
    m.d_close,
    m.d_vol,

    -- ==========================================
    -- Fundamental characteristics
    -- ==========================================
    m.yoy_growth,
    m.mom_growth_pct,
    m.eps_yoy_growth,
    m.op_margin,

    m.pe_ttm,
    m.pb_ratio,

    m.debt_ratio,
    m.equity_ratio,
    m.current_ratio,

    m.shares_outstanding,

    -- ==========================================
    -- Technical characteristics
    -- ==========================================
    SAFE_DIVIDE(
      m.d_close,
      NULLIF(m.ma20, 0)
    ) - 1 AS price_ma20_gap,

    SAFE_DIVIDE(
      m.d_close,
      NULLIF(m.ma60, 0)
    ) - 1 AS price_ma60_gap,

    -- ==========================================
    -- Size
    -- ==========================================
    m.d_close * m.shares_outstanding AS market_cap,

    CASE
      WHEN m.d_close > 0
       AND m.shares_outstanding > 0
      THEN LN(m.d_close * m.shares_outstanding)
    END AS log_market_cap,

    -- ==========================================
    -- Expectation / DCF
    -- ==========================================
    e.expected_revenue_growth,
    e.forward_constant_growth,

    -- NOTE:
    -- canonical expectation-model implied growth.
    -- This is NOT a replacement for the deprecated
    -- implied_growth_3y/5y/10y_pct fields.
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
