-- Human-readable coverage inventory for configured corporate actions.
-- Render with dbt before execution so ref()/source() resolve for the target.
-- This query is diagnostic only and does not materialize warehouse objects.

WITH actions AS (

  SELECT
    ticker,
    effective_date,
    price_factor,
    per_share_factor,
    share_factor,
    note
  FROM {{ ref('manual_corporate_actions') }}

),

income_periods AS (

  SELECT
    ticker,
    year_quarter,
    LAST_DAY(
      DATE(
        SAFE_CAST(LEFT(year_quarter, 4) AS INT64),
        SAFE_CAST(RIGHT(year_quarter, 1) AS INT64) * 3,
        1
      ),
      QUARTER
    ) AS period_end,
    net_income,
    eps
  FROM {{ ref('stg_income_statement') }}

),

income_coverage AS (

  SELECT
    ticker,
    COUNT(*) AS income_statement_rows,
    COUNTIF(eps IS NOT NULL) AS usable_eps_rows,
    MIN(year_quarter) AS earliest_income_period,
    MAX(year_quarter) AS latest_income_period
  FROM income_periods
  GROUP BY ticker

),

balance_periods AS (

  SELECT
    ticker,
    year_quarter,
    LAST_DAY(
      DATE(
        SAFE_CAST(LEFT(year_quarter, 4) AS INT64),
        SAFE_CAST(RIGHT(year_quarter, 1) AS INT64) * 3,
        1
      ),
      QUARTER
    ) AS period_end,
    SAFE_DIVIDE(
      total_equity * 1000,
      NULLIF(book_value_per_share, 0)
    ) AS approximate_shares
  FROM {{ ref('stg_balance_sheet') }}

),

balance_coverage AS (

  SELECT
    ticker,
    COUNT(*) AS balance_sheet_rows,
    COUNTIF(approximate_shares IS NOT NULL) AS usable_balance_rows,
    MIN(year_quarter) AS earliest_balance_period,
    MAX(year_quarter) AS latest_balance_period
  FROM balance_periods
  GROUP BY ticker

),

action_period_bounds AS (

  SELECT
    a.*,
    (
      SELECT MAX(i.period_end)
      FROM income_periods i
      WHERE i.ticker = a.ticker
        AND i.period_end < a.effective_date
    ) AS previous_income_period_end,
    (
      SELECT MIN(i.period_end)
      FROM income_periods i
      WHERE i.ticker = a.ticker
        AND i.period_end >= a.effective_date
    ) AS current_income_period_end
  FROM actions a

)

SELECT
  a.ticker,
  a.effective_date,
  a.price_factor,
  a.per_share_factor,
  a.share_factor,
  a.note,

  COALESCE(i.income_statement_rows, 0) AS income_statement_rows,
  COALESCE(i.usable_eps_rows, 0) AS usable_eps_rows,
  i.earliest_income_period,
  i.latest_income_period,

  COALESCE(b.balance_sheet_rows, 0) AS balance_sheet_rows,
  COALESCE(b.usable_balance_rows, 0) AS usable_balance_rows,
  b.earliest_balance_period,
  b.latest_balance_period,

  previous_income.year_quarter AS previous_income_period,
  current_income.year_quarter AS current_income_period,

  COALESCE(
    previous_income.eps IS NOT NULL
      AND previous_income.net_income IS NOT NULL
      AND current_income.eps IS NOT NULL
      AND current_income.net_income IS NOT NULL
      AND previous_balance.approximate_shares IS NOT NULL
      AND current_balance.approximate_shares IS NOT NULL,
    FALSE
  ) AS is_empirically_usable_for_eps_validation

FROM action_period_bounds a

LEFT JOIN income_coverage i USING (ticker)
LEFT JOIN balance_coverage b USING (ticker)

LEFT JOIN income_periods previous_income
  ON previous_income.ticker = a.ticker
 AND previous_income.period_end = a.previous_income_period_end

LEFT JOIN income_periods current_income
  ON current_income.ticker = a.ticker
 AND current_income.period_end = a.current_income_period_end

LEFT JOIN balance_periods previous_balance
  ON previous_balance.ticker = a.ticker
 AND previous_balance.period_end = a.previous_income_period_end

LEFT JOIN balance_periods current_balance
  ON current_balance.ticker = a.ticker
 AND current_balance.period_end = a.current_income_period_end

ORDER BY a.effective_date, a.ticker
