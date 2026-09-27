WITH benchmark AS (

  SELECT *
  FROM {{ ref('mart_factor_research_monthly') }}
  WHERE ticker = '0050'

),

calendar AS (

  SELECT DISTINCT rebalance_date
  FROM {{ ref('mart_factor_research_monthly') }}

)

SELECT
  c.rebalance_date,
  COUNT(b.ticker) AS benchmark_rows

FROM calendar c

LEFT JOIN benchmark b
  ON b.rebalance_date = c.rebalance_date

GROUP BY c.rebalance_date

HAVING COUNT(b.ticker) != 1
