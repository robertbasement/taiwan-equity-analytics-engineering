WITH expected AS (

  SELECT
    'revenue' AS family,
    '2009-11' AS source_period,
    DATE '2009-12-11' AS deadline_date,
    CAST(52.1 AS FLOAT64) AS diagnostic_value

  UNION ALL

  SELECT
    'balance_sheet' AS family,
    '2009-3' AS source_period,
    DATE '2009-11-15' AS deadline_date,
    CAST(26112292725 AS FLOAT64) AS diagnostic_value

),

actual AS (

  SELECT
    'revenue' AS family,
    rev_box.data_month_label AS source_period,
    rev_box.deadline_date AS deadline_date,
    rev_box.yoy_growth_pct AS diagnostic_value

  FROM {{ ref('int_monthly_revenue_shifter') }}

  WHERE ticker = '2330'
    AND date = DATE '2010-01-04'

  UNION ALL

  SELECT
    'balance_sheet' AS family,
    bs_box.year_quarter AS source_period,
    bs_box.deadline_date AS deadline_date,
    bs_box.shares_outstanding AS diagnostic_value

  FROM {{ ref('int_balance_sheet_shifter') }}

  WHERE ticker = '2330'
    AND date = DATE '2010-01-04'

)

SELECT
  COALESCE(e.family, a.family) AS family,
  e.source_period AS expected_source_period,
  a.source_period AS actual_source_period,
  e.deadline_date AS expected_deadline_date,
  a.deadline_date AS actual_deadline_date,
  e.diagnostic_value AS expected_diagnostic_value,
  a.diagnostic_value AS actual_diagnostic_value
FROM expected e
FULL OUTER JOIN actual a USING (family)
WHERE e.family IS NULL
  OR a.family IS NULL
  OR e.source_period != a.source_period
  OR e.deadline_date != a.deadline_date
  OR (
    e.family = 'revenue'
    AND ABS(e.diagnostic_value - a.diagnostic_value) > 1e-9
  )
  OR (
    e.family = 'balance_sheet'
    AND ABS(e.diagnostic_value - a.diagnostic_value) > 1.0
  )
