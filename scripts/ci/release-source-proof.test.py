#!/usr/bin/env python3
"""Offline admission/fallback fixtures; no GitHub state or source downloads."""

import copy
from datetime import datetime, timezone
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import URLError
from urllib.parse import quote, urlencode
from urllib.request import Request
import zipfile


sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("source_proof", Path(__file__).with_name("release-source-proof.py"))
proof = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proof)
ORIGINAL_GIT = proof.git


class SourceProofTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.inputs = {path: (proof.ROOT / path).read_bytes() for path in proof.INPUTS}
        for path, data in self.inputs.items():
            destination = self.root / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
        self.env = {"GITHUB_REPOSITORY": proof.REPOSITORY, "GITHUB_SHA": "a" * 40,
                    "RELEASE_TAG": "v1.2.3", "GH_TOKEN": "fixture-token",
                    "GITHUB_WORKFLOW_REF": proof.REPOSITORY + "/.github/workflows/release.yml@refs/tags/v1.2.3",
                    "GITHUB_WORKFLOW_SHA": "a" * 40, "GITHUB_EVENT_NAME": "push",
                    "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1", "RUNNER_TEMP": str(self.root)}

        def git(*args):
            if args == ("rev-parse", "HEAD"):
                return (self.env["GITHUB_SHA"] + "\n").encode()
            if args == ("rev-parse", "HEAD^{tree}"):
                return ("b" * 40 + "\n").encode()
            if args == ("diff", "--quiet", "HEAD", "--"):
                return b""
            if args[0] == "show":
                return self.inputs[args[1].removeprefix("HEAD:")]
            raise AssertionError(args)

        for mocked in (patch.object(proof, "ROOT", self.root), patch.object(proof, "git", side_effect=git)):
            mocked.start()
            self.addCleanup(mocked.stop)
        self.source = proof.identity(self.env)
        self.tag = self.env["RELEASE_TAG"]
        self.now = datetime(2026, 1, 2, tzinfo=timezone.utc)
        self.archive_bytes = b"exact packaged source fixture, not a live source download"
        name = "Silo-source-" + self.source["sha"] + ".tar.gz"
        self.release = {"id": 10, "tag_name": self.tag, "draft": False,
                        "published_at": "2026-01-01T00:00:00Z", "assets": [{
                            "id": 20, "name": name, "state": "uploaded", "size": len(self.archive_bytes),
                            "digest": "sha256:" + hashlib.sha256(self.archive_bytes).hexdigest(),
                            "browser_download_url": f"https://github.com/{proof.REPOSITORY}/releases/download/{self.tag}/{name}"}]}
        self.asset = proof.asset_identity(self.release, self.source, self.tag)
        self.run = {"id": 123, "run_attempt": 1, "head_sha": self.source["sha"], "head_branch": self.tag,
                    "path": ".github/workflows/release.yml", "event": "push", "status": "in_progress",
                    "conclusion": None, "repository": {"id": 999, "full_name": proof.REPOSITORY},
                    "head_repository": {"id": 999, "full_name": proof.REPOSITORY}}
        self.producer = {"run_id": 123, "run_attempt": 1, "workflow_path": self.run["path"],
                         "workflow_sha": self.source["sha"], "event": "push"}
        self.document = {"schema_version": 1, "repository": proof.REPOSITORY, "source": self.source,
                         "release_tag": self.tag, "asset": self.asset, "producer": self.producer}
        self.artifact = {"id": 456, "name": proof.artifact_name(self.source, self.tag), "expired": False,
                         "size_in_bytes": 4000, "created_at": "2026-01-01T00:01:00Z",
                         "expires_at": "2026-01-15T00:00:00Z", "workflow_run": {
                             "id": 123, "repository_id": 999, "head_repository_id": 999,
                             "head_sha": self.source["sha"], "head_branch": self.tag}}
        self.jobs = {"total_count": 1, "jobs": [{
            "id": 789, "name": "source / Publish release source", "run_id": 123,
            "head_sha": self.source["sha"], "status": "completed", "conclusion": "success",
            "started_at": "2026-01-01T00:00:30Z", "completed_at": "2026-01-01T00:01:30Z",
            "steps": [{"name": name, "status": "completed", "conclusion": "success"} for name in (
                "Package exact app and library sources", "Publish source before distributing binaries",
                "Record published source proof", "Upload published source proof")]}]}

    def zip_document(self, document=None, entries=None):
        result = io.BytesIO()
        with zipfile.ZipFile(result, "w", zipfile.ZIP_DEFLATED) as zipped:
            if entries is not None:
                for entry, content in entries:
                    zipped.writestr(entry, content)
            else:
                zipped.writestr(proof.PROOF_FILE, json.dumps(document or self.document, sort_keys=True))
        data = result.getvalue()
        self.artifact["digest"] = "sha256:" + hashlib.sha256(data).hexdigest()
        self.artifact["size_in_bytes"] = len(data)
        return data

    def api(self, data=None, artifacts=None, final_run=None):
        data = data or self.zip_document()
        root = "/repos/" + proof.REPOSITORY
        responses = {
            root + "/actions/artifacts?" + urlencode({"name": self.artifact["name"], "per_page": 2}):
                {"total_count": len(artifacts or [self.artifact]), "artifacts": artifacts or [self.artifact]},
            root + "/actions/artifacts/456/zip": data,
            root + "/actions/runs/123": self.run,
            root + "/actions/runs/123/attempts/1/jobs?per_page=100": self.jobs,
            root + "/releases/tags/" + quote(self.tag, safe=""): self.release,
        }
        class API:
            def __init__(self):
                self.calls = []
                self.run_reads = 0

            def get(api, path, binary=False):
                api.calls.append((path, binary))
                if path.endswith("/actions/runs/123"):
                    api.run_reads += 1
                    if api.run_reads > 1 and final_run is not None:
                        return final_run
                return responses[path]
        return API()

    def result(self, api=None):
        return proof.find(self.source, self.tag, api or self.api(), self.now)

    def test_complete_source_job_reuses_while_parent_delivery_is_active(self):
        api = self.api()
        result = self.result(api)
        self.assertTrue(result["reusable"])
        self.assertEqual(result["source_url"], self.asset["url"])
        self.assertEqual(len(api.calls), 6)
        self.assertEqual([path for path, binary in api.calls if binary],
                         ["/repos/" + proof.REPOSITORY + "/actions/artifacts/456/zip"])
        # A later binary failure does not invalidate this exact published source.
        self.run.update(status="completed", conclusion="failure")
        self.assertTrue(self.result()["reusable"])

    def test_both_trusted_callers_and_manual_delivery_can_produce_proof(self):
        self.run.update(path=proof.CALLERS[1], event="workflow_dispatch", head_branch="main")
        self.producer.update(workflow_path=proof.CALLERS[1], event="workflow_dispatch")
        self.artifact["workflow_run"]["head_branch"] = "main"
        self.assertTrue(self.result()["reusable"])

    def test_any_source_tree_pin_or_packager_drift_prevents_reuse(self):
        for field in ("sha", "tree", "graph", "inputs"):
            with self.subTest(field=field):
                changed = copy.deepcopy(self.document)
                if field == "graph":
                    changed["source"][field][-1]["revision"] = "c" * 40
                elif field == "inputs":
                    changed["source"][field]["scripts/ci/package-release-source.py"] = "c" * 64
                else:
                    changed["source"][field] = "c" * 40
                self.assertFalse(self.result(self.api(self.zip_document(changed)))["reusable"])
        changed = copy.deepcopy(self.document)
        changed["release_tag"] = "different-tag"
        self.assertFalse(self.result(self.api(self.zip_document(changed)))["reusable"])

    def test_asset_replacement_digest_size_url_and_draft_each_prevent_reuse(self):
        cases = [("id", 21), ("size", self.asset["size"] + 1), ("digest", "sha256:" + "c" * 64),
                 ("state", "new"), ("digest", None), ("browser_download_url", "https://example.com/source.tar.gz"),
                 ("browser_download_url", self.asset["url"] + "?download=1"),
                 ("browser_download_url", self.asset["url"].replace(self.tag, "different-tag"))]
        for key, value in cases:
            with self.subTest(key=key, value=value):
                original = self.release["assets"][0][key]
                self.release["assets"][0][key] = value
                self.assertFalse(self.result()["reusable"])
                self.release["assets"][0][key] = original
        self.release["draft"] = True
        self.assertFalse(self.result()["reusable"])

    def test_noncanonical_repository_workflow_commit_event_attempt_prevent_reuse(self):
        cases = [("head_sha", "c" * 40), ("head_branch", None), ("run_attempt", 2), ("event", "pull_request"),
                 ("path", ".github/workflows/untrusted.yml"),
                 ("head_repository", {"id": 1000, "full_name": "fork/silo-apple"}),
                 ("repository", {"id": 1000, "full_name": "fork/silo-apple"})]
        for key, value in cases:
            with self.subTest(key=key):
                original = self.run[key]
                self.run[key] = value
                self.assertFalse(self.result()["reusable"])
                self.run[key] = original
        changed = copy.deepcopy(self.document)
        changed["producer"]["workflow_sha"] = "c" * 40
        self.assertFalse(self.result(self.api(self.zip_document(changed)))["reusable"])
        changed = copy.deepcopy(self.document)
        changed["producer"]["run_attempt"] = True
        self.assertFalse(self.result(self.api(self.zip_document(changed)))["reusable"])
        changed = copy.deepcopy(self.document)
        changed["producer"]["run_id"] = "../../unrelated-api"
        api = self.api(self.zip_document(changed))
        self.assertFalse(self.result(api)["reusable"])
        self.assertEqual(len(api.calls), 2, "Invalid producer IDs must reject before any run API request")

    def test_missing_failed_active_or_duplicate_source_job_prevents_reuse(self):
        original = copy.deepcopy(self.jobs)
        for key, value in (("status", "in_progress"), ("conclusion", "failure"),
                           ("head_sha", "c" * 40), ("run_id", 124), ("name", "different job")):
            with self.subTest(key=key):
                self.jobs["jobs"][0][key] = value
                self.assertFalse(self.result()["reusable"])
                self.jobs = copy.deepcopy(original)
        self.jobs["jobs"].append(dict(self.jobs["jobs"][0], id=790))
        self.jobs["total_count"] = 2
        self.assertFalse(self.result()["reusable"])
        self.jobs = copy.deepcopy(original)
        self.jobs["total_count"] = 2
        self.assertFalse(self.result()["reusable"])

    def test_recursive_reuse_and_incomplete_publication_cannot_produce_accepted_proof(self):
        for step in self.jobs["jobs"][0]["steps"]:
            original = step["conclusion"]
            for conclusion in ("skipped", "failure", "cancelled"):
                with self.subTest(step=step["name"], conclusion=conclusion):
                    step["conclusion"] = conclusion
                    self.assertFalse(self.result()["reusable"])
            step["conclusion"] = original

    def test_artifact_digest_provenance_expiry_and_job_interval_are_required(self):
        data = self.zip_document()
        cases = [("digest", "sha256:" + "d" * 64), ("expired", True), ("id", True),
                 ("size_in_bytes", proof.MAX_ZIP_BYTES + 1), ("expires_at", "2026-01-01T00:00:00Z"),
                 ("created_at", "2026-01-01T00:00:00Z"), ("created_at", "2026-01-01T00:02:00Z"),
                 ("workflow_run", dict(self.artifact["workflow_run"], head_repository_id=1000))]
        for key, value in cases:
            with self.subTest(key=key, value=value):
                original = self.artifact[key]
                self.artifact[key] = value
                self.assertFalse(self.result(self.api(data))["reusable"])
                self.artifact[key] = original

    def test_bad_zip_duplicate_json_path_links_or_oversized_proof_are_rejected(self):
        entries = [
            [("../" + proof.PROOF_FILE, b"{}")],
            [(proof.PROOF_FILE, b"{}"), ("extra.txt", b"extra")],
            [(proof.PROOF_FILE, b'{"schema_version":1,"schema_version":1}')],
            [(proof.PROOF_FILE, b"x" * (proof.MAX_PROOF_BYTES + 1))],
        ]
        link = zipfile.ZipInfo(proof.PROOF_FILE)
        link.external_attr = 0o120777 << 16
        entries.append([(link, b"target")])
        for values in entries:
            with self.subTest(entries=values[0][0]):
                self.assertFalse(self.result(self.api(self.zip_document(entries=values)))["reusable"])
        data = b"not a ZIP"
        self.artifact["digest"] = "sha256:" + hashlib.sha256(data).hexdigest()
        self.assertFalse(self.result(self.api(data))["reusable"])

    def test_rerun_during_lookup_prevents_reuse(self):
        self.assertFalse(self.result(self.api(final_run=dict(self.run, run_attempt=2)))["reusable"])

    def test_missing_or_unavailable_proof_uses_full_path_without_raw_errors(self):
        class Missing:
            def get(api, path, binary=False):
                return {"total_count": 0, "artifacts": []}
        self.assertFalse(self.result(Missing())["reusable"])
        class Unavailable:
            def get(api, path, binary=False):
                raise URLError("fixture-token must not appear in output")
        result = proof.execute("find", self.env, api=Unavailable())
        self.assertFalse(result["reusable"])
        self.assertNotIn("fixture-token", json.dumps(result))
        self.assertEqual(result["source_url"], "")

    def test_incompatible_newest_candidate_does_not_hide_second_matching_proof(self):
        data = self.zip_document()
        rejected = dict(self.artifact, id=457, expired=True)
        api = self.api(data, artifacts=[rejected, self.artifact])
        self.assertTrue(self.result(api)["reusable"])
        self.assertEqual(len(api.calls), 6)

    def test_record_binds_exact_local_archive_to_asset_and_roundtrips(self):
        archive = self.root / self.asset["name"]
        archive.write_bytes(self.archive_bytes)
        result = proof.record(self.source, self.tag, self.api(), self.env, self.root)
        self.assertTrue(result["created"])
        self.assertEqual(result["artifact_name"], self.artifact["name"])
        document = json.loads((self.root / "release-source-proof" / proof.PROOF_FILE).read_text())
        self.assertEqual(document, self.document)
        self.assertTrue(self.result(self.api(self.zip_document(document)))["reusable"])

    def test_record_digest_mismatch_or_untrusted_caller_creates_no_proof(self):
        archive = self.root / self.asset["name"]
        archive.write_bytes(b"different source archive")
        result = proof.execute("record", self.env, self.root, self.api())
        self.assertFalse(result["created"])
        self.assertFalse((self.root / "release-source-proof" / proof.PROOF_FILE).exists())
        archive.write_bytes(self.archive_bytes)
        env = dict(self.env, GITHUB_WORKFLOW_REF=proof.REPOSITORY + "/untrusted.yml@main")
        self.assertFalse(proof.execute("record", env, self.root, self.api())["created"])
        for field, value in (("GITHUB_WORKFLOW_SHA", "c" * 40), ("GITHUB_EVENT_NAME", "pull_request"),
                             ("GITHUB_RUN_ATTEMPT", "0")):
            with self.subTest(field=field):
                self.assertFalse(proof.execute("record", dict(self.env, **{field: value}),
                                               self.root, self.api())["created"])

    def test_identity_covers_all_18_pins_and_immutable_packaging_inputs(self):
        self.assertEqual(len(self.source["graph"]), 18)
        self.assertEqual([item["kind"] for item in self.source["graph"]],
                         ["package"] * 11 + ["builder"] + ["native"] * 6)
        path = "scripts/ci/package-release-source.py"
        (self.root / path).write_bytes(self.inputs[path] + b"\n# changed after checkout\n")
        with self.assertRaises(proof.Rejected):
            proof.identity(self.env)
        self.assertFalse(proof.execute("find", self.env, api=self.api())["reusable"])
        (self.root / path).write_bytes(self.inputs[path])
        pins = json.loads(self.inputs[proof.PINS])
        pins["swift_libass_revision"] = "c" * 40
        self.inputs[proof.PINS] = json.dumps(pins).encode()
        (self.root / proof.PINS).write_bytes(self.inputs[proof.PINS])
        with self.assertRaises(proof.Rejected):
            proof.identity(self.env)

    def test_git_wrapper_disables_replacements(self):
        # Test the real wrapper separately from the fixture source graph.
        with patch.object(subprocess, "check_output", return_value=b"fixture") as command:
            self.assertEqual(ORIGINAL_GIT("rev-parse", "HEAD"), b"fixture")
        self.assertEqual(command.call_args.args[0][:2], ["git", "--no-replace-objects"])
        self.assertEqual(command.call_args.kwargs["timeout"], 5)

    def test_network_deadline_response_limit_and_cross_host_token_removal(self):
        api = proof.GitHub("fixture-token")
        with patch.object(proof.time, "monotonic", return_value=api.deadline + 1), patch.object(api.opener, "open") as request:
            with self.assertRaises(proof.Rejected):
                api.get("/repos/" + proof.REPOSITORY + "/actions/artifacts")
            request.assert_not_called()
        response = io.BytesIO(b"x" * (proof.MAX_ZIP_BYTES + 1))
        with patch.object(api.opener, "open", return_value=response):
            with self.assertRaises(proof.Rejected):
                api.get("/repos/" + proof.REPOSITORY + "/actions/artifacts/1/zip", binary=True)
        redirect = proof.ArtifactRedirect()
        request = Request("https://api.github.com/repos/example/artifact", headers={"Authorization": "Bearer fixture-token"})
        redirected = redirect.redirect_request(request, None, 302, "Found", {}, "https://storage.example/artifact")
        self.assertIsNone(redirected.get_header("Authorization"))
        with self.assertRaises(proof.Rejected):
            redirect.redirect_request(request, None, 302, "Found", {}, "http://storage.example/artifact")

    def test_partial_output_error_and_actual_workflow_controls_select_full_publication(self):
        output_path = self.root / "github-output"
        writes = []
        class InterruptedOutput:
            def __enter__(target):
                return target

            def __exit__(target, *args):
                pass

            def write(target, buffer):
                writes.append(buffer)
                with open(output_path, "w") as output:
                    output.write("reusable=true\n")
                raise OSError("fixture-token output failure")

        result = {"reusable": True, "source_url": self.asset["url"], "reason": "fixture success"}
        with patch.object(proof, "execute", return_value=result), patch.object(sys, "argv", ["source-proof", "find"]), \
                patch.dict(os.environ, {"GITHUB_OUTPUT": str(output_path)}), \
                patch.object(Path, "open", return_value=InterruptedOutput()), \
                patch.object(sys, "stdout", io.StringIO()), patch.object(sys, "stderr", io.StringIO()) as error:
            self.assertEqual(proof.main(), 1)
            self.assertNotIn("fixture-token", error.getvalue())
        self.assertEqual(len(writes), 1)
        self.assertIn("reusable=true\nsource_url=" + self.asset["url"] + "\n", writes[0])
        self.assertEqual(output_path.read_text(), "reusable=true\n")

        # Evaluate the actual fixed boolean expressions in the workflow for
        # partial output, failed/timed-out find, and complete successful output.
        workflow = Path(__file__).parents[2] / ".github/workflows/release-source.yml"
        text = workflow.read_text()
        gates = re.findall(r"        if: \$\{\{ (.*?) \}\}", text)
        full_path = [gate for gate in gates if "steps.reuse." in gate]
        upload_proof = [gate for gate in gates if "steps.proof." in gate]
        source_url = re.search(r"      source_url: \$\{\{ (.*?) \}\}", text).group(1)
        self.assertEqual(len(full_path), 3)
        self.assertEqual(len(upload_proof), 1)
        def evaluate(expression, outcome, reusable, url):
            values = {"steps.reuse.outcome": outcome, "steps.reuse.outputs.reusable": reusable,
                      "steps.reuse.outputs.source_url": url, "steps.publish.outputs.source_url": "full-publication",
                      "steps.proof.outcome": outcome, "steps.proof.outputs.created": reusable,
                      "steps.proof.outputs.artifact_name": url}
            for name in sorted(values, key=len, reverse=True):
                expression = expression.replace(name, repr(values[name]))
            expression = expression.replace("&&", " and ").replace("||", " or ").replace("!(", "not (")
            return eval(expression, {"__builtins__": {}}, {})
        for outcome, reusable, url in (("failure", "true", ""), ("success", "true", ""),
                                        ("failure", "true", self.asset["url"]), ("success", "", "")):
            with self.subTest(outcome=outcome, reusable=reusable, url=url):
                self.assertTrue(all(evaluate(gate, outcome, reusable, url) for gate in full_path))
                self.assertEqual(evaluate(source_url, outcome, reusable, url), "full-publication")
                self.assertFalse(evaluate(upload_proof[0], outcome, reusable, url))
        self.assertFalse(any(evaluate(gate, "success", "true", self.asset["url"]) for gate in full_path))
        self.assertEqual(evaluate(source_url, "success", "true", self.asset["url"]), self.asset["url"])
        self.assertTrue(evaluate(upload_proof[0], "success", "true", "complete-proof-name"))

    def test_actual_cli_output_failure_returns_nonzero_with_safe_error(self):
        script = Path(__file__).with_name("release-source-proof.py")
        env = dict(os.environ, GITHUB_REPOSITORY="fixture/invalid", GITHUB_OUTPUT=str(self.root))
        result = subprocess.run([sys.executable, str(script), "find"], env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(json.loads(result.stdout)["reusable"])
        self.assertEqual(result.stderr.decode().strip(),
                         "Unable to write source proof outputs; use the full packaging path")

    def test_real_committed_source_records_and_tracked_app_mutation_invalidates_proof(self):
        def fixture_git(*args):
            return subprocess.check_output(["git", "--no-replace-objects", "-C", str(self.root), *args],
                                           stderr=subprocess.DEVNULL, timeout=10)
        app = self.root / "iosApp/source-fixture.swift"
        app.write_text("// committed fixture app source\n")
        fixture_git("init", "--quiet")
        fixture_git("add", "--", ".")
        # This disposable synthetic repository is the offline Git-command
        # control. It creates no commit or ref in any shipping repository.
        fixture_git("-c", "user.name=Source Fixture", "-c", "user.email=fixture@example.invalid",
                    "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "source fixture")
        sha = fixture_git("rev-parse", "HEAD").decode().strip()
        tree = fixture_git("rev-parse", "HEAD^{tree}").decode().strip()
        lock = fixture_git("show", "HEAD:" + proof.RESOLVED)
        env = dict(self.env, GITHUB_SHA=sha, GITHUB_WORKFLOW_SHA=sha)
        with patch.object(proof, "git", new=ORIGINAL_GIT):
            source = proof.identity(env)
            self.assertEqual(source["sha"], sha)
            self.assertEqual(source["tree"], tree)
            release = copy.deepcopy(self.release)
            release["assets"][0]["name"] = "Silo-source-" + sha + ".tar.gz"
            release["assets"][0]["browser_download_url"] = self.asset["url"].replace(self.source["sha"], sha)
            class API:
                def get(api, path, binary=False):
                    return release
            (self.root / release["assets"][0]["name"]).write_bytes(self.archive_bytes)
            self.assertTrue(proof.record(source, self.tag, API(), env, self.root)["created"])
            recorded = json.loads((self.root / "release-source-proof" / proof.PROOF_FILE).read_text())
            self.assertEqual(recorded["source"], source)
            app.write_text("// changed tracked app source after checkout\n")
            self.assertEqual(fixture_git("rev-parse", "HEAD").decode().strip(), sha)
            self.assertEqual(fixture_git("rev-parse", "HEAD^{tree}").decode().strip(), tree)
            self.assertEqual(fixture_git("show", "HEAD:" + proof.RESOLVED), lock)
            self.assertFalse(proof.execute("find", env, api=API())["reusable"])
            self.assertFalse(proof.execute("record", env, self.root, API())["created"])


if __name__ == "__main__":
    unittest.main()
