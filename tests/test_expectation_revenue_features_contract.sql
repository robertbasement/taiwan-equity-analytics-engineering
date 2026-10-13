WITH source_monthly AS (
  SELECT
    ticker,
    year_month AS revenue_month,
    PARSE_DATE('%Y-%m', year_month) AS revenue_month_date,
    revenue,
    yoy_growth_pct
  FROM {{ ref('stg_monthly_revenue') }}
),
sequenced AS (
  SELECT
    *,
    LAG(revenue_month_date) OVER (
      PARTITION BY ticker ORDER BY revenue_month_date
    ) AS previous_revenue_month_date
  FROM source_monthly
),
segmented AS (
  SELECT
    *,
    SUM(
      IF(
        previous_revenue_month_date IS NULL
        OR DATE_DIFF(revenue_month_date, previous_revenue_month_date, MONTH) != 1,
        1,
        0
      )
    ) OVER (PARTITION BY ticker ORDER BY revenue_month_date) AS continuity_segment
  FROM sequenced
),
expected AS (
  SELECT
    ticker,
    revenue_month,
    CASE
      WHEN COUNT(revenue) OVER (
        PARTITION BY ticker, continuity_segment
        ORDER BY revenue_month_date
        ROWS BETWEEN 11 PRECEDING AND CURRENT ROW
      ) = 12
      THEN SUM(revenue) OVER (
        PARTITION BY ticker, continuity_segment
        ORDER BY revenue_month_date
        ROWS BETWEEN 11 PRECEDING AND CURRENT ROW
      )
    END AS expected_ttm,
    AVG(yoy_growth_pct / 100.0) OVER (
      PARTITION BY ticker, continuity_segment
      ORDER BY revenue_month_date
      ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    ) AS expected_3m,
    AVG(yoy_growth_pct / 100.0) OVER (
      PARTITION BY ticker, continuity_segment
      ORDER BY revenue_month_date
      ROWS BETWEEN 5 PRECEDING AND CURRENT ROW
    ) AS expected_6m
  FROM segmented
),
actual AS (
  SELECT
    ticker,
    revenue_month,
    ANY_VALUE(monthly_revenue_ttm) AS actual_ttm,
    ANY_VALUE(revenue_yoy_3m_avg) AS actual_3m,
    ANY_VALUE(revenue_yoy_6m_avg) AS actual_6m
  FROM {{ ref('mart_expectation_features') }}
  WHERE revenue_month IS NOT NULL
  GROUP BY 1, 2
)
SELECT actual.*, expected.expected_ttm, expected.expected_3m, expected.expected_6m
FROM actual
LEFT JOIN expected USING (ticker, revenue_month)
WHERE actual_ttm IS DISTINCT FROM expected_ttm
   OR ABS(actual_3m - expected_3m) > 1e-12
   OR ABS(actual_6m - expected_6m) > 1e-12
   OR (actual_3m IS NULL) != (expected_3m IS NULL)
   OR (actual_6m IS NULL) != (expected_6m IS NULL)
