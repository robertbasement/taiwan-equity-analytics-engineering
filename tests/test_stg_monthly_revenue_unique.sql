SELECT ticker, year_month, COUNT(*) AS row_count
FROM {{ ref('stg_monthly_revenue') }}
GROUP BY 1, 2
HAVING COUNT(*) != 1
