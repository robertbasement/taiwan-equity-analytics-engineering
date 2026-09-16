-- Generic, human-readable validation of corporate-action EPS transitions.
-- Render with dbt before execution so ref() resolves for the selected target.
--
-- Implied-share calculations are VALIDATION EVIDENCE ONLY. They must never
-- determine or alter the canonical EPS transformation.

WITH actions AS (

  SELECT
    ticker,
    effective_date,
    per_share_factor,
    share_factor,
    note
  FROM {{ ref('manual_corporate_actions') }}

),

configured_tickers AS (

  SELECT DISTINCT ticker
  FROM actions

),

income_periods AS (

  SELECT
    i.ticker,
    i.year_quarter,
    SAFE_CAST(LEFT(i.year_quarter, 4) AS INT64) AS fiscal_year,
    SAFE_CAST(RIGHT(i.year_quarter, 1) AS INT64) AS fiscal_quarter,
    LAST_DAY(
      DATE(
        SAFE_CAST(LEFT(i.year_quarter, 4) AS INT64),
        SAFE_CAST(RIGHT(i.year_quarter, 1) AS INT64) * 3,
        1
      ),
      QUARTER
    ) AS current_period_end,
    i.net_income AS current_ytd_net_income_thousands,
    i.eps AS current_ytd_eps
  FROM {{ ref('stg_income_statement') }} i
  INNER JOIN configured_tickers t USING (ticker)

),

-- Window the financial sequence before joining actions. This prevents a
-- ticker with multiple actions from duplicating rows used by LAG().
period_pairs AS (

  SELECT
    *,
    LAG(year_quarter) OVER (
      PARTITION BY ticker ORDER BY current_period_end
    ) AS previous_year_quarter,
    LAG(fiscal_year) OVER (
      PARTITION BY ticker ORDER BY current_period_end
    ) AS previous_fiscal_year,
    LAG(current_period_end) OVER (
      PARTITION BY ticker ORDER BY current_period_end
    ) AS previous_period_end,
    LAG(current_ytd_net_income_thousands) OVER (
      PARTITION BY ticker ORDER BY current_period_end
    ) AS previous_ytd_net_income_thousands,
    LAG(current_ytd_eps) OVER (
      PARTITION BY ticker ORDER BY current_period_end
    ) AS previous_ytd_eps
  FROM income_periods

),

interval_factors AS (

  SELECT
    p.ticker,
    p.previous_year_quarter,
    p.year_quarter AS current_year_quarter,
    p.previous_fiscal_year,
    p.fiscal_year AS current_fiscal_year,
    p.fiscal_quarter AS current_fiscal_quarter,
    p.previous_period_end,
    p.current_period_end,
    p.previous_ytd_net_income_thousands,
    p.current_ytd_net_income_thousands,
    p.previous_ytd_eps,
    p.current_ytd_eps,

    COUNT(a.effective_date) AS action_count,
    ARRAY_AGG(
      a.effective_date IGNORE NULLS ORDER BY a.effective_date
    ) AS action_dates,
    STRING_AGG(a.note, '; ' ORDER BY a.effective_date) AS action_notes,

    COALESCE(
      EXP(SUM(LN(a.per_share_factor))),
      1.0
    ) AS factor_between_periods,
    COALESCE(
      EXP(SUM(LN(a.share_factor))),
      1.0
    ) AS expected_share_transition_ratio

  FROM period_pairs p

  LEFT JOIN actions a
    ON a.ticker = p.ticker
   AND a.effective_date > p.previous_period_end
   AND a.effective_date <= p.current_period_end

  GROUP BY
    p.ticker,
    p.previous_year_quarter,
    p.year_quarter,
    p.previous_fiscal_year,
    p.fiscal_year,
    p.fiscal_quarter,
    p.previous_period_end,
    p.current_period_end,
    p.previous_ytd_net_income_thousands,
    p.current_ytd_net_income_thousands,
    p.previous_ytd_eps,
    p.current_ytd_eps

),

balance_evidence AS (

  SELECT
    ticker,
    year_quarter,
    SAFE_DIVIDE(
      total_equity * 1000,
      NULLIF(book_value_per_share, 0)
    ) AS approximate_shares
  FROM {{ ref('stg_balance_sheet') }}

),

calculated AS (

  SELECT
    f.*,

    f.previous_ytd_eps * f.factor_between_periods
      AS previous_ytd_eps_on_current_basis,

    CASE
      WHEN f.current_fiscal_quarter = 1 THEN f.current_ytd_eps
      ELSE f.current_ytd_eps - f.previous_ytd_eps
    END AS naive_q_eps,

    CASE
      WHEN f.current_fiscal_quarter = 1 THEN f.current_ytd_eps
      ELSE f.current_ytd_eps
        - f.previous_ytd_eps * f.factor_between_periods
    END AS reconciled_q_eps,

    SAFE_DIVIDE(
      f.previous_ytd_net_income_thousands * 1000,
      NULLIF(f.previous_ytd_eps, 0)
    ) AS previous_implied_ytd_shares,

    SAFE_DIVIDE(
      f.current_ytd_net_income_thousands * 1000,
      NULLIF(f.current_ytd_eps, 0)
    ) AS current_implied_ytd_shares,

    previous_balance.approximate_shares AS previous_balance_approximate_shares,
    current_balance.approximate_shares AS current_balance_approximate_shares

  FROM interval_factors f

  LEFT JOIN balance_evidence previous_balance
    ON previous_balance.ticker = f.ticker
   AND previous_balance.year_quarter = f.previous_year_quarter

  LEFT JOIN balance_evidence current_balance
    ON current_balance.ticker = f.ticker
   AND current_balance.year_quarter = f.current_year_quarter

),

ratios AS (

  SELECT
    *,
    SAFE_DIVIDE(
      current_implied_ytd_shares,
      NULLIF(previous_implied_ytd_shares, 0)
    ) AS implied_share_transition_ratio,
    SAFE_DIVIDE(
      current_balance_approximate_shares,
      NULLIF(previous_balance_approximate_shares, 0)
    ) AS balance_share_transition_ratio
  FROM calculated

)

SELECT
  ticker,
  previous_year_quarter,
  current_year_quarter,
  previous_period_end,
  current_period_end,
  action_count,
  action_dates,
  action_notes,

  previous_ytd_eps,
  current_ytd_eps,
  factor_between_periods,
  previous_ytd_eps_on_current_basis,
  naive_q_eps,
  reconciled_q_eps,

  previous_implied_ytd_shares,
  current_implied_ytd_shares,
  implied_share_transition_ratio,
  expected_share_transition_ratio,
  SAFE_DIVIDE(
    implied_share_transition_ratio,
    NULLIF(expected_share_transition_ratio, 0)
  ) - 1 AS implied_share_ratio_relative_difference,

  previous_balance_approximate_shares,
  current_balance_approximate_shares,
  balance_share_transition_ratio,
  SAFE_DIVIDE(
    balance_share_transition_ratio,
    NULLIF(expected_share_transition_ratio, 0)
  ) - 1 AS balance_share_ratio_relative_difference

FROM ratios

-- Keep all adjacent periods so factor=1 intervals are visible and future
-- actions can be verified not to leak backward. Filter action_count > 0 when
-- only configured action periods are wanted.
ORDER BY action_count DESC, ticker, current_period_end
