# Full Corporate-Action Continuity Audit

Audit date: 2026-09-23 (Asia/Taipei)

Scope: every distinct row-level corporate-action event available in
`stock_data.sii_dividend` and `stock_data.otc_dividend`. The work was read-only
against BigQuery. No production model, seed, ingestion file, warehouse object, or
production data was changed.

## Executive conclusion

**Result: structural historical price-basis incompatibility, not an isolated set
of extreme factors.**

The audit inspected 30,325 distinct source events from 2003-06-02 through
2026-05-22. Of these, 28,785 had valid source fields plus positive warehouse
prices on both sides of the event. The deterministic diagnostic classified 1,549
usable events (5.38%) as `POSSIBLE_BASIS_MISMATCH`. They span 1,031 tickers and
both markets. The rate is 5.54% for TWSE and 5.14% for TPEx, so the problem is not
isolated to one market or source table.

The strongest repeatable pattern is that the warehouse close immediately before
an event equals the source reference price rather than the source pre-event close.
There are 854 such signatures in total: 852 reconstructable events and two events
without a usable post-event quote. A further 697 reconstructable events have a
different mixed-basis signature: source/warehouse pre-event levels materially
disagree, applying the source factor breaks continuity, while the warehouse's own
adjacent price step remains within the broad diagnostic band.

The issue is temporally structured. Suspect events occur from 2003-06-02 through
2023-05-03, with especially high rates in 2003–2008 and a very large 2022 cluster.
No `POSSIBLE_BASIS_MISMATCH` was found among 4,018 usable events in 2024–2026.
This is evidence of an ingestion/source-basis regime change, but the mechanism is
**unverified** because historical price rows do not retain vendor, load-run, or
raw-versus-adjusted provenance.

Consequently, historical adjusted-price results spanning corporate actions before
May 2023 cannot currently be trusted as a complete series without event-level
reconciliation. This does not mean every historical event is wrong: 27,201 usable
events passed the stated diagnostic, and valid large factors in 2024 pass.

## Method and diagnostic thresholds

For each distinct source event the audit calculates:

```text
source_factor = source_reference_price / source_pre_close
expected_adjusted_pre = warehouse_last_positive_pre_close * source_factor
continuity_ratio = first_positive_warehouse_close_on_or_after_event
                   / expected_adjusted_pre
```

The event date is not assumed to contain a trade. Calendar-day and market-session
gaps are included in the event-level output.

The following thresholds are diagnostics, not universal economic truths:

- economically plausible continuity or adjacent move: 0.80 through 1.20;
- close match: absolute relative difference no more than 2%;
- broad source-pre-close match: absolute relative difference no more than 5%;
- material corporate-action factor: more than 5% away from 1.0;
- material warehouse/source basis mismatch: more than 20%.

Classification precedence is deterministic:

1. `INSUFFICIENT_DATA`: invalid/non-positive source values or missing pre/post quote;
2. `POSSIBLE_BASIS_MISMATCH`: warehouse pre-close is within 2% of the source
   reference while the source factor is more than 5% from one, or applying the
   factor breaks the 0.80–1.20 band while the warehouse's unadjusted adjacent move
   stays inside that band and source/warehouse pre-closes differ by over 20%;
3. `POSSIBLE_SOURCE_ANOMALY`: warehouse matches source pre-close within 5%, but
   neither adjusted continuity nor post/reference comparison is plausible;
4. `CONTINUOUS`: continuity is within 0.80–1.20 and no stronger warning matched;
5. `REVIEW_REQUIRED`: all other reconstructable discontinuities.

No event is silently corrected. Factor magnitude is not a classification input
except for requiring a material difference from one in the explicit
reference-price-match signature.

## Counts and continuity distribution

| Measure | Result |
|---|---:|
| Total distinct source events | 30,325 |
| Usable events | 28,785 |
| Insufficient data | 1,540 |
| Median continuity | 1.040499 |
| Mean continuity | 1.054548 |
| Standard deviation | 0.514227 |
| Minimum | 0.719274 |
| 1st percentile | 0.951546 |
| 5th percentile | 0.983521 |
| 25th percentile | 1.009601 |
| 50th percentile | 1.040499 |
| 75th percentile | 1.074008 |
| 95th percentile | 1.155669 |
| 99th percentile | 1.279148 |
| Maximum | 84.919682 |

