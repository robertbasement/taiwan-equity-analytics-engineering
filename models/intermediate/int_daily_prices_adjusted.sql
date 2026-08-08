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
    END AS valid_close,

    COALESCE(d.daily_factor, 1.0) AS daily_factor

  FROM {{ ref('stg_daily_prices_raw') }} p

  LEFT JOIN {{ ref('stg_dividend_factor') }} d
    ON p.date = d.ex_date
   AND p.ticker = d.ticker

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

cumulative_calculation AS (

  SELECT
    *,

    EXP(
      SUM(LN(daily_factor)) OVER (
        PARTITION BY ticker
        ORDER BY date DESC
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
      )
    ) AS rev_cum_factor

  FROM price_cleaned

)

SELECT
  c.* EXCEPT(
    daily_factor,
    rev_cum_factor,
    valid_close
  ),

  c.effective_close
  * c.rev_cum_factor
  * COALESCE((
      SELECT EXP(SUM(LN(a.price_factor)))
      FROM {{ ref('manual_corporate_actions') }} a
      WHERE a.ticker = c.ticker
        AND c.date < a.effective_date
    ), 1.0) AS adj_close

FROM cumulative_calculation c