{{ config(materialized='view') }}

WITH base AS (

  SELECT 
    i.ticker,
    i.year_quarter,

    LEFT(i.year_quarter, 4) AS year_label,
    RIGHT(i.year_quarter, 1) AS quarter_label,

    LAST_DAY(
      DATE(
        SAFE_CAST(LEFT(i.year_quarter, 4) AS INT64),
        SAFE_CAST(RIGHT(i.year_quarter, 1) AS INT64) * 3,
        1
      ),
      QUARTER
    ) AS current_period_end,

    i.revenue,
    i.operating_income,
    i.net_income,

    -- Preserve the source value here. Later CTEs reconcile only subtraction,
    -- rolling-window, and comparison operands to the current period basis.
    i.eps AS eps

  FROM {{ ref('stg_income_statement') }} i

),

source_with_previous AS (

  SELECT
    *,

    LAG(current_period_end) OVER (
      PARTITION BY ticker, year_label
      ORDER BY year_quarter
    ) AS previous_period_end,

    LAG(eps) OVER (
      PARTITION BY ticker, year_label
      ORDER BY year_quarter
    ) AS previous_ytd_eps

  FROM base

),

source_basis_reconciliation AS (

  SELECT
    p.*,

    COALESCE((
      SELECT EXP(SUM(LN(a.per_share_factor)))
      FROM {{ ref('manual_corporate_actions') }} a
      WHERE a.ticker = p.ticker
        AND a.effective_date > p.previous_period_end
        AND a.effective_date <= p.current_period_end
    ), 1.0) AS factor_between_periods

  FROM source_with_previous p

),

single_quarter_calc AS (

  SELECT 
    ticker,
    year_quarter,
    current_period_end,

    CASE 
      WHEN quarter_label = '1' THEN revenue
      ELSE revenue - LAG(revenue) OVER (
        PARTITION BY ticker, year_label
        ORDER BY year_quarter
      )
    END AS q_revenue,

    CASE 
      WHEN quarter_label = '1' THEN operating_income
      ELSE operating_income - LAG(operating_income) OVER (
        PARTITION BY ticker, year_label
        ORDER BY year_quarter
      )
    END AS q_operating_income,

    CASE 
      WHEN quarter_label = '1' THEN net_income
      ELSE net_income - LAG(net_income) OVER (
        PARTITION BY ticker, year_label
        ORDER BY year_quarter
      )
    END AS q_net_income,

    CASE 
      WHEN quarter_label = '1' THEN eps
      ELSE eps - previous_ytd_eps * factor_between_periods
    END AS q_eps

  FROM source_basis_reconciliation

),

ratios_calc AS (

  SELECT
    *,

    SAFE_DIVIDE(
      q_operating_income,
      NULLIF(q_revenue, 0)
    ) AS operating_margin,

    SAFE_DIVIDE(
      q_net_income,
      NULLIF(q_revenue, 0)
    ) AS net_margin

  FROM single_quarter_calc

),

eps_basis_factors AS (

  SELECT
    *,

    -- This cumulative factor is an internal bridge for converting window and
    -- comparison operands. It does not rewrite the historical q_eps row.
    COALESCE((
      SELECT EXP(SUM(LN(a.per_share_factor)))
      FROM {{ ref('manual_corporate_actions') }} a
      WHERE a.ticker = r.ticker
        AND a.effective_date <= r.current_period_end
    ), 1.0) AS cumulative_per_share_factor

  FROM ratios_calc r

),

eps_basis_components AS (

  SELECT
    *,

    SAFE_DIVIDE(
      q_eps,
      NULLIF(cumulative_per_share_factor, 0)
    ) AS q_eps_action_neutral

  FROM eps_basis_factors

),

