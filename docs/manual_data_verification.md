# Manual Data Verification Checklist

## Purpose

This document provides a human verification layer for the certified Taiwan equity research pipeline before the strategy progresses toward paper trading or live trading with real capital.

Internal agreement between warehouse tables, dbt models, and research outputs is necessary but insufficient. The selected observations below must also be compared against independent official TWSE, TPEx, and MOPS source data. Do not mark this review as passed merely because two internal models agree.

## Certification metadata

- [ ] Verification date: __________________
- [ ] Git commit SHA: __________________
- [ ] BigQuery project: __________________
- [ ] Dataset/model version, if applicable: __________________
- [ ] Reviewer: __________________
- [ ] Overall status: PASS / FAIL / NEEDS REVIEW

The canonical price table does not store market. The SQL below infers it from official TWSE/TPEx corporate-action source membership and returns `UNAVAILABLE` when that evidence does not exist.

## 1. Raw Price Verification

### Objective

Verify selected canonical raw OHLCV observations against independent official TWSE `MI_INDEX` or TPEx `STK_WN1430` data, then hand-check how the stored cumulative factors explain adjusted close.

### External checks

- Confirm the trading date and ticker against the relevant official market source.
- Match raw open, high, low, close, and volume.
- Treat `market_from_action_sources` as source-membership evidence, not as a canonical security-master field.
- For rows with a corporate action, separately verify the official event terms under section 2.

Expected sample count: **20**

```sql
--standardSQL
WITH samples AS (
  SELECT * FROM UNNEST([
    STRUCT('2330' AS ticker, DATE '2010-01-04' AS date, 'first certified price date; TWSE' AS sample_reason),
    STRUCT('3293', DATE '2010-01-04', 'first certified price date; TPEx'),
    STRUCT('8913', DATE '2018-06-01', 'last quote before 2018-06-04 action'),
    STRUCT('8913', DATE '2018-06-04', '2018-06-04 action date'),
    STRUCT('3293', DATE '2022-07-26', 'last quote before 2022-07-27 action'),
    STRUCT('3293', DATE '2022-07-27', '2022-07-27 action date'),
    STRUCT('3293', DATE '2024-07-23', 'last quote before 2024-07-24 action'),
    STRUCT('3293', DATE '2024-07-26', 'first quote after 2024-07-24 action'),
    STRUCT('1808', DATE '2024-09-25', 'last quote before 2024-09-26 action'),
    STRUCT('1808', DATE '2024-09-26', '2024-09-26 action date'),
    STRUCT('8921', DATE '2023-06-19', 'known zero-price diagnostic'),
    STRUCT('8921', DATE '2023-06-20', 'day after zero-price diagnostic'),
    STRUCT('0050', DATE '2025-06-10', 'last quote before 2025-06-18 split'),
    STRUCT('0050', DATE '2025-06-18', 'manual split effective date'),
    STRUCT('2330', DATE '2026-09-23', 'recent ordinary TWSE day'),
    STRUCT('2330', DATE '2026-09-24', 'latest certified production day'),
    STRUCT('5345', DATE '2023-06-07', 'known placeholder diagnostic'),
    STRUCT('8067', DATE '2023-06-27', 'known placeholder diagnostic'),
    STRUCT('2321', DATE '2023-06-21', 'known placeholder diagnostic'),
    STRUCT('5601', DATE '2023-06-26', 'known placeholder diagnostic')
  ])
),

market_evidence AS (
  SELECT
    ticker,
    STRING_AGG(DISTINCT market ORDER BY market) AS market
  FROM (
    SELECT CAST(ticker AS STRING) AS ticker, 'TWSE' AS market
    FROM `stock-backtest-491815.stock_data.sii_dividend`

    UNION ALL

    SELECT CAST(ticker AS STRING), 'TPEx'
    FROM `stock-backtest-491815.stock_data.otc_dividend`
  )
  GROUP BY ticker
),

future_source_factors AS (
  SELECT
    s.ticker,
    s.date,
    COALESCE(EXP(SUM(LN(f.daily_factor))), 1.0)
      AS future_source_factor
  FROM samples s
  LEFT JOIN `stock-backtest-491815.stock_analytics.stg_dividend_factor` f
    ON f.ticker = s.ticker
   AND f.ex_date > s.date
  GROUP BY s.ticker, s.date
),

future_manual_factors AS (
  SELECT
    s.ticker,
    s.date,
    COALESCE(EXP(SUM(LN(a.price_factor))), 1.0)
      AS future_manual_factor
  FROM samples s
  LEFT JOIN `stock-backtest-491815.stock_analytics.manual_corporate_actions` a
    ON a.ticker = s.ticker
   AND a.effective_date > s.date
  GROUP BY s.ticker, s.date
)

SELECT
  s.sample_reason,
  s.date,
  s.ticker,
  COALESCE(me.market, 'UNAVAILABLE') AS market_from_action_sources,

  p.open AS raw_open,
  p.high AS raw_high,
  p.low AS raw_low,
  p.close AS raw_close,
  p.volume AS raw_volume,

  a.last_valid_trade_date,
  a.effective_close,
  a.adj_close AS adjusted_close,

  event_factor.daily_factor AS source_event_factor_on_date,
  manual.price_factor AS manual_event_factor_on_date,

  fs.future_source_factor,
  fm.future_manual_factor,
  fs.future_source_factor * fm.future_manual_factor
    AS independently_composed_cumulative_factor,

  SAFE_DIVIDE(a.adj_close, a.effective_close)
    AS stored_effective_cumulative_factor,

  a.effective_close
    * fs.future_source_factor
    * fm.future_manual_factor
    AS independently_recomputed_adjusted_close,

  a.adj_close - (
    a.effective_close
    * fs.future_source_factor
    * fm.future_manual_factor
  ) AS adjusted_close_difference

FROM samples s
LEFT JOIN `stock-backtest-491815.stock_data.daily_prices_partitioned` p
  ON p.ticker = s.ticker
 AND p.date = s.date
LEFT JOIN `stock-backtest-491815.stock_analytics.int_daily_prices_adjusted` a
  ON a.ticker = s.ticker
 AND a.date = s.date
LEFT JOIN market_evidence me
  ON me.ticker = s.ticker
LEFT JOIN future_source_factors fs
  ON fs.ticker = s.ticker
 AND fs.date = s.date
LEFT JOIN future_manual_factors fm
  ON fm.ticker = s.ticker
 AND fm.date = s.date
LEFT JOIN `stock-backtest-491815.stock_analytics.stg_dividend_factor` event_factor
  ON event_factor.ticker = s.ticker
 AND event_factor.ex_date = s.date
LEFT JOIN `stock-backtest-491815.stock_analytics.manual_corporate_actions` manual
  ON manual.ticker = s.ticker
 AND manual.effective_date = s.date
ORDER BY s.date, s.ticker;
```

