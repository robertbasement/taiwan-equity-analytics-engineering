"""Fail-closed production release identity guard for the dbt container."""

from __future__ import annotations

import json
import os
import re
import sys
from datetime import datetime
from typing import Any

from google.cloud import storage


FULL_GIT_SHA = re.compile(r"^[0-9a-f]{40}$")
IMAGE_DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
REQUIRED_FIELDS = {
    "approved_git_sha",
    "approved_image_digest",
    "created_at",
    "release_id",
}


class ReleaseGuardError(RuntimeError):
    """Raised when production release identity cannot be proven."""


def validate_manifest(manifest: Any) -> dict[str, str]:
    if not isinstance(manifest, dict):
        raise ReleaseGuardError("approved release manifest must be a JSON object")

    missing = REQUIRED_FIELDS - manifest.keys()
    if missing:
        raise ReleaseGuardError(
            f"approved release manifest missing fields: {', '.join(sorted(missing))}"
        )

    values = {field: manifest[field] for field in REQUIRED_FIELDS}
    if not all(isinstance(value, str) and value for value in values.values()):
        raise ReleaseGuardError("approved release identity fields must be non-empty strings")
    if not FULL_GIT_SHA.fullmatch(values["approved_git_sha"]):
        raise ReleaseGuardError("approved_git_sha must be a full lowercase Git SHA")
    if not IMAGE_DIGEST.fullmatch(values["approved_image_digest"]):
        raise ReleaseGuardError("approved_image_digest must be an immutable sha256 digest")
    try:
        datetime.fromisoformat(values["created_at"].replace("Z", "+00:00"))
    except ValueError as exc:
        raise ReleaseGuardError("created_at must be an ISO-8601 timestamp") from exc
    return values


def authorize_release(embedded_git_sha: str | None, manifest: Any) -> dict[str, str]:
    if not embedded_git_sha:
        raise ReleaseGuardError("DBT_CODE_GIT_SHA is missing")
    if not FULL_GIT_SHA.fullmatch(embedded_git_sha):
        raise ReleaseGuardError("DBT_CODE_GIT_SHA is not a full lowercase Git SHA")

    approved = validate_manifest(manifest)
    if embedded_git_sha != approved["approved_git_sha"]:
        raise ReleaseGuardError(
            "embedded dbt Git SHA does not match the approved production release"
        )
    return approved


def load_gcs_manifest(uri: str | None) -> dict[str, Any]:
    if not uri or not uri.startswith("gs://"):
        raise ReleaseGuardError("DBT_APPROVED_RELEASE_URI must be a gs:// URI")
    bucket_name, separator, object_name = uri[5:].partition("/")
    if not separator or not bucket_name or not object_name:
        raise ReleaseGuardError("DBT_APPROVED_RELEASE_URI is malformed")

    try:
        payload = storage.Client().bucket(bucket_name).blob(object_name).download_as_bytes()
        return json.loads(payload)
    except Exception as exc:
        raise ReleaseGuardError(f"could not load approved release manifest: {exc}") from exc


def main() -> int:
    try:
        manifest = load_gcs_manifest(os.getenv("DBT_APPROVED_RELEASE_URI"))
        approved = authorize_release(os.getenv("DBT_CODE_GIT_SHA"), manifest)
    except ReleaseGuardError as exc:
        print(f"dbt_release_guard: BLOCKED: {exc}", file=sys.stderr)
        return 1

    print(f"dbt_release_guard: ALLOWED release_id={approved['release_id']}")
    print(f"approved_git_sha: {approved['approved_git_sha']}")
    print(f"approved_image_digest: {approved['approved_image_digest']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
