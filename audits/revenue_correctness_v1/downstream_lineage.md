# Revenue correctness V1 downstream lineage

## Canonical Revenue YoY signal

```text
stock_data.monthly_revenue.yoy_growth_pct
  (official MOPS 去年同月增減(%), percentage points)
→ stg_monthly_revenue.yoy_growth_pct
→ int_monthly_revenue_features.yoy_growth_pct
→ int_monthly_revenue_shifter.rev_box.yoy_growth_pct
→ int_vbt_stack.rev_box
→ mart_vbt_master_dataset.yoy_growth
→ mart_factor_research_daily.yoy_growth
→ mart_factor_research_monthly.yoy_growth
→ canonical 2018–2025 Revenue YoY cross-sectional ranks
```

No percentage-to-decimal conversion occurs on this path. The canonical rank signal deliberately
preserves the official percentage-point value. Uniform conversion to decimals would not alter its
ordering, but changing the field is unnecessary and could break consumers that rely on the source
unit.

## Expectation and valuation path

```text
mart_vbt_master_dataset.(revenue_month, revenue, yoy_growth)
→ mart_expectation_features
    monthly_revenue_ttm
    revenue_yoy_3m_avg
    revenue_yoy_6m_avg
    revenue_acceleration
    expected_revenue_growth
    forward_revenue_ttm
    forward_net_income
    forward_eps
    forward_constant_growth
→ mart_expectation_dataset
    implied growth / expectation_gap / signals
→ mart_factor_research_daily
→ mart_factor_research_monthly
→ mart_vbt_valuation_dataset and downstream expectation research
```

This is the directly contaminated path. The former magnitude-dependent CASE treated percentage
points in `[-1, 1]` as decimals. V1 changes only this arithmetic consumer to unconditional
`yoy_growth_pct / 100.0`.

## Calendar-dependent auxiliary path

```text
stg_monthly_revenue
→ int_monthly_revenue_features
    yoy_positive_streak_count
    yoy_triple_increase_signal
→ int_monthly_revenue_shifter
→ mart_vbt_master_dataset
→ mart_factor_dataset
```

Streak and triple-increase features now require adjacent calendar months. They are not selected as
canonical Revenue YoY inputs by `mart_factor_research_daily`.

The expectation rolling path separately segments each ticker at missing calendar months. TTM
requires 12 consecutive monthly rows. Three- and six-month averages intentionally allow partial
warm-up but cannot use rows from an earlier segment. NULL YoY values remain NULL and are ignored by
SQL `AVG`; a NULL revenue inside a 12-month window prevents TTM validity.

## Impact classification

- **Direct canonical signal contamination:** none demonstrated; production/source comparison found
  zero joined `yoy_growth` mismatches.
- **Direct expectation/valuation contamination:** confirmed.
- **Auxiliary trend-feature contamination:** confirmed for gap-crossing streak/triple calculations.
- **Price, corporate-action, and financial-statement models:** no changes in this task.
