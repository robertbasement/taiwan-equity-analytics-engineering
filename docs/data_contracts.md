# Data contracts

This document describes the relations and fields that the current SQL actually uses. It distinguishes expected input shape from guarantees enforced by dbt.

The source declaration in [`models/sources/stock_sources.yml`](../models/sources/stock_sources.yml) is currently a relation-level contract. It does not define source columns, freshness, uniqueness, or enforced dbt model contracts.

## Contract status

| Term | Meaning here |
|---|---|
| Required | Referenced by current SQL; the project cannot produce its intended output without it. |
| Expected grain | The logical row identity assumed by downstream calculations. |
| Enforced | Protected by current SQL or a dbt test. |
| Not formally contracted | Inferred from transformations or comments but absent from an enforced source/schema contract. |

## Upstream relations

### `daily_prices_partitioned`

**Expected logical grain:** one row per `ticker + date` represented in the source.

**Required fields:**

- `ticker`
- `date`
- `open`
- `high`
- `low`
- `close`
- `volume`

`date` must be parseable as either `YYYY-MM-DD` or `YYYYMMDD`. Rows with a null source date are excluded. Prices on or after 2000-01-01 enter the adjusted-price model; the analytical indicator history begins in 2009.

The project treats positive `close` values as valid trades. A previous valid close may be carried for at most 30 calendar days on source rows whose close is nonpositive. Currency, split basis, calendar completeness, and source key uniqueness are not formally contracted in this repository.

### `monthly_revenue`

**Expected logical grain:** one row per `ticker + year_month`.

**Required fields:**

- `ticker`
- `company_name`
- `year_month`
- `revenue`
- `revenue_prev_month`
- `revenue_last_year`
- `mom_growth_pct`
- `yoy_growth_pct`
- `revenue_ytd`
- `revenue_ytd_last_year`
- `ytd_growth_pct`

`year_month` is expected in `YYYY-MM` form. The shifter parses it as the first day of the month and applies the availability policy described in [Point-in-time semantics](point_in_time_semantics.md).

The staging model selects the greatest `revenue` when duplicate ticker-month rows exist. This is a policy-based fallback, not filing-version selection. No ingestion timestamp or immutable version identifier is available to this project. Revenue currency/unit and whether growth fields arrive as percentages or decimals are not formally contracted; downstream expectation logic defensively normalizes growth magnitudes greater than one by dividing by 100.

### `income_statement`

**Expected logical grain:** one row per `ticker + year_quarter`.

**Required fields:**

- `ticker`
- `company_name`
- `year_quarter`
- `revenue`
- `cost_of_goods_sold`
- `gross_profit`
- `unrealized_sales_gain_loss`
- `realized_sales_gain_loss`
- `gross_profit_net`
- `operating_expenses`
- `other_income_expense_net`
- `operating_income`
- `non_operating_income_expense`
- `income_before_tax`
- `income_tax_expense`
- `net_income`
- `eps`

`year_quarter` is expected in `YYYY-Q` form, where `Q` is 1 through 4. The feature model treats revenue, operating income, net income, and EPS as cumulative within the fiscal year and derives single-quarter values by subtraction. Q1 is used directly.

The current staging `ROW_NUMBER` does not use version or ingestion metadata; if duplicates exist, the selected row is not deterministic in business terms. Consecutive-quarter presence is expected but is not currently enforced before YTD subtraction or four-row TTM windows.

The project assumes statement monetary amounts require multiplication by 1,000 when converted to NTD for per-share calculations. EPS is treated as a per-share value. These units are encoded in downstream calculations but are not formally declared in the source YAML.

### `balance_sheet`

**Expected logical grain:** one row per `ticker + year_quarter`.

**Required fields:**

- `ticker`
- `company_name`
- `current_assets`
- `non_current_assets`
- `total_assets`
- `current_liabilities`
- `non_current_liabilities`
- `total_liabilities`
- `share_capital`
- `capital_surplus`
- `retained_earnings`
- `total_equity`
- `book_value_per_share`
- `year_quarter`

`year_quarter` is expected in `YYYY-Q` form. Balance-sheet rows are period-end snapshots, not cumulative flows.

Ticker-quarter uniqueness is not currently enforced or deduplicated in staging. Filing-version metadata is unavailable. The feature model assumes monetary statement fields require multiplication by 1,000 when expressed in NTD. It infers canonical shares outstanding as:

```text
total_equity × 1,000 / book_value_per_share
```

This is an analytical estimate, not an authoritative exchange-reported share count. A separate `share_capital × 1,000 / 10` calculation is retained only as a diagnostic because the nominal-value assumption is not reliable for every company.