| Sample | Official source checked | OHLC match | Volume match | Result | Notes |
|---|---|---|---|---|---|
| 2330 / 2010-01-04 | [ ] | [ ] | [ ] |  |  |
| 3293 / 2010-01-04 | [ ] | [ ] | [ ] |  |  |
| 8913 / 2018-06-01 | [ ] | [ ] | [ ] |  |  |
| 8913 / 2018-06-04 | [ ] | [ ] | [ ] |  |  |
| 3293 / 2022-07-26 | [ ] | [ ] | [ ] |  |  |
| 3293 / 2022-07-27 | [ ] | [ ] | [ ] |  |  |
| 3293 / 2024-07-23 | [ ] | [ ] | [ ] |  |  |
| 3293 / 2024-07-26 | [ ] | [ ] | [ ] |  |  |
| 1808 / 2024-09-25 | [ ] | [ ] | [ ] |  |  |
| 1808 / 2024-09-26 | [ ] | [ ] | [ ] |  |  |
| 8921 / 2023-06-19 | [ ] | [ ] | [ ] |  |  |
| 8921 / 2023-06-20 | [ ] | [ ] | [ ] |  |  |
| 0050 / 2025-06-10 | [ ] | [ ] | [ ] |  |  |
| 0050 / 2025-06-18 | [ ] | [ ] | [ ] |  |  |
| 2330 / 2026-09-23 | [ ] | [ ] | [ ] |  |  |
| 2330 / 2026-09-24 | [ ] | [ ] | [ ] |  |  |
| 5345 / 2023-06-07 | [ ] | [ ] | [ ] |  |  |
| 8067 / 2023-06-27 | [ ] | [ ] | [ ] |  |  |
| 2321 / 2023-06-21 | [ ] | [ ] | [ ] |  |  |
| 5601 / 2023-06-26 | [ ] | [ ] | [ ] |  |  |

## 2. Corporate Action Verification

### Objective

Verify official and manual corporate-action factors, raw price transitions, cumulative adjusted-price factors, and adjusted-price continuity. This section explicitly includes the known 8913, 3293, and 1808 regressions and the manual 0050 and 2327 cases.

Expected sample count: **10**

