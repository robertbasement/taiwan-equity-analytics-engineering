# Data & PIT Validation History

## 1. Purpose

This document records the evidence, causal reasoning, and policy decisions behind the certified V1 Taiwan equity research dataset. It is a maintenance contract, not a changelog. Its purpose is to prevent future work from rediscovering—or accidentally reintroducing—the data defects that were resolved during the 2026 validation program.

Five layers must remain conceptually separate:

| Layer | Meaning |
|---|---|
| Source truth | Exact official response or raw bytes, preserved with request metadata and checksums where practical. |
| Canonical analytical truth | Normalized values with one documented unit, key, basis, and accounting meaning. |
| Point-in-time (PIT) policy | The deterministic date on which a canonical observation may enter research. |
| Research eligibility | The securities and observations allowed into the V1 formation universe. |
| Factor methodology | Ranking, labels, portfolios, and statistics applied after the preceding contracts are satisfied. |

A scraper, processor, dbt build, or migration can complete successfully while still producing invalid research. Execution proves that code ran; it does not prove that price basis, accounting semantics, information availability, formation eligibility, or return labels are correct. Certification therefore combined source comparisons, semantic tests, deterministic hashes, migration-integrity checks, and downstream invariance checks.

This document distinguishes:

- **source facts**, such as a MOPS field being cumulative year-to-date;
- **policy decisions**, such as making Q1 financials available on May 16;
- **certified current contracts**, enforced by current code and tests; and
- **accepted limitations**, which are intentional boundaries rather than defects.

## 2. Current Certified Architecture

```text
PRICE
official TWSE/TPEx raw prices
  -> canonical daily raw prices
  -> PIT-safe corporate-action adjustment
  -> exact-endpoint Method A research labels

MONTHLY REVENUE
official MOPS raw HTML
  -> canonical monthly revenue and reported same-row YoY
  -> policy-date PIT
  -> Revenue YoY factor input

FINANCIAL STATEMENTS
MOPS t163, 2013Q1-2025Q4 + MOPS t187/OpenAPI, 2026Q1+
  -> cumulative-YTD canonical income / point-in-time canonical balance
  -> adjacent-quarter standalone conversion
  -> consecutive-quarter TTM / valuation features

SECURITY MASTER
official TWSE/TPEx company-basic OpenAPI
  -> issuer origin + official financial schema
  -> one fail-closed V1 fundamental eligibility boundary

canonical data
  -> broad feature carrier
  -> research marts and formation eligibility
  -> factor validation
```

The principal current relations are:

- `stock_data.daily_prices_partitioned`
- `stock_data.monthly_revenue`
- `stock_data.income_statement`
- `stock_data.balance_sheet`
- `stock_data.security_master` (latest certified source snapshot)
- `stock_analytics.dim_security_master`
- `int_v1_fundamental_eligibility`
- `mart_vbt_master_dataset` (intentionally broad and unfiltered)
- `mart_factor_research_daily`
- `mart_factor_research_monthly`

The implementation is described by [`architecture.md`](architecture.md), [`point_in_time_semantics.md`](point_in_time_semantics.md), the models named above, and the evidence index in Section 18. Where an older document conflicts with current tested SQL, the current model and its tests are the executable contract. In particular, the current financial feature model does enforce quarter adjacency and consecutive-quarter TTM even though an older passage in `data_contracts.md` predates that fix.

## 3. Validation Timeline / Decision Log

The validation work was dependency-ordered rather than merely chronological:

| Order | Episode | Resulting contract |
|---:|---|---|
| 1 | Price-basis and corporate-action audit | Reconstruct from official raw TWSE/TPEx prices from 2010; do not patch suspect adjusted history. |
| 2 | Placeholder-price and forward-label audit | Method A labels require valid raw current and exact-next endpoints; future validity does not filter formation. |
| 3 | PIT collision audit | Revenue and balance shifters select one deterministic latest eligible state and fail closed on unresolved payload ties. |
| 4 | Monthly-revenue source audit and migration | Official MOPS-only canonical history; retain the reported same-row prior-year comparison. |
| 5 | EPS semantic-break audit | Mixed legacy EPS cannot be repaired safely in place; replace history with official cumulative-YTD MOPS values. |
| 6 | MOPS t163 reconstruction | t163 through 2025Q4 and OpenAPI from 2026Q1 share one canonical accounting contract. |
| 7 | Missing-quarter audit | Standalone quarters require the immediately preceding fiscal quarter; TTM requires four consecutive quarters. |
| 8 | Financial PIT decision | Use conservative policy dates for eligible domestic, calendar-year, general-industry issuers. |
| 9 | Issuer-origin audit and integration | Use authoritative company-basic fields; foreign and unknown origins fail closed at one research boundary. |
| 10 | Final V1 universe certification | Underlying retained data and benchmark/calendar stayed invariant; only intended universe-dependent ranks changed. |

Sections 4–13 use a common incident template: observation, research risk, investigation, root cause, decision, implementation, certification, rejected alternatives, accepted limitation, and evidence required to reopen.

## 4. Price History / Corporate-Action Basis

### Problem

Older warehouse price history showed discontinuities inconsistent with the assumption that stored closes were unadjusted exchange prices. For a subset of corporate actions, pre-event values already appeared normalized toward the post-event basis before the official corporate-action factor was applied. Applying the official factor again created a double-adjustment signature.

### Why it mattered

Adjusted closes feed returns, momentum, valuation alignment, Method A labels, and downstream portfolio results. A basis error is multiplicative and can create implausible jumps while still passing type, uniqueness, and row-count tests.

### Investigation

The event audit compared warehouse pre/post prices, official reference prices, and corporate-action factors across 30,325 distinct events from 2003-06-02 through 2026-05-22. Of 28,785 usable events, 1,549 (5.38%) were classified as possible basis mismatches across 1,031 tickers. The evidence included 854 strong reference-price signatures and 697 other mixed-basis signatures. Representative cases included:

- `8913` on 2018-06-04: factor `0.087067`; the warehouse pre-event value was already approximately the official post-basis reference (`18.11`) while the official pre-event price was `208`, creating a strong double-adjustment signature;
- `3293` in 2022 and additional cases involving `9906`, `4994`, and `4303`; and
- a separate corrupt action mapping involving `9103`.

The population was historical and heterogeneous. In 2010–2014, 199 of 5,581 usable events (3.57%) were flagged; the largest concentration was 2022, with 629 of 2,023 usable events (31.09%). The audit found no suspect case among 4,018 usable events from 2024 onward, but the last suspect event was as recent as 2023-05-03. Legitimate extreme factors also existed—for example later events involving `3293` and `1808`—so factor magnitude alone could not identify corruption.

The audit also observed 1,094 affected daily labels and 988 affected monthly labels across 74 months in the then-materialized research output. Those are historical incident counts, not present-table counts.

### Root cause

The precise upstream legacy vendor/transformation that changed the old price basis could not be proven because the affected rows lacked durable source provenance. The evidence strongly supported a mixed or previously normalized historical price basis that was incompatible with a second application of official corporate-action factors. This conclusion is intentionally phrased as a strong inference, not an invented vendor attribution.

### Decision

The canonical contract is official raw TWSE/TPEx daily price history from the certified 2010 boundary, followed by one PIT-safe corporate-action adjustment in the analytical layer.

### Implementation

The historical price source contract was implemented in the GCP source repository:

