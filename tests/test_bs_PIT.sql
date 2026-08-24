SELECT *
FROM {{ ref('mart_factor_research_monthly') }}
WHERE balance_sheet_aligned_date > rebalance_date