```sql
--standardSQL
WITH requests AS (
  SELECT * FROM UNNEST([
    STRUCT('8913' AS ticker, DATE '2018-06-04' AS event_date, 'known TPEx regression' AS sample_reason),
    STRUCT('3293', DATE '2022-07-27', 'known TPEx regression'),
    STRUCT('3293', DATE '2024-07-24', 'known TPEx regression; first later quote is 2024-07-26'),
    STRUCT('1808', DATE '2024-09-26', 'known TWSE regression'),
    STRUCT('2330', DATE '2024-06-13', 'ordinary TWSE cash distribution'),
    STRUCT('0050', DATE '2024-07-16', 'ordinary TWSE ETF distribution'),
    STRUCT('0050', DATE '2025-06-18', 'manual one-for-four price-basis transition'),
    STRUCT('2327', DATE '2025-08-25', 'manual par-value/share-count transition'),
    STRUCT('1808', DATE '2022-09-26', 'earlier TWSE action'),
    STRUCT('3293', DATE '2023-07-17', 'ordinary TPEx distribution')
  ])
),

official_events AS (
  SELECT DISTINCT
    'TWSE' AS market,
    'sii_dividend' AS source_table,
    CAST(ticker AS STRING) AS ticker,
    DATE(ex_dividend_date) AS event_date,
    SAFE_CAST(
      REPLACE(CAST(close_price_pre_adjust AS STRING), ',', '')
      AS FLOAT64
    ) AS official_pre_close,
    SAFE_CAST(
      REPLACE(CAST(reference_price_ex_dividend AS STRING), ',', '')
      AS FLOAT64
    ) AS official_reference_price
  FROM `stock-backtest-491815.stock_data.sii_dividend`

  UNION ALL

  SELECT DISTINCT
    'TPEx',
    'otc_dividend',
    CAST(ticker AS STRING),
    DATE(ex_dividend_date),
    SAFE_CAST(
      REPLACE(CAST(close_price_pre_adjust AS STRING), ',', '')
      AS FLOAT64
    ),
    SAFE_CAST(
      REPLACE(CAST(reference_price_ex_dividend AS STRING), ',', '')
      AS FLOAT64
    )
  FROM `stock-backtest-491815.stock_data.otc_dividend`
),

market_evidence AS (
  SELECT
    ticker,
    STRING_AGG(DISTINCT market ORDER BY market) AS market
  FROM official_events
  GROUP BY ticker
),

events AS (
  SELECT
    r.*,
    COALESCE(o.market, me.market, 'UNAVAILABLE') AS market,
    o.source_table,
    o.official_pre_close,
    o.official_reference_price,
    SAFE_DIVIDE(o.official_reference_price, o.official_pre_close)
      AS official_reference_factor,

    d.daily_factor AS stored_daily_source_factor,

    m.price_factor AS manual_price_factor,
    m.per_share_factor AS manual_per_share_factor,
    m.share_factor AS manual_share_factor,
    m.note AS manual_action_note,

    COALESCE(d.daily_factor, 1.0)
      * COALESCE(m.price_factor, 1.0)
      AS combined_event_price_factor

  FROM requests r
  LEFT JOIN official_events o
    USING (ticker, event_date)
  LEFT JOIN market_evidence me
    USING (ticker)
  LEFT JOIN `stock-backtest-491815.stock_analytics.stg_dividend_factor` d
    ON d.ticker = r.ticker
   AND d.ex_date = r.event_date
  LEFT JOIN `stock-backtest-491815.stock_analytics.manual_corporate_actions` m
    ON m.ticker = r.ticker
   AND m.effective_date = r.event_date
),

prices AS (
  SELECT
    p.date,
    p.ticker,
    p.close AS raw_close,
    a.effective_close,
    a.adj_close,
    SAFE_DIVIDE(a.adj_close, a.effective_close)
      AS cumulative_adjustment_factor
  FROM `stock-backtest-491815.stock_data.daily_prices_partitioned` p
  JOIN `stock-backtest-491815.stock_analytics.int_daily_prices_adjusted` a
    USING (date, ticker)
  WHERE p.close > 0
),

pre_quotes AS (
  SELECT
    e.ticker,
    e.event_date,
    ARRAY_AGG(
      IF(
        p.date IS NULL,
        NULL,
        STRUCT(
          p.date AS quote_date,
          p.raw_close AS raw_close,
          p.adj_close AS adj_close,
          p.cumulative_adjustment_factor AS cumulative_adjustment_factor
        )
      ) IGNORE NULLS
      ORDER BY p.date DESC
      LIMIT 1
    )[SAFE_OFFSET(0)] AS pre_quote
  FROM events e
  LEFT JOIN prices p
    ON p.ticker = e.ticker
   AND p.date < e.event_date
  GROUP BY e.ticker, e.event_date
),

post_quotes AS (
  SELECT
    e.ticker,
    e.event_date,
    ARRAY_AGG(
      IF(
        p.date IS NULL,
        NULL,
        STRUCT(
          p.date AS quote_date,
          p.raw_close AS raw_close,
          p.adj_close AS adj_close,
          p.cumulative_adjustment_factor AS cumulative_adjustment_factor
        )
      ) IGNORE NULLS
      ORDER BY p.date
      LIMIT 1
    )[SAFE_OFFSET(0)] AS post_quote
  FROM events e
  LEFT JOIN prices p
    ON p.ticker = e.ticker
   AND p.date >= e.event_date
  GROUP BY e.ticker, e.event_date
),

quoted AS (
  SELECT
    e.*,
    pre.pre_quote,
    post.post_quote
  FROM events e
  LEFT JOIN pre_quotes pre
    USING (ticker, event_date)
  LEFT JOIN post_quotes post
    USING (ticker, event_date)
)

SELECT
  sample_reason,
  market,
  source_table,
  ticker,
  event_date,

  official_pre_close,
  official_reference_price,
  official_reference_factor,
  stored_daily_source_factor,

  manual_price_factor,
  manual_per_share_factor,
  manual_share_factor,
  manual_action_note,
  combined_event_price_factor,

  pre_quote.quote_date AS raw_pre_date,
  pre_quote.raw_close AS raw_close_before,
  post_quote.quote_date AS raw_on_or_after_date,
  post_quote.raw_close AS raw_close_on_or_after,

  official_pre_close - pre_quote.raw_close
    AS official_vs_warehouse_pre_close_difference,

  pre_quote.cumulative_adjustment_factor
    AS cumulative_factor_before,
  post_quote.cumulative_adjustment_factor
    AS cumulative_factor_after,

  pre_quote.adj_close AS adjusted_close_before,
  post_quote.adj_close AS adjusted_close_after,

  pre_quote.raw_close * combined_event_price_factor
    AS single_event_adjusted_pre_close,

  SAFE_DIVIDE(
    post_quote.raw_close,
    pre_quote.raw_close * combined_event_price_factor
  ) AS single_event_raw_continuity_ratio,

  SAFE_DIVIDE(
    post_quote.adj_close,
    pre_quote.adj_close
  ) AS adjusted_continuity_ratio

FROM quoted
ORDER BY event_date, ticker;
```

### Manual formulas

- Official/reference factor: `official reference price / official pre-adjustment close`
- Single-event adjusted pre-close: `warehouse raw close before × combined event price factor`
- Single-event raw continuity: `raw close on/after / single-event adjusted pre-close`
- Full adjusted continuity: `adjusted close after / adjusted close before`