The mean and standard deviation are heavily distorted by a small number of large
positive discontinuities.

| Continuity band | Events |
|---|---:|
| `< 0.8` | 1 |
| `0.8–0.9` | 3 |
| `0.9–1.1` | 24,913 |
| `1.1–1.2` | 3,092 |
| `> 1.2` | 776 |

| Classification | Events | Share of all events |
|---|---:|---:|
| `CONTINUOUS` | 27,201 | 89.70% |
| `POSSIBLE_BASIS_MISMATCH` | 1,549 | 5.11% |
| `POSSIBLE_SOURCE_ANOMALY` | 12 | 0.04% |
| `REVIEW_REQUIRED` | 23 | 0.08% |
| `INSUFFICIENT_DATA` | 1,540 | 5.08% |

## Source-versus-warehouse basis

Using a 2% matching tolerance among the 28,785 usable events:

| Warehouse pre-event relationship | Events |
|---|---:|
| Matches source pre-close only | 4,290 |
| Matches source reference only | 1,987 |
| Matches both | 2,643 |
| Matches neither | 19,865 |

Of the 1,549 basis warnings, 852 match the source reference but not the source
pre-close and 697 match neither. None match the source pre-close under the 2%
test. This is the strongest evidence that the warning is about incompatible price
bases rather than factor magnitude.

`MATCHES_NEITHER` is not automatically an error. Historical prices can be on a
common scaled basis and still produce a correct return when the relative event
factor is applied. That is why classification requires failed continuity plus a
plausible unadjusted adjacent move for this group.

## Year, era, market, and source patterns

| Year | Total | Usable | Continuous | Basis mismatch | Source anomaly | Review | Insufficient | Basis % of usable |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 2003 | 450 | 444 | 389 | 53 | 0 | 2 | 6 | 11.94% |
| 2004 | 508 | 502 | 424 | 76 | 1 | 1 | 6 | 15.14% |
| 2005 | 555 | 551 | 477 | 69 | 4 | 1 | 4 | 12.52% |
| 2006 | 523 | 521 | 469 | 51 | 0 | 1 | 2 | 9.79% |
| 2007 | 538 | 536 | 480 | 55 | 0 | 1 | 2 | 10.26% |
| 2008 | 1,005 | 1,003 | 886 | 115 | 0 | 2 | 2 | 11.47% |
| 2009 | 855 | 854 | 818 | 34 | 1 | 1 | 1 | 3.98% |
| 2010 | 996 | 995 | 966 | 27 | 0 | 2 | 1 | 2.71% |
| 2011 | 1,148 | 1,147 | 1,088 | 58 | 1 | 0 | 1 | 5.06% |
| 2012 | 1,112 | 1,112 | 1,061 | 49 | 0 | 2 | 0 | 4.41% |
| 2013 | 1,129 | 1,129 | 1,099 | 29 | 0 | 1 | 0 | 2.57% |
| 2014 | 1,198 | 1,198 | 1,161 | 36 | 0 | 1 | 0 | 3.01% |
| 2015 | 1,257 | 1,257 | 1,215 | 41 | 0 | 1 | 0 | 3.26% |
| 2016 | 1,244 | 1,244 | 1,207 | 37 | 0 | 0 | 0 | 2.97% |
| 2017 | 1,315 | 1,315 | 1,288 | 24 | 2 | 1 | 0 | 1.83% |
| 2018 | 1,412 | 1,412 | 1,384 | 27 | 1 | 0 | 0 | 1.91% |
| 2019 | 1,657 | 1,657 | 1,624 | 29 | 1 | 3 | 0 | 1.75% |
| 2020 | 1,828 | 1,828 | 1,800 | 26 | 0 | 2 | 0 | 1.42% |
| 2021 | 1,939 | 1,939 | 1,899 | 39 | 0 | 1 | 0 | 2.01% |
| 2022 | 2,023 | 2,023 | 1,394 | 629 | 0 | 0 | 0 | 31.09% |
| 2023 | 2,100 | 2,100 | 2,055 | 45 | 0 | 0 | 0 | 2.14% |
| 2024 | 2,244 | 2,131 | 2,130 | 0 | 1 | 0 | 113 | 0.00% |
| 2025 | 2,608 | 1,659 | 1,659 | 0 | 0 | 0 | 949 | 0.00% |
| 2026 | 681 | 228 | 228 | 0 | 0 | 0 | 453 | 0.00% |

