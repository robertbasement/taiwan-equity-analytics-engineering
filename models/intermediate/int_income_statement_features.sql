{{ config(materialized='view') }}

WITH base AS (

  SELECT 
    i.ticker,
    i.year_quarter,

    LEFT(i.year_quarter, 4) AS year_label,
    RIGHT(i.year_quarter, 1) AS quarter_label,

    i.revenue,
    i.operating_income,
    i.net_income,

    i.eps * COALESCE((
      SELECT EXP(SUM(LN(a.per_share_factor)))
      FROM {{ ref('manual_corporate_actions') }} a
      WHERE a.ticker = i.ticker
        AND DATE(
          SAFE_CAST(LEFT(i.year_quarter, 4) AS INT64),
          CASE SAFE_CAST(RIGHT(i.year_quarter, 1) AS INT64)
            WHEN 1 THEN 3
            WHEN 2 THEN 6
            WHEN 3 THEN 9
            WHEN 4 THEN 12
          END,
          30
        ) < a.effective_date
    ), 1.0) AS eps

  FROM {{ ref('stg_income_statement') }} i

),

single_quarter_calc AS (

  SELECT 
    ticker,
    year_quarter,

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
      ELSE eps - LAG(eps) OVER (
        PARTITION BY ticker, year_label
        ORDER BY year_quarter
      )
    END AS q_eps

  FROM base

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

    LAG(q_eps, 4) OVER (
      PARTITION BY ticker
      ORDER BY year_quarter
    ) AS last_year_q_eps

  FROM ratios_calc

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
      THEN SUM(q_eps) OVER (
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