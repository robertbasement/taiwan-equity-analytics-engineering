WITH source_with_deadline AS (

  SELECT
    ticker,
    year_quarter,
    shares_outstanding,
    CASE
      WHEN quarter = 1 THEN DATE(year, 5, 16)
      WHEN quarter = 2 THEN DATE(year, 8, 15)
      WHEN quarter = 3 THEN DATE(year, 11, 15)
      WHEN quarter = 4 THEN DATE(year + 1, 4, 1)
    END AS deadline_date

  FROM {{ ref('int_balance_sheet_features') }}

),

expected AS (

  SELECT
    ticker,
    year_quarter,
    deadline_date,
    shares_outstanding

  FROM source_with_deadline

  WHERE deadline_date <= DATE '2010-01-04'

  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY ticker
    ORDER BY deadline_date DESC, year_quarter DESC
  ) = 1

),

actual AS (

  SELECT
    ticker,
    bs_box.year_quarter AS year_quarter,
    bs_box.deadline_date AS deadline_date,
    bs_box.shares_outstanding AS shares_outstanding

  FROM {{ ref('int_balance_sheet_shifter') }}

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
