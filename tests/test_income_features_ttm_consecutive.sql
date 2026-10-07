WITH raw AS (
  SELECT
    ticker,
    year_quarter,
    SAFE_CAST(LEFT(year_quarter, 4) AS INT64) * 4
      + SAFE_CAST(RIGHT(year_quarter, 1) AS INT64) AS fiscal_quarter_index,
    LAG(
      SAFE_CAST(LEFT(year_quarter, 4) AS INT64) * 4
        + SAFE_CAST(RIGHT(year_quarter, 1) AS INT64),
      3
    ) OVER (
      PARTITION BY ticker
      ORDER BY year_quarter
    ) AS fourth_row_quarter_index
  FROM {{ ref('stg_income_statement') }}
),

features AS (
  SELECT
    ticker,
    year_quarter,
    revenue_ttm,
    operating_income_ttm,
    net_income_ttm,
    eps_ttm
  FROM {{ ref('int_income_statement_features') }}
)

SELECT
  r.ticker,
  r.year_quarter
FROM raw r
JOIN features f USING (ticker, year_quarter)
WHERE (
    r.fourth_row_quarter_index IS NULL
    OR r.fourth_row_quarter_index != r.fiscal_quarter_index - 3
  )
  AND (
    f.revenue_ttm IS NOT NULL
    OR f.operating_income_ttm IS NOT NULL
    OR f.net_income_ttm IS NOT NULL
    OR f.eps_ttm IS NOT NULL
  )
