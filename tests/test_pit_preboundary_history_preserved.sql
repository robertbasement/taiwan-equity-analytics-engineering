WITH observations AS (

  SELECT
    'revenue' AS family,
    COUNT(*) AS observation_count,
    MIN(year_month) AS first_period,
    MAX(year_month) AS last_period
  FROM {{ ref('int_monthly_revenue_features') }}
  WHERE ticker = '2330'
    AND DATE_ADD(
      DATE_ADD(PARSE_DATE('%Y-%m', year_month), INTERVAL 1 MONTH),
      INTERVAL 10 DAY
    ) <= DATE '2010-01-04'

  UNION ALL

  SELECT
    'balance_sheet' AS family,
    COUNT(*) AS observation_count,
    MIN(year_quarter) AS first_period,
    MAX(year_quarter) AS last_period
  FROM {{ ref('int_balance_sheet_features') }}
  WHERE ticker = '2330'
    AND CASE
      WHEN quarter = 1 THEN DATE(year, 5, 16)
      WHEN quarter = 2 THEN DATE(year, 8, 15)
      WHEN quarter = 3 THEN DATE(year, 11, 15)
      WHEN quarter = 4 THEN DATE(year + 1, 4, 1)
    END <= DATE '2010-01-04'

)

SELECT *
FROM observations
WHERE (family = 'revenue' AND (
    observation_count != 23
    OR first_period != '2008-01'
    OR last_period != '2009-11'
  ))
  OR (family = 'balance_sheet' AND (
    observation_count != 67
    OR first_period != '1990-4'
    OR last_period != '2009-3'
  ))
