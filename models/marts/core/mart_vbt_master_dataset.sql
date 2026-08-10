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
        MAX(adj_close) AS d_close,
        MAX(volume) AS d_vol,

        MAX(ma20) AS ma20,
        MAX(ma60) AS ma60,
        MAX(bias20) AS bias20,

        ANY_VALUE(rev_box) AS r,
        ANY_VALUE(fin_box) AS f,
        ANY_VALUE(bs_box) AS b

    FROM {{ ref('int_vbt_stack') }}
    GROUP BY date, ticker

),

filled AS (

    SELECT
        date,
        ticker,

        d_open,
        d_high,
        d_low,
        d_close,
        d_vol,

        ma20,
        ma60,
        bias20,

        /*
         * Monthly revenue features
         */

        LAST_VALUE(r.revenue IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS revenue,


        LAST_VALUE(r.revenue_last_year IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS revenue_last_year,



        LAST_VALUE(r.yoy_growth_pct IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS yoy_growth,

        LAST_VALUE(r.mom_growth_pct IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS mom_growth_pct,

        LAST_VALUE(r.ytd_growth_pct IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS ytd_growth_pct,

        LAST_VALUE(r.yoy_positive_streak_count IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS yoy_positive_streak_count,

        LAST_VALUE(r.yoy_triple_increase_signal IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS rev_triple_sig,

        LAST_VALUE(r.data_month_label IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS revenue_month,

        /*
         * Financial statement features
         */

        LAST_VALUE(f.q_revenue IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS financial_q_revenue,

        LAST_VALUE(f.revenue_ttm IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS financial_revenue_ttm,

        LAST_VALUE(f.q_operating_income IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS financial_q_operating_income,

        LAST_VALUE(f.operating_income_ttm IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS financial_operating_income_ttm,

        LAST_VALUE(f.q_net_income IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS financial_q_net_income,

        LAST_VALUE(f.net_income_ttm IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS financial_net_income_ttm,

        LAST_VALUE(f.operating_margin IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS op_margin,

        LAST_VALUE(f.operating_margin_ttm IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS operating_margin_ttm,

        LAST_VALUE(f.net_margin IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS net_margin,

        LAST_VALUE(f.net_margin_ttm IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS net_margin_ttm,

        LAST_VALUE(f.ebit_volatility IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS ebit_volatility,

        LAST_VALUE(f.net_margin_volatility IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS net_margin_volatility,

        LAST_VALUE(f.eps IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS eps,

        LAST_VALUE(f.eps_ttm IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS eps_ttm,

        LAST_VALUE(f.last_year_q_eps IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS last_year_q_eps,

        LAST_VALUE(f.eps_yoy_growth IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS eps_yoy_growth,

        LAST_VALUE(f.EBIT_signal IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS EBIT_signal,

        LAST_VALUE(f.net_income_signal IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS net_income_signal,

        LAST_VALUE(f.EPS_signal IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS EPS_signal,

        LAST_VALUE(f.EBIT_diff_signal IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS EBIT_diff_signal,

        LAST_VALUE(f.net_margin_diff_signal IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS net_margin_diff_signal,

        LAST_VALUE(f.EBIT_vol_signal IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS EBIT_vol_signal,

        LAST_VALUE(f.net_margin_vol_signal IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS net_margin_vol_signal,

        LAST_VALUE(f.year_quarter IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS report_quarter,

        /*
         * Balance sheet features
         */

        LAST_VALUE(b.current_assets IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS current_assets,

        LAST_VALUE(b.non_current_assets IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS non_current_assets,

        LAST_VALUE(b.total_assets IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS total_assets,

        LAST_VALUE(b.current_liabilities IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS current_liabilities,

        LAST_VALUE(b.non_current_liabilities IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS non_current_liabilities,

        LAST_VALUE(b.total_liabilities IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS total_liabilities,

        LAST_VALUE(b.share_capital IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS share_capital,

        LAST_VALUE(b.share_capital_ntd IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS share_capital_ntd,

        LAST_VALUE(b.shares_outstanding IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS shares_outstanding,

        LAST_VALUE(b.capital_surplus IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS capital_surplus,

        LAST_VALUE(b.retained_earnings IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS retained_earnings,

        LAST_VALUE(b.total_equity IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS total_equity,

        LAST_VALUE(b.book_value_per_share IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS book_value_per_share,

        LAST_VALUE(b.debt_ratio IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS debt_ratio,

        LAST_VALUE(b.equity_ratio IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS equity_ratio,

        LAST_VALUE(b.current_ratio IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS current_ratio,

        LAST_VALUE(b.year_quarter IGNORE NULLS) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS balance_sheet_quarter

    FROM flattened

),

final AS (

    SELECT
        *,

        SAFE_DIVIDE(
            d_close,
            NULLIF(eps_ttm, 0)
        ) AS pe_ttm,

        SAFE_DIVIDE(
            d_close,
            NULLIF(book_value_per_share, 0)
        ) AS pb_ratio,

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

    FROM filled
    WHERE date >= DATE '2010-01-01'

)

SELECT *
FROM final