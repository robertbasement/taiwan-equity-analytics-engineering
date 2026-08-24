SELECT *
FROM {{ ref('mart_factor_research_monthly') }}
WHERE effective_close > 0
  AND shares_outstanding > 0
  AND ABS(
    market_cap - effective_close * shares_outstanding
  ) > GREATEST(
    1,
    ABS(effective_close * shares_outstanding) * 1e-9
  )