| Sample | Official/manual terms checked | Factor recomputed | Raw transition checked | Adjusted continuity checked | Result | Notes |
|---|---|---|---|---|---|---|
| 8913 / 2018-06-04 | [ ] | [ ] | [ ] | [ ] |  |  |
| 3293 / 2022-07-27 | [ ] | [ ] | [ ] | [ ] |  |  |
| 3293 / 2024-07-24 | [ ] | [ ] | [ ] | [ ] |  |  |
| 1808 / 2024-09-26 | [ ] | [ ] | [ ] | [ ] |  |  |
| 2330 / 2024-06-13 | [ ] | [ ] | [ ] | [ ] |  |  |
| 0050 / 2024-07-16 | [ ] | [ ] | [ ] | [ ] |  |  |
| 0050 / 2025-06-18 (manual) | [ ] | [ ] | [ ] | [ ] |  |  |
| 2327 / 2025-08-25 (manual) | [ ] | [ ] | [ ] | [ ] |  |  |
| 1808 / 2022-09-26 | [ ] | [ ] | [ ] | [ ] |  |  |
| 3293 / 2023-07-17 | [ ] | [ ] | [ ] | [ ] |  |  |

## 3. Revenue / Revenue YoY Verification

### Objective

Verify active monthly revenue observations against official MOPS data and independently recompute Revenue YoY without relying on the stored YoY value.

### Official MOPS comparison

- Look up the ticker and active revenue month in official MOPS monthly revenue data.
- Match current-month revenue and same-month-prior-year revenue.
- Confirm that the report's policy availability date is on or before the observation date.
- Independently recompute Revenue YoY. Small differences may reflect source rounding; material differences require investigation.

Manual Revenue YoY formula:

`100 × (current revenue − same-month prior-year revenue) / same-month prior-year revenue`

Expected sample count: **20**

```sql
--standardSQL
WITH samples AS (
  SELECT * FROM UNNEST([
    STRUCT('2330' AS ticker, DATE '2010-01-04' AS observation_date, '2330 boundary' AS sample_reason),
    STRUCT('2473', DATE '2010-01-04', 'previous PIT-collision diagnostic'),
    STRUCT('3080', DATE '2010-01-04', 'previous PIT-collision diagnostic'),
    STRUCT('3293', DATE '2010-01-04', 'TPEx boundary'),

    STRUCT('2330', DATE '2010-01-15', 'first observation after 2009-12 revenue deadline'),
    STRUCT('2473', DATE '2010-01-15', 'collision-diagnostic follow-up'),
    STRUCT('3080', DATE '2010-01-15', 'collision-diagnostic follow-up'),
    STRUCT('3293', DATE '2010-01-15', 'TPEx follow-up'),

    STRUCT('8913', DATE '2018-06-15', 'historical small TPEx name'),
    STRUCT('3293', DATE '2022-07-15', 'TPEx historical case'),
    STRUCT('8921', DATE '2023-06-15', 'small/illiquid diagnostic'),
    STRUCT('1808', DATE '2024-09-16', 'TWSE historical case'),

    STRUCT('2330', DATE '2026-09-15', 'recent large cap'),
    STRUCT('2317', DATE '2026-09-15', 'recent large cap'),
    STRUCT('2454', DATE '2026-09-15', 'recent large cap'),
    STRUCT('3293', DATE '2026-09-15', 'recent TPEx'),
    STRUCT('5345', DATE '2026-09-15', 'recent TPEx'),
    STRUCT('8921', DATE '2026-09-15', 'recent smaller name'),
    STRUCT('1808', DATE '2026-09-15', 'recent TWSE'),
    STRUCT('8067', DATE '2026-09-15', 'recent smaller TPEx name')
  ])
),

market_evidence AS (
  SELECT
    ticker,
    STRING_AGG(DISTINCT market ORDER BY market) AS market
  FROM (
    SELECT CAST(ticker AS STRING) AS ticker, 'TWSE' AS market
    FROM `stock-backtest-491815.stock_data.sii_dividend`

    UNION ALL

    SELECT CAST(ticker AS STRING), 'TPEx'
    FROM `stock-backtest-491815.stock_data.otc_dividend`
  )
  GROUP BY ticker
),

source_revenue AS (
  SELECT * EXCEPT(source_rank)
  FROM (
    SELECT
      CAST(ticker AS STRING) AS ticker,
      company_name,
      year_month,
      CAST(revenue AS INT64) AS source_revenue,
      CAST(revenue_last_year AS INT64) AS source_revenue_last_year,
      SAFE_CAST(yoy_growth_pct AS FLOAT64) AS source_stored_yoy_pct,
      ROW_NUMBER() OVER (
        PARTITION BY ticker, year_month
        ORDER BY revenue DESC
      ) AS source_rank
    FROM `stock-backtest-491815.stock_data.monthly_revenue`
  )
  WHERE source_rank = 1
)

SELECT
  s.sample_reason,
  m.date AS observation_date,
  m.ticker,
  COALESCE(me.market, 'UNAVAILABLE') AS market_from_action_sources,

  m.revenue_month AS active_revenue_month,
  m.revenue_deadline_date AS policy_available_date,
  m.revenue_aligned_date AS shifted_market_date,

  m.revenue AS active_current_revenue,
  m.revenue_last_year AS active_prior_year_revenue,

  src.company_name,
  src.source_revenue,
  src.source_revenue_last_year,
  src.source_stored_yoy_pct,

  100.0 * SAFE_DIVIDE(
    m.revenue - m.revenue_last_year,
    m.revenue_last_year
  ) AS independently_recomputed_yoy_pct,

  m.yoy_growth AS stored_active_yoy_pct,

  m.yoy_growth - (
    100.0 * SAFE_DIVIDE(
      m.revenue - m.revenue_last_year,
      m.revenue_last_year
    )
  ) AS stored_minus_recomputed_yoy_pct,

  m.revenue_deadline_date <= m.date
    AS policy_available_by_observation,

  m.revenue_deadline_date > m.date
    AS policy_lookahead_violation

FROM samples s
JOIN `stock-backtest-491815.stock_analytics.mart_vbt_master_dataset` m
  ON m.ticker = s.ticker
 AND m.date = s.observation_date
LEFT JOIN source_revenue src
  ON src.ticker = m.ticker
 AND src.year_month = m.revenue_month
LEFT JOIN market_evidence me
  ON me.ticker = m.ticker
ORDER BY m.date, m.ticker;
```

