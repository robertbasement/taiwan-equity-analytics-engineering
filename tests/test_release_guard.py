import unittest

from release_guard import ReleaseGuardError, authorize_release


APPROVED_SHA = "a" * 40
APPROVED_DIGEST = "sha256:" + "b" * 64


def manifest(**overrides):
    value = {
        "approved_git_sha": APPROVED_SHA,
        "approved_image_digest": APPROVED_DIGEST,
        "created_at": "2026-10-10T00:00:00Z",
        "release_id": "dbt-prod-test",
    }
    value.update(overrides)
    return value


class ReleaseGuardTests(unittest.TestCase):
    def test_matching_approved_release_is_allowed(self):
        approved = authorize_release(APPROVED_SHA, manifest())
        self.assertEqual(approved["approved_git_sha"], APPROVED_SHA)

    def test_mismatched_git_sha_is_blocked(self):
        with self.assertRaisesRegex(ReleaseGuardError, "does not match"):
            authorize_release("7" * 40, manifest())

    def test_missing_release_identity_is_blocked(self):
        with self.assertRaisesRegex(ReleaseGuardError, "missing"):
            authorize_release(None, manifest())

    def test_malformed_manifest_is_blocked(self):
        with self.assertRaisesRegex(ReleaseGuardError, "missing fields"):
            authorize_release(APPROVED_SHA, {"approved_git_sha": APPROVED_SHA})

    def test_mutable_image_tag_is_not_accepted_as_digest(self):
        with self.assertRaisesRegex(ReleaseGuardError, "immutable sha256"):
            authorize_release(
                APPROVED_SHA,
                manifest(approved_image_digest="dbt-stock:latest"),
            )


if __name__ == "__main__":
    unittest.main()