### `sii_dividend`

**Expected logical grain:** one valid event per `ticker + ex_dividend_date` after union with the OTC source.

**Required fields:**

- `ticker`
- `ex_dividend_date`
- `reference_price_ex_dividend`
- `close_price_pre_adjust`

### `otc_dividend`

The OTC relation has the same required fields and expected logical grain as `sii_dividend`.

For both dividend sources, the derived adjustment factor is:

```text
reference_price_ex_dividend / close_price_pre_adjust
```

Only positive numerator and denominator values and dates on or after 2000-01-01 are retained. If more than one valid row remains for a combined `ticker + ex_date`, the staging model raises an explicit error instead of selecting one silently.

The meaning and units of the two price fields are inferred from their use and names; they are not described as source-level column contracts in YAML.

## Manual corporate-action seed

[`seeds/manual_corporate_actions.csv`](../seeds/manual_corporate_actions.csv) supplies actions not represented safely by the dividend-factor sources.

**Logical grain:** one configured action per `ticker + effective_date`.

**Fields:**

- `ticker`
- `effective_date`
- `price_factor`
- `per_share_factor`
- `share_factor`
- `note`

The factors drive deterministic transformations; implied-share evidence validates them but never selects or changes them. Seed uniqueness, positivity, reciprocal relationships, and external provenance are not yet enforced by seed tests. The adjusted-price model does explicitly fail a source/manual price-factor collision on the same ticker/date.

## Downstream contracts

### `mart_vbt_master_dataset`

**Grain:** one row per `date + ticker`.

**Role:** canonical reusable daily state joining price observations with the latest observable revenue, income-statement, and balance-sheet snapshots.

**Important field families:**

- raw, effective, and adjusted prices;
- technical indicators;
- revenue and source-month lineage;
- single-quarter, TTM, margin, and EPS fields;
- balance-sheet ratios, inferred shares, and BVPS;
- policy deadlines and aligned market dates; and
- P/E, P/B, and legacy row-horizon return labels.

The composite key and non-null key columns are tested. The model retains both characteristics and older forward-return fields, so consumers must not use future-return columns as formation-date inputs.

### `mart_expectation_dataset`

**Grain:** one row per eligible `date + ticker`.

**Role:** specialized daily expectation mart used by the canonical daily research contract.

**Important field families:**

- recent monthly revenue trends;
- financial-statement TTM inputs;
- forward revenue, income, and EPS estimates;
- canonical contemporaneous P/E and P/B;
- DCF-grid implied growth; and
- fundamental-versus-implied expectation gaps.

Rows require positive EPS TTM and P/E within the model's configured lookup range. The DCF assumptions are research parameters, not accounting facts.

### `mart_factor_research_daily`

**Grain:** one row per `date + ticker`.

**Role:** canonical daily research panel and the daily contract used by the downstream research platform.

**Formation-time characteristics include:**

- revenue, EPS, margin, valuation, balance-sheet, size, expectation, and technical fields;
- denominator fields used for eligibility and audit; and
- revenue, income, and balance-sheet source-period/deadline/alignment lineage.

**Realized fields include:**

- `stock_return`, calculated from adjusted `d_close` and the immediately previous observed ticker row; and
- `market_factor_return`, the same return for benchmark ticker `0050` on the date.

`effective_close` is the contemporaneous price level. `d_close` is the adjusted return-series price propagated from `adj_close`.

### `mart_factor_research_monthly`

**Grain:** one row per `rebalance_date + ticker`.

**Role:** primary downstream research and runtime contract.

The `rebalance_date` is the first benchmark (`0050`) market date on or after the 15th of a calendar month. Characteristics and lineage fields are taken from that exact date.

The following are future labels, not formation-time inputs:

- `forward_return`: adjusted-price return from the current rebalance date to the exact next scheduled rebalance date for the ticker;
- `market_return`: the corresponding `0050` return.

If a ticker has no row on the exact next rebalance date, its forward return remains null rather than silently skipping to a later month.

The downstream quantitative research platform directly consumes the daily and monthly research marts, with the monthly mart as its primary runtime dataset.

## Source lineage terminology

The current marts do not expose a generic literal `source_*_date` column. Instead they retain:

- source-period labels: `revenue_month`, `report_quarter`, and `balance_sheet_quarter`;
- policy dates: `revenue_deadline_date`, `financial_deadline_date`, and `balance_sheet_deadline_date`; and
- aligned dates: `revenue_aligned_date`, `financial_aligned_date`, and `balance_sheet_aligned_date`.

An `aligned_date` is the first market date on or after the applicable policy deadline. It is not an actual publication timestamp.
