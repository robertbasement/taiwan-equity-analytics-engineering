# Research Correctness Audit Report

Audit date: 2026-09-22 (Asia/Taipei)

Scope:

- analytics/dbt: this repository;
- research engine: `../../../taiwan-equity-quant-research`;
- execution backtest: `../../../GCP_stock_backtest`;
- warehouse: `stock_analytics` and `stock_data`, inspected with SELECT-only queries.

No production SQL or warehouse data was changed. The only repository changes made by
this audit are this report, three SELECT-only analyses, and warehouse-free tests.

## Executive conclusion

Historical results are **not cleared as research-correct**. The audit found a confirmed
critical corporate-action return error, material execution/universe risks, and
publication-timing assumptions that cannot be verified from the available source
schema. The portfolio aggregation code independently recomputes correctly when its
inputs are valid; that does not make the upstream return labels universally valid.

The most material confirmed example is ticker `8913`. A source adjustment factor of
`0.0870673076923077` dated 2018-06-04 makes the 2018-05-15 to 2018-06-15 adjusted-close
return `28.1354442864` (2,813.54%). In an independently reconstructed Revenue YoY
quintile, this one row changes Q2's equal-weight monthly return from 5.8824% to 14.9103%.

## Audit ratings

| Category | Rating | Highest severity | Historical results may be affected? | Basis |
|---|---|---:|---|---|
| Point-in-time correctness | UNVERIFIED | High | Yes | Policy dates and aligned dates work as coded, but raw fundamentals have no actual publication/version timestamps. |
| Corporate actions | FAIL | Critical | Yes, confirmed | `8913` produces an artificial 28.1x monthly return; 2327 logic itself validates for the curated case. |
| Return and execution timing | FAIL | High | Yes | The execution service trades next-session on a real quote, but research labels begin at the formation close and 21,595 formation rows have no positive volume. |
| Universe and survivorship | FAIL | High | Yes | Historical names are retained, but missing next-rebalance/delisting outcomes are omitted rather than economically resolved. |
| Transaction costs | UNVERIFIED | Medium | Yes | 25 bp fees are charged on actual order notional; tax, slippage, market impact, and explicit turnover reconciliation are absent. |
| Data integrity | FAIL | Critical | Yes, confirmed | Current keys are unique, but extreme corrupted returns pass existing range checks; staging duplicate policies are unsafe if duplicates arrive. |
| Portfolio construction | PASS | Low residual risk | Upstream errors can flow through | Research quantiles, weights, and returns independently recompute; the legacy backtest's tie-break depends on input order. |
| Adversarial automated tests | PASS | Low | N/A | Existing suites pass and six new deterministic audit fixtures were added. Known production defects were not changed. |
| Empirical warehouse spot checks | FAIL | Critical | Yes, confirmed | Clean reconstructions passed, but the 8913 reconstruction disproved universal adjustment correctness. |

`PASS` means the tested behavior matched its stated contract. It is not a statement that
all upstream data is economically correct. `UNVERIFIED` means the evidence needed to
make the claim does not exist in the current source contract.

## Architecture and lineage inspected

The production path is:

```text
stock_data raw relations
  -> staging views
  -> reporting-period feature models
  -> dated revenue/financial/balance events
  -> int_vbt_stack
  -> mart_vbt_master_dataset
  -> mart_factor_research_daily
  -> mart_factor_research_monthly
  -> research sorts / IC / beta / Fama-MacBeth

mart_vbt_master_dataset + raw quote evidence
  -> GCP_stock_backtest monthly selection
  -> next-market-session target-percent orders
  -> vectorbt returns net of configured fees
```

Principal files inspected:

- `models/staging/stg_daily_prices_raw.sql`
- `models/staging/stg_dividend_factor.sql`
- `models/staging/stg_monthly_revenue.sql`
- `models/staging/stg_income_statement.sql`
- `models/staging/stg_balance_sheet.sql`
- `models/intermediate/int_daily_prices_adjusted.sql`
- `models/intermediate/int_monthly_revenue_features.sql`
- `models/intermediate/int_monthly_revenue_shifter.sql`
- `models/intermediate/int_income_statement_features.sql`
- `models/intermediate/int_income_statement_shifter.sql`
- `models/intermediate/int_balance_sheet_features.sql`
- `models/intermediate/int_balance_sheet_shifter.sql`
- `models/intermediate/int_vbt_stack.sql`
- `models/marts/core/mart_vbt_master_dataset.sql`
- `models/marts/expectation/mart_expectation_features.sql`
- `models/marts/expectation/mart_expectation_dataset.sql`
- `models/marts/research/mart_factor_research_daily.sql`
- `models/marts/research/mart_factor_research_monthly.sql`
- `../../../taiwan-equity-quant-research/factor_app/monthly_dataset.py`
- `../../../taiwan-equity-quant-research/factor_app/daily_beta_dataset.py`
- `../../../taiwan-equity-quant-research/factor_research/sorting.py`
- `../../../taiwan-equity-quant-research/factor_research/portfolio.py`
- `../../../taiwan-equity-quant-research/factor_research/beta.py`
- `../../../GCP_stock_backtest/src/data_loader.py`
- `../../../GCP_stock_backtest/src/strategy_engine.py`
- `../../../GCP_stock_backtest/src/backtest_engine.py`
- all schema YAML, singular tests, audit analyses, and the three repositories' relevant test suites.

## 1. Point-in-time correctness — UNVERIFIED / High

### Feature availability map

| Feature family | Source/period date | Information/publication date | Observation/alignment date | Earliest legal signal/trade date |
|---|---|---|---|---|
| Raw close/volume | market `date` | same session, exact timestamp absent | same `date` | after that close; next session for close-derived signals |
| Adjusted close/returns | price `date` plus corporate-action effective/ex-dates | hindsight normalization by design | price row date | returns only; not an absolute historical valuation input |
| Monthly revenue and YoY/MoM/YTD | `year_month` | assumed first day of next month + 10 days (calendar day 11) | first common market date on/after policy date | aligned date for pre-existing fundamentals; next session if combined with closing-price ranks |
| Income statement/EPS/margins | `year_quarter` / quarter end | Q1 May 16, Q2 Aug 15, Q3 Nov 15, Q4 next Apr 1 | first common market date on/after policy date | aligned date, subject to policy-date assumption |
| Balance sheet/size/book value | `year_quarter` / quarter end | same quarterly policy | first common market date on/after policy date | aligned date; close-based market cap is only final after close |
| MA20/MA60/gaps | each price row through current row | current close | current market date | next market session |
| P/E, P/B, market cap | latest PIT financial state plus current effective close | mixed: statement policy date and current close | current market date | next market session when used as a close-dependent signal |
| Expectation features | latest revenue and financial state plus contemporaneous valuation | inherits all upstream assumptions | current market date | next session when implied growth uses current close |
| `forward_return` | current and exact next rebalance adjusted closes | outcome known only at next rebalance | labeled at current formation date | never legal as a formation feature |

Validated behavior:

- Warehouse counts for `revenue_aligned_date > rebalance_date`,
  `financial_aligned_date > rebalance_date`, and
  `balance_sheet_aligned_date > rebalance_date` were all zero.
- Monthly returns join the exact shared next rebalance date, not the next available
  ticker row.
- Daily rolling-beta snapshots and monthly rolling betas exclude the return labeled at
  the beta date; existing boundary tests verify this.
- Complete structs are forward-filled in the master, retaining values with their source
  period and availability lineage.

Unverified assumptions and likely risks:

- The raw revenue, income, and balance tables expose no publication timestamp,
  ingestion timestamp, amendment/version identifier, or immutable filing history.
  Therefore actual historical availability and restatement leakage cannot be proven.
- The revenue formula produces the 11th, not a captured company-specific publication
  date. A delayed filing after the policy date would leak.
