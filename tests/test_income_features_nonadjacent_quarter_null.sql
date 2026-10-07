WITH raw AS (
  SELECT
    ticker,
    year_quarter,
    SAFE_CAST(LEFT(year_quarter, 4) AS INT64) * 4
      + SAFE_CAST(RIGHT(year_quarter, 1) AS INT64) AS fiscal_quarter_index,
    RIGHT(year_quarter, 1) AS quarter_label,
    LAG(
      SAFE_CAST(LEFT(year_quarter, 4) AS INT64) * 4
        + SAFE_CAST(RIGHT(year_quarter, 1) AS INT64)
    ) OVER (
      PARTITION BY ticker, LEFT(year_quarter, 4)
      ORDER BY year_quarter
    ) AS previous_fiscal_quarter_index
  FROM {{ ref('stg_income_statement') }}
),

features AS (
  SELECT
    ticker,
    year_quarter,
    q_revenue,
    q_operating_income,
    q_net_income,
    eps AS q_eps
  FROM {{ ref('int_income_statement_features') }}
)

SELECT
  r.ticker,
  r.year_quarter
FROM raw r
JOIN features f USING (ticker, year_quarter)
WHERE r.quarter_label != '1'
  AND (
    r.previous_fiscal_quarter_index IS NULL
    OR r.previous_fiscal_quarter_index != r.fiscal_quarter_index - 1
  )
  AND (
    f.q_revenue IS NOT NULL
    OR f.q_operating_income IS NOT NULL
    OR f.q_net_income IS NOT NULL
    OR f.q_eps IS NOT NULL
  )