Useful empirical eras:

| Era | Usable | Basis mismatch | Rate |
|---|---:|---:|---:|
| 2000–2009 | 4,411 | 453 | 10.27% |
| 2010–2014 | 5,581 | 199 | 3.57% |
| 2015–2019 | 6,885 | 158 | 2.29% |
| 2020–2023 | 7,890 | 739 | 9.37% |
| 2024+ | 4,018 | 0 | 0.00% |

The 2020–2023 rate is driven by 2022. In that year 610 of 629 basis warnings
match the source reference exactly to floating-point precision. Warnings cluster
in June through September 2022 and affect both markets. The final basis warning
is 4923 on 2023-05-03. These are empirical structural breaks; their ingestion
cause is unverified.

| Market / source | Usable | Basis mismatch | Rate |
|---|---:|---:|---:|
| TWSE / `sii_dividend` | 17,271 | 957 | 5.54% |
| TPEx / `otc_dividend` | 11,514 | 592 | 5.14% |

Market and source table are one-to-one in the available schema, so their effects
cannot be separated. Event type is unavailable in both source tables and is not
inferred.

## Largest basis-mismatch discontinuities

| Ticker | Event | Market | Factor | Warehouse pre | First post | Continuity |
|---|---:|---|---:|---:|---:|---:|
| 8913 | 2018-06-04 | TPEx | 0.087067 | 18.11 | 19.90 | 12.6206 |
| 9105 | 2005-04-12 | TWSE | 0.100000 | 2.51 | 2.68 | 10.6773 |
| 4303 | 2018-08-29 | TPEx | 0.233758 | 32.06 | 35.24 | 4.7023 |
| 9906 | 2013-08-13 | TWSE | 0.443091 | 40.35 | 43.13 | 2.4124 |
| 4994 | 2012-07-26 | TPEx | 0.498111 | 74.46 | 79.63 | 2.1470 |
| 3293 | 2022-07-27 | TPEx | 0.468031 | 366.00 | 355.50 | 2.0753 |
| 5529 | 2013-07-18 | TPEx | 0.577751 | 55.97 | 59.84 | 1.8505 |
| 6404 | 2014-08-11 | TPEx | 0.582419 | 336.11 | 358.97 | 1.8338 |
| 01005T | 2012-03-01 | TWSE | 0.584234 | 12.97 | 13.87 | 1.8304 |
| 6286 | 2003-10-30 | TWSE | 0.588308 | 38.40 | 40.98 | 1.8140 |

The complete event list, including all 854 strong reference-price signatures, is
returned by `analyses/corporate_action_continuity_event_audit.sql`; filter
`strong_double_adjustment_signature` or `diagnostic_classification` without any
factor-magnitude filter.

Two additional extreme `REVIEW_REQUIRED` cases are not automatically attributed
to basis mismatch: 9103 on 2007-06-11 has a continuity ratio of 16.0267 and a
known warehouse date/value conflict with TWSE records; 2002A on 2009-07-24 has a
warehouse step from 0.25 to 19.77 and continuity of 84.9197.

## Known-case regression

| Ticker / event | Factor | Warehouse pre basis | Continuity | Classification |
|---|---:|---|---:|---|
| 8913 / 2018-06-04 | 0.087067 | equals source reference 18.11, not source pre 208.00 | 12.6206 | `POSSIBLE_BASIS_MISMATCH` |
| 3293 / 2022-07-27 | 0.468031 | equals source reference 366.00, not source pre 782.00 | 2.0753 | `POSSIBLE_BASIS_MISMATCH` |
| 3293 / 2024-07-24 | 0.488055 | equals source pre 1,465.00; first trade 2024-07-26 | 1.0993 | `CONTINUOUS` |
| 1808 / 2024-09-26 | 0.443096 | equals source pre 119.50 | 1.0104 | `CONTINUOUS` |

