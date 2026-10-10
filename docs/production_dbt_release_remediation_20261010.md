# Production dbt Release Remediation — 2026-10-10

## Incident and root cause

The Phase C2 issuer-origin certification was valid when performed on
2026-10-07. Its final local dbt invocation produced 240,327 monthly formation
rows, all eligible under the domestic general-industry V1 contract.

The scheduled pipeline subsequently ran Cloud Run image digest
`sha256:f41265a34c7d05547b3bf70287c262b1d7da5ac6b5b318e7b2670364c3c675b7`,
built from commit `7dc9b6eb380320e9fc53418122be93897c5fc326`. That artifact predated both
the financial quarter-adjacency change and the C2 eligibility boundary. Its
successful `CREATE OR REPLACE` build therefore restored the older broad marts.

This incident demonstrated that Git source, a built container, a Cloud Run job
configuration, and warehouse state are separate identities. A successful dbt
run proves none of the other three without explicit provenance.

## Approved release identity

| Field | Certified value |
|---|---|
| Release ID | `dbt-prod-20261010-a1324722` |
| Git SHA | `a1324722bd10bfb53f529e43147fc8d018d7a2ac` |
| Image tag | `dbt-stock:a1324722bd10bfb53f529e43147fc8d018d7a2ac` |
| Image digest | `sha256:c89884be47a19ac7021f22f470919df66feb42303d8d3af69e23bcf7fb0755f5` |
| Cloud Build | `89afdcf1-b42b-4a43-80a7-3218a841528b` |
| Cloud Run job/generation | `dbt-build` / `15` |
| Manifest | `gs://tw-stockdata-scraper-storage/dbt/releases/dbt-prod-20261010-a1324722/approved_release.json` |
| Manifest generation | `1791594690514033` |
| Manifest SHA256 | `f23c5739e4c556c98b3945ff873c5b1bfca6719a3df2415c78746b615608ca16` |

The image was built from a `git archive` of the approved SHA, not the dirty
working tree. Container-level verification against the digest ran 19 focused
tests and inspected the embedded eligibility and financial-adjacency SQL.

## Release guard

The Docker build requires and embeds the full `DBT_CODE_GIT_SHA`. For production
targets, `run_dbt.sh` invokes `release_guard.py` before `dbt deps` or `dbt build`.
The guard loads the unique approved-release manifest and requires the embedded
SHA to equal `approved_git_sha`. Missing identity, malformed manifests, and SHA
mismatches fail closed.

The manifest object was uploaded with a create-only generation precondition.
Because the bucket uses uniform bucket-level access, the dbt runner has a
conditional `roles/storage.objectViewer` binding restricted to this exact object
resource name.

Execution `dbt-build-sz4bm` demonstrated fail-closed behavior when the runner
initially lacked manifest read access: dbt did not start and no model statement
executed. After granting only the required conditional read permission, the
same image and manifest identity were retained.

The prior stale SHA `7dc9b6eb380320e9fc53418122be93897c5fc326` is rejected by
the guard because it does not equal the approved SHA.

## Production restoration and certification

The final production execution used the deployed Cloud Run path:

| Field | Value |
|---|---|
| Execution | `dbt-build-x7ffn` |
| dbt invocation | `99ec30be-3aba-4b4e-99f6-f1301db6f9de` |
| Target | `prod` |
| Result | `PASS=91 WARN=0 ERROR=0 SKIP=0 TOTAL=91` |

Financial certification:

- non-Q1 standalone values with an absent immediately preceding quarter: zero violations;
- TTM values without four actual consecutive fiscal quarters: zero violations.

V1 universe certification:

- restored monthly rows: `240,327`;
- ineligible rows: `0`;
- non-domestic rows: `0`;
- unmatched rows: `0`;
- missing or non-`ci` schema rows: `0`.

The restored row count, key fingerprint `7688365686245047390`, and full-row
fingerprint `-2339017987354039544` exactly match the time-travel C2 state at
2026-10-07 13:42 UTC. The count did not increase because no new monthly
rebalance date had occurred before this restoration.

The certified rebuild covered the income feature/shifter/stack chain, master
mart, expectation chain, security master and eligibility view, both research
marts, valuation mart, and factor dataset.

## Scheduled recurrence prevention

`vbt-pipeline-handler` still resolves `DBT_JOB_NAME=dbt-build`. Cloud Run
generation 15 is pinned to the exact certified digest and the unique manifest
URI. Scheduled executions therefore enter the same startup guard and artifact
used for this certification.

The guard does not replace semantic research tests, and this release does not
claim to resolve corporate-action completeness, revenue-growth units,
same-close execution, historical security-master dating, terminal returns, or
transaction-cost assumptions.
