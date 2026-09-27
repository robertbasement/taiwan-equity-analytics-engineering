SELECT
  'revenue' AS family,
  date,
  ticker,
  rev_box.deadline_date AS policy_availability_date
FROM {{ ref('int_monthly_revenue_shifter') }}
WHERE rev_box.deadline_date > date

UNION ALL

SELECT
  'income_statement' AS family,
  date,
  ticker,
  fin_box.deadline_date AS policy_availability_date
FROM {{ ref('int_income_statement_shifter') }}
WHERE fin_box.deadline_date > date

UNION ALL

SELECT
  'balance_sheet' AS family,
  date,
  ticker,
  bs_box.deadline_date AS policy_availability_date
FROM {{ ref('int_balance_sheet_shifter') }}
WHERE bs_box.deadline_date > date
