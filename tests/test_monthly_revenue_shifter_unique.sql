SELECT
  date,
  ticker,
  COUNT(*) AS active_state_count
FROM {{ ref('int_monthly_revenue_shifter') }}
GROUP BY 1, 2
HAVING COUNT(*) != 1