| Sample | MOPS source checked | Current revenue match | Prior-year revenue match | YoY recomputed | Policy date valid | Result | Notes |
|---|---|---|---|---|---|---|---|
| 2330 / 2010-01-04 | [ ] | [ ] | [ ] | [ ] | [ ] |  |  |
| 2473 / 2010-01-04 | [ ] | [ ] | [ ] | [ ] | [ ] |  |  |
| 3080 / 2010-01-04 | [ ] | [ ] | [ ] | [ ] | [ ] |  |  |
| 3293 / 2010-01-04 | [ ] | [ ] | [ ] | [ ] | [ ] |  |  |
| 2330 / 2010-01-15 | [ ] | [ ] | [ ] | [ ] | [ ] |  |  |
| 2473 / 2010-01-15 | [ ] | [ ] | [ ] | [ ] | [ ] |  |  |
| 3080 / 2010-01-15 | [ ] | [ ] | [ ] | [ ] | [ ] |  |  |
| 3293 / 2010-01-15 | [ ] | [ ] | [ ] | [ ] | [ ] |  |  |
| 8913 / 2018-06-15 | [ ] | [ ] | [ ] | [ ] | [ ] |  |  |
| 3293 / 2022-07-15 | [ ] | [ ] | [ ] | [ ] | [ ] |  |  |
| 8921 / 2023-06-15 | [ ] | [ ] | [ ] | [ ] | [ ] |  |  |
| 1808 / 2024-09-16 | [ ] | [ ] | [ ] | [ ] | [ ] |  |  |
| 2330 / 2026-09-15 | [ ] | [ ] | [ ] | [ ] | [ ] |  |  |
| 2317 / 2026-09-15 | [ ] | [ ] | [ ] | [ ] | [ ] |  |  |
| 2454 / 2026-09-15 | [ ] | [ ] | [ ] | [ ] | [ ] |  |  |
| 3293 / 2026-09-15 | [ ] | [ ] | [ ] | [ ] | [ ] |  |  |
| 5345 / 2026-09-15 | [ ] | [ ] | [ ] | [ ] | [ ] |  |  |
| 8921 / 2026-09-15 | [ ] | [ ] | [ ] | [ ] | [ ] |  |  |
| 1808 / 2026-09-15 | [ ] | [ ] | [ ] | [ ] | [ ] |  |  |
| 8067 / 2026-09-15 | [ ] | [ ] | [ ] | [ ] | [ ] |  |  |

## 4. PIT / No-Look-Ahead Verification

### Objective

Verify that each observation uses the latest complete financial state whose policy availability date is on or before the observation date. Older source history may remain available for lag, YoY, TTM, trend, and streak calculations, but it must not appear as a competing active state. A later state must not become active before its policy date.

Expected sample count: **15**

