# Point-in-time semantics

This project is point-in-time-oriented. It implements explicit information-availability and corporate-action boundaries, but it does not possess complete historical publication timestamps or immutable versions of every filing.

## Why point in time matters

A reporting period describes when economic activity occurred, not when a researcher could have known its reported value. Joining a 2025 Q2 statement directly to all dates in Q2 would expose information before publication and create look-ahead bias.

Per-share measures add another temporal problem: a split or denomination change can put adjacent cumulative EPS filings on different share bases. Research data must reconcile those bases without rewriting observations using actions that had not yet happened.

The project therefore models accounting time, assumed information time, market time, and corporate-action time separately.

## Four different dates

| Date concept | Meaning |
|---|---|
| Accounting/reporting period | The month or quarter described by the source row. Examples: `2025-06` and `2025-2`. |
| Assumed availability date | A policy date used when the actual historical publication timestamp is unavailable. It is stored as a domain-specific `*_deadline_date`. |
| Aligned market date | The first date in the market calendar on or after the policy date. It is stored as a domain-specific `*_aligned_date`. |
| Corporate-action effective date | The date a configured share/per-share/price basis transition becomes effective. |

The source-period labels and policy/aligned dates remain attached to forwarded values. An aligned date is not presented as an actual announcement timestamp.

## Monthly revenue

For a source `year_month`, the current policy is:

```text
first day of source month
+ 1 month
+ 10 days
= day 11 of the following month
```

For example, `2025-03` receives a policy deadline of `2025-04-11`. The revenue shifter then selects the first market date on or after that deadline. This is a conservative availability assumption, not a recovered publication timestamp.

The event retains:

- `data_month_label` as source-period lineage;
- `deadline_date` as policy lineage; and
- `aligned_date` as market-calendar lineage.

## Income statement

The income-statement shifter currently assigns these dates:

| Fiscal quarter | Assumed availability date |
|---|---|
| Q1 | May 16 of the same year |
| Q2 | August 15 of the same year |
| Q3 | November 15 of the same year |
| Q4 | April 1 of the following year |

Each deadline is aligned to the first date in the market calendar on or after it. The resulting filing event contains the derived financial snapshot plus `year_quarter`, `deadline_date`, and `aligned_date`.

These are project research policies. They are not claims about each company's actual historical filing timestamp.

## Balance sheet

The balance-sheet shifter uses a separate policy table:

| Fiscal quarter | Assumed availability date |
|---|---|
| Q1 | May 16 of the same year |
| Q2 | August 15 of the same year |
| Q3 | November 15 of the same year |
| Q4 | April 1 of the following year |

The Q2 balance-sheet date matches the income-statement Q2 date so an August 15 formation snapshot does not mix Q2 income with Q1 balance-sheet state solely because of different availability policies.

As with income statements, the deadline is aligned to the first market date on or after it and is not an actual publication timestamp.

## Whole-snapshot forwarding

Revenue, income, and balance-sheet events enter `int_vbt_stack` as separate structs. `mart_vbt_master_dataset` forward-fills each complete struct with `LAST_VALUE(... IGNORE NULLS)`.

Forward-filling the complete snapshot matters because independently filling scalar columns could combine:

- a value from one filing;
- a source-period label from another; and
- an availability date from a third.

The struct boundary keeps each value family attached to the observation and lineage that produced it.

## Corporate actions: two responsibilities

Corporate-action logic appears in both the financial feature layer and the event shifter because those layers answer different questions.

### Feature layer: reporting-basis reconciliation

The feature layer determines economically compatible quarter, TTM, and comparison measures for a financial reporting period. Its corporate-action boundary is based on reporting-period ends.

### Shifter layer: observation-date transition

The shifter determines what a researcher knows on a market date. Once an action becomes effective, it transitions an already-known per-share financial state on that date and carries that state until a later filing replaces it.

Putting all action logic in either layer would conflate financial reporting basis with information availability.

## EPS reporting-basis reconciliation

Income-statement EPS is cumulative within a fiscal year. Without a corporate action, a later single-quarter value is:

```text
current cumulative EPS - previous cumulative EPS
```

If one or more per-share actions occur between the two period ends, the previous cumulative operand must first be converted to the current filing basis:

```text
factor_between_periods = product(per_share_factor)

for actions satisfying:
previous_period_end < effective_date <= current_period_end

previous_ytd_eps_on_current_basis =
    previous_ytd_eps × factor_between_periods

q_eps =
    current_ytd_eps - previous_ytd_eps_on_current_basis
```

This logic has four important properties:

1. It converts only the operand needed for the current calculation; it does not overwrite the earlier historical row.
2. An action after the current reporting-period end is excluded.
3. Multiple action factors multiply.
4. TTM components and prior-year comparison operands are converted to the current reporting-period basis before summation or comparison.

### 2327 example

For Yageo / 國巨 `2327`, the configured action became effective on 2025-08-25 with `per_share_factor = 0.25`. It falls between the Q2 and Q3 period ends.

```text
Q2 cumulative EPS on Q3 basis = 20.51 × 0.25 = 5.1275
Q3 single-quarter EPS          = 8.22 - 5.1275 = 3.0925
Q3 basis-consistent EPS TTM    = 9.9875
```

