#!/usr/bin/env python3
"""Release proof must never replace coverage when provenance is uncertain."""

from copy import deepcopy
from datetime import datetime, timedelta, timezone
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit
from urllib.request import Request
import zipfile


sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("regression_proof", Path(__file__).with_name("find-regression-proof.py"))
proof = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proof)
metadata_spec = importlib.util.spec_from_file_location("build_metadata", Path(__file__).with_name("apple-build-metadata.py"))
build_metadata = importlib.util.module_from_spec(metadata_spec)
metadata_spec.loader.exec_module(build_metadata)


NOW = datetime(2026, 10, 7, 12, tzinfo=timezone.utc)
REPOSITORY = "Silo-Server/silo-apple"
SHA = "a" * 40
TREE = "b" * 40
LOCK = "c" * 64
ROOT = f"/repos/{REPOSITORY}/actions"


def iso(value):
    return value.isoformat().replace("+00:00", "Z")


def zip_json(value, filename="regression-proof.json", extra=None):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(filename, value if isinstance(value, str) else json.dumps(value))
        if extra:
            archive.writestr(*extra)
    return buffer.getvalue()


def environment():
    toolchains = {scheme: {"xcode_version": "27.0", "xcode_build": "27A123",
                          "sdk_version": "27.0", "sdk_build": "27A123", "architecture": "arm64"}
                  for scheme in proof.SCHEMES}
    for scheme in ("Silo", "SiloTV"):
        toolchains[scheme].update(runtime_version="27.0", runtime_build="24A123")
    return {"GH_TOKEN": "test-token", "GH_REPOSITORY": REPOSITORY, "TARGET_SHA": SHA,
            "EXPECTED_FINGERPRINT": TREE, "EXPECTED_LOCK_SHA256": LOCK,
            "EXPECTED_TOOLCHAIN_JSON": json.dumps(toolchains)}


class FakeGitHub:
    def __init__(self):
        self.calls = []
        self.workflow = {"id": 77, "path": proof.WORKFLOW}
        self.run = {"id": 100, "workflow_id": 77, "path": proof.WORKFLOW,
                    "repository": {"id": 42, "full_name": REPOSITORY},
                    "head_repository": {"id": 42, "full_name": REPOSITORY},
                    "event": "push", "head_branch": "main", "head_sha": SHA,
                    "status": "completed", "conclusion": "success", "run_attempt": 2}
        self.runs = [{"id": 100}]
        self.final_run = None
        self.run_reads = 0
        self.jobs, self.artifacts, self.manifests = [], [], {}
        self.archives = {}
        self.page_size = 100
        self.fail_path = None
        self.truncated_key = None
        toolchains = json.loads(environment()["EXPECTED_TOOLCHAIN_JSON"])
        for number, scheme in enumerate(proof.SCHEMES):
            names = ["Build player", "Record regression proof", "Upload regression proof"]
            if scheme != "SiloMac":
                names.append("Run complete simulator suite")
            self.jobs.append({"id": number + 1000, "run_id": 100, "head_sha": SHA,
                              "name": f"Regression ({scheme})", "status": "completed",
                              "conclusion": "success", "started_at": iso(NOW - timedelta(minutes=30)),
                              "completed_at": iso(NOW - timedelta(minutes=5)),
                              "steps": [{"name": name, "status": "completed", "conclusion": "success"}
                                        for name in names]})
            self.artifacts.append({"id": number + 2000,
                                   "name": f"apple-regression-proof-{scheme}-2", "expired": False,
                                   "size_in_bytes": 1024, "created_at": iso(NOW - timedelta(minutes=6)),
                                   "expires_at": iso(NOW + timedelta(days=7)),
                                   "workflow_run": {"id": 100, "repository_id": 42,
                                                    "head_repository_id": 42, "head_branch": "main",
                                                    "head_sha": SHA}})
            self.manifests[number + 2000] = {
                "schema_version": 1, "repository": REPOSITORY, "workflow_path": proof.WORKFLOW,
                "event": "push", "branch": "main", "sha": SHA, "run_id": 100, "run_attempt": 2,
                "scheme": scheme, "fingerprint": TREE, "dependency_lock_sha256": LOCK,
                "frozen_dependencies": True, "full_suite": True, "toolchain": toolchains[scheme]}

    def get(self, path, binary=False):
        self.calls.append((path, binary))
        parsed = urlsplit(path)
        route, query = parsed.path, parse_qs(parsed.query)
        if self.fail_path and self.fail_path in route:
            raise OSError("Authorization test-token and signed URL must never appear")
        if route == ROOT + "/workflows/player-regression.yml":
            return deepcopy(self.workflow)
        if route == ROOT + "/runs/100":
            self.run_reads += 1
            return deepcopy(self.final_run if self.run_reads > 1 and self.final_run is not None else self.run)
        if route == ROOT + "/workflows/player-regression.yml/runs":
            self.query = query
            return self.page("workflow_runs", self.runs, query)
        if route == ROOT + "/runs/100/attempts/2/jobs":
            return self.page("jobs", self.jobs, query)
        if route == ROOT + "/runs/100/artifacts":
            return self.page("artifacts", self.artifacts, query)
        if route.startswith(ROOT + "/artifacts/") and route.endswith("/zip"):
            artifact_id = int(route.split("/")[-2])
            assert binary
            return self.archives.get(artifact_id, zip_json(self.manifests[artifact_id]))
        raise OSError("Unexpected GitHub request")

    def page(self, key, values, query):
        page = int(query["page"][0])
        start = (page - 1) * self.page_size
        data = values[start:start + self.page_size]
        if self.truncated_key == key and page > 1:
            data = []
        return {"total_count": len(values), key: deepcopy(data)}