```sql
--standardSQL
WITH samples AS (
  SELECT * FROM UNNEST([
    STRUCT('2330' AS ticker, DATE '2010-01-04' AS observation_date, 'required 2330 boundary' AS sample_reason),
    STRUCT('2317', DATE '2010-01-04', 'TWSE boundary'),
    STRUCT('2454', DATE '2010-01-04', 'TWSE boundary'),
    STRUCT('3293', DATE '2010-01-04', 'TPEx boundary'),
    STRUCT('5345', DATE '2010-01-04', 'TPEx boundary'),

    STRUCT('2330', DATE '2010-01-15', 'after 2009-12 revenue becomes eligible'),

    STRUCT('3293', DATE '2022-07-27', 'corporate-action date'),
    STRUCT('3293', DATE '2024-07-26', 'first quote after 2024 action'),
    STRUCT('1808', DATE '2024-09-26', 'corporate-action date'),

    STRUCT('2330', DATE '2026-09-24', 'recent large cap'),
    STRUCT('2317', DATE '2026-09-24', 'recent large cap'),
    STRUCT('2454', DATE '2026-09-24', 'recent large cap'),
    STRUCT('3293', DATE '2026-09-24', 'recent TPEx'),
    STRUCT('5345', DATE '2026-09-24', 'recent TPEx'),
    STRUCT('8067', DATE '2026-09-24', 'recent smaller TPEx name')
  ])
),

revenue_source_states AS (
  SELECT
    ticker,
    year_month AS source_period,
    DATE_ADD(
      DATE_ADD(PARSE_DATE('%Y-%m', year_month), INTERVAL 1 MONTH),
      INTERVAL 10 DAY
    ) AS policy_date
  FROM `stock-backtest-491815.stock_analytics.int_monthly_revenue_features`
),

income_source_states AS (
  SELECT
    ticker,
    year_quarter AS source_period,
    CASE
      WHEN ENDS_WITH(year_quarter, '-1')
        THEN DATE(SAFE_CAST(LEFT(year_quarter, 4) AS INT64), 5, 16)
      WHEN ENDS_WITH(year_quarter, '-2')
        THEN DATE(SAFE_CAST(LEFT(year_quarter, 4) AS INT64), 8, 15)
      WHEN ENDS_WITH(year_quarter, '-3')
        THEN DATE(SAFE_CAST(LEFT(year_quarter, 4) AS INT64), 11, 15)
      ELSE DATE(
        SAFE_CAST(LEFT(year_quarter, 4) AS INT64) + 1,
        4,
        1
      )
    END AS policy_date
  FROM `stock-backtest-491815.stock_analytics.int_income_statement_features`
),

balance_source_states AS (
  SELECT
    ticker,
    year_quarter AS source_period,
    CASE
      WHEN quarter = 1 THEN DATE(year, 5, 16)
      WHEN quarter = 2 THEN DATE(year, 8, 15)
      WHEN quarter = 3 THEN DATE(year, 11, 15)
      WHEN quarter = 4 THEN DATE(year + 1, 4, 1)
    END AS policy_date
  FROM `stock-backtest-491815.stock_analytics.int_balance_sheet_features`
),

next_revenue_by_sample AS (
  SELECT
    s.ticker,
    s.observation_date,
    ARRAY_AGG(
      IF(
        r.source_period IS NULL,
        NULL,
        STRUCT(r.source_period, r.policy_date)
      ) IGNORE NULLS
      ORDER BY r.policy_date, r.source_period
      LIMIT 1
    )[SAFE_OFFSET(0)] AS next_revenue
  FROM samples s
  LEFT JOIN revenue_source_states r
    ON r.ticker = s.ticker
   AND r.policy_date > s.observation_date
  GROUP BY s.ticker, s.observation_date
),

next_income_by_sample AS (
  SELECT
    s.ticker,
    s.observation_date,
    ARRAY_AGG(
      IF(
        i.source_period IS NULL,
        NULL,
        STRUCT(i.source_period, i.policy_date)
      ) IGNORE NULLS
      ORDER BY i.policy_date, i.source_period
      LIMIT 1
    )[SAFE_OFFSET(0)] AS next_income
  FROM samples s
  LEFT JOIN income_source_states i
    ON i.ticker = s.ticker
   AND i.policy_date > s.observation_date
  GROUP BY s.ticker, s.observation_date
),

next_balance_by_sample AS (
  SELECT
    s.ticker,
    s.observation_date,
    ARRAY_AGG(
      IF(
        b.source_period IS NULL,
        NULL,
        STRUCT(b.source_period, b.policy_date)
      ) IGNORE NULLS
      ORDER BY b.policy_date, b.source_period
      LIMIT 1
    )[SAFE_OFFSET(0)] AS next_balance
  FROM samples s
  LEFT JOIN balance_source_states b
    ON b.ticker = s.ticker
   AND b.policy_date > s.observation_date
  GROUP BY s.ticker, s.observation_date
),

samples_with_next_states AS (
  SELECT
    s.*,
    r.next_revenue,
    i.next_income,
    b.next_balance
  FROM samples s
  LEFT JOIN next_revenue_by_sample r
    USING (ticker, observation_date)
  LEFT JOIN next_income_by_sample i
    USING (ticker, observation_date)
  LEFT JOIN next_balance_by_sample b
    USING (ticker, observation_date)
)

SELECT
  s.sample_reason,
  m.date AS observation_date,
  m.ticker,

  -- Revenue active state
  m.revenue_month,
  m.revenue_deadline_date,
  m.revenue_aligned_date,
  m.revenue,
  m.revenue_last_year,
  m.yoy_growth AS active_revenue_yoy,
  m.revenue_deadline_date <= m.date AS revenue_policy_ok,

  -- Next revenue state: should not yet be active
  s.next_revenue.source_period AS next_revenue_month_not_yet_eligible,
  s.next_revenue.policy_date AS next_revenue_policy_date,
  s.next_revenue.policy_date > m.date
    AS next_revenue_correctly_not_yet_eligible,

  -- Income-statement active state
  m.report_quarter,
  m.financial_deadline_date,
  m.financial_aligned_date,
  m.financial_q_revenue,
  m.financial_q_operating_income,
  m.financial_q_net_income,
  m.eps,
  m.eps_ttm,
  m.eps_yoy_growth,
  m.financial_deadline_date <= m.date AS income_policy_ok,

  -- Next income state
  s.next_income.source_period AS next_income_quarter_not_yet_eligible,
  s.next_income.policy_date AS next_income_policy_date,
  s.next_income.policy_date > m.date
    AS next_income_correctly_not_yet_eligible,

  -- Balance-sheet active state
  m.balance_sheet_quarter,
  m.balance_sheet_deadline_date,
  m.balance_sheet_aligned_date,
  m.shares_outstanding,
  m.current_assets,
  m.current_liabilities,
  m.total_assets,
  m.total_liabilities,
  m.total_equity,
  m.book_value_per_share,
  m.balance_sheet_deadline_date <= m.date AS balance_policy_ok,

  -- Next balance-sheet state
  s.next_balance.source_period AS next_balance_quarter_not_yet_eligible,
  s.next_balance.policy_date AS next_balance_policy_date,
  s.next_balance.policy_date > m.date
    AS next_balance_correctly_not_yet_eligible

FROM samples_with_next_states s
JOIN `stock-backtest-491815.stock_analytics.mart_vbt_master_dataset` m
  ON m.ticker = s.ticker
 AND m.date = s.observation_date
ORDER BY m.date, m.ticker;
```

