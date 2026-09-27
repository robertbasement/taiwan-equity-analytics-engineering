SELECT *
FROM {{ ref('mart_factor_research_monthly') }}
WHERE forward_return IS NOT NULL
  AND (
    current_raw_close IS NULL
    OR current_raw_close <= 0
    OR next_raw_close IS NULL
    OR next_raw_close <= 0
  )