The prior-year Q3 comparison operand is similarly converted from `7.02` to `1.755`, producing a basis-compatible YoY comparison. These values are empirical regression evidence for this case, not universal accounting rules.

## Observation-date transition

The income shifter creates two event types:

- filing events, representing a new financial snapshot on its aligned availability date; and
- corporate-action events, rebasing the latest observable filing state on the action's effective date.

For a filing event, the shifter applies only actions after the statement's reporting-basis date and on or before its availability date. For a later action event, it begins with the most recent observable filing and applies actions after that filing event through the current action date.

This produces the intended `2327` timeline:

```text
2025-08-15  Q2 filing state, pre-action EPS basis
2025-08-25  known Q2 per-share state transitions by 0.25
2025-11-17  Q3 filing replaces the state on its already post-action basis
```

The first post-action filing is not multiplied by `0.25` again because its feature values were already constructed on the Q3 reporting basis.

The balance-sheet shifter also creates filing and corporate-action events for shares and BVPS. Its current canonical filing fields retain the source contemporaneous basis, while later action events multiply shares and per-share state as appropriate. Same-day and period-end-to-filing balance-action cases are not independently protected by the current fixture suite and remain a documented validation gap.

## Price semantics

The project intentionally maintains two price meanings.

### `effective_close`

`effective_close` is a contemporaneous price level. A positive source close is used directly; on source rows without a positive close, the most recent valid close may be carried for up to 30 calendar days.

Canonical P/E, P/B, and market capitalization use `effective_close` because a future-adjusted historical price is not an observable historical valuation level.

### `adj_close` and `d_close`

`adj_close` is a hindsight-normalized price series used for return continuity and scale-invariant technical calculations. `mart_vbt_master_dataset` publishes that field under the historical name `d_close`.

For both source dividend factors and configured manual price factors, an event factor applies only to price dates strictly before its event/effective date. It does not adjust the event-date price itself. Non-trading event dates are placed in the factor timeline so the boundary remains correct even without a same-day price row.

Applying known future adjustment factors to older prices is intentional for constructing a comparable return series. Using that adjusted price as the absolute price in a historical valuation multiple would be inappropriate. The canonical marts therefore separate `d_close` return usage from `effective_close` valuation usage.

## Forward labels

The monthly research panel defines a shared rebalance calendar from benchmark ticker `0050`: the first benchmark market date on or after the 15th of each month.

At a rebalance date:

- revenue, financial, valuation, size, expectation, and technical characteristics are formation-time fields;
- `next_rebalance_date` is the next date in the shared calendar;
- `forward_return` compares the ticker's adjusted price on the exact current and next rebalance dates; and
- `market_return` makes the same comparison for `0050`.

The next price is joined on the exact scheduled date. If a ticker lacks that date, the label is null rather than silently jumping to a later observation.

Future return labels must be outcomes, never feature inputs for the same formation date.

## Empirical validation

Three validation layers serve different purposes:

1. [`tests/test_research_correctness_fixtures.py`](../tests/test_research_correctness_fixtures.py) provides warehouse-free economic fixtures and production-boundary checks.
2. [`analyses/corporate_action_eps_validation.sql`](../analyses/corporate_action_eps_validation.sql) provides a generic, warehouse-backed action-period diagnostic.
3. [`analyses/yageo_2327_corporate_action_case_study.sql`](../analyses/yageo_2327_corporate_action_case_study.sql) replays the price, financial, PIT-event, valuation, and implied-share chain for the one usable equity action case.

[`analyses/corporate_action_coverage.sql`](../analyses/corporate_action_coverage.sql) explains why not every configured action can support the same financial-statement validation.

Yageo `2327` is evidence that the implemented mechanism works for the observed source transition. It is not proof that every source or future action restates historical EPS in the same way.

## Known PIT limitations

- Monthly and quarterly availability dates are policies, not complete actual publication histories.
- The warehouse does not retain immutable filing snapshots.
- An explicit historical re-fetch can replace the filing basis previously observed for an old quarter.
- Only one usable equity corporate-action case has been validated end to end.
- Manual action coverage and checked-in provenance are limited.
- Shares outstanding are inferred from statement fields and are not authoritative exchange-reported counts.
- Source/staging uniqueness and deterministic version selection are not complete, particularly for balance sheets.

These limitations are why the repository uses the term **point-in-time-oriented** rather than claiming universal PIT safety.

## Glossary

| Term | Meaning in this repository |
|---|---|
| `vbt` | Historical/internal model naming convention; no expansion is asserted. |
| `effective_close` | Contemporaneous price level used for valuation and market capitalization. |
| `adj_close` | Adjusted return-series price produced by the price model. |
| `d_close` | Master/research-mart name for `adj_close`. |
| `deadline_date` | Policy-based assumed information-availability date. |
| `aligned_date` | First market date on or after a policy deadline; not an actual filing timestamp. |
| Source-period label | `revenue_month`, `report_quarter`, or `balance_sheet_quarter`; the current schema does not expose a generic literal `source_*_date`. |
| `rebalance_date` | First `0050` market date on or after the 15th of a research month. |
| `next_rebalance_date` | Exact following date in that shared rebalance calendar. |
