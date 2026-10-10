#!/bin/bash
set -euo pipefail

dbt_target="${DBT_TARGET:-dev}"

echo "dbt_code_git_sha: ${DBT_CODE_GIT_SHA:-missing}"
echo "dbt target: ${dbt_target}"
echo "dbt args: $*"

if [[ "$dbt_target" == "prod" ]]; then
  python release_guard.py
fi

dbt deps --profiles-dir .
dbt build --profiles-dir . --target "$dbt_target" "$@"
