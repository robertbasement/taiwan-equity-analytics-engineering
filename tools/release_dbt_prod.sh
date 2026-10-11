#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-stock-backtest-491815}"
REGION="${REGION:-asia-east1}"
CLOUD_RUN_JOB="${CLOUD_RUN_JOB:-dbt-build}"
PRODUCTION_BRANCH="${PRODUCTION_BRANCH:-main}"
IMAGE_REPOSITORY="${IMAGE_REPOSITORY:-asia-east1-docker.pkg.dev/stock-backtest-491815/dbt-jobs/dbt-stock}"
RELEASE_BUCKET="${RELEASE_BUCKET:-tw-stockdata-scraper-storage}"
DBT_RUNNER_SERVICE_ACCOUNT="${DBT_RUNNER_SERVICE_ACCOUNT:-dbt-runner@stock-backtest-491815.iam.gserviceaccount.com}"
GCLOUD_BIN="${GCLOUD_BIN:-gcloud}"
GIT_BIN="${GIT_BIN:-git}"

DRY_RUN=false
RUN_WITHOUT_PROMPT=false
RELEASE_GIT_SHA=""
IMAGE_TAG=""
IMAGE_DIGEST=""
IMAGE_REF=""
RELEASE_ID=""
MANIFEST_URI=""
MANIFEST_GENERATION=""
MANIFEST_SHA256=""
CLOUD_RUN_GENERATION=""
PRODUCTION_EXECUTION="NOT RUN"
RELEASE_STATUS="NOT STARTED"
TEMP_ROOT=""

usage() {
  cat <<'EOF'
Usage: ./tools/release_dbt_prod.sh [--dry-run] [--yes|--deploy-and-run] [--help]

Explicitly release the committed and pushed main revision to the production
dbt Cloud Run job. A git push alone never deploys production.

Developer workflow:
  git add ...
  git commit -m "..."
  git push
  ./tools/release_dbt_prod.sh --dry-run
  ./tools/release_dbt_prod.sh

Options:
  --dry-run         Run Git and local validation and print the planned release.
                    Stops before image build/push, GCS writes, Cloud Run update,
                    or production execution.
  --yes             Build, deploy, and run production without the final prompt.
  --deploy-and-run  Alias for --yes.
  --help            Show this help.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$TEMP_ROOT" && -d "$TEMP_ROOT" ]]; then
    rm -rf -- "$TEMP_ROOT"
  fi
}

validate_git_sha() {
  [[ "${1:-}" =~ ^[0-9a-f]{40}$ ]] || die "Git SHA must be a full lowercase 40-character SHA."
}

validate_image_digest() {
  [[ "${1:-}" =~ ^sha256:[0-9a-f]{64}$ ]] || die "Image digest is malformed or is not an immutable sha256 digest."
}

require_equal() {
  local label="$1" expected="$2" actual="$3"
  [[ "$expected" == "$actual" ]] || die "$label mismatch: expected '$expected', got '$actual'."
}

run_gcloud() {
  "$GCLOUD_BIN" "$@"
}

repo_root() {
  "$GIT_BIN" rev-parse --show-toplevel 2>/dev/null || die "This command must run inside a Git repository."
}

preflight_git() {
  local branch origin_sha

  RELEASE_GIT_SHA=$("$GIT_BIN" rev-parse --verify HEAD^{commit} 2>/dev/null) || die "HEAD is not a committed Git revision."
  validate_git_sha "$RELEASE_GIT_SHA"

  if [[ -n "$("$GIT_BIN" status --porcelain --untracked-files=all)" ]]; then
    die "Working tree is not clean. Commit, stash, or remove every tracked and untracked change before release."
  fi

  branch=$("$GIT_BIN" branch --show-current)
  require_equal "production branch" "$PRODUCTION_BRANCH" "$branch"

  printf 'Refreshing origin/%s for release validation...\n' "$PRODUCTION_BRANCH"
  "$GIT_BIN" fetch --quiet origin "$PRODUCTION_BRANCH"
  origin_sha=$("$GIT_BIN" rev-parse --verify "origin/$PRODUCTION_BRANCH^{commit}" 2>/dev/null) || die "origin/$PRODUCTION_BRANCH is unavailable."

  if ! "$GIT_BIN" merge-base --is-ancestor "$RELEASE_GIT_SHA" "origin/$PRODUCTION_BRANCH"; then
    die "HEAD $RELEASE_GIT_SHA is not present on origin/$PRODUCTION_BRANCH. Push it first."
  fi
  require_equal "local HEAD versus origin/$PRODUCTION_BRANCH" "$origin_sha" "$RELEASE_GIT_SHA"
}