### Required 2330 boundary regression

For `2330 / 2010-01-04`, require all of the following:

- Revenue active state: **2009-11**
- Next revenue state: **2009-12**, unavailable until **2010-01-11**
- Balance active state: **2009-Q3**
- **2009-Q4** unavailable until **2010-04-01**

| Sample | Revenue latest eligible | Revenue next excluded | Income latest eligible | Balance latest eligible | Balance next excluded | No look-ahead | Result | Notes |
|---|---|---|---|---|---|---|---|---|
| 2330 / 2010-01-04 | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |  |  |
| 2317 / 2010-01-04 | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |  |  |
| 2454 / 2010-01-04 | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |  |  |
| 3293 / 2010-01-04 | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |  |  |
| 5345 / 2010-01-04 | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |  |  |
| 2330 / 2010-01-15 | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |  |  |
| 3293 / 2022-07-27 | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |  |  |
| 3293 / 2024-07-26 | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |  |  |
| 1808 / 2024-09-26 | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |  |  |
| 2330 / 2026-09-24 | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |  |  |
| 2317 / 2026-09-24 | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |  |  |
| 2454 / 2026-09-24 | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |  |  |
| 3293 / 2026-09-24 | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |  |  |
| 5345 / 2026-09-24 | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |  |  |
| 8067 / 2026-09-24 | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |  |  |

## 5. Monthly Forward Return Verification

### Objective

Verify Methodology A at the final monthly research layer without changing formation membership or factor assignments. Valid samples should produce returns from the two fixed common-date adjusted endpoints. Intentionally invalid samples should remain in the formation dataset but have `NULL` forward returns.

### Endpoint eligibility rule

A forward-return label is eligible only when:

- Current fixed-date raw close is observed and positive.
- Next fixed-date raw close is observed and positive.
- Current adjusted close is positive and finite.
- Next adjusted close is positive and finite.

A carried adjusted price cannot authorize a return endpoint. Do not search for a ticker-specific replacement date.

Manual return formula, only after eligibility is established:

`next adjusted close / current adjusted close − 1`

The final BigQuery mart does not persist the production Python qcut assignment. The SQL reports this explicitly rather than approximating it.

Expected sample count: **20**

```sql
--standardSQL
WITH samples AS (
  SELECT * FROM UNNEST([
    STRUCT('8913' AS ticker, DATE '2018-05-15' AS observation_date, 'interval crosses 2018-06-04 action' AS sample_reason),
    STRUCT('3293', DATE '2022-07-15', 'interval crosses 2022-07-27 action'),
    STRUCT('3293', DATE '2024-07-15', 'interval crosses 2024-07-24 action'),
    STRUCT('1808', DATE '2024-09-16', 'interval crosses 2024-09-26 action'),
    STRUCT('0050', DATE '2025-05-15', 'interval crosses 2025-06-18 split'),
    STRUCT('2327', DATE '2025-07-15', 'next fixed endpoint unavailable around 2025-08-25 action'),

    STRUCT('2330', DATE '2010-01-15', 'early normal large-cap observation'),
    STRUCT('2330', DATE '2026-08-17', 'recent normal large cap'),
    STRUCT('2317', DATE '2026-08-17', 'recent normal large cap'),
    STRUCT('2454', DATE '2026-08-17', 'recent normal large cap'),
    STRUCT('8921', DATE '2023-06-15', 'smaller/illiquid name'),
    STRUCT('5345', DATE '2023-06-15', 'smaller TPEx name'),

    STRUCT('1418', DATE '2018-05-15', 'invalid next endpoint'),
    STRUCT('1469', DATE '2018-05-15', 'invalid current endpoint'),
    STRUCT('3288', DATE '2018-05-15', 'illiquid invalid next endpoint'),
    STRUCT('3465', DATE '2018-05-15', 'illiquid invalid next endpoint'),

    STRUCT('1435', DATE '2025-08-15', 'recent invalid current endpoint'),
    STRUCT('2073', DATE '2025-08-15', 'both endpoints invalid'),
    STRUCT('2235', DATE '2025-08-15', 'recent invalid next endpoint'),
    STRUCT('2321', DATE '2025-08-15', 'recent invalid next endpoint')
  ])
),

market_evidence AS (
  SELECT
    ticker,
    STRING_AGG(DISTINCT market ORDER BY market) AS market
  FROM (
    SELECT CAST(ticker AS STRING) AS ticker, 'TWSE' AS market
    FROM `stock-backtest-491815.stock_data.sii_dividend`

    UNION ALL

    SELECT CAST(ticker AS STRING), 'TPEx'
    FROM `stock-backtest-491815.stock_data.otc_dividend`
  )
  GROUP BY ticker
),

verified AS (
  SELECT
    s.sample_reason,
    m.*,
    COALESCE(me.market, 'UNAVAILABLE') AS market_from_action_sources,

    COALESCE(
      m.current_raw_close > 0
      AND m.next_raw_close > 0
      AND m.current_adjusted_close > 0
      AND NOT IS_NAN(m.current_adjusted_close)
      AND NOT IS_INF(m.current_adjusted_close)
      AND m.next_adjusted_close > 0
      AND NOT IS_NAN(m.next_adjusted_close)
      AND NOT IS_INF(m.next_adjusted_close),
      FALSE
    ) AS independently_recomputed_eligibility,

    CASE
      WHEN COALESCE(
        m.current_raw_close > 0
        AND m.next_raw_close > 0
        AND m.current_adjusted_close > 0
        AND NOT IS_NAN(m.current_adjusted_close)
        AND NOT IS_INF(m.current_adjusted_close)
        AND m.next_adjusted_close > 0
        AND NOT IS_NAN(m.next_adjusted_close)
        AND NOT IS_INF(m.next_adjusted_close),
        FALSE
      )
      THEN SAFE_DIVIDE(
        m.next_adjusted_close,
        m.current_adjusted_close
      ) - 1
    END AS independently_recomputed_forward_return

  FROM samples s
  JOIN `stock-backtest-491815.stock_analytics.mart_factor_research_monthly` m
    ON m.ticker = s.ticker
   AND m.rebalance_date = s.observation_date
  LEFT JOIN market_evidence me
    ON me.ticker = m.ticker
)

SELECT
  sample_reason,
  ticker,
  market_from_action_sources,
  rebalance_date AS observation_date,
  next_rebalance_date AS next_observation_date,

  yoy_growth AS revenue_yoy_factor_value,

  -- The final BigQuery mart does not persist the Python qcut assignment.
  CAST(NULL AS INT64) AS stored_revenue_yoy_quintile,
  'NOT_PERSISTED_IN_BIGQUERY_MART' AS quintile_status,

  d_vol AS observation_date_volume,
  market_cap,

  current_raw_close,
  next_raw_close,
  current_adjusted_close,
  next_adjusted_close,

  current_endpoint_observed,
  next_endpoint_observed,
  forward_return_eligible,
  independently_recomputed_eligibility,

  forward_return AS stored_forward_return,
  independently_recomputed_forward_return,

  forward_return - independently_recomputed_forward_return
    AS stored_minus_recomputed_return,

  forward_return_eligible = independently_recomputed_eligibility
    AS eligibility_flags_match,

  (
    forward_return IS NULL
    AND independently_recomputed_forward_return IS NULL
  )
  OR ABS(
    forward_return - independently_recomputed_forward_return
  ) < 1e-12 AS return_label_matches

FROM verified
ORDER BY observation_date, ticker;
```