- The downstream research adapter projects out all PIT lineage fields. It validates
  uniqueness but cannot re-check that aligned dates precede formation.
- `stg_income_statement` resolves duplicate ticker-quarter rows with
  `ROW_NUMBER ... ORDER BY ticker`, which is nondeterministic within the partition.
  `stg_monthly_revenue` chooses the greatest source revenue, not the latest known
  version. No duplicates exist in the current warehouse, so these are latent risks,
  not demonstrated current-result changes.

Recommended fix (not implemented): capture actual publication and ingestion/version
timestamps; select `effective_from <= signal_timestamp`; retain immutable versions;
carry lineage columns through the runtime adapter; make duplicate handling fail closed.

## 2. Corporate actions — FAIL / Critical

Validated behavior:

- Source-basis reconciliation, PIT action transitions, and hindsight price
  normalization remain conceptually separate.
- Price factors apply strictly before the event date. Existing fixtures verify
  day-before/effective-date/day-after and non-trading event boundaries.
- The 2327 example validates numerically: Q2 EPS TTM is 34.60 before transition, 8.65
  at/after the 2025-08-25 action, and Q3 filing EPS TTM becomes 9.9875 on 2025-11-17
  without applying the factor twice.
- Canonical P/E and P/B use `effective_close`; adjusted `d_close` is reserved for
  return continuity and scale-invariant technical features.

Confirmed bug:

- `stg_dividend_factor` accepts any positive `reference_price / pre_close` factor.
  For 8913 on 2018-06-04 the factor is `0.0870673076923077`. The pre-event adjusted
  close is compressed to roughly 1.6 while the post-event price is roughly 20–47,
  generating an artificial 2,813.54% monthly return.
- Nine source factors are below 0.5 (eight tickers); the minimum is the 8913 factor.
  Extreme factors are not quarantined or economically reconciled before use.
- 248 monthly labels exceed +100% in absolute value and 26 daily labels exceed 100%.
  Some may be genuine; current tests do not distinguish genuine moves from adjustment
  discontinuities.

Likely risk:

- Balance-sheet action events are not de-duplicated against filing events on the same
  date. The master uses `ANY_VALUE(bs_box)` after grouping, so a future same-day
  filing/action collision could select either state. No such collision exists for the
  current configured actions.
- Manual action coverage is limited and only 2327 is validated end to end.

Recommended fix (not implemented): introduce an action-type-aware reconciliation and
continuity test comparing pre-event adjusted close with event-date raw close; quarantine
extreme/unexplained factors; add deterministic balance-event priority; expand curated
case coverage beyond 2327.

## 3. Return and execution timing — FAIL / High

Research-mart trace:

```text
rebalance_date close -> exact next_rebalance_date close -> forward_return
```

Backtest-service trace:

```text
monthly signal close D -> first broad-market session after D
-> first positive raw quote at/after that session
-> target-percent order at adjusted close
-> later real-quote target change / exit
```

Validated behavior:

- The execution service never schedules on signal day and does not execute using a
  merely carried master close. Missing raw quotes postpone buys and sells.
- A new signal supersedes an unfilled prior target; old orders do not queue forever.
- The monthly mart does not skip two months when the exact next endpoint is missing.

Confirmed/likely problems:

- Monthly research labels use the formation close as entry. This is acceptable as a
  return label for a fundamental signal fixed before the close, but it is not executable
  for ranks that depend on that same close (size, valuation, MA gaps, implied growth).
  Those factors require a next-session entry convention.
- 21,595 monthly formation rows have null/non-positive volume; 21,214 still receive a
  realized forward label. A close/reference price is not proof of executable notional.
- The backtest uses forward-filled closes for mark-to-market. If a held security never
  quotes again, it can remain valued at its last close indefinitely while its sale is
  pending.

Recommended fix (not implemented): publish explicit `signal_timestamp`,
`scheduled_entry_date`, `actual_entry_date`, raw-quote evidence, and exit status; use a
next-session label for close-dependent signals; define suspended/delisted valuation and
liquidation rules.

