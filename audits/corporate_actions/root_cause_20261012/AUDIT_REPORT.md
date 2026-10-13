# Corporate-Action Root Cause and Revenue YoY Impact Audit

Date: 2026-10-12  
Mode: diagnostic and read-only; no production mutations

## Executive conclusion

The dominant demonstrated cause is a missing capital-reduction event category. Exact official
exchange records explain **259/360 (71.94%)** material discontinuities and **122/168 (72.62%)**
of the >100% cases. This is strong evidence of a systematic omission, but not proof that every
residual anomaly is a capital reduction. The residuals remain unresolved unless another official
event source directly explains them.

Revenue YoY itself is not price-derived. The current concern is primarily label contamination:
**155/240,327 (0.0645%)** monthly observations have a material anomaly inside their forward-return
interval; 150 have eligible labels. The exact 2018-2025 Revenue YoY validation has **90/144,475
(0.0623%)** return-eligible observations directly exposed. Canonical MA lookbacks have **680/240,327
(0.2829%)** potentially exposed observations (235 MA20, 680 MA60); 388/147,225 (0.2635%) occur in
the Revenue YoY formation sample. Exposure is not proof that a research conclusion changes.

## Frozen anomaly population

- Source: prior `05_candidates_gt30.json` (571 rows), filtered with `abs(adjusted_return) > 0.50`.
- Material population: 360 transitions / 262 tickers; 336 positive and 24 negative.
- All 360 have unchanged cumulative factor and no matched current-ledger event.
- 357 follow at least one missing market session; three do not.
- Repeated anomalies: 81 tickers; maximum four for one ticker.
- Raw-ratio range: 0.045034 to 37.260870.
- Ratios within 5% of 2x/4x/5x/10x: 46 / 7 / 6 / 2. These are detector features, not event proof.

## Deterministic sample and authoritative classification

The 30-row sample combines top 10 positive, top five negative, five longest gaps, all available
no-gap cases (only three exist), five current-event controls, the 6294/5364 regressions, then fills
by absolute magnitude. Categories overlap. Ticker 2429 on 2024-07-02 is a non-material control and
is not included in the 360.

- Authoritatively classified: 8
- Unresolved: 22
- Confirmed missing corporate action: 7
- Confirmed adjustment error: 1

The sampled official reduction matches include 5364 (2013-12-10), 3095 (2022-10-31), 2348
(2012-12-28), 2408 (2014-09-09), 8941 (2013-10-18), 2364 (2021-10-08), and 8077
(2014-10-20). Official evidence fields and URLs are preserved row-by-row in
`root_cause_sample_30_final.json`.

6294 remains `UNRESOLVED` under this run's strict evidence rule because the public TPEx reduction
reference dataset begins in 2013. This does not reverse the prior regression finding; it means the
bounded official endpoint used here cannot itself certify a 2010 event.

## Official source coverage

| Source | Confirmed content | Public historical limit | Assessment |
|---|---|---|---|
| TWSE `TWTAUU` reduction reference | effective/resumption date, ticker, pre-close, reference price, reduction reason, detail key | page states 2011-01-01 onward | confirmed usable |
| TPEx `bulletin/revivt` | resumption date, ticker, pre-close, reference price, reason; detail includes suspension date, exchange ratio, cash refund and capital-increase terms | page states 2013-01 onward | confirmed usable |
| TWSE `TWT49U` / TPEx `exDailyQ` (current production inputs) | ex-right/ex-dividend reference and pre-close; includes dividend and some capital-increase mechanics | TWSE page states 2003-05-05 onward; production scraper requests current year | insufficient for reductions |
| TWSE/TPEx par-value-change reference pages | separate resumption/reference-price product | historical completeness not established here | promising, unverified |
| MOPS company announcements | issuer notices can cover older reductions and reorganizations | machine-readable completeness and stable bulk access not established here | promising for bounded residual review |
| Current manual seed | only explicitly entered events | not systematic | insufficient at scale |

The current scraper calls only the dividend/ex-right endpoints and reduces every row to
`reference_price / pre_close`. It has no systematic capital-reduction ingestion. It also cannot
distinguish free distributions from paid subscription rights; 2429 demonstrates why that matters.

## Research lineage and contamination paths

`int_monthly_revenue_features.yoy_growth_pct` -> `int_monthly_revenue_shifter.rev_box` ->
`int_vbt_stack` -> `mart_vbt_master_dataset.yoy_growth` -> `mart_factor_research_daily.yoy_growth`
-> `mart_factor_research_monthly.yoy_growth`.

