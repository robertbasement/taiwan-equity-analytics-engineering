SELECT *
FROM {{ ref('mart_factor_research_monthly') }}
WHERE forward_return_eligible != (forward_return IS NOT NULL)
  OR (
    forward_return IS NOT NULL
    AND (
    NOT forward_return_eligible
    OR NOT current_endpoint_observed
    OR NOT next_endpoint_observed
    OR current_raw_close IS NULL
    OR current_raw_close <= 0
    OR next_raw_close IS NULL
    OR next_raw_close <= 0
    OR current_adjusted_close IS NULL
    OR current_adjusted_close <= 0
    OR IS_NAN(current_adjusted_close)
    OR IS_INF(current_adjusted_close)
    OR next_adjusted_close IS NULL
    OR next_adjusted_close <= 0
    OR IS_NAN(next_adjusted_close)
    OR IS_INF(next_adjusted_close)
    )
  )
