{{ config(materialized='view') }}

WITH raw_balance_sheet AS (

  SELECT
    *,

    CASE
      WHEN quarter = 1 THEN DATE(year, 5, 16)
      WHEN quarter = 2 THEN DATE(year, 8, 16)
      WHEN quarter = 3 THEN DATE(year, 11, 15)
      WHEN quarter = 4 THEN DATE(year + 1, 4, 1)
    END AS deadline_date

  FROM {{ ref('int_balance_sheet_features') }}

),

market_dates AS (

  SELECT DISTINCT date
  FROM {{ ref('int_daily_indicators') }}

),

aligned_historical AS (

  SELECT
    b.ticker,
    b.year_quarter,
    MIN(m.date) AS aligned_date

  FROM raw_balance_sheet b

  JOIN market_dates m
    ON m.date >= b.deadline_date

  WHERE b.deadline_date IS NOT NULL

  GROUP BY
    b.ticker,
    b.year_quarter

),

-- ============================================================
-- 1. 真實財報 event
-- ============================================================

filing_events AS (

  SELECT

    COALESCE(
      a.aligned_date,
      b.deadline_date
    ) AS date,

    b.ticker,

    'financial_filing' AS event_type,

    STRUCT(
      b.current_assets AS current_assets,
      b.non_current_assets AS non_current_assets,
      b.total_assets AS total_assets,

      b.current_liabilities AS current_liabilities,
      b.non_current_liabilities AS non_current_liabilities,
      b.total_liabilities AS total_liabilities,

      b.share_capital AS share_capital,
      b.share_capital_ntd AS share_capital_ntd,

      -- PIT / contemporaneous basis
      b.shares_outstanding AS shares_outstanding,

      -- fully normalized diagnostic basis
      b.adjusted_shares_outstanding AS adjusted_shares_outstanding,

      b.capital_surplus AS capital_surplus,
      b.retained_earnings AS retained_earnings,
      b.total_equity AS total_equity,

      -- PIT / contemporaneous basis
      b.book_value_per_share AS book_value_per_share,

      -- fully normalized diagnostic basis
      b.adjusted_book_value_per_share AS adjusted_book_value_per_share,

      b.debt_ratio AS debt_ratio,
      b.equity_ratio AS equity_ratio,
      b.current_ratio AS current_ratio,

      -- source period
      b.year_quarter AS year_quarter,

      -- PIT lineage
      b.deadline_date AS deadline_date,
      a.aligned_date AS aligned_date

    ) AS bs_box

  FROM raw_balance_sheet b

  LEFT JOIN aligned_historical a
    ON b.ticker = a.ticker
   AND b.year_quarter = a.year_quarter

  WHERE b.deadline_date IS NOT NULL

),

-- ============================================================
-- 2. Corporate actions
-- ============================================================

actions AS (

  SELECT
    ticker,
    effective_date,

    COALESCE(share_factor, 1.0) AS share_factor,
    COALESCE(per_share_factor, 1.0) AS per_share_factor

  FROM {{ ref('manual_corporate_actions') }}

  WHERE COALESCE(share_factor, 1.0) != 1.0
     OR COALESCE(per_share_factor, 1.0) != 1.0

),

-- ============================================================
-- 3. 對每個 corporate action：
--    找 effective_date 當下最新已知的「真實 filing」
-- ============================================================

action_with_latest_filing AS (

  SELECT
    a.ticker,
    a.effective_date,

    f.date AS filing_event_date,
    f.bs_box,

    ROW_NUMBER() OVER (
      PARTITION BY
        a.ticker,
        a.effective_date

      ORDER BY
        f.date DESC
    ) AS rn

  FROM actions a

  JOIN filing_events f
    ON f.ticker = a.ticker
   AND f.date <= a.effective_date

),

latest_filing AS (

  SELECT
    ticker,
    effective_date,
    filing_event_date,
    bs_box

  FROM action_with_latest_filing

  WHERE rn = 1

),

-- ============================================================
-- 4. 計算：
--    從這份 filing 開始，到目前 action date 為止，
--    所有已發生 corporate actions 的 cumulative factor
--
--    Example:
--
--    filing shares = 100
--
--    8/25 ×4
--    10/10 ×2
--
--    8/25 cumulative = 4
--    10/10 cumulative = 4 × 2 = 8
-- ============================================================

action_factors AS (

  SELECT
    base.ticker,
    base.effective_date,
    base.filing_event_date,
    base.bs_box,

    EXP(
      SUM(
        LN(a.share_factor)
      )
    ) AS cumulative_share_factor,

    EXP(
      SUM(
        LN(a.per_share_factor)
      )
    ) AS cumulative_per_share_factor

  FROM latest_filing base

  JOIN actions a
    ON a.ticker = base.ticker

   -- 只算 filing 已經可用之後發生的 action
   AND a.effective_date > base.filing_event_date

   -- 只算到目前正在建立的 corporate-action event
   AND a.effective_date <= base.effective_date

  GROUP BY
    base.ticker,
    base.effective_date,
    base.filing_event_date,
    base.bs_box

),

-- ============================================================
-- 5. Synthetic corporate-action transition events
-- ============================================================

corporate_action_events AS (

  SELECT

    effective_date AS date,

    ticker,

    'corporate_action' AS event_type,

    STRUCT(
      -- ------------------------------------------------------
      -- Total-level accounting fields 不因 split 改變
      -- ------------------------------------------------------

      bs_box.current_assets AS current_assets,
      bs_box.non_current_assets AS non_current_assets,
      bs_box.total_assets AS total_assets,

      bs_box.current_liabilities AS current_liabilities,
      bs_box.non_current_liabilities AS non_current_liabilities,
      bs_box.total_liabilities AS total_liabilities,

      bs_box.share_capital AS share_capital,
      bs_box.share_capital_ntd AS share_capital_ntd,

      -- ------------------------------------------------------
      -- Basis-sensitive fields
      -- ------------------------------------------------------

      bs_box.shares_outstanding
        * cumulative_share_factor
        AS shares_outstanding,

      -- fully adjusted series 已經是 normalized basis，
      -- 不需要再乘一次
      bs_box.adjusted_shares_outstanding
        AS adjusted_shares_outstanding,

      bs_box.capital_surplus AS capital_surplus,
      bs_box.retained_earnings AS retained_earnings,
      bs_box.total_equity AS total_equity,

      bs_box.book_value_per_share
        * cumulative_per_share_factor
        AS book_value_per_share,

      bs_box.adjusted_book_value_per_share
        AS adjusted_book_value_per_share,

      bs_box.debt_ratio AS debt_ratio,
      bs_box.equity_ratio AS equity_ratio,
      bs_box.current_ratio AS current_ratio,

      -- ------------------------------------------------------
      -- 仍是同一份 underlying financial statement
      -- ------------------------------------------------------

      bs_box.year_quarter AS year_quarter,

      -- ------------------------------------------------------
      -- 保留原 filing PIT lineage
      --
      -- corporate action 不是新財報
      -- ------------------------------------------------------

      bs_box.deadline_date AS deadline_date,
      bs_box.aligned_date AS aligned_date

    ) AS bs_box

  FROM action_factors

),

-- ============================================================
-- 6. Complete balance-sheet state timeline
-- ============================================================

all_events AS (

  SELECT
    date,
    ticker,
    event_type,
    bs_box

  FROM filing_events

  UNION ALL

  SELECT
    date,
    ticker,
    event_type,
    bs_box

  FROM corporate_action_events

)

SELECT *
FROM all_events