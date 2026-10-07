#!/usr/bin/env python3
"""Exercise controls against real disposable Git repositories and CLI calls."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).parent
SPEC = importlib.util.spec_from_file_location("device_controls", HERE / "device-benchmark-controls.py")
CONTROLS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CONTROLS)
BRANCH = "refs/heads/private/apple-device-dependency-controller"
FIXTURE_CI = ("Gemfile", "Gemfile.lock", "fastlane/Fastfile",
              ".github/actions/cache-spm/action.yml", ".github/workflows/sideload-ipa.yml",
              "scripts/ci/apple-build-metadata.py")


class ControlsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.fixture, self.source, self.controller = [self.base / name for name in ("fixture", "source", "controller")]
        for root in (self.fixture, self.source, self.controller):
            root.mkdir()
            self.git(root, "init", "-q")
            self.git(root, "config", "user.name", "Fixture")
            self.git(root, "config", "user.email", "fixture@example.invalid")
        for root in (self.source, self.fixture):
            for path in FIXTURE_CI:
                self.put(root, path, "reviewed CI\n")
            self.put(root, "iosApp/App.swift", "let value = 1\n")
            self.put(root, "iosApp/project.yml", "name: Silo\n")
            self.put(root, ".gitignore", "ignored-local\n")
            (root / "app-link").symlink_to("iosApp/App.swift")
        self.put(self.source, "scripts/ci/optimization.py", "reviewed optimization\n")
        self.source_sha, self.fixture_sha = self.commit(self.source), self.commit(self.fixture)
        self.put(self.controller, CONTROLS.HELPER, (HERE / "device-benchmark-controls.py").read_text())
        self.put(self.controller, CONTROLS.WORKFLOW, "on: workflow_dispatch\n")
        _, entries, _, _ = CONTROLS.inspect(self.source, self.source_sha)
        self.manifest = {"schema": 1, "selection": CONTROLS.SELECTION, "entries": entries}
        self.put(self.controller, CONTROLS.MANIFEST, CONTROLS.canonical(self.manifest).decode())
        self.controller_sha = self.commit(self.controller)
        self.env = os.environ.copy()
        self.env.update(GITHUB_REPOSITORY=CONTROLS.REPOSITORY, GITHUB_EVENT_NAME="workflow_dispatch",
                        GITHUB_REF=BRANCH, GITHUB_SHA=self.controller_sha,
                        GITHUB_WORKFLOW_SHA=self.controller_sha,
                        GITHUB_WORKFLOW_REF=CONTROLS.REPOSITORY + "/" + CONTROLS.WORKFLOW + "@" + BRANCH,
                        GITHUB_RUN_ID="123456", GITHUB_RUN_ATTEMPT="1")

    @staticmethod
    def git(root, *args):
        result = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, timeout=10)
        if result.returncode:
            raise AssertionError(result.stderr)
        return result.stdout.strip()

    @staticmethod
    def put(root, path, text):
        target = root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def commit(self, root):
        self.git(root, "add", "-A")
        self.git(root, "commit", "-qm", "Fixture")
        return self.git(root, "rev-parse", "HEAD")

    def refresh_controller(self):
        self.controller_sha = self.commit(self.controller)
        self.env.update(GITHUB_SHA=self.controller_sha, GITHUB_WORKFLOW_SHA=self.controller_sha)

    def run_controls(self, operation="bind", changes=None, env=None, expect=True, helper=None):
        values = {"controller-root": self.controller, "shipping-ci-manifest": self.controller / CONTROLS.MANIFEST,
                  "controller-sha": self.controller_sha, "source-sha": self.source_sha,
                  "fixture-sha": self.fixture_sha, "expected-branch": BRANCH, "profile": "off",
                  "namespace": "apple-device-fixture", "prime-run-id": ""}
        values.update(changes or {})
        output = self.base / ("receipt-" + str(len(list(self.base.glob("receipt-*")))) + ".json")
        values["output"] = output
        if operation == "bind":
            values.update({"source-root": self.source, "fixture-root": self.fixture})
        command = [sys.executable, str(helper or self.controller / CONTROLS.HELPER), operation]
        for key, value in values.items():
            command += ["--" + key, str(value)]
        result = subprocess.run(command, env=env or self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode == 0, expect, result.stderr)
        if expect:
            return json.loads(output.read_bytes())
        self.assertFalse(output.exists())
        self.assertIn("rejected", result.stderr.lower())
        return result.stderr

    def test_valid_pair_records_ci_and_app_trees_and_provenance(self):
        receipt = self.run_controls()
        self.assertTrue(receipt["qualified"])
        self.assertEqual(receipt["source"]["app"], receipt["fixture"]["app"])
        self.assertNotEqual(receipt["source"]["ci"], receipt["fixture"]["ci"])
        self.assertEqual(receipt["source"]["ci"], receipt["shipping_ci"])
        self.assertEqual(set(receipt["provenance"]), {CONTROLS.WORKFLOW, CONTROLS.HELPER, CONTROLS.MANIFEST})
        self.assertEqual(receipt["context"]["source_sha"], self.source_sha)

    def test_preflight_needs_no_source_or_fixture_checkout(self):
        self.fixture.rename(self.base / "fixture-moved")
        self.source.rename(self.base / "source-moved")
        receipt = self.run_controls("preflight")
        self.assertNotIn("source", receipt)
        self.assertEqual(receipt["operation"], "preflight")

    def test_manifest_sealing_is_canonical_and_requires_clean_immutable_source(self):
        output = self.base / "sealed.json"
        command = [sys.executable, str(self.controller / CONTROLS.HELPER), "seal-shipping-ci",
                   "--root", str(self.source), "--sha", self.source_sha, "--output", str(output)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.read_bytes(), CONTROLS.canonical(self.manifest))
        output.unlink()
        self.put(self.source, "local-override", "dirty")
        result = subprocess.run(command, capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())

    def test_invalid_operation_fails_before_receipt(self):
        result = subprocess.run([sys.executable, str(self.controller / CONTROLS.HELPER), "delete"],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 2)
        self.assertIn("invalid choice", result.stderr)

    def test_mutable_or_malformed_commit_inputs_are_rejected(self):
        for key in ("controller-sha", "source-sha", "fixture-sha"):
            for value in ("main", "a" * 39, "A" * 40, "a" * 40 + "\n"):
                with self.subTest(key=key, value=value):
                    self.run_controls(changes={key: value}, expect=False)

    def test_unsafe_namespace_and_nonprivate_branch_are_rejected(self):
        for namespace in ("production", "apple-device-", "apple-device-a/b", "apple-device-A",
                          "apple-device-" + "x" * 17, "apple-device-x\n"):
            with self.subTest(namespace=namespace):
                self.run_controls(changes={"namespace": namespace}, expect=False)
        self.run_controls(changes={"expected-branch": "refs/heads/main"}, expect=False)

    def test_profiles_and_prime_run_ids_are_checked_before_mac_work(self):
        for profile, prior in (("unknown", ""), ("off", "1"), ("prime", "1"), ("warm", ""),
                               ("warm", "0"), ("warm", "１２"), ("warm", "1\n")):
            with self.subTest(profile=profile, prior=prior):
                self.run_controls("preflight", {"profile": profile, "prime-run-id": prior}, expect=False)
        receipt = self.run_controls("preflight", {"profile": "warm", "prime-run-id": "456"})
        self.assertEqual(receipt["context"]["prime_run_id"], "456")

    def test_wrong_github_event_repo_ref_sha_or_workflow_is_rejected(self):
        variants = {"GITHUB_EVENT_NAME": "push", "GITHUB_REPOSITORY": "other/silo-apple",
                    "GITHUB_REF": "refs/heads/main", "GITHUB_SHA": "a" * 40,
                    "GITHUB_WORKFLOW_SHA": "b" * 40, "GITHUB_WORKFLOW_REF": "other.yml@" + BRANCH,
                    "GITHUB_RUN_ID": "-1", "GITHUB_RUN_ATTEMPT": "0"}
        for name, value in variants.items():
            with self.subTest(name=name):
                env = dict(self.env, **{name: value})
                self.run_controls("preflight", env=env, expect=False)

    def test_checkout_head_must_match_input(self):
        self.run_controls(changes={"source-sha": "a" * 40}, expect=False)
        self.run_controls(changes={"fixture-sha": "b" * 40}, expect=False)

    def test_changed_committed_ci_bytes_are_rejected(self):
        self.put(self.source, "fastlane/Fastfile", "different archive behavior\n")
        self.source_sha = self.commit(self.source)
        self.assertIn("Source CI tree differs", self.run_controls(expect=False))

    def test_added_or_missing_committed_ci_files_are_rejected(self):
        target = self.source / "scripts/ci/optimization.py"
        target.unlink()
        self.source_sha = self.commit(self.source)
        self.assertIn("Source CI tree differs", self.run_controls(expect=False))
        self.put(self.source, "fastlane/new-step.rb", "extra work\n")
        self.source_sha = self.commit(self.source)
        self.assertIn("Source CI tree differs", self.run_controls(expect=False))

    def test_committed_ci_mode_change_is_rejected(self):
        (self.source / "fastlane/Fastfile").chmod(0o755)
        self.source_sha = self.commit(self.source)
        self.assertIn("Source CI tree differs", self.run_controls(expect=False))

    def test_committed_app_difference_is_rejected(self):
        self.put(self.source, "iosApp/App.swift", "let value = 2\n")
        self.source_sha = self.commit(self.source)
        self.assertIn("Source app tree differs", self.run_controls(expect=False))

    def test_fixture_difference_is_rejected(self):
        (self.fixture / "iosApp/project.yml").unlink()
        self.fixture_sha = self.commit(self.fixture)
        self.assertIn("Source app tree differs", self.run_controls(expect=False))

    def test_staged_unstaged_untracked_and_ignored_overlays_are_rejected(self):
        for root in (self.source, self.fixture):
            for change in ("unstaged", "staged", "untracked", "ignored"):
                with self.subTest(root=root.name, change=change):
                    path = "iosApp/App.swift" if change in ("staged", "unstaged") else (
                        "ignored-local" if change == "ignored" else "local-override")
                    self.put(root, path, "dirty\n")
                    if change == "staged":
                        self.git(root, "add", path)
                    self.assertIn("Checkout contains", self.run_controls(expect=False))
                    self.git(root, "reset", "--hard", "HEAD")
                    self.git(root, "clean", "-fdx")

    def test_hidden_index_entries_cannot_mask_an_overlay(self):
        for flag in ("--assume-unchanged", "--skip-worktree"):
            with self.subTest(flag=flag):
                self.git(self.source, "update-index", flag, "iosApp/App.swift")
                self.put(self.source, "iosApp/App.swift", "hidden dirty\n")
                self.assertIn("hidden index entries", self.run_controls(expect=False))
                self.git(self.source, "update-index", "--no-assume-unchanged", "iosApp/App.swift")
                self.git(self.source, "update-index", "--no-skip-worktree", "iosApp/App.swift")
                self.git(self.source, "checkout", "--", "iosApp/App.swift")

    def test_ignored_filemode_configuration_cannot_mask_an_overlay(self):
        self.git(self.source, "config", "core.fileMode", "false")
        (self.source / "iosApp/App.swift").chmod(0o755)
        self.assertIn("executable mode", self.run_controls(expect=False))

    def test_git_replacement_objects_cannot_redefine_frozen_app_commits(self):
        for root, original in ((self.source, self.source_sha), (self.fixture, self.fixture_sha)):
            self.put(root, "iosApp/App.swift", "let value = 2\n")
            replacement = self.commit(root)
            self.git(root, "replace", original, replacement)
            self.git(root, "checkout", "--detach", original)
        self.assertIn("Checkout contains", self.run_controls(expect=False))

    def test_matching_symlinks_cannot_read_external_or_missing_source(self):
        (self.base / "outside-file").write_text("unbound source\n")
        for target in ("../outside-file", "../missing-file"):
            with self.subTest(target=target):
                for root in (self.source, self.fixture):
                    (root / "app-link").unlink()
                    (root / "app-link").symlink_to(target)
                self.source_sha, self.fixture_sha = self.commit(self.source), self.commit(self.fixture)
                self.assertIn("Symlink target is not bound", self.run_controls(expect=False))

    def test_controller_helper_and_manifest_are_bound_to_tracked_paths(self):
        outside = self.base / "outside.py"
        outside.write_text((self.controller / CONTROLS.HELPER).read_text())
        self.assertIn("outside the controller", self.run_controls("preflight", helper=outside, expect=False))
        self.run_controls("preflight", {"shipping-ci-manifest": self.base / "outside.py"}, expect=False)
        self.put(self.controller, CONTROLS.WORKFLOW, "on: push\n")
        self.assertIn("Checkout contains", self.run_controls("preflight", expect=False))

    def test_manifest_schema_and_closed_selection_cannot_change(self):
        self.manifest["selection"] = {"prefixes": [".github/", "scripts/ci/", "fastlane/", "iosApp/"],
                                     "files": ["Gemfile", "Gemfile.lock"]}
        self.put(self.controller, CONTROLS.MANIFEST, CONTROLS.canonical(self.manifest).decode())
        self.refresh_controller()
        self.assertIn("schema or selection", self.run_controls("preflight", expect=False))

    def test_manifest_must_be_canonical_complete_and_unique(self):
        original = self.manifest.copy()
        for variant in ("noncanonical", "missing", "duplicate"):
            with self.subTest(variant=variant):
                manifest = dict(original, entries=list(original["entries"]))
                if variant == "missing":
                    manifest["entries"] = [e for e in manifest["entries"] if e["path"] != "Gemfile"]
                if variant == "duplicate":
                    manifest["entries"] += [manifest["entries"][0]]
                raw = json.dumps(manifest, indent=2) if variant == "noncanonical" else CONTROLS.canonical(manifest).decode()
                self.put(self.controller, CONTROLS.MANIFEST, raw)
                self.refresh_controller()
                self.run_controls("preflight", expect=False)


if __name__ == "__main__":
    unittest.main()