- TWSE source: official `MI_INDEX` daily response;
- TPEx source: official `stk_wn1430` response;
- the returned source date must equal the requested date;
- TPEx dates before ROC year 100 use a three-digit ROC year (for example, `099/07/20` for 2010);
- each market response must contain the expected table/schema;
- statuses distinguish `SUCCESSFUL_TRADING_DAY`, `MARKET_CLOSED_OR_NO_DATA`, `SOURCE_ERROR`, `SCHEMA_ERROR`, and `DATE_MISMATCH`; only success and closed/no-data are terminal;
- exact raw payloads and manifests include request/source dates, status, byte identity, and checksum; and
- historical staging is isolated from production ingestion and does not publish production messages.

The certified historical archive prefix is:

```text
gs://tw-stockdata-historical-backfill/daily_prices/source_contract_v1/
```

### Certification evidence

Source-date validation, retry/status tests, deterministic archives, staging isolation, and later downstream PIT/return-label tests establish the contract. A read-only check on 2026-10-07 found `6,777,113` rows at or after 2010 in `stock_data.daily_prices_partitioned`, the same number of distinct `(ticker, date)` keys, with coverage from 2010-01-04 through 2026-10-07. The `85,593` null/nonpositive closes in that query are retained exchange missing/placeholder observations, not duplicate-key failures.

Traceability note: no durable, version-controlled price-migration report containing the final production run ID and final table fingerprint was found during preparation of this document. The official archive, current canonical relation, source-contract code, commits, and later research certifications are durable evidence of the active contract, but an exact historical migration fingerprint should not be invented.

### Rejected alternatives

- **Filter corporate actions above/below a factor threshold:** rejected because valid economic actions can have extreme factors, while corrupt basis mixtures need not cross one threshold.
- **Patch only the known suspect population:** rejected because incomplete provenance made a complete rule impossible and would preserve silent basis heterogeneity.
- **Retain legacy prices where official coverage overlaps:** rejected because row count is not worth mixed semantics.

### Remaining limitation

Certified official price history begins at 2010. Pre-2010 prices are outside the V1 certified boundary. Exchange placeholders remain source facts and must be handled explicitly rather than rewritten into prices.

### Reopen only if

Reopen the price-source decision only if reproducible official evidence shows a material error in the archived source bytes/date validation, an exchange retroactive correction not represented in the archive, or a validated pre-2010 source with an equally explicit raw-price contract. Do not reopen it because a factor result is surprising.

## 5. Price Placeholders and Method A Return Labels

### Problem

Official feeds contain hyphen placeholders and numeric zero observations. Adjusted-price construction may carry a last valid analytical price through a missing raw quote. That is useful for some state alignment, but a carried value is not a valid realized-return endpoint.

### Why it mattered

If a future valid quote is used to decide whether a security was allowed into the current formation universe, the research contains look-ahead. Conversely, using a carried price as an endpoint fabricates a tradable return. Formation eligibility and outcome-label validity are different concepts.

### Investigation

The Method A audit separately evaluated current scheduled endpoint validity, exact-next scheduled endpoint validity, formation ranks, and label production. Relative to the prior 328,791 monthly labels, exact-endpoint Method A retained 322,181 and invalidated exactly 6,610:

| Endpoint failure | Observations |
|---|---:|
| Current only | 2,714 |
| Next only | 2,762 |
| Both | 1,134 |
| Total | 6,610 |

The invalid set hash recorded by the certification was `9b1aa42cd5d4bb5c533bf5bbb14c7d410055e68a9c06d8c3660ea0c182ad1fd9`. Formation membership, ranks, and quantile assignments were invariant when only the return mask changed.

### Root cause

The prior logic did not maintain a strict boundary between an analytical carried price and an official raw-price endpoint. It could therefore produce a label in a period where one of the exact scheduled raw endpoints was not valid.

### Decision

Method A is frozen as follows. The observation/rebalance universe is determined at time `t`. A forward-return label is valid only when:

```text
current exact endpoint raw close > 0
AND
next exact scheduled endpoint raw close > 0
```

Otherwise `forward_return = NULL`.

The invalid future endpoint does **not** remove the security before current-period ranking. The model does not search for a ticker-specific next valid trading date and does not use a carried price as either label endpoint.

### Implementation

`mart_factor_research_monthly.sql` builds the current formation panel before attaching exact current and next scheduled raw/adjusted endpoints. `forward_return_eligible` requires positive raw endpoints and finite positive adjusted endpoints. The forward return is emitted only after that check.

### Certification evidence

The 6,610 invalid endpoint set reconciled exactly; the 322,181 valid labels reconciled; and ranks/quantiles remained unchanged under the label-only correction. Current tests include:

- `test_monthly_forward_return_endpoint_eligibility.sql`
- `test_monthly_forward_return_integrity.sql`
- `test_monthly_no_carried_only_return_endpoints.sql`

The deterministic PIT/Method A correction is commit `7dc9b6eb380320e9fc53418122be93897c5fc326` in this dbt repository.

### Rejected alternatives

- **Drop securities at formation if the future endpoint will be missing:** rejected as direct look-ahead.
- **Use the next ticker-specific valid date:** rejected because it changes the investment horizon by security and uses future availability to choose an endpoint.
- **Use carried adjusted closes:** rejected because a state-carried value is not evidence of an executable endpoint.

### Remaining limitation

Method A is a policy label using scheduled research endpoints; it is not a transaction-level execution simulator. Liquidity, fills, and market microstructure remain later research questions.

### Reopen only if

Reopen only if the research label definition itself is deliberately changed and validated as a new methodology. A desire for more non-null labels is not sufficient evidence.

## 6. PIT Nondeterminism

### Problem

The 2010 price-history boundary caused multiple older monthly-revenue and balance-sheet source states to align to the same first available research date. Downstream use of `ANY_VALUE` could select an arbitrary state from those collisions.

### Why it mattered

A PIT join can be free of obvious future dates yet still be nondeterministic. Two identical runs could choose different eligible historical payloads, or choose an older payload over the latest known state, changing factor values without any source-data change.

### Investigation

Before remediation, the revenue shifter had 369,110 rows but only 340,908 distinct aligned keys—28,202 excess collision rows. The boundary comparison found 294 active Revenue YoY state differences across 21 tickers and 37 research months. A representative case was ticker `1523` on 2010-01-15: an older 2008-01 YoY state (`23.79`) could be chosen instead of the latest available 2009-07 state (`-11.3`). Balance-sheet states had the analogous collapse risk.

### Root cause

Many pre-boundary policy dates mapped to the same earliest market date. The shifters allowed multiple candidate states per `(aligned_date, ticker)`, and `ANY_VALUE` was not a semantic precedence rule.

### Decision

Every PIT alignment must select exactly one deterministic state using legitimate source chronology. If two materially different payloads remain tied on all valid precedence fields, the model must fail closed rather than choose arbitrarily.

### Implementation

- Monthly revenue orders candidates by policy deadline descending, then source month descending.
- Balance sheet gives corporate-action state precedence over filing state where the existing model requires it, then orders by policy deadline descending and fiscal quarter descending.
- Rows tied on all legitimate precedence fields but containing different material payloads enter `unresolved_ties` and raise an error.
- Pre-boundary source history remains available to seed the first in-boundary state; it is not deleted merely because the market calendar starts later.