## 4. Universe and survivorship — FAIL / High

Validated behavior:

- The universe is built from historical observed price rows, not from a present-day
  constituent list. Of 2,975 tickers in the monthly mart, 979 disappear more than 12
  months before the latest rebalance date. This is evidence against simple
  present-constituent survivorship filtering.
- IPOs enter only once observations exist; exact-next-date joins do not backfill future
  prices.

Confirmed/likely problems:

- 1,379 rows with a scheduled next rebalance have a null forward return. Research
  formation membership is correctly frozen, but realized portfolio calculations omit
  those rows. If missingness includes delistings or long suspensions, omission is an
  optimistic attrition bias.
- There is no security master with listing, delisting, security type, exchange, merger,
  cash-out, or delisting-return fields. ETFs and non-common-equity-looking tickers are
  present in the raw universe.
- The backtest does not assign a terminal recovery value to a security that never
  resumes trading.

Recommended fix (not implemented): add a PIT security master and explicit inclusion
rules; classify null endpoints; model delisting/cash-out returns; report coverage and
missing-return rates by formation month and portfolio.

## 5. Transaction costs — UNVERIFIED / Medium

Validated behavior:

- `run_vbt_backtest` passes `fees=0.0025` to target-percent orders. A deterministic
  round trip showed buy fee 2,493.77 on 997,506.23 traded notional and sell fee 2,743.14
  on 1,097,256.86, totaling 5,236.91. Each equals 25 bp of actual order notional.
- Underfilled Top-N portfolios retain cash instead of scaling the selected names to
  100%, matching the current strategy definition.

Unverified/absent behavior:

- No explicit turnover series reconciles weights, orders, and fees.
- Brokerage minimums, Taiwan securities transaction tax, bid/ask spread, slippage,
  market impact, price limits, partial fills, and volume participation are not modeled.
- The research platform explicitly states that it is not an execution backtester and
  applies no costs to factor portfolio returns.

Recommended fix (not implemented): define a dated cost policy by side/security type,
calculate traded notional and one-way turnover explicitly, reconcile expected versus
engine fees per order, and disclose gross and net results separately.

## 6. Data integrity — FAIL / Critical

Warehouse results:

- duplicate raw keys: price 0, revenue 0, income 0, balance 0;
- duplicate daily/monthly mart keys: 0 / 0;
- non-positive monthly adjusted closes: 0;
- non-consecutive income-statement pairs: 0 current rows;
- missing exact next-rebalance labels: 1,379;
- monthly absolute returns above 100%: 248;
- daily absolute returns above 100%: 26.

Latent bugs/risks:

- Cumulative-to-quarter subtraction uses the preceding row, not an asserted preceding
  fiscal quarter. TTM windows count four rows, not four consecutive quarters. Current
  data has no gaps, but a missing Q2 would make Q3 subtraction and later TTM values
  incorrect rather than fail.
- Raw source YAML declares relation names but no column tests, freshness, or source-grain
  uniqueness. Balance staging performs no duplicate check.
- Zero price is converted to missing and carried for up to 30 calendar days. This is
  documented valuation behavior, but it must not be confused with tradeability.

Recommended fix (not implemented): enforce source-grain and period-continuity tests;
reject ambiguous duplicates; add factor/return continuity diagnostics around every
action; distinguish quote, trade, reference price, and carried valuation explicitly.

## 7. Portfolio construction — PASS / Low residual risk

Validated behavior:

- Formation assignments do not depend on `forward_return` availability.
- Q1 is the lowest raw factor and Q5 is the highest; direction changes only spread
  orientation.
- Ties in the research platform are deterministically ordered by ticker.
- Duplicate assignment/panel keys and missing point-in-time characteristic joins fail.
- Return eligibility excludes non-finite returns and invalid value weights after
  formation, without reranking.