The two valid 2024 factors remain valid despite being below 0.5.

## Daily and monthly return-label impact

The 1,549 `POSSIBLE_BASIS_MISMATCH` events were linked to the currently
materialized research marts:

| Impact | Count / range |
|---|---|
| Suspicious events | 1,549 across 1,031 tickers |
| Events present in the older materialized event-date join | 1,541 |
| Non-null affected daily research labels | 1,094 across 913 tickers |
| Daily transition-date range | 2003-06-03 through 2023-05-04 |
| Affected monthly forward-return labels | 988 across 825 tickers |
| Monthly formation months | 74 |
| Monthly formation/exit range | 2010-06-15 through 2023-05-15 |

Eight suspect events have no warehouse row on the event date. The older
materialization therefore omitted their factor entirely; they are not counted as
affected labels even though their source/raw continuity remains suspicious.

For current materialized daily labels, the suspicious transition-return
distribution has median +9.22%, mean +14.53%, 95th percentile +34.05%, 99th
percentile +61.18%, and maximum +1,161.08%. Affected monthly labels have median
+10.22%, mean +16.95%, 95th percentile +50.66%, 99th percentile +98.21%, and
maximum +2,813.54%.

Important warehouse-state finding: the current BigQuery tables were last built on
2026-08-25, while commit `787e396` changed the event-date boundary on 2026-09-15.
The materialized `int_daily_prices_adjusted`, daily mart, and monthly mart therefore
do not embody the checked-in PIT boundary logic. In the materialized tables the
factor persists through the event-date price and drops on the next warehouse price
row. Thus the abnormal daily label appears on the first price date strictly after
the event. The monthly endpoint return remains contaminated when the holding
interval crosses the transition.

Examples from the materialized marts:

- 8913: event continuity implies +1,162.06%; the materialized transition occurs
  on 2018-06-05 and records +1,161.08%; the 2018-05-15 monthly label is
  +2,813.54%.
- 3293: event continuity implies +107.53%; the materialized transition occurs on
  2022-07-28 and records +110.96%; the 2022-07-15 monthly label is +155.20%.

This refresh mismatch is confirmed evidence about current warehouse state. It is
separate from the source-basis mismatch and must not be interpreted as evidence
against the newer checked-in boundary logic.

## Revenue YoY contamination

The diagnostic independently assigns Revenue YoY quintiles each formation month
with `NTILE(5) OVER (ORDER BY yoy_growth, ticker)`, matching the prior audit's
deterministic convention. It then removes only labels crossing a
`POSSIBLE_BASIS_MISMATCH`; quantile membership is not recomputed. This is a
diagnostic exclusion, not a proposed correction.

There are 988 affected Revenue YoY observations across 74 formation months and
211 affected quintile-month portfolios.

| Revenue YoY quintile | Current mean monthly return | Diagnostic mean excluding suspects | Difference |
|---:|---:|---:|---:|
| 1 | 0.6033% | 0.5589% | 0.0444 pp |
| 2 | 0.8869% | 0.8055% | 0.0814 pp |
| 3 | 1.2794% | 1.2336% | 0.0459 pp |
| 4 | 1.6873% | 1.6474% | 0.0399 pp |
| 5 | 2.0746% | 2.0206% | 0.0540 pp |

The mean Q5-minus-Q1 spread changes from 1.4713% to 1.4617% per month, a decrease
of 0.0096 percentage points. The monotonic ordering and broad Revenue YoY
conclusion survive this limited exclusion diagnostic.

Contamination is nevertheless material in individual months:

- 2018-05-15 Q2 changes from 14.8561% to 5.8281%, a 9.0280 percentage-point
  difference caused by 8913;
- 2022-07-15 Q3 changes by 1.6906 percentage points after excluding 48 suspect
  labels;