resolve_local_tools() {
  PYTHON_BIN="${PYTHON_BIN:-$REPO_ROOT/../venv/bin/python}"
  DBT_BIN="${DBT_BIN:-$REPO_ROOT/../venv/bin/dbt}"
  [[ -x "$PYTHON_BIN" ]] || die "Python executable not found: $PYTHON_BIN"
  [[ -x "$DBT_BIN" ]] || die "dbt executable not found: $DBT_BIN"
}

run_prebuild_validation() {
  printf 'Running focused release tests...\n'
  "$PYTHON_BIN" -m unittest \
    tests.test_release_dbt_prod \
    tests.test_release_guard \
    tests.test_income_quarter_adjacency \
    tests.test_issuer_eligibility_contract
  printf 'Parsing dbt project for prod...\n'
  "$DBT_BIN" parse --profiles-dir . --target prod --no-partial-parse
}

set_release_names() {
  local release_timestamp short_sha
  release_timestamp=$(date -u +%Y%m%dT%H%M%SZ)
  short_sha=${RELEASE_GIT_SHA:0:8}
  RELEASE_ID="dbt-prod-${release_timestamp}-${short_sha}"
  IMAGE_TAG="${IMAGE_REPOSITORY}:${RELEASE_GIT_SHA}"
  MANIFEST_URI="gs://${RELEASE_BUCKET}/dbt/releases/${RELEASE_ID}/approved_release.json"
}

print_plan() {
  printf '\nPlanned production release:\n'
  printf '  Git SHA:          %s\n' "$RELEASE_GIT_SHA"
  printf '  Image tag:        %s\n' "$IMAGE_TAG"
  printf '  Release ID:       %s\n' "$RELEASE_ID"
  printf '  Release manifest: %s\n' "$MANIFEST_URI"
  printf '  Cloud Run job:    %s (%s/%s)\n' "$CLOUD_RUN_JOB" "$PROJECT_ID" "$REGION"
}

ensure_manifest_absent() {
  local uri="$1" output_file="$2"
  if run_gcloud storage objects describe "$uri" --project="$PROJECT_ID" >"$output_file" 2>&1; then
    die "Approved release manifest already exists and will not be overwritten: $uri"
  fi
  if ! grep -Eqi 'not found|does not exist|404|matched no objects' "$output_file"; then
    cat "$output_file" >&2
    die "Could not prove that the release manifest is absent."
  fi
}

build_exact_source_archive() {
  local build_dir="$1"
  mkdir -p "$build_dir"
  "$GIT_BIN" archive "$RELEASE_GIT_SHA" | tar -x -C "$build_dir"
  require_equal "archived source commit" "$RELEASE_GIT_SHA" "$("$GIT_BIN" rev-parse "$RELEASE_GIT_SHA")"
}

build_and_resolve_image() {
  local build_dir="$1" build_id resolved_digest
  printf 'Building immutable image from %s...\n' "$RELEASE_GIT_SHA"
  build_id=$(run_gcloud builds submit "$build_dir" \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --config="$build_dir/cloudbuild.release.yaml" \
    --substitutions="_DBT_CODE_GIT_SHA=${RELEASE_GIT_SHA},_IMAGE_URI=${IMAGE_TAG}" \
    --format='value(id)')
  [[ -n "$build_id" ]] || die "Cloud Build did not return a build ID."
  printf 'Cloud Build: %s\n' "$build_id"

  resolved_digest=$(run_gcloud artifacts docker images describe "$IMAGE_TAG" \
    --project="$PROJECT_ID" --format='value(image_summary.digest)')
  validate_image_digest "$resolved_digest"
  IMAGE_DIGEST="$resolved_digest"
  IMAGE_REF="${IMAGE_REPOSITORY}@${IMAGE_DIGEST}"
}

verify_built_artifact() {
  local verification_id
  printf 'Verifying built artifact %s...\n' "$IMAGE_REF"
  verification_id=$(run_gcloud builds submit --no-source \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --config="$REPO_ROOT/cloudbuild.verify-release.yaml" \
    --substitutions="_DBT_CODE_GIT_SHA=${RELEASE_GIT_SHA},_IMAGE_REF=${IMAGE_REF}" \
    --format='value(id)')
  [[ -n "$verification_id" ]] || die "Artifact verification did not return a Cloud Build ID."
  printf 'Artifact verification Cloud Build: %s\n' "$verification_id"

  require_equal "tag digest" "$IMAGE_DIGEST" "$(run_gcloud artifacts docker images describe "$IMAGE_TAG" --project="$PROJECT_ID" --format='value(image_summary.digest)')"
}