signals AS (

  SELECT
    *,

    STDDEV(operating_margin) OVER (
      PARTITION BY ticker
      ORDER BY year_quarter
      ROWS BETWEEN 3 PRECEDING AND CURRENT ROW
    ) AS ebit_volatility,

    STDDEV(net_margin) OVER (
      PARTITION BY ticker
      ORDER BY year_quarter
      ROWS BETWEEN 3 PRECEDING AND CURRENT ROW
    ) AS net_margin_volatility,

    MIN(operating_margin) OVER (
      PARTITION BY ticker
      ORDER BY year_quarter
      ROWS BETWEEN 7 PRECEDING AND CURRENT ROW
    ) AS min_margin_8q,

    MIN(net_margin) OVER (
      PARTITION BY ticker
      ORDER BY year_quarter
      ROWS BETWEEN 7 PRECEDING AND CURRENT ROW
    ) AS min_net_margin_8q,

    LAG(operating_margin) OVER (
      PARTITION BY ticker
      ORDER BY year_quarter
    ) AS prev_margin,

    LAG(net_margin) OVER (
      PARTITION BY ticker
      ORDER BY year_quarter
    ) AS prev_net_margin,

    -- Convert only the prior-year comparison operand to this report's basis.
    LAG(q_eps_action_neutral, 4) OVER (
      PARTITION BY ticker
      ORDER BY year_quarter
    ) * cumulative_per_share_factor AS last_year_q_eps

  FROM eps_basis_components

),

ttm_calc AS (

  SELECT
    *,

    CASE
      WHEN COUNT(q_revenue) OVER (
        PARTITION BY ticker
        ORDER BY year_quarter
        ROWS BETWEEN 3 PRECEDING AND CURRENT ROW
      ) = 4
      THEN SUM(q_revenue) OVER (
        PARTITION BY ticker
        ORDER BY year_quarter
        ROWS BETWEEN 3 PRECEDING AND CURRENT ROW
      )
    END AS revenue_ttm,

    CASE
      WHEN COUNT(q_operating_income) OVER (
        PARTITION BY ticker
        ORDER BY year_quarter
        ROWS BETWEEN 3 PRECEDING AND CURRENT ROW
      ) = 4
      THEN SUM(q_operating_income) OVER (
        PARTITION BY ticker
        ORDER BY year_quarter
        ROWS BETWEEN 3 PRECEDING AND CURRENT ROW
      )
    END AS operating_income_ttm,

    CASE
      WHEN COUNT(q_net_income) OVER (
        PARTITION BY ticker
        ORDER BY year_quarter
        ROWS BETWEEN 3 PRECEDING AND CURRENT ROW
      ) = 4
      THEN SUM(q_net_income) OVER (
        PARTITION BY ticker
        ORDER BY year_quarter
        ROWS BETWEEN 3 PRECEDING AND CURRENT ROW
      )
    END AS net_income_ttm,

    CASE
      WHEN COUNT(q_eps) OVER (
        PARTITION BY ticker
        ORDER BY year_quarter
        ROWS BETWEEN 3 PRECEDING AND CURRENT ROW
      ) = 4
      THEN cumulative_per_share_factor
        * SUM(q_eps_action_neutral) OVER (
          PARTITION BY ticker
          ORDER BY year_quarter
          ROWS BETWEEN 3 PRECEDING AND CURRENT ROW
        )
    END AS eps_ttm

  FROM signals

),

ttm_ratios AS (

  SELECT
    *,

    SAFE_DIVIDE(
      operating_income_ttm,
      NULLIF(revenue_ttm, 0)
    ) AS operating_margin_ttm,

    SAFE_DIVIDE(
      net_income_ttm,
      NULLIF(revenue_ttm, 0)
    ) AS net_margin_ttm

  FROM ttm_calc

)

SELECT
  ticker,
  year_quarter,

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

  q_eps AS eps,
  eps_ttm,

  last_year_q_eps,

  SAFE_DIVIDE(
    q_eps,
    NULLIF(last_year_q_eps, 0)
  ) - 1 AS eps_yoy_growth,

  IF(min_margin_8q > 0, 1, 0) AS EBIT_signal,

  IF(min_net_margin_8q > 0, 1, 0) AS net_income_signal,

  IF(q_eps > 0, 1, 0) AS EPS_signal,

  IF(
    operating_margin > prev_margin,
    1,
    0
  ) AS EBIT_diff_signal,

  IF(
    net_margin > prev_net_margin,
    1,
    0
  ) AS net_margin_diff_signal,

  IF(
    ebit_volatility < 0.05,
    1,
    0
  ) AS EBIT_vol_signal,

  IF(
    net_margin_volatility < 0.05,
    1,
    0
  ) AS net_margin_vol_signal

FROM ttm_ratios
