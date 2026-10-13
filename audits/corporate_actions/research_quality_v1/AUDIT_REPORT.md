# Research Quality Layer V1 implementation report

Generated 2026-10-13 (Asia/Taipei). This report describes a local research artifact only. No
production BigQuery table, GCS object, dbt model, Cloud Run job, Scheduler, or adjustment factor
was mutated.

## Architecture and lineage

The implementation is a Python research adapter over the unchanged
`mart_factor_research_monthly` table plus a versioned CSV anomaly input. The production mart is
materialized as a table at grain `(rebalance_date, ticker)`. It forms observations first, then
constructs the fixed next-rebalance endpoint label. Revenue YoY is `yoy_growth`; the relevant price
features are `price_ma20_gap` and `price_ma60_gap`, sourced from inclusive 20/60-row moving averages
over `int_daily_prices_adjusted`.

Outputs preserve every original row and selected original source/factor fields, add the three
quality flags and `forward_return_research`, and retain a normalized many-anomaly relationship
table. The production models remain unchanged.

## Input certification

- Material anomaly input: 360 unique transitions, 262 tickers,
  `abs(adjusted_return) > 0.50`.
- Additional control: 2429, transition ending 2024-07-02, not counted among the 360.
- Input CSV SHA256: `b053b4491d0dabd03ab299f506505ead01f74bb6b264f1efb363929962a0ebcd`.
- Input generation is reproducible from the preserved reverse-QA and root-cause artifacts.
- 2429 is invalidated on its event transition and while MA windows still cross that transition;
  there is no permanent ticker blacklist.

## Quality results

| Population | Forward invalid | MA20 invalid | MA60 / MA-union invalid | Union of all components |
|---|---:|---:|---:|---:|
| 360 material transitions only | 155 | 218 | 670 | 825 |
| 2429 control only | 1 | 1 | 3 | 4 |
| Combined V1 | 156 | 219 | 673 | 829 |

The combined union is 829 / 240,327 observations (0.34495%). There are 151 invalidated labels that
previously contained a finite return; five other forward-invalid observations already had no usable
label. MA60 contains the MA20-exposed observation set at this sampling frequency, so the combined
price-feature count is 673 / 240,327 (0.28004%), not 219 + 673.

The previous impact audit reported 155 direct, 235 MA20, 680 MA60, and a union of 835 for the
material population. Direct exposure reconciles exactly. Exact production window semantics reduce
MA20 by 17, MA60 by 10, and the union by 10: offsets 19/59 were conservatively included before, but
those windows begin on the post-event quote and no longer cross the anomalous transition. Adding
2429 produces the combined counts above.

Regression evidence:

- 6294 on 2010-02-22 is present in the anomaly input without a ticker-specific rule, but it has no
  observation in the current V1-eligible monthly research panel at the affected date, so it creates
  no research relationship.
- 5364 on 2013-12-10 invalidates the 2013-11-15 forward label, the 2013-12-16 MA20 value, and MA60
  on 2013-12-16, 2014-01-15, and 2014-02-17.
- 2429 on 2024-07-02 produces the same relationship pattern: one direct label, one MA20 value, and
  three MA60 values.

## Canonical Revenue YoY comparison, 2018–2025

Formation uses the existing cohort and procedure: `d_close > 0`, benchmark 0050 excluded,
cross-sectional inclusive P1/P99 trim, deterministic ticker tie-break, five position quantiles,
equal weighting, and Newey-West lag 3.

| Measure | Baseline | Quality-aware |
|---|---:|---:|
| Formation observations | 147,225 | 147,225 |
| Return observations | 144,475 | 144,384 |
| Mean monthly Spearman IC | 0.037697 | 0.037963 |
| ICIR | 0.516485 | 0.519907 |
| Q1 mean forward return | 0.007654 | 0.006663 |
| Q2 mean forward return | 0.008841 | 0.007946 |
| Q3 mean forward return | 0.012792 | 0.012436 |
| Q4 mean forward return | 0.016733 | 0.016234 |
| Q5 mean forward return | 0.023875 | 0.022943 |
| Q5-Q1 mean spread | 0.016220 | 0.016281 |
| Positive spread months | 75.00% | 77.08% |
| Newey-West t-statistic | 6.396955 | 6.645223 |
| Newey-West p-value | 1.5851e-10 | 3.0276e-11 |

Exactly 91 previously finite labels are excluded: 90 from the material population baseline and one
from the 2429 control. There are 92 forward-invalid formation observations because one material
case already lacked a usable original return. Exact MA exposure is 385 formation observations
(382 material plus three from 2429), compared with the earlier conservative material estimate of
388.

The formation comparison found zero row-membership differences, zero Revenue YoY value changes,
and zero quintile changes. Mean IC sign, spread sign, and 5% significance classification are all
unchanged. The evidence remains strongly positive under this bounded label-quality policy; this is
stability of the scoped Revenue YoY result, not validation of the entire price layer.

## BigQuery safety and cost

Both statements were statically restricted to `SELECT`/`WITH` and dry-run before execution.

| Stage | Job ID | Processed bytes | Billed bytes | Rows |
|---|---|---:|---:|---:|
| Relationships | `807a2724-86d3-4277-8c0d-82f5ab6fb7fa` | 100,207,820 | 100,663,296 | 1,048 |
| Monthly panel | `5acb17f0-0145-4053-b956-fc72fc170645` | 36,887,886 | 37,748,736 | 240,327 |

Total dry-run estimate and actual processed bytes were both 137,095,706 (about 0.128 GiB). Local
post-processing used zero BigQuery bytes. The progress manifest records all stages and enables
repeatable local continuation.

## Acceptance and use

Revenue YoY V1 research may proceed with caveats when:

1. the original formation cohort and quintiles are used unchanged;
2. `forward_return_research`, not the original label, is used for evaluation;
3. MA-dependent analysis excludes or explicitly reviews `INVALID` and `UNKNOWN` features; and
4. conclusions are described as covered by this versioned anomaly set, not by a fully certified
   adjusted-price history.

The next bounded step is to wire this local adapter into the Revenue YoY research entry point (still
after formation), rerun the same acceptance tests, and obtain explicit approval before creating any
persistent BigQuery research table. Systematic capital-reduction reconstruction remains a separate
future Price Foundation project.