### Certification evidence

After commit `7dc9b6eb380320e9fc53418122be93897c5fc326`, the revenue shifter contained 340,908 unique aligned keys and the 294 active differences reconciled to zero. The final deterministic post-MOPS/remediation fingerprints recorded by the certification were `7c9a8417d068e10ba49a640b424be38db3d8b4eab328f71124964d69a34d1475` for the revenue shifter and the unchanged `843cf1a6741e5ab555ddb93fb5d0fc24647ef37add7314c699a2c3467650b72b` for the balance shifter. Durable tests include:

- `test_monthly_revenue_shifter_unique.sql`
- `test_balance_sheet_shifter_unique.sql`
- `test_revenue_boundary_latest_state.sql`
- `test_balance_sheet_boundary_latest_state.sql`
- `test_pit_shifter_no_lookahead.sql`
- `test_pit_shifter_unresolved_payload_ties.sql`
- `test_pit_preboundary_history_preserved.sql`

### Rejected alternatives

- **Keep `ANY_VALUE`:** rejected because SQL execution stability is not a business rule.
- **Drop all source states before 2010:** rejected because the latest pre-boundary state is legitimately known at the first research date.
- **Choose by ingestion order:** rejected because operational timing is not source chronology.

### Remaining limitation

Policy dates remain modeled availability dates, not original publication timestamps. Determinism guarantees the same eligible state is selected; it does not convert a policy-date dataset into filing-time archival PIT.

### Reopen only if

Reopen if a new source supplies a more authoritative chronology or if a test reveals materially distinct payloads tied after all legitimate precedence fields. Do not replace explicit precedence with a nondeterministic aggregate.

## 7. Monthly Revenue Source Migration

### Problem

Legacy monthly-revenue history mixed provenance and included rows not present in the current official MOPS archive. Revenue YoY could also be recomputed incorrectly from warehouse `t-12` values instead of preserving the comparison MOPS reported for the contemporaneous row.

### Why it mattered

Monthly revenue is a primary research signal. Source-basis changes, restatements, reporting-population changes, and a wrong prior-year comparator can alter Revenue YoY while all arithmetic appears internally consistent.

### Investigation

The reconstruction fetched 448 official source pages covering 224 months from 2008-01 through 2026-08. All pages passed request, checksum, and source-period validation. Normalization produced 369,110 unique rows for 2,165 tickers.

Against the then-production 349,417 rows:

- common keys: 345,880;
- exact rows: 336,818;
- official-candidate-only: 23,230;
- production-only: 3,537;
- material economic differences: 729; and
- reported YoY source differences: 558.

The focused 2009/2010 audit found exact 2009 coverage of 15,552 rows in both datasets. In 2010, the official candidate had 16,516 rows, 16,472 common keys, 44 official-only rows, and zero production-only rows. A broader 2013 reporting-basis transition explained why historical populations could change: 21 tickers present before 2013 disappeared from the current archive after 2012 (3,034 rows), and five legacy tickers (503 rows) never appeared in the current official archive. Absence from the current archive was not evidence that legacy values should remain canonical.

### Root cause

The historical warehouse was not a single reproducible official-source projection. In addition, calculating YoY from warehouse `t-12` assumes the current and prior rows share the same current-vintage reporting basis, which MOPS does not guarantee.

### Decision

Canonical monthly revenue is official MOPS-only history. Revenue YoY uses the prior-year comparator reported on the **same contemporaneous MOPS row** (`去年同月增減(%)`), not a reconstructed ratio from the current warehouse's `t-12` revenue.

The architectural principle is:

```text
Scraper preserves SOURCE TRUTH.
Processor produces ANALYTICAL TRUTH.
```

### Implementation

- The live V2 scraper preserves raw official HTML under a versioned source contract before normalization.
- Historical reconstruction uses the same shared normalization behavior.
- The canonical candidate replaced the full historical slice; no CMoney/legacy fallback and no union of the 3,537 production-only rows were allowed.
- Monthly-revenue policy availability is the 11th day of the following month, then aligned to the first market date on or after that date by the deterministic shifter.

The live V2 raw layout is rooted under:

```text
gs://tw-stockdata-monthly-storage/monthly_revenue_raw/source_contract_v2/
```

The isolated historical reconstruction evidence used:

```text
gs://tw-stockdata-monthly-storage/monthly_revenue_raw/historical_reconstruction/source_contract_v1/
```

The production-migration report records that it did not copy or modify GCS objects during that B3 execution; therefore this document does not claim that the isolated historical prefix was separately promoted into a new production prefix.

### Certification evidence

The local production-column candidate fingerprint was `f1419d4feed0a82cb3c425c197ecc0d9928bd6fd5a3d5cbff62d263c4fab55ae`; the BigQuery-normalized signed-zero-equivalent fingerprint was `03188b179c0bf146e3c636a2516e9b6f3d3166f72eac72abae5bb23524de5490`. The production source table certified exactly 369,110 MOPS rows, while all 3,537 legacy-only rows were absent and none remained active downstream. The full reconciliation is preserved in the monthly-revenue B2/B3 certification documents listed in Section 18.

Source code commits include:

- `e39bf678a99d51523e0515fba7d505ab221d2f8c` — isolated historical reconstruction;
- `27744a3fe71fe03357ac4162919276a6f2cd10e4` — raw MOPS HTML preservation.

### Rejected alternatives

- **Recompute YoY from canonical revenue at `t-12`:** rejected because it discards the contemporaneous reported basis/comparator.
- **Retain legacy-only rows for coverage:** rejected because unverifiable coverage is not canonical truth.
- **Fallback to CMoney:** rejected because it reintroduces mixed provenance.
- **Normalize inside the scraper and discard HTML:** rejected because future parser fixes would require refetching and could not reproduce exact source evidence.

### Remaining limitation

The official historical pages are current-vintage MOPS representations. Reporting changes and revisions can be reflected. The historical archive promotion status is as described above, not overstated.

### Reopen only if

Reopen the same-row YoY rule only if MOPS documentation or raw rows prove the field has changed meaning. Reopen source coverage only with official archived evidence for missing periods—not with legacy warehouse rows alone.

## 8. Financial Statement Source and EPS Semantic Break

### Problem

The old `stock_data.income_statement.eps` column did not have one accounting meaning. Monetary income fields were overwhelmingly cumulative YTD, but historical EPS mixed standalone-quarter and cumulative-YTD values. The downstream model assumed every raw EPS observation was cumulative.

### Why it mattered

Subtracting a prior cumulative EPS from an already-standalone EPS corrupts `q_eps`, which then corrupts `eps_ttm`, `eps_yoy_growth`, `pe_ttm`, implied-growth/valuation features, and any eligibility rule that depends on positive or non-null TTM EPS.

### Investigation

The Phase B1 audit compared warehouse EPS with official MOPS cumulative EPS and the implied standalone differences, using explicit rounding, missing-prior-quarter, basis/restatement, and corporate-action categories rather than treating every mismatch as corruption.

Among decisive Q2–Q4 comparisons, 53,645 matched cumulative semantics. Another 9,815 matched standalone semantics (8,771 exact and 1,044 rounding-only). The history was not separated by one clean date: 2013 was mixed, 2014–2015 was predominantly standalone, and 2016–2024 was predominantly cumulative; 2025 was essentially cumulative. This disproved the simplistic rule “all CMoney years are standalone, all OpenAPI years are cumulative.”

