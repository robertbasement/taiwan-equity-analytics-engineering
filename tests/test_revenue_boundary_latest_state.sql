WITH expected AS (

  SELECT
    ticker,
    year_month AS data_month_label,
    DATE_ADD(
      DATE_ADD(PARSE_DATE('%Y-%m', year_month), INTERVAL 1 MONTH),
      INTERVAL 10 DAY
    ) AS deadline_date

  FROM {{ ref('int_monthly_revenue_features') }}

  WHERE DATE_ADD(
    DATE_ADD(PARSE_DATE('%Y-%m', year_month), INTERVAL 1 MONTH),
    INTERVAL 10 DAY
  ) <= DATE '2010-01-04'

  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY ticker
    ORDER BY deadline_date DESC, year_month DESC
  ) = 1

),

actual AS (

  SELECT
    ticker,
    rev_box.data_month_label AS data_month_label,
    rev_box.deadline_date AS deadline_date

  FROM {{ ref('int_monthly_revenue_shifter') }}

  WHERE date = DATE '2010-01-04'

),

differences AS (

  (
    SELECT 'expected_minus_actual' AS direction, * FROM expected
    EXCEPT DISTINCT
    SELECT 'expected_minus_actual' AS direction, * FROM actual
  )

  UNION ALL

  (
    SELECT 'actual_minus_expected' AS direction, * FROM actual
    EXCEPT DISTINCT
    SELECT 'actual_minus_expected' AS direction, * FROM expected
  )

)

SELECT *
FROM differences
