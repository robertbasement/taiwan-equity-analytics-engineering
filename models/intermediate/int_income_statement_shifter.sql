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

    -- Feature EPS values are basis-consistent as of the reporting period end.
    -- The shifter applies only later actions through the observation date.
    LAST_DAY(
      DATE(
        SAFE_CAST(LEFT(year_quarter, 4) AS INT64),
        SAFE_CAST(RIGHT(year_quarter, 1) AS INT64) * 3,
        1
      ),
      QUARTER
    ) AS statement_basis_date,

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

filing_events AS (

  SELECT 

    -- Dashboard / operational event date
    COALESCE(
      al.aligned_date,
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

      f.eps * COALESCE((
        SELECT EXP(SUM(LN(a.per_share_factor)))
        FROM {{ ref('manual_corporate_actions') }} a
        WHERE a.ticker = f.ticker
          AND a.effective_date > f.statement_basis_date
          AND a.effective_date <= COALESCE(al.aligned_date, f.deadline_date)
      ), 1.0) AS eps,
      f.eps_ttm * COALESCE((
        SELECT EXP(SUM(LN(a.per_share_factor)))
        FROM {{ ref('manual_corporate_actions') }} a
        WHERE a.ticker = f.ticker
          AND a.effective_date > f.statement_basis_date
          AND a.effective_date <= COALESCE(al.aligned_date, f.deadline_date)
      ), 1.0) AS eps_ttm,
      f.last_year_q_eps * COALESCE((
        SELECT EXP(SUM(LN(a.per_share_factor)))
        FROM {{ ref('manual_corporate_actions') }} a
        WHERE a.ticker = f.ticker
          AND a.effective_date > f.statement_basis_date
          AND a.effective_date <= COALESCE(al.aligned_date, f.deadline_date)
      ), 1.0) AS last_year_q_eps,
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
      al.aligned_date AS aligned_date

    ) AS fin_box

  FROM raw_income_statement f

  LEFT JOIN aligned_historical al
    ON f.ticker = al.ticker
   AND f.year_quarter = al.year_quarter

),

actions AS (
  SELECT ticker, effective_date, per_share_factor
  FROM {{ ref('manual_corporate_actions') }}
  WHERE per_share_factor != 1.0
),

-- Rebase the most recently observable filing on each action date. Filing
-- snapshots already include actions effective by their availability date;
-- only later actions are applied here, including successive actions.
action_with_latest_filing AS (
  SELECT
    a.ticker,
    a.effective_date,
    f.date AS filing_event_date,
    f.fin_box,
    ROW_NUMBER() OVER (
      PARTITION BY a.ticker, a.effective_date
      ORDER BY f.date DESC, f.fin_box.year_quarter DESC
    ) AS rn
  FROM actions a
  JOIN filing_events f
    ON f.ticker = a.ticker
   AND f.date <= a.effective_date
),

action_factors AS (
  SELECT
    base.ticker,
    base.effective_date,
    base.fin_box,
    COALESCE(EXP(SUM(LN(a.per_share_factor))), 1.0) AS cumulative_per_share_factor
  FROM action_with_latest_filing base
  LEFT JOIN actions a
    ON a.ticker = base.ticker
   AND a.effective_date > base.filing_event_date
   AND a.effective_date <= base.effective_date
  WHERE base.rn = 1
  GROUP BY base.ticker, base.effective_date, base.fin_box
),

corporate_action_events AS (
  SELECT
    effective_date AS date,
    ticker,
    (SELECT AS STRUCT
      fin_box.* REPLACE(
        fin_box.eps * cumulative_per_share_factor AS eps,
        fin_box.eps_ttm * cumulative_per_share_factor AS eps_ttm,
        fin_box.last_year_q_eps * cumulative_per_share_factor AS last_year_q_eps
      )
    ) AS fin_box
  FROM action_factors
),

all_events AS (
  SELECT date, ticker, fin_box, 0 AS event_priority FROM filing_events
  UNION ALL
  SELECT date, ticker, fin_box, 1 AS event_priority FROM corporate_action_events
)

SELECT date, ticker, fin_box
FROM all_events
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY date, ticker ORDER BY event_priority DESC, fin_box.year_quarter DESC
) = 1