The monthly mart selects the first 0050 research date on/after the 15th. `forward_return` uses exact
adjusted-price endpoints from `int_daily_prices_adjusted`, with positive observed raw endpoints.
Therefore an anomaly in `(rebalance_date, next_rebalance_date]` directly contaminates that label.
`price_ma20_gap` and `price_ma60_gap` use adjusted-close row windows and can be affected for up to
20/60 price-table rows after an anomaly. Current `market_cap`, PE and PB use `effective_close`, not
adjusted close; they are not counted in the adjusted-discontinuity feature total. Beta/volatility/
momentum are notebook-derived in alternate analyses rather than canonical monthly-mart columns, so
no unsupported single contamination count is claimed for them.

The canonical validation notebook uses `mart_factor_research_monthly`, 2018-01-01 through
2025-12-31, excludes 0050, trims date-level Revenue YoY at [P1, P99], makes deterministic quintiles,
and applies forward-return eligibility only after formation. Revenue YoY rankings therefore remain
formed from Revenue YoY, while contaminated labels can alter portfolio returns and subsequent
return-derived controls.

## Blast radius

| Measure | Count | Share |
|---|---:|---:|
| Total monthly research observations | 240,327 | 100% |
| Material anomalies inside research date span | 267 | — |
| Material anomalies with a research ticker | 300 | — |
| Unique direct-label observations | 155 | 0.0645% |
| Direct and forward-return eligible | 150 | — |
| Unique MA60-potential observations | 680 | 0.2829% |
| Unique MA20-potential observations | 235 | — |
| Revenue YoY evaluation direct/eligible | 90 / 144,475 | 0.0623% |
| Revenue YoY formation with MA potential | 388 / 147,225 | 0.2635% |

Across direct and feature paths there are 835 unique research keys, 176 tickers and 153 months.
The paths do not overlap at the same ticker-month in this result. Exact relationship detail is in
`research_exposure_details.csv`.

## Repair/quarantine scenarios

| Scenario | Correctness / effort | Measured impact and residual risk |
|---|---|---|
| A — full repair | strongest correctness; must authoritatively resolve 101 residual material cases and pre-coverage history | avoids outcome-based quarantine, but delays research and still needs event-type semantics tests |
| B — retrospective quality quarantine | quickest bounded label policy; preserve the original ex-ante formation universe | mark 155 total labels (90 current Revenue YoY eligible labels) unusable for outcome evaluation; flag 680 MA-window observations for price-control analyses. Do not use future anomalies to select securities ex ante. |
| C — hybrid | best bounded path: ingest and validate official reduction events, then quarantine residual labels/features | confirmed reduction repair addresses 132/155 direct and 585/680 feature observations; residual is 23 direct and 95 feature observations (12 and 53 in the Revenue YoY formation sample respectively) |

## Recommendation and Research-Ready status

Implementing changes is outside this audit. The smallest next action is a dry-run reconstruction of
the two official capital-reduction ledgers into a non-production comparison artifact, with explicit
event provenance and factor semantics, then rerun reverse QA. This addresses 71.9% of the material
population using direct official evidence. Separately keep paid capital increases such as 2429 out
of a generic dividend-factor rule until their self-financing return treatment is specified.

Revenue YoY signal research may proceed only under a documented **scoped label-quality policy**:
retain the original factor-formation universe and quantiles, but exclude contaminated outcomes from
retrospective performance/IC estimation and flag affected price-control windows. The overall price
layer is **not Research Ready** while 360 material discontinuities exist; the pure Revenue YoY signal
is not itself contaminated, but unrestricted return-based conclusions are not certified.

## Query accounting

- Metrics job: `624e8a0b-e31e-4859-a202-3f5574f66a02`, 104,259,079 processed / 104,857,600 billed bytes.
- Detail job: `3ab5fcc2-3c3f-48ac-a1d3-614a6461a3ff`, 104,259,079 processed / 104,857,600 billed bytes.
- Total: 208,518,158 processed / 209,715,200 billed bytes (~0.195 GiB).
- Both queries were dry-run first and contained only `WITH ... SELECT`; no BigQuery object was created.

## Production mutation statement

No production BigQuery table, GCS object, Cloud Run/Function, Pub/Sub, Scheduler, dbt model,
corporate-action factor, or research methodology was changed. All new files are local audit
scripts/results under this directory; nothing was committed or pushed.