### Valid endpoint examples

The first group contains normal observations and corporate-action-adjacent intervals. Verify eligibility from the returned raw endpoints before recomputing the return; do not assume every named action-adjacent sample is valid without checking its output.

### Intentionally invalid endpoint examples

The 1418, 1469, 3288, 3465, 1435, 2073, 2235, and 2321 samples deliberately exercise missing or nonpositive fixed-date endpoints. The 2327 sample exercises an unavailable next fixed endpoint around its manual action. These observations should retain their factor data where present while producing `NULL` forward returns.

| Sample | Endpoint class | Raw endpoints checked | Eligibility correct | Adjusted endpoints checked | Return recomputed or NULL confirmed | Result | Notes |
|---|---|---|---|---|---|---|---|
| 8913 / 2018-05-15 | Action-adjacent | [ ] | [ ] | [ ] | [ ] |  |  |
| 3293 / 2022-07-15 | Action-adjacent | [ ] | [ ] | [ ] | [ ] |  |  |
| 3293 / 2024-07-15 | Action-adjacent | [ ] | [ ] | [ ] | [ ] |  |  |
| 1808 / 2024-09-16 | Action-adjacent | [ ] | [ ] | [ ] | [ ] |  |  |
| 0050 / 2025-05-15 | Action-adjacent | [ ] | [ ] | [ ] | [ ] |  |  |
| 2327 / 2025-07-15 | Intentionally invalid | [ ] | [ ] | [ ] | [ ] |  |  |
| 2330 / 2010-01-15 | Normal | [ ] | [ ] | [ ] | [ ] |  |  |
| 2330 / 2026-08-17 | Normal | [ ] | [ ] | [ ] | [ ] |  |  |
| 2317 / 2026-08-17 | Normal | [ ] | [ ] | [ ] | [ ] |  |  |
| 2454 / 2026-08-17 | Normal | [ ] | [ ] | [ ] | [ ] |  |  |
| 8921 / 2023-06-15 | Small/illiquid | [ ] | [ ] | [ ] | [ ] |  |  |
| 5345 / 2023-06-15 | Small/illiquid | [ ] | [ ] | [ ] | [ ] |  |  |
| 1418 / 2018-05-15 | Intentionally invalid | [ ] | [ ] | [ ] | [ ] |  |  |
| 1469 / 2018-05-15 | Intentionally invalid | [ ] | [ ] | [ ] | [ ] |  |  |
| 3288 / 2018-05-15 | Intentionally invalid | [ ] | [ ] | [ ] | [ ] |  |  |
| 3465 / 2018-05-15 | Intentionally invalid | [ ] | [ ] | [ ] | [ ] |  |  |
| 1435 / 2025-08-15 | Intentionally invalid | [ ] | [ ] | [ ] | [ ] |  |  |
| 2073 / 2025-08-15 | Intentionally invalid | [ ] | [ ] | [ ] | [ ] |  |  |
| 2235 / 2025-08-15 | Intentionally invalid | [ ] | [ ] | [ ] | [ ] |  |  |
| 2321 / 2025-08-15 | Intentionally invalid | [ ] | [ ] | [ ] | [ ] |  |  |

## Final Certification

- [ ] Raw prices externally verified
- [ ] Corporate actions externally verified
- [ ] Revenue values externally verified
- [ ] Revenue YoY manually recomputed
- [ ] PIT states verified with no look-ahead
- [ ] Forward returns manually recomputed
- [ ] Invalid endpoints correctly produce NULL returns
- [ ] All material discrepancies investigated

Overall result: __________________

Reviewer notes:

__________________
