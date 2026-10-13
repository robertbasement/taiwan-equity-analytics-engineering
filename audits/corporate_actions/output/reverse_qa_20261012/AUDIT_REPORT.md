# Corporate-Action Reverse QA Audit

Generated: 2026-10-12T03:47:51.833596Z

All warehouse operations were SELECT-only. Valid observations require raw close > 0; carried effective_close rows are not observation endpoints.

## Coverage

- Valid transitions: 6,691,275
- Tickers: 2,203
- Actual BigQuery bytes processed: 1,642,153,802

## Threshold counts

| Threshold | Raw | Adjusted | Raw/no event | Adjusted/no event | Explained |
|---:|---:|---:|---:|---:|---:|
| 30% | 570 | 538 | 538 | 537 | 32 |
| 40% | 429 | 419 | 418 | 418 | 11 |
| 50% | 367 | 360 | 360 | 360 | 7 |

## Empirical distribution

| Series | p90 abs | p95 abs | p99 abs | p99.5 abs | p99.9 abs | max abs | >30% | >50% | >100% |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Raw | 3.7538% | 5.6417% | 9.8513% | 9.9448% | 10.0000% | 3626.0870% | 570 | 367 | 168 |
| Adjusted | 3.7234% | 5.5882% | 9.8446% | 9.9415% | 10.0000% | 3626.0870% | 538 | 360 | 168 |

## Gap evidence

| Basis | Group | Transitions | Raw >30% | Adjusted >30% | Adjusted >50% |
|---|---|---:|---:|---:|---:|
| CALENDAR_GAP | <=4_DAYS | 6,594,325 | 44 | 15 | 3 |
| CALENDAR_GAP | >4_DAYS | 96,950 | 526 | 523 | 357 |
| MISSING_MARKET_SESSIONS | NONE | 6,629,510 | 43 | 13 | 3 |
| MISSING_MARKET_SESSIONS | ONE_OR_MORE | 50,434 | 527 | 525 | 357 |
| MISSING_MARKET_SESSIONS | UNKNOWN | 11,331 | 0 | 0 | 0 |

Quote gaps are a strong prioritization feature, not a complete detector: 13 adjusted >30% transitions and 3 adjusted >50% transitions have no missing 0050 market session.

## Explanation matrix

- A_EXPLAINED_BY_EXISTING_ADJUSTMENT: 32
- C_UNEXPLAINED_NO_SESSION_GAP: 12
- D_UNEXPLAINED_AFTER_QUOTE_GAP: 525
- E_ADJUSTMENT_CREATES_EXTREME_RETURN: 1
- OTHER: 1

## Regression cases

- 6294: 2010-01-26 -> 2010-02-22; raw 1.13 -> 40.65 (34.973451); adjusted return 34.973451; missing market sessions 12; existing event False; generic >30% detector True.
- 5364: 2013-11-27 -> 2013-12-10; raw 1.15 -> 42.85 (36.260870); adjusted return 36.260870; missing market sessions 8; existing event False; generic >30% detector True.

## Initial materiality view

At a 50% adjusted-return threshold, 360 transitions have no event in the current ledger. These are unexplained candidates, not confirmed corporate actions.

The smallest robust permanent gate is: automatic PASS when a raw >30% transition has an interval event whose ledger factor reconciles to the cumulative-factor change and adjusted return is <=30%; REVIEW every raw or adjusted move >30%; hard research-data FAIL while any adjusted move >50% lacks authoritative classification. Missing-session count raises review priority but never determines the classification.

Gap counts are in `04_gap_counts.csv`. Candidate details, cumulative factors, interval event arrays, and the top 50/200 rankings are in the adjacent machine-readable files.

## Most extreme unexplained transitions

| Ticker | Previous | Current | Raw return | Adjusted return | Missing sessions |
|---|---|---|---:|---:|---:|
| 5364 | 2013-11-27 | 2013-12-10 | 3626.0870% | 3626.0870% | 8 |
| 6294 | 2010-01-26 | 2010-02-22 | 3497.3451% | 3497.3451% | 12 |
| 6240 | 2011-02-09 | 2011-02-22 | 1610.6383% | 1610.6383% | 8 |
| 8934 | 2012-01-18 | 2012-02-22 | 1063.4615% | 1063.4615% | 18 |
| 3095 | 2022-10-19 | 2022-10-31 | 983.0325% | 983.0325% | 7 |
| 2348 | 2012-12-14 | 2012-12-28 | 923.2143% | 923.2143% | 10 |
| 1529 | 2018-12-12 | 2018-12-24 | 853.3898% | 853.3898% | 8 |
| 2408 | 2014-08-25 | 2014-09-09 | 832.0988% | 832.0988% | 9 |
| 8941 | 2013-10-04 | 2013-10-18 | 830.6452% | 830.6452% | 8 |
| 5011 | 2010-10-15 | 2010-11-18 | 830.0000% | 830.0000% | 23 |

## Next step

Authoritatively verify only the bounded material unexplained set. Do not derive factors from price jumps. Classify each as missing event, source-basis problem, adjustment error, or confirmed market move before changing any production data.
