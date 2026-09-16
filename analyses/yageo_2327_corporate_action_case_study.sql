-- Yageo / 國巨 2327 is currently the only usable equity corporate-action
-- case empirically validated in this project. This SELECT-only case study is
-- an end-to-end regression example, not a universal accounting rule.
--
-- It reproduces commit 787e396 semantics without materializing the branch:
--   * reporting-basis reconciliation belongs to financial features;
--   * observation-date transitions belong to the PIT shifter;
--   * dividend and split price factors apply strictly before their event date.
--
-- The warehouse does not retain immutable filing versions. Re-fetching an old
-- quarter may replace its previously observed source basis.
-- Render with dbt before execution so ref() resolves for the selected target.

WITH actions AS (

  -- A. Corporate-action definition
  SELECT
    ticker,
    effective_date,
    price_factor,
    per_share_factor,
    share_factor,
    note
  FROM {{ ref('manual_corporate_actions') }}
  WHERE ticker = '2327'

),

income_source AS (

  -- B. Source cumulative EPS and reporting-period boundaries
  SELECT
    ticker,
    year_quarter,
    LEFT(year_quarter, 4) AS year_label,
    RIGHT(year_quarter, 1) AS quarter_label,
    LAST_DAY(
      DATE(
        SAFE_CAST(LEFT(year_quarter, 4) AS INT64),
        SAFE_CAST(RIGHT(year_quarter, 1) AS INT64) * 3,
        1
      ),
      QUARTER
    ) AS current_period_end,
    net_income AS ytd_net_income_thousands,
    eps AS raw_ytd_eps
  FROM {{ ref('stg_income_statement') }}
  WHERE ticker = '2327'
    AND year_quarter BETWEEN '2023-1' AND '2025-4'

),

income_with_previous AS (

  SELECT
    *,
    LAG(current_period_end) OVER (
      PARTITION BY ticker, year_label ORDER BY year_quarter
    ) AS previous_period_end,
    LAG(raw_ytd_eps) OVER (
      PARTITION BY ticker, year_label ORDER BY year_quarter
    ) AS previous_ytd_eps,
    LAG(ytd_net_income_thousands) OVER (
      PARTITION BY ticker, year_label ORDER BY year_quarter
    ) AS previous_ytd_net_income_thousands
  FROM income_source

),

income_factors AS (

  SELECT
    p.*,
    COALESCE((
      SELECT EXP(SUM(LN(a.per_share_factor)))
      FROM actions a
      WHERE a.ticker = p.ticker
        AND a.effective_date > p.previous_period_end
        AND a.effective_date <= p.current_period_end
    ), 1.0) AS factor_between_periods,
    COALESCE((
      SELECT EXP(SUM(LN(a.per_share_factor)))
      FROM actions a
      WHERE a.ticker = p.ticker
        AND a.effective_date <= p.current_period_end
    ), 1.0) AS cumulative_per_share_factor
  FROM income_with_previous p

),

quarter_features AS (

  -- Convert only the previous cumulative operand. The historical source row
  -- itself remains unchanged.
  SELECT
    *,
    previous_ytd_eps * factor_between_periods
      AS previous_ytd_eps_on_current_basis,
    CASE
      WHEN quarter_label = '1' THEN raw_ytd_eps
      ELSE raw_ytd_eps - previous_ytd_eps * factor_between_periods
    END AS q_eps,
    CASE
      WHEN quarter_label = '1' THEN ytd_net_income_thousands
      ELSE ytd_net_income_thousands - previous_ytd_net_income_thousands
    END AS q_net_income_thousands
  FROM income_factors

),

eps_components AS (

  -- C. Basis-compatible quarterly components used only to construct current
  -- TTM and prior-year comparison operands.
  SELECT
    *,
    SAFE_DIVIDE(
      q_eps,
      NULLIF(cumulative_per_share_factor, 0)
    ) AS q_eps_action_neutral
  FROM quarter_features

),

financial_features_before_yoy AS (

  SELECT
    *,
    CASE
      WHEN COUNT(q_eps) OVER (
        PARTITION BY ticker ORDER BY year_quarter
        ROWS BETWEEN 3 PRECEDING AND CURRENT ROW
      ) = 4
      THEN cumulative_per_share_factor * SUM(q_eps_action_neutral) OVER (
        PARTITION BY ticker ORDER BY year_quarter
        ROWS BETWEEN 3 PRECEDING AND CURRENT ROW
      )
    END AS eps_ttm,
    LAG(q_eps_action_neutral, 4) OVER (
      PARTITION BY ticker ORDER BY year_quarter
    ) * cumulative_per_share_factor AS last_year_q_eps
  FROM eps_components

),

