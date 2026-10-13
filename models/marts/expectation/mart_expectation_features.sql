{{ config(materialized='view') }}

WITH base AS (

    SELECT *
    FROM {{ ref('mart_vbt_master_dataset') }}

),

/*
 * 每個 ticker、revenue_month 只保留一次月營收資料。
 *
 * mart_vbt_master_dataset 已將月營收 forward fill 到每日，
 * 因此必須先還原成月頻資料，避免 rolling window 重複計算。
 */
monthly_revenue AS (

    SELECT
        ticker,
        revenue_month,
        PARSE_DATE('%Y-%m', revenue_month) AS revenue_month_date,

        MIN(date) AS revenue_available_date,

        ANY_VALUE(revenue) AS revenue,
        -- MOPS 去年同月增減(%) is contractually percentage points.
        ANY_VALUE(yoy_growth) AS yoy_growth_pct

    FROM base

    WHERE revenue_month IS NOT NULL
      AND revenue IS NOT NULL

    GROUP BY
        ticker,
        revenue_month

),

/*
 * A row window is not a calendar window.  Split each ticker into contiguous
 * month segments so no revenue history crosses an absent calendar month.
 */
monthly_revenue_sequenced AS (

    SELECT
        *,
        LAG(revenue_month_date) OVER (
            PARTITION BY ticker
            ORDER BY revenue_month_date
        ) AS previous_revenue_month_date

    FROM monthly_revenue

),

monthly_revenue_segmented AS (

    SELECT
        *,
        SUM(
            CASE
                WHEN previous_revenue_month_date IS NULL
                  OR DATE_DIFF(
                      revenue_month_date,
                      previous_revenue_month_date,
                      MONTH
                  ) != 1
                THEN 1
                ELSE 0
            END
        ) OVER (
            PARTITION BY ticker
            ORDER BY revenue_month_date
        ) AS continuity_segment

    FROM monthly_revenue_sequenced

),

/*
 * 月營收歷史特徵。
 *
 * monthly_revenue_ttm：
 * 僅保留作為歷史觀察特徵，不再作為 forward revenue 的基期。
 *
 * revenue_yoy_3m_avg / revenue_yoy_6m_avg：
 * 將月營收 YoY 正規化為小數後計算移動平均。
 */
monthly_features_1 AS (

    SELECT
        *,

        CASE
            WHEN COUNT(revenue) OVER (
                PARTITION BY ticker, continuity_segment
                ORDER BY revenue_month_date
                ROWS BETWEEN 11 PRECEDING AND CURRENT ROW
            ) = 12
            THEN SUM(revenue) OVER (
                PARTITION BY ticker, continuity_segment
                ORDER BY revenue_month_date
                ROWS BETWEEN 11 PRECEDING AND CURRENT ROW
            )
        END AS monthly_revenue_ttm,

        AVG(
            yoy_growth_pct / 100.0
        ) OVER (
            PARTITION BY ticker, continuity_segment
            ORDER BY revenue_month_date
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
        ) AS revenue_yoy_3m_avg,

        AVG(
            yoy_growth_pct / 100.0
        ) OVER (
            PARTITION BY ticker, continuity_segment
            ORDER BY revenue_month_date
            ROWS BETWEEN 5 PRECEDING AND CURRENT ROW
        ) AS revenue_yoy_6m_avg

    FROM monthly_revenue_segmented

),

/*
 * 將近期月營收趨勢轉成 forward revenue growth 假設。
 */
monthly_features AS (

    SELECT
        *,

        revenue_yoy_3m_avg
            - revenue_yoy_6m_avg
            AS revenue_acceleration,

        GREATEST(
            -0.5,
            LEAST(
                1.0,

                revenue_yoy_6m_avg
                    + 0.5 * (
                        revenue_yoy_3m_avg
                        - revenue_yoy_6m_avg
                    )
            )
        ) AS expected_revenue_growth

    FROM monthly_features_1

),

/*
 * 將 daily master dataset 與當期月營收成長特徵結合。
 *
 * financial_revenue_ttm 與 net_margin_ttm
 * 已由財報模型計算並在 master dataset 做 point-in-time forward fill。
 */
daily_base AS (

    SELECT
        b.date,
        b.ticker,

        b.d_close,

        b.eps,
        b.eps_ttm,
        b.pe_ttm,
        b.pb_ratio,

        /*
         * 月營收資料
         */
        b.revenue,
        b.revenue_month,

        mf.monthly_revenue_ttm,
        mf.revenue_yoy_3m_avg,
        mf.revenue_yoy_6m_avg,
        mf.revenue_acceleration,
        mf.expected_revenue_growth,

        /*
         * 財報資料
         */
        b.report_quarter,

        b.financial_q_revenue,
        b.financial_revenue_ttm,

        b.financial_q_operating_income,
        b.financial_operating_income_ttm,

        b.financial_q_net_income,
        b.financial_net_income_ttm,

        b.op_margin,
        b.operating_margin_ttm,

        b.net_margin,
        b.net_margin_ttm,

        b.ebit_volatility,
        b.net_margin_volatility,

        /*
         * 資產負債表資料
         */
        b.shares_outstanding,
        b.book_value_per_share,

        b.debt_ratio,
        b.equity_ratio,
        b.current_ratio

    FROM base b

    LEFT JOIN monthly_features mf
        ON b.ticker = mf.ticker
       AND b.revenue_month = mf.revenue_month

),

/*
 * Forward revenue：
 *
 * 使用財報口徑 revenue TTM 作為基準，
 * 月營收只負責提供 expected growth。
 */
forward_revenue_calc AS (

    SELECT
        *,

        financial_revenue_ttm
            * (1 + expected_revenue_growth)
            AS forward_revenue_ttm

    FROM daily_base

),

/*
 * Forward net income：
 *
 * 使用 TTM net margin 將 forward revenue 轉換為預估淨利。
 */
forward_income_calc AS (

    SELECT
        *,

        forward_revenue_ttm
            * net_margin_ttm
            AS forward_net_income

    FROM forward_revenue_calc

),

/*
 * Forward EPS：
 *
 * 保留原模型的單位轉換假設：
 * 財報數值 × 1000 / shares_outstanding。
 */
forward_eps_calc AS (

    SELECT
        *,

        SAFE_DIVIDE(
            forward_net_income * 1000,
            shares_outstanding
        ) AS forward_eps

    FROM forward_income_calc

),

final AS (

    SELECT
        *,

        SAFE_DIVIDE(
            forward_eps,
            NULLIF(eps_ttm, 0)
        ) - 1 AS forward_constant_growth

    FROM forward_eps_calc

)

SELECT *
FROM final
