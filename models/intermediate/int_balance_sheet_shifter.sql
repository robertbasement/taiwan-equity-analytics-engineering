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

final AS (

  SELECT

    -- operational event date
    COALESCE(
      a.aligned_date,
      b.deadline_date
    ) AS date,

    b.ticker,

    STRUCT(
      b.current_assets AS current_assets,
      b.non_current_assets AS non_current_assets,
      b.total_assets AS total_assets,

      b.current_liabilities AS current_liabilities,
      b.non_current_liabilities AS non_current_liabilities,
      b.total_liabilities AS total_liabilities,

      b.share_capital AS share_capital,
      b.share_capital_ntd AS share_capital_ntd,
      b.shares_outstanding AS shares_outstanding,

      b.capital_surplus AS capital_surplus,
      b.retained_earnings AS retained_earnings,
      b.total_equity AS total_equity,

      b.book_value_per_share AS book_value_per_share,

      b.debt_ratio AS debt_ratio,
      b.equity_ratio AS equity_ratio,
      b.current_ratio AS current_ratio,

      -- source lineage
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

)

SELECT *
FROM final