WITH features AS (
  SELECT ticker, year_month, yoy_growth_pct, yoy_triple_increase_signal
  FROM {{ ref('int_monthly_revenue_features') }}
),
flagged AS (
  SELECT
    curr.ticker,
    curr.year_month,
    curr.yoy_growth_pct,
    previous_1.yoy_growth_pct AS yoy_lag1,
    previous_2.yoy_growth_pct AS yoy_lag2
  FROM features curr
  LEFT JOIN features previous_1
    ON previous_1.ticker = curr.ticker
   AND PARSE_DATE('%Y-%m', previous_1.year_month)
       = DATE_SUB(PARSE_DATE('%Y-%m', curr.year_month), INTERVAL 1 MONTH)
  LEFT JOIN features previous_2
    ON previous_2.ticker = curr.ticker
   AND PARSE_DATE('%Y-%m', previous_2.year_month)
       = DATE_SUB(PARSE_DATE('%Y-%m', curr.year_month), INTERVAL 2 MONTH)
  WHERE curr.yoy_triple_increase_signal = 1
)
SELECT *
FROM flagged
WHERE yoy_lag1 IS NULL
   OR yoy_lag2 IS NULL
   OR NOT (yoy_growth_pct > yoy_lag1 AND yoy_lag1 > yoy_lag2)