- 2022-07-15 Q2 changes by 1.5640 percentage points after excluding 47 labels;
- 2022-08-15 Q5 changes by 1.0747 percentage points after excluding 16 labels;
- 2012-07-16 Q3 changes by 1.0727 percentage points after excluding six labels.

Assessment: contamination is structural in the return data and material in some
months, but this equal-weight, single-sort exclusion diagnostic does not materially
reverse the aggregate Revenue YoY conclusion. That conclusion is limited: it does
not substitute corrected raw prices, does not recompute memberships, and does not
cover every alternative weighting or double-sort specification used outside the
warehouse marts.

## Evidence classification

### Confirmed evidence

- The warehouse contains 30,325 distinct source events and 28,785 reconstructable
  events under the stated rules.
- 852 usable events have the strong pre-close-equals-reference signature with a
  material source factor; two more have the signature but insufficient post data.
- Basis warnings exist in both markets and are sharply concentrated by year.
- Current materialized adjusted-price and research tables predate the checked-in
  event-boundary fix and place the factor transition after the event-date row.
- 1,094 daily and 988 monthly research labels link to factors actually present in
  the older materialized event-date join.
- Known bad and known valid large-factor regressions classify as expected.

### Strong inference

- A material portion of historical warehouse closes were loaded on an already
  adjusted or otherwise incompatible basis.
- The 2022 concentration and disappearance after 2023-05-03 indicate one or more
  historical ingestion/source regimes rather than random market moves.
- Historical adjusted-return results crossing pre-May-2023 actions require
  reconstruction before they can be relied on globally.

### Unverified explanations

- Which vendor, scraper version, backfill, or transformation created each basis.
- Whether every one of the 697 `MATCHES_NEITHER` warnings is adjusted-price
  contamination rather than a source-row anomaly or mapping problem.
- Event type, because it is not retained in either corporate-action source table.
- The 1,540 insufficient events, many of which are recent/future source events
  without a corresponding positive warehouse post quote.

## Remediation options — not implemented

1. Build a basis-explicit canonical raw-price source with vendor, source URL/file,
   ingestion run, original value, and adjustment-basis metadata.
2. Reconcile each action against source pre-close and reference price before use;
   quarantine basis conflicts using the invariant, never a factor-size cutoff.
3. Retain action type and underlying cash, stock distribution, rights, reduction,
   and split fields so source-reference calculations can be independently checked.
4. After source-basis repair, full-refresh the adjusted-price table and every
   downstream daily/monthly research mart using the checked-in PIT boundary logic.
5. Compare pre/post refresh labels event by event, then rerun portfolio research
   from corrected prices. Preserve both runs for auditability.
6. Add build-version/run metadata to warehouse marts so code-versus-materialization
   drift is detectable automatically.
7. Add regression fixtures for exact reference-price matches, valid large factors,
   missing event-date trades, source anomalies, and table-refresh/version checks.

## Reproducible artifacts and queries

- `analyses/corporate_action_continuity_event_audit.sql`: all events,
  reconstructions, diagnostics, classification, gaps, and era.
- `analyses/corporate_action_continuity_return_impact.sql`: suspicious-event links
  to materialized daily/monthly labels and Revenue YoY portfolio comparisons.
- `analyses/corporate_action_extreme_factor_reconstruction.sql`: prior known-case
  reconstruction retained unchanged.

SELECT-only warehouse operations executed:

1. full event-level reconstruction to CSV for aggregate analysis;
2. full suspicious-event daily/monthly and Revenue YoY linkage;
3. layer comparison across `int_daily_prices_adjusted`,
   `mart_factor_research_daily`, and known 8913/3293 dates;
4. staged-factor date check for 8913 and 3293;
5. `bq show` metadata inspection for adjusted, daily, and monthly materializations.

## Validation

- Both new dbt analyses compile successfully.
- The event query returned exactly 30,325 data rows plus its CSV header.
- No identical duplicate source rows were found after grouping all exposed source
  fields; conflicting same-key rows remain separate by design.
- Known-case classifications reproduce as required.
- No production files or warehouse objects were changed.