financial_features AS (

  SELECT
    *,
    SAFE_DIVIDE(q_eps, NULLIF(last_year_q_eps, 0)) - 1
      AS eps_yoy_growth,
    CASE quarter_label
      WHEN '1' THEN DATE(SAFE_CAST(year_label AS INT64), 5, 16)
      WHEN '2' THEN DATE(SAFE_CAST(year_label AS INT64), 8, 15)
      WHEN '3' THEN DATE(SAFE_CAST(year_label AS INT64), 11, 15)
      ELSE DATE(SAFE_CAST(year_label AS INT64) + 1, 4, 1)
    END AS deadline_date
  FROM financial_features_before_yoy

),

market_dates AS (

  SELECT DISTINCT date
  FROM {{ ref('int_daily_indicators') }}

),

aligned_financial_features AS (

  SELECT
    f.*,
    COALESCE((
      SELECT MIN(m.date)
      FROM market_dates m
      WHERE m.date >= f.deadline_date
    ), f.deadline_date) AS event_date
  FROM financial_features f

),

filing_events AS (

  -- D. A filing is already on its reporting-period basis. Apply only actions
  -- after that period end and no later than its observation date.
  SELECT
    event_date,
    'financial_filing' AS event_type,
    ticker,
    year_quarter,
    q_eps * applied_factor AS q_eps,
    eps_ttm * applied_factor AS eps_ttm,
    last_year_q_eps * applied_factor AS last_year_q_eps,
    eps_yoy_growth,
    applied_factor
  FROM (
    SELECT
      f.*,
      COALESCE((
        SELECT EXP(SUM(LN(a.per_share_factor)))
        FROM actions a
        WHERE a.ticker = f.ticker
          AND a.effective_date > f.current_period_end
          AND a.effective_date <= f.event_date
      ), 1.0) AS applied_factor
    FROM aligned_financial_features f
  )

),

latest_filing_at_action AS (

  SELECT
    a.effective_date,
    f.*,
    ROW_NUMBER() OVER (
      PARTITION BY a.ticker, a.effective_date
      ORDER BY f.event_date DESC, f.year_quarter DESC
    ) AS row_num
  FROM actions a
  INNER JOIN filing_events f
    ON f.ticker = a.ticker
   AND f.event_date <= a.effective_date

),

corporate_action_events AS (

  SELECT
    effective_date AS event_date,
    'corporate_action' AS event_type,
    ticker,
    year_quarter,
    q_eps * action_factor AS q_eps,
    eps_ttm * action_factor AS eps_ttm,
    last_year_q_eps * action_factor AS last_year_q_eps,
    eps_yoy_growth,
    applied_factor * action_factor AS applied_factor
  FROM (
    SELECT
      f.*,
      COALESCE((
        SELECT EXP(SUM(LN(a.per_share_factor)))
        FROM actions a
        WHERE a.ticker = f.ticker
          AND a.effective_date > f.event_date
          AND a.effective_date <= f.effective_date
      ), 1.0) AS action_factor
    FROM latest_filing_at_action f
    WHERE row_num = 1
  )

),

financial_events AS (

  SELECT * FROM filing_events
  UNION ALL
  SELECT * FROM corporate_action_events

),

financial_event_state AS (

  SELECT * EXCEPT(event_priority)
  FROM (
    SELECT
      *,
      IF(event_type = 'corporate_action', 1, 0) AS event_priority
    FROM financial_events
  )
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY ticker, event_date
    ORDER BY event_priority DESC, year_quarter DESC
  ) = 1

),

raw_price_rows AS (

  -- E/F. Reproduce effective price and event-date-adjusted return semantics.
  SELECT
    ticker,
    date,
    close AS raw_close,
    IF(close > 0, close, NULL) AS valid_close
  FROM {{ ref('stg_daily_prices_raw') }}
  WHERE ticker = '2327'
    AND date >= DATE '2000-01-01'

),