The impact audit identified 9,373 materially affected `q_eps` observations and 16,685 materially different comparable `eps_ttm` observations. Control tests showed decisive cumulative matches above 99.8% for revenue, operating income, and net income, establishing that the break was primarily EPS-specific.

### Root cause

The legacy construction mapped CMoney EPS directly as standalone-quarter EPS while converting monetary income fields to cumulative YTD, then merged those rows with other financial rows whose EPS was cumulative. The resulting raw column mixed semantics. dbt correctly implemented its documented cumulative assumption, but that assumption was false for part of the source history.

### Decision

Do not patch the mixed raw EPS column and do not “detect” semantics row by row in downstream SQL. Replace 2013+ history with one official source whose raw EPS is uniformly cumulative YTD.

### Implementation

The financial-source migration described in Section 9 replaced the historical slice with official MOPS t163 values. The existing downstream cumulative-to-quarter logic remained the intended architecture and was separately corrected for missing-quarter adjacency in Section 10.

### Certification evidence

The official candidate preserves t163 cumulative EPS byte-to-normalization lineage; the t163/OpenAPI overlap showed no unexplained canonical-field difference; and post-migration source and downstream checks passed. The migration commit is `dca62e50e74bfebd8fb210b60f16b7093aa5dc80` in the GCP source repository and `e0d0ae8600b6ead3ed2f8bb7f13ed1f35d97da19` in this dbt repository.

The detailed B1 row-level audit was retained in temporary analysis artifacts rather than a version-controlled Phase B1 report. The counts above were recovered and cross-checked during this documentation task; the durable B3 report certifies the replacement and current contract. This is a traceability gap, not permission to recreate mixed EPS history.

### Rejected alternatives

- **Fix downstream subtraction only:** rejected because the same raw column contained both meanings.
- **Infer semantics from date/source label alone:** rejected because the transition was mixed and not one clean boundary.
- **Treat all MOPS/warehouse mismatches as corruption:** rejected because rounding, restatement, share-basis changes, and corporate actions can produce legitimate differences.
- **Retain CMoney rows as fallback:** rejected because fallback would make the canonical semantic contract conditional again.

### Remaining limitation

Historical official data is current-vintage and can reflect later amendments. EPS share-basis effects remain handled by the existing corporate-action methodology; the migration did not redesign it.

### Reopen only if

Reopen only if official source evidence shows t163/OpenAPI EPS is not cumulative YTD for an approved schema era, or if a reproducible corporate-action case violates the separately tested factor methodology. Do not reopen to recover legacy-only coverage.

## 9. MOPS t163 Canonical Financial Reconstruction

### Problem

After the EPS break was established, the project needed a reproducible, official, schema-aware history that could join cleanly to the current t187/OpenAPI pipeline without changing the accounting contract.

### Why it mattered

A numeric match for a few tickers was insufficient. A canonical source needed complete period validation, deterministic schema mappings, preserved raw evidence, consistent units/accounting periods, balance identities, and systematic overlap with the current official feed.

### Investigation

The source audit classified MOPS t163 as a standardized official financial-statement projection. The relevant interfaces are:

- income: `t163sb04` / `ajax_t163sb04` (`綜合損益表`);
- balance: `t163sb05` / `ajax_t163sb05` (`資產負債表`).

For the V1 general-industry (`ci`) universe, t163 income values—including EPS—are cumulative YTD; balance values are point-in-time at period end; monetary values are NT$ thousands; and EPS is currency per share. The exhaustive audit validated 216/216 expected source slices through the overlap period.

The approved schema fingerprints are:

| Statement | Period | Fingerprint |
|---|---|---|
| Income | 2013Q1–2016Q4 | `bf4ac487f74be4a3` |
| Income | 2017Q1–2026Q2 | `7bf29ba09ba4f46f` |
| Balance | 2013Q1–2013Q4 | `2ef6ba0fa87a12f6` |
| Balance | 2014Q1–2014Q4 | `157f8ddb78a937d9` |
| Balance | 2015Q1–2017Q4 | `17ed7fbfdbe97715` |
| Balance | 2018Q1–2020Q1 | `7192492760e022c5` |
| Balance | 2020Q2–2026Q2 | `14cfbee6a7f86699` |

Mappings are keyed by statement/schema fingerprint and labels, not by a timeless column position. Unknown fingerprints fail closed.

The systematic 2026Q2 t163/OpenAPI overlap compared 48,350 canonical field slots and found 48,350 compatible, with zero unexplained official-source differences. All 90,295 candidate balance rows in the broader dry run satisfied the balance identity under the certified tolerance.

### Root cause

The original problem was not a deficiency in MOPS accounting data; it was a legacy mixed-source warehouse contract. t163 and t187/OpenAPI are different official projections over the MOPS issuer-reporting system and can share a canonical contract when parsed by validated schema era.

### Decision

The frozen source boundary is:

```text
2013Q1–2025Q4  -> official MOPS t163
2026Q1 onward  -> existing official MOPS t187/OpenAPI
```

V1 canonical financial semantics are limited to the ordinary general-industry `ci` schema. Financial-sector and special schemas are not made comparable by this migration.

### Implementation

The historical parser preserves exact HTML, request/source period, market, checksum, schema fingerprint, parser version, and manifest evidence. It fails closed on an unknown fingerprint. The immutable production archive is:

```text
gs://tw-stockdata-quarterly-storage/t163/
```

It contains 208 HTML objects, 104 period manifests, and the completion marker written last at:

```text
gs://tw-stockdata-quarterly-storage/t163/_releases/20261007T144439CST/release_manifest.json
```

The 2013Q1–2025Q4 production slice contains 86,428 income rows and 86,428 balance rows. Its production-column fingerprints are:

```text
income   3406e941807ebabb15a5429f4b30efbecc3733420bc8dc207ec54c4933d81547
balance  db092c5146413967f5d947c20f646aa0630a73dbd142855642ca37cfaa54973f
```

### Certification evidence

The production migration used backups, staging, an atomic income/balance transaction, immediate source certification, and a verified dbt build. The historical hashes matched the certified candidate; the 2026Q1+ fingerprints were unchanged; balance-identity failures were zero; 1,023 official-candidate-only keys were present; and 5,506 legacy-only keys were absent. Downstream changed-observation counts were 6,310 `q_revenue`, 7,102 `q_operating_income`, 6,648 `q_net_income`, 17,257 `q_eps`, 6,945 `revenue_ttm`, 8,488 `operating_income_ttm`, 7,688 `net_income_ttm`, 22,696 `eps_ttm`, 22,786 `eps_yoy_growth`, and 1,355,582 daily `pe_ttm` observations. Every difference was classified as an expected EPS correction, current-vintage revision, official-source coverage change, adjacency-null correction, or consecutive-TTM correction; the unexpected class was zero. The archive manifest/release hashes and production execution evidence are in `GCP_cloud_functions/docs/mops_t163_b3_migration_20261007.md`.

### Rejected alternatives

- **CMoney fallback or `COALESCE(MOPS, CMoney)`:** rejected because it would restore mixed semantics.
- **Keep legacy-only rows to maximize coverage:** rejected because they are outside the canonical official source.
- **Parse by fixed column position across all years:** rejected because schema eras demonstrably changed.
- **Reconstruct immutable original-as-filed vintages:** rejected as unnecessary for the stated V1 current-vintage policy.
- **Solve financial-sector comparability in this migration:** rejected as outside V1.