- On 2025-08-15, an independent Revenue YoY five-way assignment produced eligible
  counts 353/354/354/354/353. Every equal-weight sum was exactly 1.0. Equal- and
  value-weight returns exactly matched recomputation from daily endpoint prices.

Residual risk:

- The separate execution backtest uses `rank(method='first')`; its loader currently
  sorts ticker/date, making normal UI runs stable, but the function itself is sensitive
  to caller row order.
- Correct aggregation faithfully incorporates corrupted upstream returns, as the 8913
  impact demonstrates.

Recommended fix (not implemented): make the execution backtest's tie-break explicit by
ticker and add a portfolio-level quarantine/diagnostic for suspect input returns without
silently changing strategy membership.

## 8. Adversarial automated tests

New tests added to `tests/test_research_correctness_fixtures.py`:

1. duplicate source observations fail explicitly;
2. delayed actual publication overrides an earlier policy date in the audit fixture;
3. a missing exact next-rebalance price does not skip to a later price;
4. zero, negative, and missing endpoints cannot produce a return;
5. quarter continuity accepts Q4-to-Q1 and rejects missing-quarter windows;
6. a delisted/no-future-price security receives no fabricated exit return.

These complement the pre-existing corporate-action, EPS-basis, price-boundary, and Q2
availability fixtures. They are evidence and regression guards; they do not implement
production fixes.

Executed suites:

- dbt fixture suite before changes: 12 passed;
- dbt parse: passed with dbt 1.11.11 / BigQuery adapter 1.11.1;
- quantitative research suite: 162 passed;
- execution backtest suite: 33 passed;
- post-audit dbt fixture suite: 18 passed;
- production-target dbt data tests: 22 passed, 0 warnings/errors/skips.

## 9. Warehouse queries executed

All warehouse operations were SELECT-only. No dbt run/build and no DDL/DML was used.

Successful query groups:

1. `INFORMATION_SCHEMA.TABLES` inventory for `stock_analytics`.
2. Consolidated duplicate, PIT-ordering, next-date, non-positive-price, and extreme-return checks.
3. Top 40 monthly returns with formation/next dates and PIT period labels.
4. Master price paths for 8913, 2540, and 8291 around representative extreme returns.
5. Exact monthly-versus-master reconstruction for 8913 around 2018-06-04.
6. Source/manual action inventory for 8913, 2540, and 8291.
7. Extreme source-factor distribution (`daily_factor < 0.5 OR > 1.5`).
8. Income-statement quarter-continuity and TTM-gap check.
9. Raw source `INFORMATION_SCHEMA.COLUMNS` publication/version-field search.
10. Universe disappearance, zero-volume formation, and missing-exit counts.
11. Independent 2025-08-15 Revenue YoY quintile/weight/return reconstruction.
12. 8913 portfolio-impact reconstruction for 2018-05-15.
13. 2327 action-date and post-filing EPS/valuation checks.
14. Configured action versus balance-filing same-day collision check (zero rows).
15. 2330 source revenue -> policy/aligned date -> signal -> quintile -> endpoint return reconstruction.

Reusable exact SQL for the principal checks is checked in as:

- `analyses/research_correctness_audit_summary.sql`
- `analyses/research_correctness_audit_8913.sql`
- `analyses/research_correctness_audit_reconstruction.sql`

Two attempted versions of the quintile reconstruction were rejected by BigQuery before
execution because they nested analytic and aggregate functions; the corrected query is
the checked-in version. One same-day collision query was rejected for addressing a
struct field incorrectly; the corrected query returned zero rows.

## Recommended remediation order

1. **Critical:** quarantine/reconcile the 8913 factor and systematically test every
   corporate-action boundary. Recompute all affected returns and downstream research.
2. **High:** add actual publication/version data or explicitly constrain claims to
   policy-date research; retain PIT lineage in the consumer.
3. **High:** define delisting/suspension/missing-exit treatment and next-session returns
   for close-dependent signals.
4. **Medium:** add source uniqueness and consecutive-period assertions.
5. **Medium:** document and reconcile turnover, taxes, slippage, and fill assumptions.