price_filled AS (

  SELECT
    *,
    LAST_VALUE(valid_close IGNORE NULLS) OVER (
      PARTITION BY ticker ORDER BY date
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS last_valid_close,
    MAX(IF(valid_close IS NOT NULL, date, NULL)) OVER (
      PARTITION BY ticker ORDER BY date
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS last_valid_trade_date
  FROM raw_price_rows

),

price_cleaned AS (

  SELECT
    *,
    CASE
      WHEN last_valid_trade_date IS NULL THEN NULL
      WHEN DATE_DIFF(date, last_valid_trade_date, DAY) <= 30
        THEN last_valid_close
    END AS effective_close
  FROM price_filled

),

dividend_factors AS (

  SELECT ticker, ex_date, daily_factor
  FROM {{ ref('stg_dividend_factor') }}
  WHERE ticker = '2327'

),

price_factor_timeline AS (

  SELECT
    ticker,
    date,
    1 AS is_price,
    CAST(NULL AS FLOAT64) AS log_factor
  FROM (SELECT DISTINCT ticker, date FROM price_cleaned)

  UNION ALL

  SELECT
    d.ticker,
    d.ex_date AS date,
    0 AS is_price,
    LN(CASE
      WHEN EXISTS (
        SELECT 1
        FROM actions a
        WHERE a.ticker = d.ticker
          AND a.effective_date = d.ex_date
          AND a.price_factor != 1.0
      ) THEN ERROR('source/manual price-factor collision in 2327 case study')
      ELSE d.daily_factor
    END) AS log_factor
  FROM dividend_factors d

),

price_factor_windows AS (

  SELECT
    ticker,
    date,
    is_price,
    EXP(COALESCE(SUM(log_factor) OVER (
      PARTITION BY ticker
      ORDER BY date DESC, is_price DESC
      ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
    ), 0.0)) AS source_future_factor
  FROM price_factor_timeline

),

price_features AS (

  SELECT
    p.ticker,
    p.date,
    p.raw_close,
    p.effective_close,
    f.source_future_factor,
    COALESCE((
      SELECT EXP(SUM(LN(a.price_factor)))
      FROM actions a
      WHERE a.ticker = p.ticker
        AND p.date < a.effective_date
    ), 1.0) AS manual_future_factor,
    p.effective_close
      * f.source_future_factor
      * COALESCE((
          SELECT EXP(SUM(LN(a.price_factor)))
          FROM actions a
          WHERE a.ticker = p.ticker
            AND p.date < a.effective_date
        ), 1.0) AS adjusted_close
  FROM price_cleaned p
  INNER JOIN price_factor_windows f
    ON f.ticker = p.ticker
   AND f.date = p.date
   AND f.is_price = 1

),

price_returns AS (

  SELECT
    *,
    SAFE_DIVIDE(
      adjusted_close,
      LAG(adjusted_close) OVER (PARTITION BY ticker ORDER BY date)
    ) - 1 AS daily_return
  FROM price_features

),

price_evidence AS (

  SELECT
    p.*,
    d.daily_factor AS dividend_event_factor,
    a.price_factor AS corporate_action_event_factor
  FROM price_returns p
  LEFT JOIN dividend_factors d
    ON d.ticker = p.ticker
   AND d.ex_date = p.date
  LEFT JOIN actions a
    ON a.ticker = p.ticker
   AND a.effective_date = p.date

),

daily_financial_state AS (

  SELECT
    p.date,
    p.effective_close,
    e.year_quarter AS source_financial_quarter,
    e.eps_ttm AS pit_eps_ttm,
    ROW_NUMBER() OVER (
      PARTITION BY p.date
      ORDER BY e.event_date DESC, e.year_quarter DESC
    ) AS row_num
  FROM price_evidence p
  INNER JOIN financial_event_state e
    ON e.ticker = p.ticker
   AND e.event_date <= p.date
  WHERE p.date IN (
    DATE '2025-08-13',
    DATE '2025-08-25',
    DATE '2025-08-26',
    DATE '2025-11-14',
    DATE '2025-11-17'
  )

),

balance_evidence AS (

  SELECT
    SAFE_DIVIDE(
      total_equity * 1000,
      NULLIF(book_value_per_share, 0)
    ) AS q3_balance_approximate_shares
  FROM {{ ref('stg_balance_sheet') }}
  WHERE ticker = '2327'
    AND year_quarter = '2025-3'

),

implied_share_evidence AS (

  -- G. Independent validation evidence only; never an EPS input.
  SELECT
    MAX(IF(
      year_quarter = '2025-2',
      SAFE_DIVIDE(ytd_net_income_thousands * 1000, NULLIF(raw_ytd_eps, 0)),
      NULL
    )) AS q2_implied_ytd_shares,
    MAX(IF(
      year_quarter = '2025-3',
      SAFE_DIVIDE(ytd_net_income_thousands * 1000, NULLIF(raw_ytd_eps, 0)),
      NULL
    )) AS q3_implied_ytd_shares,
    MAX(IF(year_quarter = '2025-3', q_net_income_thousands, NULL))
      AS q3_incremental_net_income_thousands,
    MAX(IF(year_quarter = '2025-3', q_eps, NULL)) AS q3_reconciled_eps
  FROM financial_features

),

share_sanity AS (

  SELECT
    s.*,
    SAFE_DIVIDE(q3_implied_ytd_shares, NULLIF(q2_implied_ytd_shares, 0))
      AS implied_ytd_share_transition_ratio,
    a.share_factor AS configured_share_factor,
    SAFE_DIVIDE(
      q3_incremental_net_income_thousands * 1000,
      NULLIF(q3_reconciled_eps, 0)
    ) AS q3_implied_quarter_shares,
    b.q3_balance_approximate_shares
  FROM implied_share_evidence s
  CROSS JOIN balance_evidence b
  CROSS JOIN actions a

)

SELECT
  'A_action_definition' AS section,
  CAST(effective_date AS STRING) AS sort_key,
  TO_JSON_STRING(STRUCT(
    ticker,
    effective_date,
    price_factor,
    per_share_factor,
    share_factor,
    note
  )) AS row_json
FROM actions

UNION ALL

SELECT
  'B_source_basis_reconciliation',
  year_quarter,
  TO_JSON_STRING(STRUCT(
    year_quarter,
    raw_ytd_eps,
    previous_ytd_eps,
    factor_between_periods,
    previous_ytd_eps_on_current_basis,
    q_eps
  ))
FROM financial_features
WHERE year_quarter IN ('2025-2', '2025-3', '2025-4')

UNION ALL

SELECT
  'C_basis_consistent_features',
  year_quarter,
  TO_JSON_STRING(STRUCT(
    year_quarter,
    q_eps,
    eps_ttm,
    last_year_q_eps,
    eps_yoy_growth
  ))
FROM financial_features
WHERE year_quarter IN ('2025-2', '2025-3', '2025-4')

UNION ALL

SELECT
  'D_pit_event_timeline',
  CAST(event_date AS STRING),
  TO_JSON_STRING(STRUCT(
    event_date,
    event_type,
    year_quarter AS source_quarter,
    q_eps,
    eps_ttm,
    last_year_q_eps,
    eps_yoy_growth,
    applied_factor
  ))
FROM financial_event_state
WHERE event_date IN (
  DATE '2025-08-15',
  DATE '2025-08-25',
  DATE '2025-11-17'
)

UNION ALL

SELECT
  'E_pe_continuity',
  CAST(date AS STRING),
  TO_JSON_STRING(STRUCT(
    date,
    effective_close,
    pit_eps_ttm,
    SAFE_DIVIDE(effective_close, NULLIF(pit_eps_ttm, 0)) AS pe_ttm,
    source_financial_quarter
  ))
FROM daily_financial_state
WHERE row_num = 1

UNION ALL

SELECT
  'F_price_adjustment',
  CAST(date AS STRING),
  TO_JSON_STRING(STRUCT(
    date,
    raw_close,
    effective_close,
    adjusted_close,
    daily_return,
    dividend_event_factor,
    corporate_action_event_factor,
    source_future_factor,
    manual_future_factor
  ))
FROM price_evidence
WHERE date IN (
  DATE '2025-06-12',
  DATE '2025-06-13',
  DATE '2025-06-16',
  DATE '2025-08-13',
  DATE '2025-08-25',
  DATE '2025-08-26'
)

UNION ALL

SELECT
  'G_implied_share_sanity',
  '2025-3',
  TO_JSON_STRING(STRUCT(
    q2_implied_ytd_shares,
    q3_implied_ytd_shares,
    implied_ytd_share_transition_ratio,
    configured_share_factor,
    q3_incremental_net_income_thousands,
    q3_reconciled_eps,
    q3_implied_quarter_shares,
    q3_balance_approximate_shares,
    SAFE_DIVIDE(
      q3_implied_quarter_shares,
      NULLIF(q3_balance_approximate_shares, 0)
    ) - 1 AS quarter_vs_balance_relative_difference
  ))
FROM share_sanity

ORDER BY section, sort_key