### Remaining limitation

t163 is current-vintage official history. Later amendments/restatements may appear in old periods. It is a condensed standardized projection and does not retain every note or filing-version metadata item. V1 fundamentals begin at 2013Q1.

### Reopen only if

Reopen if an approved official schema fingerprint changes, a systematic t163/OpenAPI overlap discrepancy appears, archived raw bytes fail their checksum, or official documentation changes the period/unit meaning. Do not reopen merely because legacy coverage is larger.

## 10. Nonadjacent Quarters and TTM

### Problem

The cumulative-to-standalone model previously subtracted the last available row, even if it was not the immediately preceding fiscal quarter. For example:

```text
Q1 cumulative EPS = 2
Q2 missing
Q3 cumulative EPS = 8
```

`8 - 2 = 6` represents Q2 plus Q3, not standalone Q3.

### Why it mattered

The error affected every cumulative field converted to a quarter and allowed a four-row rolling window with a missing fiscal quarter to masquerade as a four-quarter TTM period.

### Investigation

The t163 dry run exposed non-Q1 first observations and nonadjacent prior rows. Certification then queried all invalid/nonconsecutive cases rather than sampling only known tickers.

### Root cause

Window functions encoded “previous observed row” and “four observed rows,” not “previous fiscal quarter” and “four consecutive fiscal quarters.”

### Decision

For Q2/Q3/Q4, a standalone value is derived only when the immediately preceding fiscal quarter exists. Otherwise the derived `q_*` value is `NULL`; the raw cumulative value remains valid. TTM is emitted only for four genuinely consecutive fiscal quarters.

For EPS, adjacency is validated first. If adjacent, the existing factor-between-periods corporate-action methodology applies. Adjacency and per-share basis adjustment are separate concerns.

### Implementation

`int_income_statement_features.sql` computes fiscal-quarter ordinals and enforces adjacency for quarterly revenue, operating income, net income, EPS, and the other cumulative fields derived by that model. Its rolling measures validate the four-quarter ordinal span before emitting TTM.

### Certification evidence

Production certification inspected 10,238 non-Q1 nonadjacent rows and found zero non-null standalone violations. It inspected 17,999 invalid/nonconsecutive windows and found zero non-null TTM violations. The `2327` corporate-action regression remained:

```text
2025Q3 q_eps = 3.0925
```

Focused tests include `test_income_features_nonadjacent_quarter_null.sql`, `test_income_features_ttm_consecutive.sql`, and the corporate-action correctness fixtures. The code is part of dbt commit `e0d0ae8600b6ead3ed2f8bb7f13ed1f35d97da19`.

### Rejected alternatives

- **Subtract the previous observed row:** rejected because observation adjacency is not fiscal adjacency.
- **Carry or interpolate a missing cumulative quarter:** rejected because it invents a standalone statement.
- **Redesign corporate-action EPS logic at the same time:** rejected to keep two correctness concerns independently testable.

### Remaining limitation

Missing adjacent statements intentionally create null quarterly and potentially null TTM features. This is fail-closed behavior, not a coverage bug.

### Reopen only if

Reopen only with an authoritative source for the missing fiscal quarter or evidence that the fiscal calendar assumption is wrong for an included issuer. Never relax adjacency solely to reduce nulls.

## 11. Financial PIT Policy

### Problem

Official historical values identify accounting periods but do not by themselves provide a complete, immutable actual-publication-time history for every issuer and amendment. Backtests still require a deterministic no-look-ahead availability date.

### Why it mattered

Making a quarter available before the applicable filing window creates look-ahead. Building a purportedly precise issuer-specific engine from incomplete filing history creates false precision and a larger maintenance surface.

### Investigation

The source-semantics audit separated period end, statutory deadline, actual issuer filing date, and MOPS product/update date. It also examined whether ordinary domestic general-industry issuers formed a large or systematic population for which the simple policy would be too early. No material systematic V1 population was established once foreign-registered and special-schema issuers were excluded.

### Root cause

The project intentionally uses current-vintage official history; it does not possess a complete archive of original filing timestamps/vintages. Actual-publication PIT and policy-date PIT are therefore different products.

### Decision

The V1 financial availability policy is frozen as:

| Fiscal period | Policy availability date |
|---|---|
| Q1 | May 16 |
| Q2 | August 15 |
| Q3 | November 15 |
| Q4 | April 1 of the following year |

This is **POLICY-DATE PIT**, not reconstructed actual-publication-time PIT. It is valid for the V1 population only under the domestic, general-industry, supported calendar-year assumptions enforced by the eligibility boundary.

### Implementation

Financial shifter models derive these policy deadlines and align them to the first available research market date. Eligibility is attached once at the research boundary described in Section 12; the broad feature carrier is not globally filtered.

### Certification evidence

PIT tests prohibit future source states, enforce unique deterministic shifter keys, retain the proper pre-boundary seed state, and fail on unresolved payload ties. The issuer-origin/schema guard confines the simple policy to the population for which it was approved.

### Rejected alternatives

- **Issuer-specific historical filing engine:** rejected for V1 because the required archival coverage/complexity was not justified by a material ordinary-domestic population.
- **Use MOPS page update date as actual filing date:** rejected because product update, amendment, and original issuer filing are different concepts.
- **Apply the simple dates to every financial schema/foreign issuer:** rejected because those populations may follow different rules.

### Remaining limitation

Rare extensions, unusual fiscal years, later amendments, and filing-before-deadline differences are not modeled. Current-vintage values can be paired with conservative policy dates; that does not recreate the original information set exactly.

### Reopen only if

Reopen if evidence quantifies a large/systematic included population for which a policy date is too early, or if an authoritative complete filing-time source becomes operationally available. Isolated edge cases should first be documented or excluded, not trigger an unbounded deadline engine.

## 12. Issuer-Origin / V1 Research Universe

### Problem

The simplified financial PIT policy was intended for ordinary domestic general-industry issuers, but the research panel lacked an authoritative reusable origin guard. Company names, `-KY`, and ticker patterns are not source contracts.

### Why it mattered

Foreign-registered issuers and special financial schemas can have different filing/accounting requirements. Including them under the domestic `ci` PIT contract silently broadens the population and can contaminate formation ranks.

### Investigation

The C1 audit inspected existing metadata and official candidates, then selected the smallest explicit current-snapshot sources:

- TWSE: `https://openapi.twse.com.tw/v1/opendata/t187ap03_L`, field `外國企業註冊地國`;
- TPEx: `https://www.tpex.org.tw/openapi/v1/mopsfin_t187ap03_O`, field `Registration`, officially described as `外國企業註冊地國`.

Official t187ap06 schema-family membership supplies the independent financial schema (`ci`, `basi`, `fh`, `bd`, `ins`, `mim`). The investigation found no evidence that building a historical SCD2 origin history was materially required for V1; origin is effectively stable for a continuing listed security, while delisted/replaced issuers absent from the current snapshot can safely fail closed.

### Root cause

The prior research universe had no single authoritative join that combined market identity, issuer registration, official schema class, and source-contract validity.

### Decision

Canonical origin values are:

| Raw official value | Canonical value |
|---|---|
| Exact trimmed `－` | `DOMESTIC` |
| Recognized explicit foreign registration country | `FOREIGN_REGISTERED` |
| Null, blank, absent, or unrecognized | `UNKNOWN` |

