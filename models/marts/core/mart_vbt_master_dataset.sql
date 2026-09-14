{{ config(
    materialized='table',
    partition_by={
      "field": "date",
      "data_type": "date",
      "granularity": "month"
    },
    cluster_by=["ticker"]
) }}

WITH flattened AS (

    SELECT
        date,
        ticker,

        MAX(open) AS d_open,
        MAX(high) AS d_high,
        MAX(low) AS d_low,

        -- PIT / price-level fields
        MAX(raw_close) AS raw_close,
        MAX(effective_close) AS effective_close,

        -- Total-return adjusted price
        MAX(adj_close) AS d_close,

        MAX(volume) AS d_vol,

        MAX(ma20) AS ma20,
        MAX(ma60) AS ma60,
        MAX(bias20) AS bias20,

        ANY_VALUE(rev_box) AS r,
        ANY_VALUE(fin_box) AS f,
        ANY_VALUE(bs_box) AS b

    FROM {{ ref('int_vbt_stack') }}

    GROUP BY
        date,
        ticker

),

filled_boxes AS (

    SELECT
        date,
        ticker,

        d_open,
        d_high,
        d_low,

        raw_close,
        effective_close,
        d_close,
        d_vol,

        ma20,
        ma60,
        bias20,

        /*
         * Forward-fill the entire event snapshot instead of each
         * field independently.
         *
         * This keeps values and their PIT lineage together.
         */

        LAST_VALUE(r IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS r_filled,

        LAST_VALUE(f IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS f_filled,

        LAST_VALUE(b IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS b_filled

    FROM flattened

),

expanded AS (

    SELECT
        date,
        ticker,

        d_open,
        d_high,
        d_low,

        raw_close,
        effective_close,
        d_close,
        d_vol,

        ma20,
        ma60,
        bias20,


        /*
         * ============================================================
         * Monthly revenue
         * ============================================================
         */

        r_filled.revenue AS revenue,

        r_filled.revenue_last_year AS revenue_last_year,

        r_filled.yoy_growth_pct AS yoy_growth,

        r_filled.mom_growth_pct AS mom_growth_pct,

        r_filled.ytd_growth_pct AS ytd_growth_pct,

        r_filled.yoy_positive_streak_count AS yoy_positive_streak_count,

        r_filled.yoy_triple_increase_signal AS rev_triple_sig,

        /*
         * Revenue PIT lineage
         */

        r_filled.data_month_label AS revenue_month,

        r_filled.deadline_date AS revenue_deadline_date,

        r_filled.aligned_date AS revenue_aligned_date,


        /*
         * ============================================================
         * Income statement
         * ============================================================
         */

        r_filled.data_month_label IS NOT NULL AS has_revenue_snapshot,

        f_filled.q_revenue AS financial_q_revenue,

        f_filled.revenue_ttm AS financial_revenue_ttm,

        f_filled.q_operating_income AS financial_q_operating_income,

        f_filled.operating_income_ttm AS financial_operating_income_ttm,

        f_filled.q_net_income AS financial_q_net_income,

        f_filled.net_income_ttm AS financial_net_income_ttm,

        f_filled.operating_margin AS op_margin,

        f_filled.operating_margin_ttm AS operating_margin_ttm,

        f_filled.net_margin AS net_margin,

        f_filled.net_margin_ttm AS net_margin_ttm,

        f_filled.ebit_volatility AS ebit_volatility,

        f_filled.net_margin_volatility AS net_margin_volatility,

        f_filled.eps AS eps,

        f_filled.eps_ttm AS eps_ttm,

        f_filled.last_year_q_eps AS last_year_q_eps,

        f_filled.eps_yoy_growth AS eps_yoy_growth,

        f_filled.EBIT_signal AS EBIT_signal,

        f_filled.net_income_signal AS net_income_signal,

        f_filled.EPS_signal AS EPS_signal,

        f_filled.EBIT_diff_signal AS EBIT_diff_signal,

        f_filled.net_margin_diff_signal AS net_margin_diff_signal,

        f_filled.EBIT_vol_signal AS EBIT_vol_signal,

        f_filled.net_margin_vol_signal AS net_margin_vol_signal,

        /*
         * Income statement PIT lineage
         */

        f_filled.year_quarter AS report_quarter,

        f_filled.deadline_date AS financial_deadline_date,

        f_filled.aligned_date AS financial_aligned_date,


        /*
         * ============================================================
         * Balance sheet
         * ============================================================
         */

        b_filled.current_assets AS current_assets,

        b_filled.non_current_assets AS non_current_assets,

        b_filled.total_assets AS total_assets,

        b_filled.current_liabilities AS current_liabilities,

        b_filled.non_current_liabilities AS non_current_liabilities,

        b_filled.total_liabilities AS total_liabilities,

        b_filled.share_capital AS share_capital,

        b_filled.share_capital_ntd AS share_capital_ntd,

        b_filled.shares_outstanding AS shares_outstanding,
        
        b_filled.adjusted_shares_outstanding AS adjusted_shares_outstanding,

        b_filled.capital_surplus AS capital_surplus,

        b_filled.retained_earnings AS retained_earnings,

        b_filled.total_equity AS total_equity,

        b_filled.book_value_per_share AS book_value_per_share,
        
        b_filled.adjusted_book_value_per_share AS adjusted_book_value_per_share,

        b_filled.debt_ratio AS debt_ratio,

        b_filled.equity_ratio AS equity_ratio,

        b_filled.current_ratio AS current_ratio,

        /*
         * Balance sheet PIT lineage
         */

        b_filled.year_quarter AS balance_sheet_quarter,

        b_filled.deadline_date AS balance_sheet_deadline_date,

        b_filled.aligned_date AS balance_sheet_aligned_date

    FROM filled_boxes

),

final AS (

    SELECT
        *,

        /*
         * Valuation multiples should use a contemporaneously observable
         * price level, not future-adjusted total-return price.
         */

        SAFE_DIVIDE(
            effective_close,
            NULLIF(eps_ttm, 0)
        ) AS pe_ttm,

        SAFE_DIVIDE(
            effective_close,
            NULLIF(book_value_per_share, 0)
        ) AS pb_ratio,

        /*
         * Forward returns continue to use adjusted close because these
         * are return measurements, not historical price-level features.
         */

        SAFE_DIVIDE(
            LEAD(d_close, 1) OVER (
                PARTITION BY ticker
                ORDER BY date
            ),
            d_close
        ) - 1 AS ret_1d,

        SAFE_DIVIDE(
            LEAD(d_close, 5) OVER (
                PARTITION BY ticker
                ORDER BY date
            ),
            d_close
        ) - 1 AS ret_5d,

        SAFE_DIVIDE(
            LEAD(d_close, 10) OVER (
                PARTITION BY ticker
                ORDER BY date
            ),
            d_close
        ) - 1 AS ret_10d,

        SAFE_DIVIDE(
            LEAD(d_close, 20) OVER (
                PARTITION BY ticker
                ORDER BY date
            ),
            d_close
        ) - 1 AS ret_20d

    FROM expanded

    WHERE date >= DATE '2010-01-01'

)

SELECT *
FROM final