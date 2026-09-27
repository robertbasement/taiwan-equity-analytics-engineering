WITH revenue_ties AS (

  SELECT
    'revenue' AS family,
    ticker,
    year_month AS source_period,
    COUNT(DISTINCT TO_JSON_STRING(STRUCT(
      revenue,
      revenue_last_year,
      yoy_growth_pct,
      mom_growth_pct,
      ytd_growth_pct,
      yoy_triple_increase_signal,
      yoy_positive_streak_count
    ))) AS distinct_payload_count

  FROM {{ ref('int_monthly_revenue_features') }}

  GROUP BY 1, 2, 3

  HAVING distinct_payload_count > 1

),

balance_sheet_ties AS (

  SELECT
    'balance_sheet' AS family,
    ticker,
    year_quarter AS source_period,
    COUNT(DISTINCT TO_JSON_STRING(STRUCT(
      current_assets,
      non_current_assets,
      total_assets,
      current_liabilities,
      non_current_liabilities,
      total_liabilities,
      share_capital,
      shares_outstanding,
      book_value_per_share,
      total_equity
    ))) AS distinct_payload_count

  FROM {{ ref('int_balance_sheet_features') }}

  GROUP BY 1, 2, 3

  HAVING distinct_payload_count > 1

)

SELECT * FROM revenue_ties
UNION ALL
SELECT * FROM balance_sheet_ties