create_manifest_file() {
  local path="$1" created_at dbt_version dbt_bigquery_version
  created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  dbt_version=$(sed -n 's/^dbt-core==//p' requirements.txt)
  dbt_bigquery_version=$(sed -n 's/^dbt-bigquery==//p' requirements.txt)
  "$PYTHON_BIN" -c 'import json,sys; p=sys.argv; data={"approved_git_sha":p[2],"approved_image_digest":p[3],"created_at":p[4],"release_id":p[5],"dbt_version":p[6],"dbt_bigquery_version":p[7]}; open(p[1],"w",encoding="utf-8").write(json.dumps(data,sort_keys=True,indent=2)+"\n")' \
    "$path" "$RELEASE_GIT_SHA" "$IMAGE_DIGEST" "$created_at" "$RELEASE_ID" "$dbt_version" "$dbt_bigquery_version"
}

upload_and_verify_manifest() {
  local manifest_file="$1" collision_output="$2" readback_file="$3"
  ensure_manifest_absent "$MANIFEST_URI" "$collision_output"
  MANIFEST_SHA256=$(shasum -a 256 "$manifest_file" | awk '{print $1}')

  run_gcloud storage cp "$manifest_file" "$MANIFEST_URI" \
    --project="$PROJECT_ID" --if-generation-match=0

  run_gcloud storage cat "$MANIFEST_URI" --project="$PROJECT_ID" >"$readback_file"
  cmp -s "$manifest_file" "$readback_file" || die "Uploaded manifest readback differs from the approved local manifest."
  MANIFEST_GENERATION=$(run_gcloud storage objects describe "$MANIFEST_URI" \
    --project="$PROJECT_ID" --format='value(generation)')
  [[ "$MANIFEST_GENERATION" =~ ^[0-9]+$ ]] || die "Manifest generation is missing or malformed."
}

grant_runner_manifest_access() {
  local object_name condition_title condition_expression
  object_name="dbt/releases/${RELEASE_ID}/approved_release.json"
  condition_title="dbt_release_${RELEASE_ID//-/_}_manifest_read"
  condition_expression="resource.name == 'projects/_/buckets/${RELEASE_BUCKET}/objects/${object_name}'"
  run_gcloud storage buckets add-iam-policy-binding "gs://${RELEASE_BUCKET}" \
    --project="$PROJECT_ID" \
    --member="serviceAccount:${DBT_RUNNER_SERVICE_ACCOUNT}" \
    --role=roles/storage.objectViewer \
    --condition="expression=${condition_expression},title=${condition_title},description=Read one approved dbt release manifest"
}

deploy_cloud_run() {
  local deployed_image
  printf 'Atomically updating Cloud Run image digest and manifest URI...\n'
  run_gcloud run jobs update "$CLOUD_RUN_JOB" \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --image="$IMAGE_REF" \
    --update-env-vars="DBT_APPROVED_RELEASE_URI=${MANIFEST_URI}"

  deployed_image=$(run_gcloud run jobs describe "$CLOUD_RUN_JOB" \
    --project="$PROJECT_ID" --region="$REGION" \
    --format='value(spec.template.spec.template.spec.containers[0].image)')
  require_equal "deployed Cloud Run image" "$IMAGE_REF" "$deployed_image"
  CLOUD_RUN_GENERATION=$(run_gcloud run jobs describe "$CLOUD_RUN_JOB" \
    --project="$PROJECT_ID" --region="$REGION" --format='value(metadata.generation)')
  [[ "$CLOUD_RUN_GENERATION" =~ ^[0-9]+$ ]] || die "Cloud Run generation is missing or malformed."
}

confirm_production_run() {
  local answer
  if [[ "$RUN_WITHOUT_PROMPT" == true ]]; then
    return 0
  fi
  printf '\nRelease deployed with internally consistent identities.\n'
  read -r -p 'Run the production dbt build now? [y/N] ' answer || answer=""
  [[ "$answer" =~ ^[Yy]$ ]]
}

