SELECT *
FROM {{ ref('mart_factor_research_monthly') }}
WHERE revenue_aligned_date > rebalance_date