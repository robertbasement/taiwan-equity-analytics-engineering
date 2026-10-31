{{ config(severity='warn') }}

-- Staleness is operationally visible but does not make otherwise valid analytics
-- unavailable. Structural and semantic failures remain ERRORs in the companion
-- integrity test.
WITH expected_markets AS (
  SELECT market
  FROM UNNEST(['TWSE', 'TPEX']) AS market
),

source_summary AS (
  SELECT
    market,
    COUNT(*) AS row_count,
    MIN(source_as_of_date) AS source_as_of_date
  FROM {{ ref('dim_security_master') }}
  WHERE market IN ('TWSE', 'TPEX')
  GROUP BY market
)

SELECT
  expected.market,
  COALESCE(actual.row_count, 0) AS row_count,
  actual.source_as_of_date,
  'STALE_SOURCE_DATE' AS failure_reason
FROM expected_markets AS expected
LEFT JOIN source_summary AS actual USING (market)
WHERE actual.source_as_of_date
  < DATE_SUB(CURRENT_DATE('Asia/Taipei'), INTERVAL 7 DAY)