The field proves foreign registration; it is not renamed `FIRST_LISTED_FOREIGN` without an independent authoritative listing-type source. `-KY` remains diagnostic only and is absent from production eligibility logic. Current-snapshot classification is accepted for V1; no invented `effective_from`/`effective_to` or SCD2 is used.

Eligibility requires all of:

```text
authoritative ticker + market match
AND source contract valid
AND market IN ('TWSE', 'TPEX')
AND official financial_schema_class = 'ci'
AND issuer_origin = 'DOMESTIC'
```

Unknown, unmatched, market-mismatched, foreign-registered, or non-`ci` rows are ineligible with an explicit reason.

### Implementation

Exact raw source bytes were archived at:

```text
gs://tw-stockdata-scraper-storage/security_master/issuer_origin_v1/
  2026/10/07/20261007T211328CST/
```

`stock_analytics.dim_security_master` holds the latest certified normalized snapshot. `int_v1_fundamental_eligibility` is the one reusable boundary. `mart_factor_research_daily` attaches it, and `mart_factor_research_monthly` enforces formation eligibility. `mart_vbt_master_dataset` remains broad/unfiltered so the benchmark, market calendar, and non-V1 uses are not accidentally narrowed.

### Certification evidence

The archived manifest hash is `9cce1b0843c645d373ab2fc3af92f66ce83af4295d5b173cc50d2e1f585695b2`; the normalized security-master hash is `0e4da254f8fee70005a87bba9ed67f2cf0bd9bdd3c3e1770082fbbca8c05c915`. The relevant income/balance intersection contained 1,983 tickers:

- 1,813 eligible domestic `ci`;
- 122 foreign registered;
- 42 non-general schema; and
- 6 unmatched.

The six unmatched financial tickers at certification were `3426`, `4130`, `4987`, `5371`, `6806`, and `8183`; they failed closed. Source, model, and 91/91 dbt checks passed. Source commit `e7aa6703316a284c5462a9e8c614ae7c71f2576c` and dbt commit `2a0d0cc18220c8042745b35acb764fc2a721041e` implement the guard.

### Rejected alternatives

- **`-KY` or company-name matching:** rejected because a naming convention is neither complete nor authoritative.
- **Ticker-pattern inference:** rejected because ticker format does not encode origin.
- **Manual foreign ticker list:** rejected because it is non-reproducible and drifts.
- **SCD2 now:** rejected because no material V1 need was shown and the official source is a current snapshot.
- **Filter raw canonical financial tables:** rejected because source truth and research eligibility are separate concerns.

### Remaining limitation

Current-snapshot metadata may omit delisted/replaced historical issuers. They become unmatched/unknown and are conservatively excluded. The dimension is deliberately not a comprehensive corporate master.

### Reopen only if

Reopen effective dating if authoritative history demonstrates material same-security classification changes or if current-snapshot omissions materially damage the certified 2013+ V1 universe. Reopen canonical labels only if a new official listing-type source proves a more precise category.

## 13. Final Research Universe Certification

### Problem

Adding an origin/schema guard changes formation membership. The project had to distinguish intended universe-driven rank changes from unintended changes to prices, financials, revenue, dates, benchmarks, or factor methodology.

### Why it mattered

An eligibility filter can appear to “improve” a factor simply by changing the sample. Certification must prove that retained domestic source/features stayed fixed and must not treat a post-filter performance change as alpha validation.

### Investigation

The C2 audit captured the pre-change panel and compared retained rows field by field after integration. It separately evaluated benchmark/calendar identity, underlying feature identity, eligibility removals, and expected reranking.

### Root cause

The pre-change formation universe admitted foreign-registered, unmatched/unknown, and non-general-schema observations. The data values themselves were not the cause of those securities being eligible; the missing boundary was.

### Decision

Certify the V1 formation universe only after authoritative origin plus official `ci` membership. Do not globally filter the feature carrier or change the factor method.

### Implementation

The final panel changed as follows:

| Classification | Observations |
|---|---:|
| Before guard | 254,378 |
| After guard | 240,327 |
| Removed | 14,051 |
| — `FOREIGN_REGISTERED` | 13,787 |
| — security-master unmatched / unknown | 10 |
| — non-general-industry schema | 254 |

The before panel contained 1,977 tickers; the after panel contained 1,809 eligible tickers.

### Certification evidence

- The broad daily baseline contained 6,771,705 rows and was unchanged apart from the newly attached eligibility columns.
- The monthly 240,327-row result was the exact intended eligible subset.
- The 160-row benchmark calendar and 4,102 daily observations for benchmark `0050` were invariant.
- Retained domestic raw Revenue YoY, PIT-aligned observations, financial features, price features, observation dates, and Method A endpoint values had zero unexpected differences.
- Universe removal legitimately changed 5,620 common quintile assignments and 11,827 decile assignments; Q1 and Q5 membership changed by 970 and 1,427 observations respectively.
- Across the same 159 spread months, mean Revenue YoY high-minus-low return changed from `0.0156527721` to `0.0167056639`.
- Mean raw Spearman IC over the overlapping period changed from `0.0383748595` to `0.0405281779`.

These last two statistics show that the Revenue YoY association survives the certified data/universe corrections. They do **not** prove independent alpha or a deployable strategy.

### Rejected alternatives

- **Freeze pre-filter ranks for retained names:** rejected because ranks are defined over the eligible formation universe.
- **Interpret every rank change as data corruption:** rejected because removing ineligible peers necessarily changes cross-sectional ranks.
- **Claim factor validation from improved spread/IC:** rejected because confounding, costs, stability, and multiple testing remain open.

### Remaining limitation

Certification covers data contracts and the V1 formation universe, not an investment thesis. Historical origin is current-snapshot based, financial PIT is policy-date based, and excluded financial schemas remain outside V1.

### Reopen only if

Reopen the universe integration if retained underlying values, benchmark/calendar, or factor definitions change unexpectedly; the official origin/schema source drifts; or unknown/unmatched populations breach QA thresholds. Do not reopen merely because ranks differ after a legitimate universe change.

## 14. What Is Now Frozen

“Frozen” means a future change requires explicit evidence and recertification; it does not mean the code can never evolve.

