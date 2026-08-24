SELECT *
FROM {{ ref('mart_factor_research_monthly') }}
WHERE financial_aligned_date > rebalance_date