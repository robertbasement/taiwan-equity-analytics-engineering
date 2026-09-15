-- Validation only: this test never changes EPS values.
--
-- A 20% relative-error threshold is deliberately conservative. Implied shares
-- from cumulative net income / EPS can differ from period-end shares because
-- of weighted-average and diluted/basic EPS conventions. The threshold is
-- intended to catch directionally wrong or grossly mistyped manual factors,
-- not to require accounting-measure equality.

WITH income AS (

  SELECT
    ticker,
    year_quarter,
    SAFE_CAST(LEFT(year_quarter, 4) AS INT64) AS fiscal_year,
    LAST_DAY(
      DATE(
        SAFE_CAST(LEFT(year_quarter, 4) AS INT64),
        SAFE_CAST(RIGHT(year_quarter, 1) AS INT64) * 3,
        1
      ),
      QUARTER
    ) AS current_period_end,
    net_income AS current_ytd_net_income,
    eps AS current_ytd_eps
  FROM {{ ref('stg_income_statement') }}

),

with_previous AS (

  SELECT
    *,
    LAG(current_period_end) OVER (
      PARTITION BY ticker ORDER BY year_quarter
    ) AS previous_period_end,
    LAG(current_ytd_net_income) OVER (
      PARTITION BY ticker ORDER BY year_quarter
    ) AS previous_ytd_net_income,
    LAG(current_ytd_eps) OVER (
      PARTITION BY ticker ORDER BY year_quarter
    ) AS previous_ytd_eps
  FROM income

),

action_periods AS (

  SELECT
    i.ticker,
    i.year_quarter,
    i.previous_period_end,
    i.current_period_end,
    i.previous_ytd_net_income,
    i.previous_ytd_eps,
    i.current_ytd_net_income,
    i.current_ytd_eps,
    EXP(SUM(LN(a.share_factor))) AS expected_share_factor
  FROM with_previous i
  JOIN {{ ref('manual_corporate_actions') }} a
    ON a.ticker = i.ticker
   AND a.effective_date > i.previous_period_end
   AND a.effective_date <= i.current_period_end
  GROUP BY
    i.ticker,
    i.year_quarter,
    i.previous_period_end,
    i.current_period_end,
    i.previous_ytd_net_income,
    i.previous_ytd_eps,
    i.current_ytd_net_income,
    i.current_ytd_eps

),

diagnostics AS (

  SELECT
    *,
    SAFE_DIVIDE(
      SAFE_DIVIDE(current_ytd_net_income, NULLIF(current_ytd_eps, 0)),
      SAFE_DIVIDE(previous_ytd_net_income, NULLIF(previous_ytd_eps, 0))
    ) AS implied_share_ratio
  FROM action_periods

)

SELECT
  *,
  ABS(
    SAFE_DIVIDE(implied_share_ratio, NULLIF(expected_share_factor, 0)) - 1
  ) AS relative_error
FROM diagnostics
WHERE implied_share_ratio IS NOT NULL
  AND expected_share_factor > 0
  AND ABS(
    SAFE_DIVIDE(implied_share_ratio, NULLIF(expected_share_factor, 0)) - 1
  ) > 0.20