| Component | Certified decision | Do not change casually because... | Evidence required to reopen |
|---|---|---|---|
| Official raw price history | Official TWSE/TPEx raw prices from 2010+ | Legacy basis mixtures caused double adjustment. | Reproducible official discrepancy, checksum failure, or equally rigorous expanded history. |
| Corporate-action adjustment | Apply the official factor once in the PIT-safe analytical model | Source basis and adjustment basis must remain separate. | A source-documented factor/basis case that fails current regression tests. |
| Method A return labels | Valid raw close at current and exact next scheduled endpoint; invalid label is null without pre-ranking removal | Other rules either fabricate endpoints or use future validity at formation. | A deliberately specified new label method with independent look-ahead and execution validation. |
| Revenue same-row MOPS YoY | Preserve the comparator reported on the contemporaneous MOPS row | Warehouse `t-12` can have a different reporting basis/vintage. | Official documentation/raw evidence that the field meaning changed. |
| Revenue PIT alignment | 11th of following month, deterministic latest eligible state | `ANY_VALUE` collisions selected arbitrary historical states. | Authoritative availability chronology or evidence the policy is systematically early. |
| Financial source boundary | t163 2013Q1–2025Q4; OpenAPI 2026Q1+ | It is systematically overlap-certified and eliminates mixed vendor semantics. | New official-source incompatibility, archive corruption, or schema drift. |
| Cumulative raw EPS | Raw canonical EPS is cumulative YTD | Mixed raw semantics corrupted quarterly and TTM features. | Official source evidence contradicting cumulative meaning for an approved schema. |
| Quarter adjacency | Q2/Q3/Q4 standalone derivation requires immediate predecessor | Last-observed subtraction combines missing quarters. | Authoritative missing-quarter data or an included nonstandard fiscal calendar contract. |
| Consecutive-quarter TTM | Four fiscal quarters must be consecutive | Four rows do not necessarily represent four quarters. | A newly defined non-quarterly metric, separately named and validated. |
| Financial PIT policy | May 16 / Aug 15 / Nov 15 / next Apr 1 | Conservative, deterministic V1 policy avoids false publication-time precision. | Quantified material systematic look-ahead or complete authoritative filing-time history. |
| Issuer-origin source | TWSE `t187ap03_L` and TPEx `mopsfin_t187ap03_O` official fields | Names and ticker conventions are not authoritative. | An official superior field/history with clear semantics and both-market coverage. |
| `UNKNOWN` fail-closed | Unknown/unmatched origin is ineligible | Inferring domestic status can apply the wrong PIT contract. | Authoritative classification resolving the unknown. |
| General-industry requirement | Official `financial_schema_class = 'ci'` | Financial/special schemas are not conceptually comparable to general industry. | A separately designed and certified schema-specific research contract. |
| Broad feature carrier | `mart_vbt_master_dataset` remains unfiltered | Global filtering can alter benchmark/calendar and other non-V1 uses. | An architecture redesign with invariance and dependency evidence. |

## 15. Accepted Limitations

These are boundaries of the intended contract, not bugs unless an implementation violates them:

- Certified official price history begins at the 2010 boundary.
- V1 financial fundamentals begin at 2013Q1.
- MOPS t163 history is current-vintage official data, not immutable original-as-filed history; later amendments/restatements may appear.
- Financial availability is policy-date PIT, not actual historical filing/publication-time PIT.
- Monthly-revenue historical pages are current official representations; reporting-basis changes can affect historical comparisons.
- Issuer origin is a current authoritative snapshot, not an effective-dated history.
- Delisted/replaced historical issuers absent from the snapshot may fail closed.
- Financial-sector and other non-`ci` accounting schemas are outside V1.
- `UNKNOWN` and unmatched classifications are conservatively excluded.
- Rare filing extensions, unusual fiscal years, and special issuer classes are not modeled by a comprehensive deadline engine.
- Method A is a research label contract, not a simulation of fills, liquidity, or execution costs.
- Exact older price-migration run identity/fingerprint was not found in a durable version-controlled report; Section 4 records the evidence that is available.

## 16. Data Correctness vs Research Validity

The completed work establishes **data correctness and contract certification** for the V1 dataset. It does not establish that Revenue YoY—or any other factor—is independent alpha.

### Questions already addressed

- Is the price source official and on a consistent raw basis?
- Is the corporate-action adjustment applied once and without future factors?
- Are return labels based on valid exact endpoints without filtering formation on future missingness?
- Are monthly revenue and reported YoY reproducible from official MOPS source truth?
- Is PIT alignment deterministic and free of future source states under the documented policy?
- Do raw financial fields have one accounting meaning and unit?
- Does quarterly/TTM derivation respect fiscal adjacency?
- Does V1 use authoritative issuer origin and official general-industry schema membership?
- Do unknown classifications fail closed?

### Research questions still open

- monotonicity across quantiles;
- IC distribution rather than mean IC alone;
- subperiod and regime stability;
- industry dependence and neutralization;
- size, value, momentum, quality, liquidity, and volatility confounding;
- portfolio concentration and capacity;
- turnover and realistic transaction costs;
- sensitivity to rebalance/holding definitions;
- multiple testing and researcher degrees of freedom; and
- genuine out-of-sample stability.

A clean dataset is the precondition for these studies, not their conclusion. The post-eligibility improvement in Revenue YoY spread/IC is evidence that the association survives the corrections; it is not evidence that the factor is causal, independent, or tradable after costs.

## 17. Troubleshooting / Future Investigation Guide

| Symptom | Likely layer | First checks, in order |
|---|---|---|
| Unexpected raw/adjusted price jump | Price source or corporate action | Exact official raw date/market payload -> source-date/schema status -> corporate-action event/factor -> `int_daily_prices_adjusted` PIT rule. |
| Unexpected forward return | Method A endpoints | Scheduled current/next dates -> raw endpoint closes > 0 -> adjusted endpoint finiteness -> `forward_return_eligible`; never start by searching a later ticker date. |
| Missing return but visible carried price | Label validity | Confirm raw endpoint placeholder/zero; a carried analytical close is intentionally not a valid label endpoint. |
| Revenue YoY disagrees with hand calculation | MOPS source/comparator | Exact contemporaneous raw MOPS row -> reported same-row prior-year comparison -> normalized row -> revenue shifter policy/aligned state. |
| Revenue changes near 2010 boundary | PIT collision | Candidate source months/deadlines mapped to first market date -> deterministic ordering -> unresolved-tie test; do not use `ANY_VALUE`. |
| Balance state changes near boundary/event | Balance shifter | Filing vs corporate-action state precedence -> deadline/quarter order -> unique aligned key. |
| EPS disagreement | Financial semantics | Archived t163/OpenAPI raw cumulative EPS -> schema fingerprint/mapping -> immediate-quarter adjacency -> EPS factor-between-periods -> TTM consecutiveness. |
| Q3 standalone contains Q2+Q3 | Quarter adjacency | Verify Q2 key exists and fiscal ordinal differs by exactly one; expected output is null when it does not. |
| TTM appears across a gap | Rolling window | Inspect all four fiscal ordinals, not just row count. |
| Missing fundamental security | Eligibility | Security-master ticker+market match -> source-contract validity -> `ci` membership -> issuer origin -> explicit ineligibility reason. |
| Foreign security appears eligible | Security master | Raw authoritative registration field -> canonical normalization -> market match -> `int_v1_fundamental_eligibility`; search for forbidden name/`-KY` heuristics. |
| Factor rank/decile changed | Universe or factor | First prove retained underlying source/PIT values unchanged -> compare eligible universe -> inspect qcut/ranking -> only then suspect methodology. |
| Benchmark/calendar changed after eligibility work | Wrong integration boundary | Confirm `mart_vbt_master_dataset` remains broad and eligibility is enforced in research marts only. |
| Build passed but results are stale | Execution identity | Verify commit/worktree, compiled SQL, dbt version, image digest/job generation, and invocation artifact. A successful stale image is still wrong. |
| Candidate hash differs | Representation or semantics | Check column order/types, signed zero/null serialization, key order, and source checksum before assuming corruption; hashes prove identity, not correctness. |

## 18. Evidence Index

Paths are relative to this dbt project unless prefixed with the workspace root. GCS and BigQuery references are production evidence and must be inspected read-only unless a separately approved migration authorizes mutation.

### Current contracts and tests

