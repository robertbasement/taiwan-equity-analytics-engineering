import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "tools" / "release_dbt_prod.sh"
DOCKERFILE = REPO_ROOT / "Dockerfile"


class ReleaseImageContractTests(unittest.TestCase):
    def test_dbt_packages_are_installed_during_image_build(self):
        dockerfile = DOCKERFILE.read_text()

        project_copy = dockerfile.index("COPY . .")
        dependency_install = dockerfile.index("RUN dbt deps --profiles-dir .")
        entrypoint = dockerfile.index('ENTRYPOINT ["./run_dbt.sh"]')

        self.assertLess(project_copy, dependency_install)
        self.assertLess(dependency_install, entrypoint)
        self.assertTrue((REPO_ROOT / "packages.yml").is_file())
        self.assertTrue((REPO_ROOT / "package-lock.yml").is_file())


class ReleaseScriptFunctionTests(unittest.TestCase):
    def run_bash(self, body):
        return subprocess.run(
            ["bash", "-c", f"source {SCRIPT!s}; {body}"],
            text=True,
            capture_output=True,
        )

    def test_missing_git_sha_is_blocked(self):
        result = self.run_bash("validate_git_sha ''")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Git SHA", result.stderr)

    def test_malformed_digest_is_blocked(self):
        result = self.run_bash("validate_image_digest 'dbt-stock:latest'")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("digest", result.stderr)

    def test_image_identity_mismatch_is_blocked(self):
        result = self.run_bash("require_equal image expected actual")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("mismatch", result.stderr)

    def test_existing_manifest_collision_is_blocked(self):
        with tempfile.NamedTemporaryFile() as output:
            body = (
                "run_gcloud() { return 0; }; "
                f"ensure_manifest_absent gs://bucket/existing {output.name}"
            )
            result = self.run_bash(body)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("already exists", result.stderr)


class ReleaseScriptDryRunTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = pathlib.Path(tempfile.mkdtemp())
        self.origin = self.temp_dir / "origin.git"
        self.repo = self.temp_dir / "repo"
        subprocess.run(["git", "init", "--bare", str(self.origin)], check=True, capture_output=True)
        subprocess.run(["git", "init", "-b", "main", str(self.repo)], check=True, capture_output=True)
        subprocess.run(["git", "-C", str(self.repo), "config", "user.email", "release-test@example.invalid"], check=True)
        subprocess.run(["git", "-C", str(self.repo), "config", "user.name", "Release Test"], check=True)

        (self.repo / "tools").mkdir()
        shutil.copy2(SCRIPT, self.repo / "tools" / SCRIPT.name)
        (self.repo / "marker.txt").write_text("clean\n")
        subprocess.run(["git", "-C", str(self.repo), "add", "."], check=True)
        subprocess.run(["git", "-C", str(self.repo), "commit", "-m", "test release"], check=True, capture_output=True)
        subprocess.run(["git", "-C", str(self.repo), "remote", "add", "origin", str(self.origin)], check=True)
        subprocess.run(["git", "-C", str(self.repo), "push", "-u", "origin", "main"], check=True, capture_output=True)

        self.gcloud_log = self.temp_dir / "gcloud.log"
        self.fake_gcloud = self.temp_dir / "fake-gcloud"
        self.fake_gcloud.write_text(f"#!/bin/sh\necho invoked >> {self.gcloud_log}\nexit 99\n")
        self.fake_gcloud.chmod(0o755)

    def tearDown(self):
        shutil.rmtree(self.temp_dir)

    def run_release(self):
        env = os.environ.copy()
        env.update(
            {
                "PYTHON_BIN": "/usr/bin/true",
                "DBT_BIN": "/usr/bin/true",
                "GCLOUD_BIN": str(self.fake_gcloud),
            }
        )
        return subprocess.run(
            ["bash", "tools/release_dbt_prod.sh", "--dry-run"],
            cwd=self.repo,
            env=env,
            text=True,
            capture_output=True,
        )

    def test_dry_run_performs_no_gcloud_mutations(self):
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("DRY RUN", result.stdout)
        self.assertFalse(self.gcloud_log.exists())

    def test_dirty_working_tree_is_blocked(self):
        (self.repo / "marker.txt").write_text("dirty\n")
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not clean", result.stderr)
        self.assertFalse(self.gcloud_log.exists())

    def test_commit_not_on_origin_main_is_blocked(self):
        (self.repo / "marker.txt").write_text("new commit\n")
        subprocess.run(["git", "-C", str(self.repo), "add", "marker.txt"], check=True)
        subprocess.run(["git", "-C", str(self.repo), "commit", "-m", "not pushed"], check=True, capture_output=True)
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue("not present" in result.stderr or "mismatch" in result.stderr)
        self.assertFalse(self.gcloud_log.exists())


if __name__ == "__main__":
    unittest.main()
