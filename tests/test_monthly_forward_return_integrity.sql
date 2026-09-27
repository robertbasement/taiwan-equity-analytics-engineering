SELECT *
FROM {{ ref('mart_factor_research_monthly') }}
WHERE forward_return IS NOT NULL
  AND (
    IS_NAN(forward_return)
    OR IS_INF(forward_return)
    OR forward_return = -1.0
    OR ABS(
      forward_return
      - (
        SAFE_DIVIDE(next_adjusted_close, current_adjusted_close) - 1
      )
    ) >= 1e-12
  )