| Evidence | Location |
|---|---|
| Architecture overview | [`docs/architecture.md`](architecture.md) |
| PIT policy and Method A | [`docs/point_in_time_semantics.md`](point_in_time_semantics.md) |
| General contracts (some historical narrative predates later fixes) | [`docs/data_contracts.md`](data_contracts.md) |
| PIT-safe price adjustment | [`models/intermediate/int_daily_prices_adjusted.sql`](../models/intermediate/int_daily_prices_adjusted.sql) |
| Revenue shifter | [`models/intermediate/int_monthly_revenue_shifter.sql`](../models/intermediate/int_monthly_revenue_shifter.sql) |
| Balance shifter | [`models/intermediate/int_balance_sheet_shifter.sql`](../models/intermediate/int_balance_sheet_shifter.sql) |
| Quarterly/TTM financial features | [`models/intermediate/int_income_statement_features.sql`](../models/intermediate/int_income_statement_features.sql) |
| Security-master staging | [`models/staging/stg_security_master.sql`](../models/staging/stg_security_master.sql) |
| Canonical security-master dimension | [`models/marts/dim_security_master.sql`](../models/marts/dim_security_master.sql) |
| V1 eligibility boundary | [`models/intermediate/int_v1_fundamental_eligibility.sql`](../models/intermediate/int_v1_fundamental_eligibility.sql) |
| Daily research integration | [`models/marts/research/mart_factor_research_daily.sql`](../models/marts/research/mart_factor_research_daily.sql) |
| Monthly formation/Method A | [`models/marts/research/mart_factor_research_monthly.sql`](../models/marts/research/mart_factor_research_monthly.sql) |
| Tests | [`tests/`](../tests/)—especially `test_income_features_*`, `test_monthly_*endpoint*`, `test_*boundary_latest_state`, `test_pit_shifter_*`, and `test_v1_*` |

### Source code and durable migration reports

| Evidence | Workspace path / production location |
|---|---|
| Price source validation | `GCP_cloud_functions/stockprice_scraper/source.py` |
| Isolated price reconstruction | `GCP_cloud_functions/stockprice_scraper/historical.py` |
| Price raw archive | `gs://tw-stockdata-historical-backfill/daily_prices/source_contract_v1/` |
| Monthly-revenue scraper/normalization | `GCP_cloud_functions/monthly_revenue_scraper/` |
| Monthly-revenue B1 report | `docs/monthly_revenue_phase_b1_report_2026-09-30.md` at workspace root |
| Monthly-revenue B2 certification | `docs/monthly_revenue_phase_b2_certification_2026-09-30.md` at workspace root |
| Monthly-revenue B3 migration | `docs/monthly_revenue_phase_b3_migration_2026-09-30.md` at workspace root |
| t163 parser/schema registry | `GCP_cloud_functions/quarterly_fin_report_scraper/t163_history.py` |
| Financial B3 preparation | `docs/financial_statement_b3_preparation.md` at workspace root |
| Financial production migration | `GCP_cloud_functions/docs/mops_t163_b3_migration_20261007.md` |
| t163 production raw archive | `gs://tw-stockdata-quarterly-storage/t163/` |
| Issuer-origin production certification | `GCP_cloud_functions/docs/issuer_origin_c2_20261007.md` |
| Issuer-origin raw archive | `gs://tw-stockdata-scraper-storage/security_master/issuer_origin_v1/2026/10/07/20261007T211328CST/` |
| Canonical tables | `stock_data.daily_prices_partitioned`, `stock_data.monthly_revenue`, `stock_data.income_statement`, `stock_data.balance_sheet` |
| Canonical security master | `stock_analytics.dim_security_master` |

The workspace-root monthly-revenue and financial-preparation documents are durable local certification artifacts but are not part of this dbt subrepository's Git history. Their decisive results are therefore also summarized in this committed document. Detailed EPS B1 and price-basis audit work was not found as a committed final report; Sections 4 and 8 explicitly preserve the verified conclusions and identify the missing traceability rather than inventing it.

### Important verified commits

| Repository | Commit | Purpose |
|---|---|---|
| dbt analytics | `787e396890a4d7d2e80631849c2a6a43156da358` | PIT-safe corporate-action adjustments. |
| GCP source | `e5c9c224f7f75f85d0892256302336faded25f4f` | Resumable official historical price backfill. |
| GCP source | `5c91f176a9e4e49fd55f8274ac19e31ffa7d17ac` | Retry handling for historical GCS writes. |
| dbt analytics | `7dc9b6eb380320e9fc53418122be93897c5fc326` | Deterministic PIT state selection and Method A endpoints. |
| GCP source | `e39bf678a99d51523e0515fba7d505ab221d2f8c` | Isolated MOPS monthly-revenue reconstruction. |
| GCP source | `27744a3fe71fe03357ac4162919276a6f2cd10e4` | Preserve raw MOPS HTML in monthly-revenue ingestion. |
| GCP source | `dca62e50e74bfebd8fb210b60f16b7093aa5dc80` | Rebuild historical financial statements from MOPS. |
| dbt analytics | `e0d0ae8600b6ead3ed2f8bb7f13ed1f35d97da19` | Financial reconstruction plus adjacency/TTM correctness. |
| GCP source | `e7aa6703316a284c5462a9e8c614ae7c71f2576c` | Authoritative issuer-origin source/archive. |
| dbt analytics | `2a0d0cc18220c8042745b35acb764fc2a721041e` | Security master and V1 eligibility integration. |

Commit identifiers were verified with `git rev-parse` during preparation of this document. Use `git show <commit>` in the named repository to inspect exact changes. Do not assume that a commit alone proves its production deployment; pair it with the corresponding migration/certification report.

## 19. Decision Principles Learned

1. **Source correctness comes before model sophistication.** A better factor model cannot repair mixed price or accounting semantics.
2. **Pipeline success is not research certification.** Code can run successfully with a stale image, a wrong basis, or look-ahead.
3. **Preserve exact raw source bytes when practical.** They make parser changes reproducible without refetching a mutable source.
4. **Separate source truth from analytical truth.** Scrapers should preserve what the authority sent; processors/models should make normalization explicit.
5. **PIT is a data contract, not merely a date join.** Availability, collision precedence, and tie failure behavior must all be deterministic.
6. **Future information must never change current formation eligibility.** Outcome validity belongs to the label, not the ranking universe.
7. **Fail closed when validity is uncertain.** Null quarterly values, unknown origin, and unresolved ties are safer than invented certainty.
8. **Hashes prove identity and integrity, not semantic correctness.** A perfectly reproducible wrong dataset is still wrong.
9. **Atomic transactions prove all-or-nothing mutation, not data validity.** Semantic checks are still required before and after replacement.
10. **Certification requires semantic tests and migration-integrity checks.** Row counts, source comparisons, invariance, and rollback evidence answer different questions.
11. **Prefer authoritative reconstruction over symptom patching.** Rebuilding official price, revenue, and financial history removed entire classes of ambiguity.
12. **Do not maximize coverage at the expense of a coherent contract.** Legacy-only and unknown rows were deliberately excluded where their meaning could not be certified.
13. **Add complexity only when evidence shows it is necessary.** V1 did not build SCD2 issuer origin, filing-time archives, or financial-sector comparability without a material requirement.
14. **Keep research conclusions downstream of data certification.** A surviving association deserves further study; it is not automatically alpha.