No recommendation above was implemented during this audit.

## Final verification and exact Git state

Verification:

```text
python3 -m unittest discover -s tests -p test_research_correctness_fixtures.py -v
Ran 18 tests: OK

dbt parse --profiles-dir . --target dev
PASS

dbt compile --profiles-dir . --target dev --select [three audit analyses]
PASS; all three compiled under target/compiled

dbt test --profiles-dir . --target prod
PASS=22 WARN=0 ERROR=0 SKIP=0 TOTAL=22

git diff --check
PASS (no output)
```

Exact dbt repository status at handoff:

```text
## main...origin/main
 M tests/test_research_correctness_fixtures.py
?? analyses/research_correctness_audit_8913.sql
?? analyses/research_correctness_audit_reconstruction.sql
?? analyses/research_correctness_audit_summary.sql
?? docs/research_correctness_audit_2026-09-22.md
```

Tracked diff at handoff:

```text
tests/test_research_correctness_fixtures.py | 102 +++++++++++++++++++++++++++-
1 file changed, 101 insertions(+), 1 deletion(-)
```

The three analysis files and this report are untracked new files, so Git does not include
their contents in `git diff --stat` until staged. No file under `models/`, no seed, and no
production code was modified. `taiwan-equity-quant-research` remained clean on
`main...origin/main`. `GCP_stock_backtest` is not a Git repository. Pre-existing user
changes in sibling repositories `factor_research_streamlit` and `GCP_cloud_functions`
were inspected only where relevant and were not modified by this audit.

## Manual Validation Checklist

1. Obtain the official 8913 corporate-action notice for 2018-06-04 and reconcile
   pre-event close, reference price, post-event close, share ratio, and cash component.
2. Independently calculate 8913 total return from 2018-05-15 to 2018-06-15 from exchange
   records; compare with `28.1354442864`.
3. Review all nine source adjustment factors below 0.5 against exchange notices and
   verify day-before/effective-date/day-after continuity.
4. Reconfirm 2327 Q2 cumulative EPS 20.51, action factor 0.25, Q3 cumulative EPS 8.22,
   reconciled Q3 EPS 3.0925, and TTM EPS 9.9875 from filings.
5. Verify 2327 shares and BVPS immediately before and after 2025-08-25 against official
   capital/share records, not only implied statement shares.
6. For 2330 July 2025 revenue, verify the actual public timestamp, values 323,165,707 and
   256,953,058, and whether 2025-08-11 was legally usable before the signal.
7. Sample at least ten revenue filings published after the policy date and test whether
   the model would expose them early.
8. Sample Q1/Q2/Q3/Q4 filings around weekends/holidays and confirm the first market date
   is not earlier than actual publication time.
9. Compare historical amended filings with the warehouse to determine whether current
   rows overwrite what was known at the time.
10. Review 20 of the 1,379 missing endpoint rows; classify suspension, delisting, merger,
    new listing, data outage, and other causes.
11. For delisted securities, reconstruct cash-out or terminal recovery returns and
    compare with the current omitted-return treatment.
12. Review 20 of the 21,595 no-positive-volume formation rows and determine whether the
    recorded close was executable, indicative, stale, or an exchange reference price.
13. Recreate the 2025-08-15 Revenue YoY quintiles independently in a spreadsheet and
    confirm boundary tickers and 353/354/354/354/353 eligible counts.
14. Recompute one equal-weight and one value-weight quintile return from raw endpoint
    prices, shares, and corporate actions rather than analytical mart values.
15. Reconcile a real backtest round trip order by order: target weight, shares, price,
    traded notional, 25 bp fee, tax, and resulting cash.
16. Verify a suspended holding across two rebalance dates and confirm when a pending
    sell should execute or be written down.
17. Review IPO entry dates against listing dates and ensure no pre-listing fundamentals
    or prices enter formation.
18. Verify whether ETFs, warrants, depositary receipts, and other non-common equities
    are intended members of each research universe.