execute_production() {
  local execution
  execution=$(run_gcloud run jobs execute "$CLOUD_RUN_JOB" \
    --project="$PROJECT_ID" --region="$REGION" --wait \
    --format='value(metadata.name)') || die "Production Cloud Run execution failed. Inspect Cloud Run logs; the guard was not bypassed."
  [[ -n "$execution" ]] || die "Production execution succeeded but no execution ID was returned."
  PRODUCTION_EXECUTION="$execution"
}

post_deploy_verify() {
  local deployed_image manifest_readback manifest_sha approved_sha approved_digest
  deployed_image=$(run_gcloud run jobs describe "$CLOUD_RUN_JOB" \
    --project="$PROJECT_ID" --region="$REGION" \
    --format='value(spec.template.spec.template.spec.containers[0].image)')
  require_equal "post-deploy Cloud Run image" "$IMAGE_REF" "$deployed_image"

  manifest_readback="$TEMP_ROOT/post-deploy-manifest.json"
  run_gcloud storage cat "$MANIFEST_URI" --project="$PROJECT_ID" >"$manifest_readback"
  manifest_sha=$(shasum -a 256 "$manifest_readback" | awk '{print $1}')
  require_equal "manifest SHA256" "$MANIFEST_SHA256" "$manifest_sha"
  approved_sha=$("$PYTHON_BIN" -c 'import json,sys; print(json.load(open(sys.argv[1]))["approved_git_sha"])' "$manifest_readback")
  approved_digest=$("$PYTHON_BIN" -c 'import json,sys; print(json.load(open(sys.argv[1]))["approved_image_digest"])' "$manifest_readback")
  require_equal "approved Git SHA" "$RELEASE_GIT_SHA" "$approved_sha"
  require_equal "approved image digest" "$IMAGE_DIGEST" "$approved_digest"
}

print_summary() {
  cat <<EOF

========================================
DBT PRODUCTION RELEASE
========================================

Git SHA:
  $RELEASE_GIT_SHA

Image tag:
  $IMAGE_TAG

Image digest:
  ${IMAGE_DIGEST:-NOT BUILT}

Release ID:
  $RELEASE_ID

Release manifest:
  $MANIFEST_URI

Manifest generation:
  ${MANIFEST_GENERATION:-NOT CREATED}

Manifest SHA256:
  ${MANIFEST_SHA256:-NOT CREATED}

Cloud Run generation:
  ${CLOUD_RUN_GENERATION:-NOT DEPLOYED}

Cloud Run image:
  ${IMAGE_REF:-NOT DEPLOYED}

Production execution:
  $PRODUCTION_EXECUTION

Status:
  $RELEASE_STATUS
EOF
}

main() {
  local arg build_dir manifest_file collision_output readback_file
  for arg in "$@"; do
    case "$arg" in
      --dry-run) DRY_RUN=true ;;
      --yes|--deploy-and-run) RUN_WITHOUT_PROMPT=true ;;
      --help|-h) usage; return 0 ;;
      *) die "Unknown option: $arg. Use --help." ;;
    esac
  done
  if [[ "$DRY_RUN" == true && "$RUN_WITHOUT_PROMPT" == true ]]; then
    die "--dry-run cannot be combined with --yes or --deploy-and-run."
  fi

  REPO_ROOT=$(repo_root)
  cd "$REPO_ROOT"
  preflight_git
  resolve_local_tools
  run_prebuild_validation
  set_release_names
  print_plan

  if [[ "$DRY_RUN" == true ]]; then
    RELEASE_STATUS="DRY RUN — NO REMOTE MUTATIONS"
    print_summary
    printf '\nDry run stopped before image build/push, GCS writes, Cloud Run update, and production execution.\n'
    return 0
  fi

  TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dbt-prod-release.XXXXXX")
  trap cleanup EXIT
  build_dir="$TEMP_ROOT/source"
  manifest_file="$TEMP_ROOT/approved_release.json"
  collision_output="$TEMP_ROOT/manifest-collision-check.txt"
  readback_file="$TEMP_ROOT/approved_release.readback.json"

  build_exact_source_archive "$build_dir"
  build_and_resolve_image "$build_dir"
  verify_built_artifact
  create_manifest_file "$manifest_file"
  upload_and_verify_manifest "$manifest_file" "$collision_output" "$readback_file"
  grant_runner_manifest_access
  deploy_cloud_run

  if confirm_production_run; then
    execute_production
    post_deploy_verify
    RELEASE_STATUS="SUCCESS"
  else
    post_deploy_verify
    RELEASE_STATUS="DEPLOYED — PRODUCTION BUILD NOT RUN"
  fi
  print_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
