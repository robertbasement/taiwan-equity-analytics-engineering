{{ config(
    materialized='table',
    partition_by={
      "field": "date",
      "data_type": "date",
      "granularity": "month"
    },
    cluster_by=["ticker"]
) }}

WITH price_joined AS (

  SELECT
    p.*,

    -- source 原始 close
    p.close AS raw_close,

    -- 0 視為無有效成交價
    -- NULLIF(p.close, 0) AS valid_close,
    CASE
      WHEN p.close > 0 THEN p.close
      ELSE NULL
    END AS valid_close

  FROM {{ ref('stg_daily_prices_raw') }} p

  WHERE p.date >= DATE '2000-01-01'

),

price_filled AS (

  SELECT
    *,

    -- 最近一次有效成交價
    LAST_VALUE(
      valid_close IGNORE NULLS
    ) OVER (
      PARTITION BY ticker
      ORDER BY date
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS last_valid_close,

    -- 最近一次有效成交日期
    MAX(
      IF(
        valid_close IS NOT NULL,
        date,
        NULL
      )
    ) OVER (
      PARTITION BY ticker
      ORDER BY date
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS last_valid_trade_date

  FROM price_joined

),

price_cleaned AS (

  SELECT
    *,

    DATE_DIFF(
      date,
      last_valid_trade_date,
      DAY
    ) AS days_since_last_trade,

    CASE
      WHEN last_valid_trade_date IS NULL THEN NULL

      -- 暫時先用 30 calendar days
      WHEN DATE_DIFF(
        date,
        last_valid_trade_date,
        DAY
      ) <= 30
        THEN last_valid_close

      ELSE NULL
    END AS effective_close

  FROM price_filled

),

-- Include all event dates, even when the ex-date is not a price row. A price
-- row sorts before an event on the same date, so its frame contains only
-- events with ex_date strictly greater than its own date.
factor_timeline AS (
  SELECT ticker, date, 1 AS is_price, CAST(NULL AS FLOAT64) AS log_factor
  FROM (SELECT DISTINCT ticker, date FROM price_cleaned)
  UNION ALL
  SELECT
    d.ticker,
    d.ex_date AS date,
    0 AS is_price,
    LN(CASE WHEN EXISTS (
      SELECT 1 FROM {{ ref('manual_corporate_actions') }} a
      WHERE a.ticker = d.ticker
        AND a.effective_date = d.ex_date
        AND a.price_factor != 1.0
    ) THEN ERROR(CONCAT(
      'source/manual price-factor collision: ', d.ticker, ' ', CAST(d.ex_date AS STRING)
    )) ELSE d.daily_factor END) AS log_factor
  FROM {{ ref('stg_dividend_factor') }} d
),
factor_windows AS (
  SELECT
    ticker, date, is_price,
    EXP(COALESCE(SUM(log_factor) OVER (
      PARTITION BY ticker
      ORDER BY date DESC, is_price DESC
      ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
    ), 0.0)) AS rev_cum_factor
  FROM factor_timeline
),
price_factors AS (
  SELECT ticker, date, rev_cum_factor
  FROM factor_windows
  WHERE is_price = 1
)

SELECT
  c.* EXCEPT(valid_close),

  c.effective_close
  * pf.rev_cum_factor
  * COALESCE((
      SELECT EXP(SUM(LN(a.price_factor)))
      FROM {{ ref('manual_corporate_actions') }} a
      WHERE a.ticker = c.ticker
        AND c.date < a.effective_date
    ), 1.0) AS adj_close

FROM price_cleaned c
JOIN price_factors pf
  ON c.ticker = pf.ticker AND c.date = pf.date
