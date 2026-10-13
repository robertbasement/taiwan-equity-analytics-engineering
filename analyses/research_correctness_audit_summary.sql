-- SELECT-only audit inventory. This analysis does not materialize data.

WITH checks AS (
  SELECT 'raw_price_duplicate_keys' AS check_name, COUNT(*) AS issue_count
  FROM (
    SELECT date, ticker
    FROM {{ source('stock_data', 'daily_prices_partitioned') }}
    GROUP BY 1, 2 HAVING COUNT(*) > 1
  )
  UNION ALL
  SELECT 'raw_income_duplicate_keys', COUNT(*)
  FROM (
    SELECT ticker, year_quarter
    FROM {{ source('stock_data', 'income_statement') }}
    GROUP BY 1, 2 HAVING COUNT(*) > 1
  )
  UNION ALL
  SELECT 'raw_balance_duplicate_keys', COUNT(*)
  FROM (
    SELECT ticker, year_quarter
    FROM {{ source('stock_data', 'balance_sheet') }}
    GROUP BY 1, 2 HAVING COUNT(*) > 1
  )
  UNION ALL
  SELECT 'raw_revenue_duplicate_keys', COUNT(*)
  FROM (
    SELECT ticker, year_month
    FROM {{ source('stock_data', 'monthly_revenue') }}
    GROUP BY 1, 2 HAVING COUNT(*) > 1
  )
  UNION ALL
  SELECT 'monthly_forward_return_null_with_next_date', COUNT(*)
  FROM {{ ref('mart_factor_research_monthly') }}
  WHERE next_rebalance_date IS NOT NULL AND forward_return IS NULL
  UNION ALL
  SELECT 'monthly_abs_return_gt_100pct', COUNT(*)
  FROM {{ ref('mart_factor_research_monthly') }}
  WHERE ABS(forward_return) > 1
  UNION ALL
  SELECT 'formation_rows_without_positive_volume', COUNT(*)
  FROM {{ ref('mart_factor_research_monthly') }}
  WHERE d_vol IS NULL OR d_vol <= 0
  UNION ALL
  SELECT 'revenue_pit_future', COUNT(*)
  FROM {{ ref('mart_factor_research_monthly') }}
  WHERE revenue_aligned_date > rebalance_date
  UNION ALL
  SELECT 'income_pit_future', COUNT(*)
  FROM {{ ref('mart_factor_research_monthly') }}
  WHERE financial_aligned_date > rebalance_date
  UNION ALL
  SELECT 'balance_pit_future', COUNT(*)
  FROM {{ ref('mart_factor_research_monthly') }}
  WHERE balance_sheet_aligned_date > rebalance_date
)

SELECT *
FROM checks
ORDER BY check_name