class RegressionProofTests(unittest.TestCase):
    def setUp(self):
        self.api = FakeGitHub()
        self.env = environment()

    def lookup(self):
        return proof.lookup(self.env, self.api, NOW)

    def rejected(self, text=None):
        result = self.lookup()
        self.assertFalse(result["reusable"])
        self.assertEqual(result["run_id"], "")
        self.assertEqual(result["run_url"], "")
        self.assertNotIn("test-token", result["reason"])
        if text:
            self.assertIn(text, result["reason"])

    def test_complete_trusted_proof_uses_current_attempt_and_filtered_lookup(self):
        result = self.lookup()
        self.assertTrue(result["reusable"])
        self.assertEqual(result["run_id"], 100)
        self.assertEqual(result["run_url"], "https://github.com/Silo-Server/silo-apple/actions/runs/100")
        self.assertEqual(self.api.query["event"], ["push"])
        self.assertEqual(self.api.query["branch"], ["main"])
        self.assertEqual(self.api.query["head_sha"], [SHA])
        self.assertNotIn("status", self.api.query)
        self.assertEqual(self.api.run_reads, 2)
        self.assertTrue(any("/attempts/2/jobs" in path for path, _ in self.api.calls))

    def test_real_metadata_producer_and_proof_consumer_share_the_same_contract(self):
        # Exercise the actual producer rather than separately inventing its
        # source-tree digest, lock hash, toolchain fields or proof JSON shape.
        # Git reads this checkout; only the unavailable Apple tools are mocked.
        original_command = build_metadata.command
        runtimes = {"runtimes": [
            {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "version": "27.0",
             "buildversion": "24A123", "isAvailable": True},
            {"identifier": "com.apple.CoreSimulator.SimRuntime.tvOS-27-0", "version": "27.0",
             "buildversion": "24T123", "isAvailable": True}]}

        def measured_command(*args, cwd=None):
            if args == ("xcodebuild", "-version"):
                return "Xcode 27.0\nBuild version 27A123"
            if args == ("uname", "-m"):
                return "arm64"
            if args == ("xcrun", "simctl", "list", "runtimes", "--json"):
                return json.dumps(runtimes)
            if args[0] == "xcrun":
                return "27A123" if args[-1] == "--show-sdk-build-version" else "27.0"
            return original_command(*args, cwd=cwd)

        root = Path(__file__).resolve().parents[2]
        with patch.object(build_metadata, "command", side_effect=measured_command):
            result = build_metadata.metadata(root, {})
        producer_env = {"GITHUB_EVENT_NAME": "push", "GITHUB_REF_NAME": "main",
                        "GITHUB_SHA": result["source_sha"], "GITHUB_REPOSITORY": REPOSITORY,
                        "GITHUB_RUN_ID": "100", "GITHUB_RUN_ATTEMPT": "2", "SILO_FULL_SUITE": "true"}
        self.env.update(TARGET_SHA=result["source_sha"], EXPECTED_FINGERPRINT=result["fingerprint"],
                        EXPECTED_LOCK_SHA256=result["lock_sha256"],
                        EXPECTED_TOOLCHAIN_JSON=result["toolchain_json"])
        self.api.run["head_sha"] = result["source_sha"]
        for number, scheme in enumerate(proof.SCHEMES):
            self.api.jobs[number]["head_sha"] = result["source_sha"]
            self.api.artifacts[number]["workflow_run"]["head_sha"] = result["source_sha"]
            self.api.manifests[number + 2000] = build_metadata.proof(result, root, producer_env, scheme)
        self.assertTrue(self.lookup()["reusable"])

    def test_current_branch_path_suffixes_are_supported(self):
        for suffix in ("", "@main", "@refs/heads/main"):
            with self.subTest(suffix=suffix):
                self.api = FakeGitHub()
                self.api.run["path"] = proof.WORKFLOW + suffix
                self.assertTrue(self.lookup()["reusable"])

    def test_wrong_registered_workflow_or_run_path_is_rejected(self):
        for field, value in (("path", ".github/workflows/release.yml"),
                             ("path", proof.WORKFLOW + "@feature"), ("workflow_id", 999)):
            with self.subTest(field=field, value=value):
                self.api = FakeGitHub()
                self.api.run[field] = value
                self.rejected("workflow")
        self.api = FakeGitHub()
        self.api.workflow["path"] = ".github/workflows/other.yml"
        self.rejected("workflow")

    def test_wrong_repository_fork_or_commit_is_rejected(self):
        for key in ("repository", "head_repository"):
            with self.subTest(key=key):
                self.api = FakeGitHub()
                self.api.run[key]["full_name"] = "attacker/silo-apple"
                self.rejected("repository")
        self.api = FakeGitHub()
        self.api.run["head_repository"]["id"] = 43
        self.rejected("repository")
        self.api = FakeGitHub()
        self.api.run["head_sha"] = "f" * 40
        self.rejected("commit")

    def test_dispatch_pull_request_and_non_main_runs_are_rejected(self):
        for field, value in (("event", "workflow_dispatch"), ("event", "pull_request"),
                             ("event", "pull_request_target"), ("event", "workflow_call"),
                             ("head_branch", "feature")):
            with self.subTest(field=field, value=value):
                self.api = FakeGitHub()
                self.api.run[field] = value
                self.rejected("trusted")

    def test_latest_failed_cancelled_or_active_run_prevents_older_success_reuse(self):
        self.api.runs = [{"id": 99}, {"id": 100}]
        for status, conclusion in (("completed", "failure"), ("completed", "cancelled"),
                                   ("completed", "skipped"), ("in_progress", None), ("queued", None)):
            with self.subTest(status=status, conclusion=conclusion):
                self.api.run.update(status=status, conclusion=conclusion)
                self.rejected("Latest")

    def test_absent_proof_falls_back(self):
        self.api.runs = []
        self.rejected("No main")

    def test_partial_routing_or_duplicate_matrix_leg_is_rejected(self):
        for removed in range(3):
            with self.subTest(removed=removed):
                self.api = FakeGitHub()
                del self.api.jobs[removed]
                self.rejected("platform")
        self.api = FakeGitHub()
        extra = deepcopy(self.api.jobs[0])
        extra["id"] = 9999
        self.api.jobs.append(extra)
        self.rejected("duplicate")

    def test_unexpected_regression_platform_is_rejected(self):
        extra = deepcopy(self.api.jobs[0])
        extra.update(id=9999, name="Regression (Other)")
        self.api.jobs.append(extra)
        self.rejected("Unexpected")

    def test_each_platform_must_succeed_with_exact_commit_and_run(self):
        for job_index in range(3):
            for field, value in (("status", "in_progress"), ("conclusion", "skipped"),
                                 ("conclusion", "cancelled"), ("conclusion", "failure"),
                                 ("head_sha", "f" * 40), ("run_id", 99)):
                with self.subTest(job=job_index, field=field, value=value):
                    self.api = FakeGitHub()
                    self.api.jobs[job_index][field] = value
                    self.rejected()

    def test_required_build_full_suite_and_proof_steps_must_succeed(self):
        for name in ("Build player", "Run complete simulator suite", "Record regression proof",
                     "Upload regression proof"):
            for conclusion in ("skipped", "failure", "cancelled"):
                with self.subTest(name=name, conclusion=conclusion):
                    self.api = FakeGitHub()
                    for step in self.api.jobs[0]["steps"]:
                        if step["name"] == name:
                            step["conclusion"] = conclusion
                    self.rejected("Required")
            self.api = FakeGitHub()
            self.api.jobs[0]["steps"] = [step for step in self.api.jobs[0]["steps"] if step["name"] != name]
            self.rejected("Required")

    def test_future_or_reversed_job_timestamps_are_rejected(self):
        for job_index in range(3):
            with self.subTest(job=job_index):
                self.api = FakeGitHub()
                self.api.jobs[job_index]["completed_at"] = iso(NOW + timedelta(seconds=1))
                self.rejected("timestamp")
        self.api = FakeGitHub()
        self.api.jobs[0]["started_at"] = iso(NOW)
        self.rejected("timestamp")

    def test_old_matching_proof_remains_reusable_when_artifacts_are_available(self):
        for job in self.api.jobs:
            job["started_at"] = iso(NOW - timedelta(days=30, minutes=30))
            job["completed_at"] = iso(NOW - timedelta(days=30, minutes=5))
        for artifact in self.api.artifacts:
            artifact["created_at"] = iso(NOW - timedelta(days=30, minutes=6))
        self.assertTrue(self.lookup()["reusable"])

    def test_timestamp_timezone_offsets_are_supported(self):
        self.api = FakeGitHub()
        self.api.jobs[0]["completed_at"] = "2026-10-07T07:55:00-04:00"
        self.assertTrue(self.lookup()["reusable"])

    def test_matching_proof_requires_provenance_tree_lock_and_complete_frozen_suite(self):
        mismatches = {"schema_version": 2, "repository": "attacker/silo-apple",
                      "workflow_path": ".github/workflows/other.yml", "event": "workflow_dispatch",
                      "branch": "feature", "sha": "f" * 40, "run_id": 99, "run_attempt": 1,
                      "scheme": "SiloTV", "fingerprint": "d" * 40,
                      "dependency_lock_sha256": "d" * 64,
                      "frozen_dependencies": False, "full_suite": False}
        for field, value in mismatches.items():
            with self.subTest(field=field):
                self.api = FakeGitHub()
                self.api.manifests[2000][field] = value
                self.rejected("current inputs")
        for field in mismatches:
            with self.subTest(missing=field):
                self.api = FakeGitHub()
                del self.api.manifests[2000][field]
                self.rejected("current inputs")
        self.api = FakeGitHub()
        self.api.manifests[2000]["full_suite"] = 1
        self.rejected("current inputs")

    def test_actual_xcode_sdk_and_simulator_runtime_must_match_current_preflight(self):
        for scheme_index in range(3):
            for field in self.api.manifests[scheme_index + 2000]["toolchain"]:
                with self.subTest(scheme=scheme_index, field=field):
                    self.api = FakeGitHub()
                    self.api.manifests[scheme_index + 2000]["toolchain"][field] = "different"
                    self.rejected("current inputs")
        for field in ("sdk_build", "architecture", "runtime_build"):
            with self.subTest(missing=field):
                self.api = FakeGitHub()
                del self.api.manifests[2000]["toolchain"][field]
                self.rejected("current inputs")

    def test_artifacts_must_be_unique_available_and_bound_to_run_repository_and_commit(self):
        for field, value in (("expired", True), ("size_in_bytes", proof.MAX_ARCHIVE_BYTES + 1),
                             ("size_in_bytes", 0), ("expires_at", iso(NOW)),
                             ("created_at", iso(NOW + timedelta(minutes=1)))):
            with self.subTest(field=field):
                self.api = FakeGitHub()
                self.api.artifacts[0][field] = value
                self.rejected("unavailable")
        for field, value in (("id", 99), ("repository_id", 43), ("head_repository_id", 43),
                             ("head_sha", "f" * 40), ("head_branch", "feature")):
            with self.subTest(provenance=field):
                self.api = FakeGitHub()
                self.api.artifacts[0]["workflow_run"][field] = value
                self.rejected("provenance")
        self.api = FakeGitHub()
        self.api.artifacts.pop()
        self.rejected("Missing")
        self.api = FakeGitHub()
        extra = deepcopy(self.api.artifacts[0])
        extra["id"] = 9999
        self.api.artifacts.append(extra)
        self.rejected("duplicate")

    def test_previous_attempt_artifacts_do_not_disable_complete_current_attempt_proof(self):
        for number, scheme in enumerate(proof.SCHEMES):
            previous = deepcopy(self.api.artifacts[number])
            previous.update(id=number + 3000, name=f"apple-regression-proof-{scheme}-1", expired=True)
            self.api.artifacts.append(previous)
            previous_manifest = deepcopy(self.api.manifests[number + 2000])
            previous_manifest["run_attempt"] = 1
            self.api.manifests[number + 3000] = previous_manifest
        self.assertTrue(self.lookup()["reusable"])
        self.assertFalse(any("/artifacts/300" in path for path, _ in self.api.calls))

    def test_artifact_name_must_match_the_current_attempt(self):
        for attempt in (1, 3):
            with self.subTest(attempt=attempt):
                self.api = FakeGitHub()
                self.api.artifacts[0]["name"] = f"apple-regression-proof-Silo-{attempt}"
                self.rejected("Missing")

    def test_invalid_oversized_or_ambiguous_zip_cannot_be_proof(self):
        value = self.api.manifests[2000]
        bad = [b"not a zip", b"x" * (proof.MAX_ARCHIVE_BYTES + 1),
               zip_json(value, "../regression-proof.json"),
               zip_json(value, extra=("extra.txt", "unexpected")),
               zip_json("x" * (proof.MAX_PROOF_BYTES + 1)),
               zip_json('{"full_suite":true,"full_suite":false}'), zip_json("[]")]
        for archive in bad:
            with self.subTest(size=len(archive)):
                self.api.archives[2000] = archive
                self.rejected()

    def test_complete_pagination_is_required_for_jobs_artifacts_and_runs(self):
        self.api.page_size = 1
        self.assertTrue(self.lookup()["reusable"])
        for key in ("jobs", "artifacts", "workflow_runs"):
            with self.subTest(key=key):
                self.api = FakeGitHub()
                self.api.page_size = 1
                self.api.runs = [{"id": 100}, {"id": 99}]
                self.api.truncated_key = key
                self.rejected("pagination")

    def test_duplicate_api_ids_are_rejected(self):
        self.api.jobs[1]["id"] = self.api.jobs[0]["id"]
        self.rejected("Duplicate")

    def test_missing_timestamps_and_timezone_are_rejected(self):
        for value in (None, "2026-10-07T11:55:00", "invalid"):
            with self.subTest(value=value):
                self.api = FakeGitHub()
                self.api.jobs[0]["completed_at"] = value
                self.rejected()

    def test_rerun_started_or_attempt_changed_while_reading_proof_falls_back(self):
        for changes in ({"status": "in_progress", "conclusion": None}, {"run_attempt": 3}):
            with self.subTest(changes=changes):
                self.api = FakeGitHub()
                self.api.final_run = dict(self.api.run, **changes)
                self.rejected()

    def test_api_failures_fall_back_without_printing_error_details(self):
        for failure in ("/workflows/", "/runs/100", "/attempts/", "/artifacts"):
            with self.subTest(failure=failure):
                self.api = FakeGitHub()
                self.api.fail_path = failure
                self.rejected("full gate")

    def test_malformed_github_response_or_json_falls_back(self):
        for response in (None, [], {}, {"id": 77, "path": proof.WORKFLOW}):
            with self.subTest(response=response), patch.object(self.api, "get", return_value=response):
                self.rejected()
        client = proof.GitHub("test-token")
        with patch.object(client.opener, "open", return_value=io.BytesIO(b"not valid JSON")):
            result = proof.lookup(self.env, client, NOW)
        self.assertFalse(result["reusable"])
        self.assertNotIn("test-token", result["reason"])

    def test_invalid_or_missing_expected_configuration_does_not_use_network(self):
        for field, value in (("GH_TOKEN", ""), ("GH_REPOSITORY", "../../silo-apple"),
                             ("TARGET_SHA", "main"), ("EXPECTED_FINGERPRINT", "wrong"),
                             ("EXPECTED_LOCK_SHA256", "wrong"), ("EXPECTED_TOOLCHAIN_JSON", "{}"),
                             ("EXPECTED_TOOLCHAIN_JSON", "malformed")):
            with self.subTest(field=field):
                self.env = environment()
                self.env[field] = value
                self.api = FakeGitHub()
                self.rejected()
                self.assertEqual(self.api.calls, [])

    def test_missing_expected_simulator_runtime_never_assumes_sdk_equivalence(self):
        values = json.loads(self.env["EXPECTED_TOOLCHAIN_JSON"])
        del values["Silo"]["runtime_build"]
        self.env["EXPECTED_TOOLCHAIN_JSON"] = json.dumps(values)
        self.rejected("toolchain")
        self.assertEqual(self.api.calls, [])

    def test_missing_or_invalid_sdk_build_and_architecture_cannot_establish_equivalence(self):
        for scheme in proof.SCHEMES:
            for field in ("sdk_build", "architecture"):
                with self.subTest(scheme=scheme, field=field, missing=True):
                    self.api = FakeGitHub()
                    self.env = environment()
                    values = json.loads(self.env["EXPECTED_TOOLCHAIN_JSON"])
                    del values[scheme][field]
                    self.env["EXPECTED_TOOLCHAIN_JSON"] = json.dumps(values)
                    self.rejected("toolchain")
                    self.assertEqual(self.api.calls, [])
                for value in (("", "sdk build", "27A123\n") if field == "sdk_build"
                              else ("", "aarch64", "arm64\n", 1)):
                    with self.subTest(scheme=scheme, field=field, invalid=value):
                        self.api = FakeGitHub()
                        self.env = environment()
                        values = json.loads(self.env["EXPECTED_TOOLCHAIN_JSON"])
                        values[scheme][field] = value
                        self.env["EXPECTED_TOOLCHAIN_JSON"] = json.dumps(values)
                        self.rejected()
                        self.assertEqual(self.api.calls, [])

    def test_intel_architecture_proof_is_accepted_when_the_preflight_matches(self):
        values = json.loads(self.env["EXPECTED_TOOLCHAIN_JSON"])
        for scheme in proof.SCHEMES:
            values[scheme]["architecture"] = "x86_64"
        self.env["EXPECTED_TOOLCHAIN_JSON"] = json.dumps(values)
        for manifest in self.api.manifests.values():
            manifest["toolchain"]["architecture"] = "x86_64"
        self.assertTrue(self.lookup()["reusable"])

    def test_json_duplicate_fields_are_rejected(self):
        self.env["EXPECTED_TOOLCHAIN_JSON"] = '{"Silo":{},"Silo":{}}'
        self.rejected("Duplicate")

    def test_main_always_emits_false_outputs_and_success_status_for_fallback(self):
        with tempfile.TemporaryDirectory() as scratch:
            output = Path(scratch) / "github-output"
            stdout = io.StringIO()
            with patch.dict(proof.os.environ, {"GITHUB_OUTPUT": str(output)}, clear=True), patch(
                    "sys.stdout", stdout):
                self.assertEqual(proof.main(), 0)
            self.assertFalse(json.loads(stdout.getvalue())["reusable"])
            self.assertIn("reusable=false\n", output.read_text())
            self.assertIn("run_id=\n", output.read_text())

    def test_missing_output_file_parent_still_falls_back_with_success_status(self):
        with tempfile.TemporaryDirectory() as scratch:
            with patch.dict(proof.os.environ, {"GITHUB_OUTPUT": str(Path(scratch) / "missing" / "output")},
                            clear=True), patch("sys.stdout", io.StringIO()), patch("sys.stderr", io.StringIO()):
                self.assertEqual(proof.main(), 0)

    def test_artifact_redirect_drops_token_and_rejects_plain_http(self):
        request = Request("https://api.github.com/repos/a/b/actions/artifacts/1/zip",
                          headers={"Authorization": "Bearer test-token"})
        handler = proof.ArtifactRedirect()
        redirected = handler.redirect_request(request, None, 302, "Found", {},
                                               "https://storage.example.test/signed-archive")
        self.assertIsNone(redirected.get_header("Authorization"))
        with self.assertRaises(proof.ProofRejected):
            handler.redirect_request(request, None, 302, "Found", {}, "http://storage.example.test/archive")


if __name__ == "__main__":
    unittest.main()
