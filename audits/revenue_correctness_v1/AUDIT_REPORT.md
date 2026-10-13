# Revenue Data Correctness V1

Audit date: 2026-10-13 (Asia/Taipei). Scope is Revenue YoY unit semantics, monthly calendar
continuity, and the canonical 2018–2025 quality-aware Revenue YoY regression. Corporate actions and
Research Quality Layer V1 methodology were not changed.

## Decision

Revenue YoY V1 is ready for independent predictive-power research under the existing Research
Quality Layer V1 policy. The canonical signal, ranks, quintiles, and quality-aware metrics are
unchanged. This decision does not certify all expectation factors or the entire financial platform,
and the corrected dbt source has not been deployed in this task.

## Source-unit contract

The official field is MOPS `去年同月增減(%)`: percentage points. The shared production/history
normalizer finds that exact heading and applies `safe_float` without scaling. A preserved fixture
maps an official value of `25.0` to `yoy_growth_pct = 25.0`.

Independent warehouse evidence agrees:

- 369,110 unique monthly observations; 366,993 non-null YoY values;
- 366,726 recomputable observations were closer to percentage-point semantics;
- zero were closer to decimal-fraction semantics; and
- 366,432 agreed with the percentage-point recomputation within 0.011 percentage points.

The old expectation CASE divided values only when `ABS(yoy_growth) > 1`. It therefore treated
non-zero percentage-point values in `[-1, 1]` as decimals. There are 11,687 such rows across 1,897
tickers and all 224 revenue months from 2008-01 through 2026-08. Zero and NULL were already
numerically safe; large values are retained without clipping.

The correction is explicit `yoy_growth_pct / 100.0` inside `mart_expectation_features`. The
canonical rank signal remains in documented percentage points because it is not an arithmetic
decimal-growth input.

## Unit blast radius

The conditional conversion changed 32,441 three-month averages, 59,449 six-month averages, and
58,826 `expected_revenue_growth` monthly feature rows. It maps into 41,681 monthly research rows'
expectation columns. Downstream arithmetic includes forward revenue, forward income, forward EPS,
forward constant growth, expectation gap, expectation signals, valuation datasets, and expectation
research fields.

It did not alter the canonical `mart_factor_research_monthly.yoy_growth`: the source-to-research
comparison found zero joined mismatches. Therefore canonical Revenue YoY values, rankings, and
quintiles were not wrong because of this CASE.

## Calendar continuity

The source contains 165 gaps across 116 tickers. No duplicate raw ticker-month keys currently
exist. Gap distribution:

| Missing months | Gaps |
|---|---:|
| 1 | 51 |
| 2–5 | 45 |
| 6–11 | 54 |
| 12+ | 15 |

Median missing months is 2; maximum is 60. Ticker 4749 has the required regression gap from
2016-07 to 2021-08, missing 60 months.

Previous row windows crossed these gaps. Exact effects are 1,180 TTM rows, 307 three-month average
rows, 742 six-month average rows, and 1,425 unique rolling-feature rows across 158 revenue months.
At the canonical research-panel grain, 54 observations across six tickers and 42 rebalance months
carry a calendar-affected auxiliary feature. In addition, 331 positive-streak counts and 52
triple-increase signals crossed gaps.

The correction segments each ticker whenever the current month is not exactly one calendar month
after the preceding row:

- TTM is valid only with 12 non-null revenue values inside one consecutive segment.
- Three- and six-month averages retain intentional partial warm-up, but reset at every gap.
- NULL YoY values remain NULL and are ignored by `AVG`.
- NULL revenue prevents a full TTM window.
- Streak and triple-increase calculations require actual adjacent months.
- No missing month is synthesized or forward-filled.

Unit and continuity corrections together change 59,399 monthly expected-growth values and 41,695
research-row expectation values. They do not change canonical Revenue YoY.

Internal data alone does not prove whether each gap represents a source boundary, listing-history
change, or reporting-history change. That unresolved classification does not justify bridging the
gap and is not required for this conservative reset policy.

## Canonical research regression

The comparison reuses the certified Research Quality Layer V1 labels and the established 2018–2025
method: benchmark 0050 excluded, inclusive P1/P99 monthly trim, deterministic ticker tie-break,
five position quantiles, equal weighting, and Newey-West lag 3. Evaluation uses
`forward_return_research`.

| Metric | Before | After |
|---|---:|---:|
| Formation observations | 147,225 | 147,225 |
| Return-eligible observations | 144,384 | 144,384 |
| Changed Revenue YoY values | – | 0 |
| Changed rankings | – | 0 |
| Changed quintiles | – | 0 |
| Mean monthly Spearman IC | 0.0379632562 | 0.0379632562 |
| ICIR | 0.5199069981 | 0.5199069981 |
| Q1 mean return | 0.0066625103 | 0.0066625103 |
| Q2 mean return | 0.0079464577 | 0.0079464577 |
| Q3 mean return | 0.0124356003 | 0.0124356003 |
| Q4 mean return | 0.0162337440 | 0.0162337440 |
| Q5 mean return | 0.0229433815 | 0.0229433815 |
| Q5−Q1 | 0.0162808711 | 0.0162808711 |
| Newey-West t-statistic | 6.6452227025 | 6.6452227025 |
| Newey-West p-value | 3.0276e-11 | 3.0276e-11 |
| Positive spread months | 77.0833% | 77.0833% |

No factor month changes. The predictive conclusion is identical because neither corrected path
feeds the canonical `yoy_growth` value or its formation cohort.

## Implementation and validation

Changed dbt models:

- `models/marts/expectation/mart_expectation_features.sql`
- `models/intermediate/int_monthly_revenue_features.sql`

Documentation-only contract changes:

- `docs/data_contracts.md`
- `models/marts/research/mart_factor_research.yml`

Focused dbt tests:

- `tests/test_stg_monthly_revenue_unique.sql`
- `tests/test_revenue_trend_requires_calendar_continuity.sql`
- `tests/test_expectation_revenue_features_contract.sql`

Validation performed:

```text
python audits/revenue_correctness_v1/test_revenue_correctness_v1.py  # 9/9 passed
dbt parse --target dev --profiles-dir .                              # passed
dbt compile --target dev --profiles-dir . --select ...               # passed
python audits/revenue_correctness_v1/dry_run_compiled.py             # 5/5 dry runs passed
git diff --check                                                     # passed
```

The compiled model dry runs used the isolated `stock_analytics_dev` target and did not execute or
materialize queries. The largest estimate was 1,446,305,343 bytes for the expectation view.

Six executed diagnostic jobs were all SELECT-only and processed 79,639,418 bytes in total. Their
IDs and per-job costs are in `bigquery_jobs.json`.

No dbt build/test materialization was run, even against dev. No production BigQuery data, GCS
object, Cloud Run job, Scheduler, corporate-action logic, price logic, financial-statement model,
or Research Quality Layer artifact was changed.

## Remaining limitations

1. Production still contains the pre-fix compiled logic because deployment was explicitly out of scope.
2. Post-fix values are validated by read-only simulation and compiled-query dry runs, not by a materialized dev build.
3. The causes of individual historical calendar gaps remain unclassified.
4. Canonical `yoy_growth` remains percentage points by contract; decimal consumers must convert explicitly.
5. This work certifies scoped Revenue YoY V1, not every expectation factor or the full financial-data platform.

## Smallest next step

Review these two model diffs and three tests, then use the explicit dbt production release command
in a separately authorized deployment task. After deployment, run the three singular tests and
confirm the documented expectation-feature counts without changing Revenue YoY formation.
