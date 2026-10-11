# Production dbt Release Runbook

Production deployment is an explicit local operation. Pushing Git updates the
source repository but does not build, deploy, or run production.

## Normal workflow

```bash
# Develop and validate normally.
git add ...
git commit -m "..."
git push

# Inspect the exact committed revision that would be released.
./tools/release_dbt_prod.sh --dry-run

# Build, approve, and deploy; then answer the production execution prompt.
./tools/release_dbt_prod.sh
```

Use `--yes` or `--deploy-and-run` only when an unattended invocation is
intentional. Either option suppresses the final `Run the production dbt build
now? [y/N]` prompt.

## What the command enforces

The command requires a clean `main` worktree whose exact `HEAD` equals the
freshly fetched `origin/main`. It runs the focused release-guard, financial
quarter-adjacency, and issuer-eligibility tests plus a production-target dbt
parse before building anything.

The image is built from `git archive <RELEASE_GIT_SHA>`, not from the working
directory. The release identity chain is:

```text
Git SHA
  -> SHA-tagged image with embedded DBT_CODE_GIT_SHA
  -> immutable Artifact Registry digest
  -> create-only approved_release.json
  -> Cloud Run generation pinned to the digest
  -> guarded production dbt execution
```

The tag is for human traceability. The digest is authoritative. The approved
manifest records the Git SHA and digest independently so the container startup
guard can fail closed if source and approval disagree.

The command creates and verifies the new manifest before it atomically updates
the Cloud Run job's image digest and manifest URI. Before the update, the old
image and old manifest remain paired. After it, the new pair is active. A
transition failure therefore preserves the old pair or causes execution to fail
closed; it does not authorize a mismatched image.

`--dry-run` performs Git preflight, focused local tests, and dbt parse, then
prints the planned Git SHA, image tag, release ID, manifest path, and job. It
stops before Cloud Build, image push, GCS writes, IAM changes, Cloud Run changes,
and production dbt execution.

## Inspect current production

```bash
gcloud run jobs describe dbt-build \
  --project=stock-backtest-491815 \
  --region=asia-east1 \
  --format='yaml(metadata.generation,spec.template.spec.template.spec.containers)'
```

Read the `DBT_APPROVED_RELEASE_URI` shown in the job configuration, then inspect
its immutable record:

```bash
gcloud storage cat gs://.../approved_release.json \
  --project=stock-backtest-491815
```

The Cloud Run image digest, manifest `approved_image_digest`, and embedded Git
SHA must describe the same release. Do not bypass the startup guard when they
disagree.
