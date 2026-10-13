# Extreme Corporate-Action Factor Reconstruction

Audit date: 2026-09-23 (Asia/Taipei)

This follow-up is SELECT-only. No production model, seed, ingestion code, or warehouse
data was changed.

## Conclusion

The factor formula is not the root cause. `reference price / pre-event close` is the
correct backward-adjustment factor when the price input is an unadjusted market close.
It produces plausible continuity for both 2024 extreme events.

Seven older events fail because `daily_prices_partitioned.close` is not on the raw basis
implied by the official action row. In six cases the warehouse price sequence preserves
approximately the correct event return but is already on a later normalized scale, so
the dbt model applies the official factor a second time. Ticker 9103 is more severe: its
warehouse date/value sequence also conflicts with official trading records.

The action rows themselves match the official TWSE/TPEx fields and classifications.
Therefore the primary classification is **source price data quality / source-basis
interpretation**, not arithmetic formula error and not event misclassification.

## Reconstruction

Definitions:

- calculated factor = official/source reference price / official/source pre-event close;
- adjusted pre-event price = warehouse pre-event close × calculated factor;
- continuity ratio = first positive warehouse close on/after event / adjusted pre-event price;
- official continuity = first official traded close on/after event / official reference price.

| Ticker | Event | Market / class | Source pre → reference | Factor | Warehouse pre → locally adjusted | Warehouse event/first quote | Warehouse continuity | Official first close / continuity | Classification |
|---|---|---|---:|---:|---:|---:|---:|---:|---|
| 9105 | 2005-04-12 | TWSE / ex-right | 53.80 → 5.38 | 0.100000 | 2.51 → 0.2510 | 2.68 | 10.6773 | 5.75 / 1.0688 | Warehouse historical close is on an incompatible normalized basis; factor and action row are correct. |
| 9103 | 2007-06-11 | TWSE / ex-right | 12.45 → 3.11 | 0.249799 | 2.89 → 0.7219 | 11.57 on 2007-06-12 | 16.0267 | 3.32 on 2007-06-13 / 1.0675 | Confirmed warehouse price-data corruption or wrong historical mapping: both value and first-trade date disagree with TWSE. |
| 4994 | 2012-07-26 | TPEx / ex-right-and-dividend | 397.00 → 197.75 | 0.498111 | 74.46 → 37.0893 | 79.63 | 2.1470 | 211.50 / 1.0695 | Warehouse sequence is already scaled; applying the official factor again double-adjusts it. |
| 9906 | 2013-08-13 | TWSE / ex-right | 110.00 → 48.74 | 0.443091 | 40.35 → 17.8787 | 43.13 | 2.4124 | 52.10 / 1.0689 | Warehouse sequence is already normalized and inconsistent with official raw closes; double adjustment. |
| 8913 | 2018-06-04 | TPEx / ex-right-and-dividend | 208.00 → 18.11 | 0.087067 | 18.11 → 1.5768 | 19.90 | 12.6206 | 19.90 / 1.0988 | Clearest double adjustment: warehouse pre-close already equals the official reference price. |
| 4303 | 2018-08-29 | TPEx / ex-right-and-dividend | 165.00 → 38.57 | 0.233758 | 32.06 → 7.4943 | 35.24 | 4.7023 | 42.40 / 1.0993 | Warehouse sequence is already on another normalized scale; factor is applied twice. |
| 3293 | 2022-07-27 | TPEx / ex-right-and-dividend | 782.00 → 366.00 | 0.468031 | 366.00 → 171.2992 | 355.50 | 2.0753 | 355.50 / 0.9713 | Clear double adjustment: warehouse pre-close already equals official reference price. |
| 3293 | 2024-07-24 | TPEx / ex-right-and-dividend | 1,465.00 → 715.00 | 0.488055 | 1,465.00 → 715.00 | 786.00 on 2024-07-26 | 1.0993 | 786.00 / 1.0993 | Valid. No event-date trade; first later quote is consistent with the adjusted basis and price limit. |
| 1808 | 2024-09-26 | TWSE / ex-right-and-dividend | 119.50 → 52.95 | 0.443096 | 119.50 → 52.95 | 53.50 | 1.0104 | 53.50 / 1.0104 | Valid. Warehouse raw close and official source basis agree. |

## Root-cause determination

### Source interpretation — confirmed contributor

`int_daily_prices_adjusted.sql` assumes `daily_prices_partitioned.close` is an
unadjusted contemporaneous close. That assumption is false for seven older extreme
events. The source contract has no field declaring price basis, adjustment history,
load provenance, or original vendor/source version.

### Formula — validated

The implementation multiplies pre-event prices by `reference / pre-close` and excludes
the event date itself. On genuinely raw prices this maps the prior close to the official
reference-price basis. The 2024 cases reproduce correctly, and applying the same formula
to official raw closes gives continuity ratios between 0.9713 and 1.0993 for all nine
events.

### Event classification — not the primary error

Official records classify the events as ex-right or ex-right-and-dividend. Although the
warehouse table is named `*_dividend`, the stored reference/pre-close pair is sufficient
for return adjustment when paired with raw closes. The narrow four-column schema loses
cash dividend, stock distribution, issue, and event-type fields, which prevents stronger
validation but did not cause the arithmetic discontinuity.

### Source data quality — confirmed primary error

- All seven failed cases have warehouse pre-event prices that disagree materially with
  official daily closes.
- For 8913 and 3293 (2022), the warehouse pre-event close already equals the official
  ex-event reference price.
- For 4994, 9906, and 4303, the warehouse pre/post ratio remains close to the official
  event return while both levels are on a different scale.
- For 9103, the warehouse reports a positive 11.57 close on 2007-06-12; TWSE reports
  zero volume/no close that day and the first traded close is 3.32 on 2007-06-13.

The exact mechanism that produced the older normalized/corrupt rows is **unverified**:
the current ingestion code reads official daily market files, but the price table does
not retain ingestion provenance and the audited historical rows predate the current
pipeline evidence.

## Implication

The previously identified 8913 failure is part of a broader mixed-basis price history.
At least seven of nine extreme factors are incorrectly applied to their warehouse price
inputs. Historical adjusted returns and every downstream result consuming those returns
may be affected. The two valid 2024 cases must not be removed merely because their
factors are numerically extreme.

## Evidence

- Warehouse reconstruction: `analyses/corporate_action_extreme_factor_reconstruction.sql`
- Production factor logic: `models/staging/stg_dividend_factor.sql` and
  `models/intermediate/int_daily_prices_adjusted.sql`
- Ingestion mapping: `../../../GCP_cloud_functions/dividend_processor/main.py`
- Official action and daily-price endpoints: TWSE TWT49U / MI_INDEX and TPEx exDailyQ /
  daily OTC quotes.

