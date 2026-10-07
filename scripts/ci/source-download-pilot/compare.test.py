#!/usr/bin/env python3
"""Offline checks on an actual clean committed source checkout."""
import copy
import importlib.util
import io
import json
from pathlib import Path
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
SOURCE = Path(sys.argv.pop(1)).resolve()
spec = importlib.util.spec_from_file_location("pilot", HERE / "compare.py")
pilot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pilot)


class PilotTests(unittest.TestCase):
    def setUp(self):
        self.expected = json.loads((HERE / "binding.json").read_text())
        self.expected.update(source_sha=pilot.git(SOURCE, "rev-parse", "HEAD"),
                             source_tree=pilot.git(SOURCE, "rev-parse", "HEAD^{tree}"))
        self.pins = json.loads((SOURCE / pilot.PINS).read_text())
        self.responses, self.closed_responses, self.arm_index = {}, [], 0

    def response(self, url, **kwargs):
        self.assertEqual(kwargs, {"timeout": 120})
        if url not in self.responses:
            builder = "checkout() { echo fetch; }\ncheckout\necho build\n"
            source_map = "\n".join(f'  {pin["name"]})\n    SOURCE_REPO_URL="{pin["repository"]}"\n'
                                    f'    SOURCE_ID="{pin["tag"]}"\n    ;;' for pin in self.pins["libraries"])
            buffer = io.BytesIO()
            with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
                for name, body, mode in (("source/build-libraries.sh", builder, 0o644),
                                         ("source/scripts/source.sh", source_map, 0o644),
                                         ("source/source.txt", url, 0o644), ("source/tool.sh", "echo tool\n", 0o755)):
                    data = body.encode()
                    member = tarfile.TarInfo(name)
                    member.mode, member.size = mode, len(data)
                    archive.addfile(member, io.BytesIO(data))
                link = tarfile.TarInfo("source/source-link")
                link.type, link.linkname = tarfile.SYMTYPE, "source.txt"
                archive.addfile(link)
            self.responses[url] = buffer.getvalue()
        data = bytearray(self.responses[url])
        # Different gzip headers must retain identical extracted member payloads.
        data[4:8] = (self.arm_index + 1).to_bytes(4, "little")
        time.sleep(0.025)
        response = io.BytesIO(data)
        self.closed_responses.append(response)
        return response

    def offline_arm(self, command, log, scratch, receipt):
        self.arm_index = int(command[command.index("--arm") + 1])
        output = Path(command[command.index("--output") + 1])
        record = None
        with patch("tempfile.tempdir", str(scratch)), patch("urllib.request.urlopen", side_effect=self.response):
            record = pilot.execute_arm(pilot.ORDER[self.arm_index], SOURCE, output / "archive", self.expected,
                                       command[command.index("--app-tar-digest") + 1])
        receipt.update(exit_code=0 if record["result"] == "passed" else 1, cleanup_complete=True)
        return receipt["exit_code"]

    def test_unfrozen_binding_and_wrong_source_or_helper_reject_before_downloads(self):
        unfrozen = dict(self.expected, source_sha=None, source_tree=None)
        with patch.object(pilot.Path, "read_text", return_value=json.dumps(unfrozen)):
            with self.assertRaisesRegex(ValueError, "not been frozen"):
                pilot.binding()
        with patch.object(pilot.Path, "read_text", return_value=json.dumps(self.expected)):
            self.assertEqual(pilot.binding(), self.expected)
        for key in ("source_sha", "source_tree"):
            wrong = dict(self.expected, **{key: "0" * 40})
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "frozen commit/tree"):
                pilot.validate_source(SOURCE, wrong)
        wrong = copy.deepcopy(self.expected)
        wrong["helpers"]["candidate"] = "0" * 64
        with tempfile.TemporaryDirectory() as scratch, patch("urllib.request.urlopen") as fetch:
            with self.assertRaisesRegex(ValueError, "helper bytes changed"):
                pilot.execute_arm("candidate", SOURCE, Path(scratch), wrong, "0" * 64)
            fetch.assert_not_called()

    def test_wrong_event_repository_or_branch_rejects_before_packaging(self):
        context = {"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REPOSITORY": "Silo-Server/silo-apple",
                   "GITHUB_REF": "refs/heads/private/apple-source-download-pilot"}
        for key, value in (("GITHUB_EVENT_NAME", "push"), ("GITHUB_REPOSITORY", "fixture/fork"),
                           ("GITHUB_REF", "refs/heads/main")):
            with self.subTest(key=key), patch.dict(pilot.os.environ, dict(context, **{key: value})), patch.object(pilot, "git") as git:
                with self.assertRaisesRegex(ValueError, "manual private-branch context"):
                    pilot.validate_context()
                git.assert_not_called()

    def test_overlapping_phases_are_not_summed_as_wall_time(self):
        events = [{"phase": "download", "start": 0, "end": 5}, {"phase": "download", "start": 1, "end": 2},
                  {"phase": "download", "start": 6, "end": 8}]
        result = pilot.phases(events)["download"]
        self.assertEqual(result["operation_seconds_sum"], 8)
        self.assertEqual(result["active_wall_seconds"], 7)
        self.assertEqual(result["span_seconds"], 8)

    def test_git_tree_replacement_cannot_change_frozen_app_archive(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            clone = root / "source"
            subprocess.run(["git", "clone", "--shared", "--no-checkout", str(SOURCE), str(clone)], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["git", "-C", str(clone), "checkout", "--detach", self.expected["source_sha"]], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            # Build a separate attack tree without requiring parent history.
            replacement_tree = subprocess.check_output(["git", "-C", str(clone), "mktree"], input=b"").decode().strip()
            self.assertNotEqual(replacement_tree, self.expected["source_tree"])
            subprocess.run(["git", "-C", str(clone), "replace", self.expected["source_tree"], replacement_tree], check=True)
            original, replaced = root / "original.tar", root / "replaced.tar"
            subprocess.run(["git", "--no-replace-objects", "-C", str(clone), "archive", "HEAD", "-o", str(original)], check=True)
            subprocess.run(["git", "-C", str(clone), "archive", "HEAD", "-o", str(replaced)], check=True)
            self.assertNotEqual(pilot.digest(original), pilot.digest(replaced))
            output, temporary = root / "arm", root / "tmp"
            output.mkdir()
            temporary.mkdir()
            with patch("tempfile.tempdir", str(temporary)), patch("urllib.request.urlopen", side_effect=self.response):
                record = pilot.execute_arm("candidate", clone, output / "archive", self.expected, pilot.digest(original))
            self.assertEqual(record["result"], "passed")
            self.assertTrue(record["app_archive_matches_committed_snapshot"])

    def test_four_real_archives_match_despite_gzip_provenance_changes(self):
        with tempfile.TemporaryDirectory() as scratch, patch.object(pilot, "run_owned", side_effect=self.offline_arm):
            output = Path(scratch) / "comparison"
            pilot.compare(SOURCE, output, self.expected)
            report = json.loads((output / "comparison.json").read_text())
            self.assertTrue(report["qualified"])
            self.assertEqual([arm["kind"] for arm in report["arms"]], list(pilot.ORDER))
            self.assertEqual([arm["observed_acquisition_concurrency"] for arm in report["arms"]], [1, 2, 1, 2])
            self.assertTrue(all(arm["app_archive_matches_committed_snapshot"] for arm in report["arms"]))
            self.assertTrue(all(len(arm["download_results"]) == 18 for arm in report["arms"]))
            self.assertTrue(all(arm["phases"]["source_extraction"]["operations"] == 18 for arm in report["arms"]))
            self.assertTrue(all(arm["phases"]["final_compression"]["operations"] == 1 for arm in report["arms"]))
            self.assertEqual(len(report["arms"][1]["downloaded_archive_digest_changes"]), 18)
            self.assertTrue(all(response.closed for response in self.closed_responses))

    def test_network_failure_is_retained_and_no_partial_comparison_qualifies(self):
        def fail(command, log, scratch, receipt):
            with patch("urllib.request.urlopen", side_effect=OSError("fixture transport failed")):
                output = Path(command[command.index("--output") + 1])
                record = pilot.execute_arm("sequential", SOURCE, output / "archive", self.expected,
                                           command[command.index("--app-tar-digest") + 1])
            receipt.update(exit_code=1, cleanup_complete=True)
            return 1

        with tempfile.TemporaryDirectory() as scratch, patch.object(pilot, "run_owned", side_effect=fail):
            output = Path(scratch) / "comparison"
            with self.assertRaisesRegex(ValueError, "exited 1"):
                pilot.compare(SOURCE, output, self.expected)
            report = json.loads((output / "comparison.json").read_text())
            self.assertFalse(report["qualified"])
            self.assertEqual(len(report["arms"]), 1)
            self.assertEqual(report["arms"][0]["error_type"], "OSError")
            self.assertFalse(list(output.rglob("*.tar.gz")))

    def test_archive_mode_change_blocks_comparison(self):
        def altered(command, log, scratch, receipt):
            returncode = self.offline_arm(command, log, scratch, receipt)
            if self.arm_index == 1:
                output = Path(command[command.index("--output") + 1])
                record = json.loads((output / "timing.json").read_text())
                path = Path(record["archive"])
                replacement = path.with_suffix(".replacement")
                with tarfile.open(path) as before, tarfile.open(replacement, "w:gz") as after:
                    for member in before:
                        if member.name.endswith("packages/swift-libass/tool.sh"):
                            member.mode = 0o644
                        after.addfile(member, before.extractfile(member) if member.isfile() else None)
                replacement.replace(path)
            return returncode

        with tempfile.TemporaryDirectory() as scratch, patch.object(pilot, "run_owned", side_effect=altered):
            output = Path(scratch) / "comparison"
            with self.assertRaisesRegex(ValueError, "archive payload"):
                pilot.compare(SOURCE, output, self.expected)
            report = json.loads((output / "comparison.json").read_text())
            self.assertFalse(report["qualified"])
            self.assertEqual(len(report["arms"]), 2)

    def test_interrupt_wait_stops_and_reaps_only_owned_process_group(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            ready = root / "ready"
            code = '''import pathlib,signal,subprocess,sys,time
child=subprocess.Popen([sys.executable,"-c","import time;time.sleep(60)"])
def stop(*args):
    child.terminate()
    child.wait()
    sys.exit(0)
signal.signal(signal.SIGTERM,stop)
pathlib.Path(sys.argv[1]).write_text(str(child.pid))
time.sleep(60)
'''
            original_popen = pilot.subprocess.Popen
            owned = []

            def popen(*args, **kwargs):
                process = original_popen(*args, **kwargs)
                owned.append(process)
                original_wait = process.wait
                calls = 0

                def wait(*args, **kwargs):
                    nonlocal calls
                    calls += 1
                    if calls <= 2:
                        deadline = time.monotonic() + 5
                        while not ready.exists() and time.monotonic() < deadline:
                            time.sleep(0.01)
                        self.assertTrue(ready.exists())
                        raise KeyboardInterrupt("fixture wait interrupted")
                    return original_wait(*args, **kwargs)

                process.wait = wait
                return process

            receipt = {}
            with (root / "process.log").open("wb") as log, patch.object(pilot.subprocess, "Popen", side_effect=popen):
                with self.assertRaisesRegex(KeyboardInterrupt, "fixture wait interrupted"):
                    pilot.run_owned([sys.executable, "-c", code, str(ready)], log, root, receipt)
            self.assertTrue(receipt["cleanup_complete"])
            self.assertEqual(receipt["owned_process_group"], owned[0].pid)
            self.assertEqual(receipt["wait_error_type"], "KeyboardInterrupt")
            self.assertEqual(receipt["cleanup_wait_error_type"], "KeyboardInterrupt")
            self.assertTrue(any(item["signal"] == "SIGTERM" and item["sent"] for item in receipt["termination_signals"]))
            self.assertIsNotNone(receipt["exit_code"])
            with self.assertRaises(ProcessLookupError):
                pilot.os.kill(int(ready.read_text()), 0)

    def test_timeout_records_term_and_kill_escalation_for_owned_group(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            ready = root / "ready"
            child_code = 'import os,pathlib,signal,sys,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);pathlib.Path(sys.argv[1]).write_text(str(os.getpid()));time.sleep(60)'
            code = 'import signal,subprocess,sys,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);subprocess.Popen([sys.executable,"-c",sys.argv[2],sys.argv[1]]);time.sleep(60)'
            original_popen = pilot.subprocess.Popen

            def popen(*args, **kwargs):
                process = original_popen(*args, **kwargs)
                original_wait = process.wait
                calls = 0

                def wait(*args, **kwargs):
                    nonlocal calls
                    calls += 1
                    if calls == 1:
                        deadline = time.monotonic() + 5
                        while not ready.exists() and time.monotonic() < deadline:
                            time.sleep(0.01)
                        self.assertTrue(ready.exists())
                        raise subprocess.TimeoutExpired("fixture", 480)
                    if calls == 2:
                        raise subprocess.TimeoutExpired("fixture", 10)
                    return original_wait(*args, **kwargs)

                process.wait = wait
                return process

            receipt = {}
            with (root / "process.log").open("wb") as log, patch.object(pilot.subprocess, "Popen", side_effect=popen):
                with self.assertRaisesRegex(ValueError, "eight-minute limit"):
                    pilot.run_owned([sys.executable, "-c", code, str(ready), child_code], log, root, receipt)
            self.assertTrue(receipt["timed_out"])
            self.assertTrue(receipt["cleanup_complete"])
            self.assertEqual(receipt["exit_code"], -signal.SIGKILL)
            self.assertTrue(any(item["signal"] == "SIGTERM" and item["sent"] for item in receipt["termination_signals"]))
            self.assertTrue(any(item["signal"] == "SIGKILL" and item["sent"] for item in receipt["termination_signals"]))
            with self.assertRaises(ProcessLookupError):
                pilot.os.kill(int(ready.read_text()), 0)


if __name__ == "__main__":
    unittest.main()
