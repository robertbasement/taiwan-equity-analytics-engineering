SELECT
  date,
  ticker,
  COUNT(*) AS active_state_count
FROM {{ ref('int_balance_sheet_shifter') }}
GROUP BY 1, 2
HAVING COUNT(*) != 1
