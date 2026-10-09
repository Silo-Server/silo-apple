#!/usr/bin/env python3
"""Exercise platform selection against real commits and merge checkouts."""

import importlib.util
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


sys.dont_write_bytecode = True
SCRIPT = Path(__file__).with_name("select-apple-platforms.py")
PROJECT = SCRIPT.parents[2] / "iosApp/project.yml"
CONFIGS = {str(path.relative_to(SCRIPT.parents[2])): path.read_text() for path in PROJECT.with_name("Signing").glob("*.xcconfig")}
spec = importlib.util.spec_from_file_location("apple_platforms", SCRIPT)
apple_platforms = importlib.util.module_from_spec(spec)
spec.loader.exec_module(apple_platforms)
ALL = ["ios", "tvos", "macos"]


class PlatformSelectionTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="apple-platforms-")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git("init", "-b", "main")
        self.git("config", "user.name", "CI fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.write("iosApp/project.yml", PROJECT.read_text())
        for path, contents in CONFIGS.items():
            self.write(path, contents)
        for path in (
            "iosApp/iosApp/macOS/Player.swift",
            "iosApp/TopShelf/ContentProvider.swift",
            "iosApp/NotificationService/NotificationService.swift",
            "iosApp/DownloadsActivity/DownloadsLiveActivity.swift",
            "iosApp/iosApp/Screens/Player/iOS/Player.swift",
            "iosApp/iosApp/tvOS/Player.swift",
            "docs/build.md", "README.md", "LICENSE", "APPSTORE-EXCEPTION.md",
        ):
            self.write(path, "original\n")
        self.base = self.commit("base")

    def git(self, *args):
        return subprocess.run(
            ["git", "-C", str(self.repo), *args],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True,
        ).stdout.decode().strip()

    def write(self, path, contents="changed\n"):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(contents)

    def commit(self, message="change"):
        self.git("add", "--all")
        self.git("commit", "--quiet", "-m", message)
        return self.git("rev-parse", "HEAD")

    def push_selection(self, before=None, **kwargs):
        head = self.git("rev-parse", "HEAD")
        return apple_platforms.select_platforms(
            self.repo, {"before": before or self.base, "after": head}, "push", **kwargs,
        )

    def test_reviewed_build_input_snapshot_matches_the_current_repository(self):
        self.assertEqual(
            apple_platforms.build_inputs_fingerprint(PROJECT.read_text(), CONFIGS),
            apple_platforms.BUILD_INPUTS_SHA256,
        )

    def test_owned_directories_select_only_their_actual_platform(self):
        for path, expected in (
            ("iosApp/iosApp/macOS/Player.swift", ["macos"]),
            ("iosApp/TopShelf/ContentProvider.swift", ["tvos"]),
            ("iosApp/NotificationService/NotificationService.swift", ["ios"]),
            ("iosApp/DownloadsActivity/DownloadsLiveActivity.swift", ["ios"]),
        ):
            with self.subTest(path=path):
                self.git("reset", "--hard", self.base)
                self.write(path)
                head = self.commit()
                result = self.push_selection()
                self.assertEqual(result["platforms"], expected)
                self.assertEqual(result["head_sha"], head)
                self.assertEqual(result["base_sha"], self.base)

    def test_multiple_owned_directories_union_their_platforms(self):
        self.write("iosApp/iosApp/macOS/Player.swift")
        self.write("iosApp/DownloadsActivity/DownloadsLiveActivity.swift")
        self.commit()
        self.assertEqual(self.push_selection()["platforms"], ["ios", "macos"])

    def test_shared_build_inputs_are_never_narrowed_by_swift_guards_or_file_extension(self):
        for path in (
            "iosApp/iosApp/Screens/Player/iOS/Player.swift",
            "iosApp/iosApp/tvOS/Player.swift",
            "iosApp/iosApp/Shared/Storage.swift",
            "iosApp/Resources/license.md",
            "iosApp/Tests/Test.swift",
            "iosApp/Signing/SiloMac.xcconfig",
            "iosApp/Package.resolved",
            "iosApp/iosApp/macOS-Info.plist",
            "LICENSE", "APPSTORE-EXCEPTION.md",
            "scripts/ci/helper.py",
            ".github/workflows/player-regression.yml",
            "fastlane/Fastfile",
            "unknown.file",
            "docs/generated.swift",
        ):
            with self.subTest(path=path):
                self.git("reset", "--hard", self.base)
                self.git("clean", "-fd")
                self.write(path, "#if os(iOS)\nchanged\n#endif\n")
                self.commit()
                self.assertEqual(self.push_selection()["platforms"], ALL)

    def test_known_documentation_requires_no_apple_build(self):
        self.write("README.md")
        self.write("docs/build.md")
        self.commit()
        result = self.push_selection()
        self.assertEqual(result["platforms"], [])
        self.assertEqual(result["changed_files"], 2)

    def test_documentation_does_not_hide_bundled_app_store_permission(self):
        self.write("README.md")
        self.write("APPSTORE-EXCEPTION.md")
        self.commit()
        self.assertEqual(self.push_selection()["platforms"], ALL)

    def test_even_owned_or_documentation_deletions_run_all_platforms(self):
        for path in ("iosApp/iosApp/macOS/Player.swift", "docs/build.md"):
            with self.subTest(path=path):
                self.git("reset", "--hard", self.base)
                (self.repo / path).unlink()
                self.commit()
                self.assertEqual(self.push_selection()["platforms"], ALL)

    def test_renames_preserve_both_paths_and_run_all_platforms(self):
        old = "iosApp/iosApp/macOS/Player.swift"
        new = "iosApp/TopShelf/Renamed Player.swift"
        self.git("mv", old, new)
        head = self.commit()
        raw = apple_platforms.git(self.repo, "diff", "--find-renames", "--name-status", "-z", self.base, head)
        self.assertEqual(apple_platforms.parse_changes(raw), [("R100", (old, new))])
        self.assertEqual(self.push_selection()["platforms"], ALL)

    def test_spaces_and_shell_metacharacters_are_literal_git_paths(self):
        path = "iosApp/iosApp/macOS/Player $(touch ROUTER_EXECUTED) with spaces.swift"
        self.write(path)
        self.commit()
        self.assertEqual(self.push_selection()["platforms"], ["macos"])
        self.assertFalse((self.repo / "ROUTER_EXECUTED").exists())

    def test_comparison_includes_more_than_api_file_pagination_limit(self):
        for index in range(325):
            self.write(f"iosApp/TopShelf/Added{index}.swift")
        self.commit()
        result = self.push_selection()
        self.assertEqual(result["platforms"], ["tvos"])
        self.assertEqual(result["changed_files"], 325)

    def test_pull_request_uses_the_event_base_and_actual_merge_checkout(self):
        self.git("checkout", "-b", "feature")
        self.write("iosApp/iosApp/macOS/Player.swift")
        branch_head = self.commit()
        self.git("checkout", "main")
        self.write("iosApp/TopShelf/ContentProvider.swift")
        current_base = self.commit("advance main")
        self.git("merge", "--no-ff", "--quiet", "-m", "merge fixture", "feature")
        merge_head = self.git("rev-parse", "HEAD")
        event = {"pull_request": {"base": {"sha": current_base}, "head": {"sha": branch_head}}}
        result = apple_platforms.select_platforms(self.repo, event, "pull_request", github_sha=merge_head)
        self.assertEqual(result["platforms"], ["macos"])
        self.assertEqual(result["head_sha"], merge_head)
        self.assertEqual(result["base_sha"], current_base)
        # An older event base widens the comparison instead of losing changes.
        event["pull_request"]["base"]["sha"] = self.base
        self.assertEqual(apple_platforms.select_platforms(self.repo, event, "pull_request")["platforms"], ["tvos", "macos"])

    def test_unmerged_event_head_requires_all_platforms(self):
        self.git("checkout", "-b", "feature")
        self.write("iosApp/iosApp/macOS/Player.swift")
        branch_head = self.commit()
        self.git("checkout", "main")
        event = {"pull_request": {"base": {"sha": self.base}, "head": {"sha": branch_head}}}
        self.assertEqual(apple_platforms.select_platforms(self.repo, event, "pull_request")["platforms"], ALL)

    def test_missing_invalid_and_zero_base_commits_require_all_platforms(self):
        self.write("iosApp/iosApp/macOS/Player.swift")
        self.commit()
        for base in ("f" * 40, "0" * 40, "--output=unsafe", "abc"):
            with self.subTest(base=base):
                self.assertEqual(self.push_selection(before=base)["platforms"], ALL)

    def test_malformed_event_shapes_require_all_platforms(self):
        for event in (None, [], {}, {"pull_request": []}, {"pull_request": {"base": [], "head": "bad"}}):
            with self.subTest(event=event):
                self.assertEqual(apple_platforms.select_platforms(self.repo, event, "pull_request")["platforms"], ALL)

    def test_wrong_push_or_workflow_commit_requires_all_platforms(self):
        self.write("iosApp/iosApp/macOS/Player.swift")
        self.commit()
        self.assertEqual(self.push_selection(github_sha=self.base)["platforms"], ALL)
        event = {"before": self.base, "after": self.base}
        self.assertEqual(apple_platforms.select_platforms(self.repo, event, "push")["platforms"], ALL)

    def test_shallow_history_requires_all_platforms_even_with_valid_diff_objects(self):
        self.write("iosApp/iosApp/macOS/Player.swift")
        self.commit()
        clone = self.root / "shallow"
        subprocess.run(["git", "clone", "--quiet", "--depth", "2", self.repo.as_uri(), str(clone)], check=True)
        head = self.git("rev-parse", "HEAD")
        result = apple_platforms.select_platforms(clone, {"before": self.base, "after": head}, "push")
        self.assertEqual(result["platforms"], ALL)
        self.assertIn("incomplete history", result["reasons"][0])

    def test_source_graph_change_disables_narrowing_in_following_commit(self):
        project = PROJECT.read_text().replace('          - "macOS/**"\n', "", 1)
        self.write("iosApp/project.yml", project)
        changed_graph = self.commit("change ownership")
        self.write("iosApp/iosApp/macOS/Player.swift")
        self.commit()
        result = self.push_selection(before=changed_graph)
        self.assertEqual(result["platforms"], ALL)
        self.assertIn("ownership review", result["reasons"][0])

    def test_comments_do_not_invalidate_reviewed_input_ownership(self):
        project = PROJECT.read_text().replace("      - path: TopShelf", "      # additional explanation\n      - path: TopShelf")
        self.write("iosApp/project.yml", project)
        self.write("iosApp/Signing/Silo.xcconfig", "// more explanation\n" + CONFIGS["iosApp/Signing/Silo.xcconfig"])
        changed_settings = self.commit("update comments")
        self.write("iosApp/iosApp/macOS/Player.swift")
        self.commit()
        self.assertEqual(self.push_selection(before=changed_settings)["platforms"], ["macos"])

    def test_settings_redirecting_into_docs_disable_narrowing_in_later_commits(self):
        for config_path in ("iosApp/project.yml", "iosApp/Signing/Silo.xcconfig"):
            with self.subTest(config_path=config_path):
                self.git("reset", "--hard", self.base)
                if config_path == "iosApp/project.yml":
                    contents = PROJECT.read_text().replace("INFOPLIST_FILE: iosApp/Info.plist", "INFOPLIST_FILE: ../docs/AppInfo.md")
                else:
                    contents = CONFIGS[config_path] + "\nINFOPLIST_FILE = ../docs/AppInfo.md\n"
                self.write(config_path, contents)
                self.write("docs/AppInfo.md", "original\n")
                redirected = self.commit("redirect consumed input")
                self.write("docs/AppInfo.md", "changed\n")
                self.commit()
                self.assertEqual(self.push_selection(before=redirected)["platforms"], ALL)

    def test_template_sources_and_target_inheritance_require_review(self):
        for project in (
            PROJECT.read_text().replace("  ShippableProduct:\n", "  ShippableProduct:\n    sources:\n      - path: Other\n"),
            PROJECT.read_text().replace("  SiloMac:\n", "  SiloMac:\n    <<: *OtherTarget\n", 1),
        ):
            with self.subTest(project=project[:20]):
                self.git("reset", "--hard", self.base)
                self.write("iosApp/project.yml", project)
                changed_graph = self.commit("inherit sources")
                self.write("iosApp/iosApp/macOS/Player.swift")
                self.commit()
                self.assertEqual(self.push_selection(before=changed_graph)["platforms"], ALL)

    def test_manual_and_reusable_calls_default_to_all_platforms(self):
        for event_name in ("workflow_dispatch", "workflow_call", "release", "unknown"):
            with self.subTest(event_name=event_name):
                self.assertEqual(apple_platforms.select_platforms(self.repo, None, event_name)["platforms"], ALL)
        for platform in ALL:
            with self.subTest(platform=platform):
                self.assertEqual(apple_platforms.select_platforms(self.repo, None, "workflow_dispatch", force_platforms=platform)["platforms"], [platform])
        self.assertEqual(apple_platforms.select_platforms(self.repo, None, "workflow_call", force_platforms="ios")["platforms"], ALL)
        self.assertEqual(self.push_selection(force_platforms="ios")["platforms"], ALL)

    def test_truncated_or_unknown_diff_records_cannot_be_classified(self):
        for raw in (b"M\0path", b"R100\0old\0", b"Q\0path\0", b"M\0\0"):
            with self.subTest(raw=raw), self.assertRaises(apple_platforms.SelectionUnavailable):
                apple_platforms.parse_changes(raw)

    def test_cli_outputs_are_single_lines_even_when_git_paths_contain_newlines(self):
        self.write("unknown\nselection=unsafe")
        head = self.commit()
        event = self.root / "event.json"
        event.write_text(json.dumps({"before": self.base, "after": head}))
        output = self.root / "github-output"
        env = {key: value for key, value in os.environ.items() if not key.startswith("GITHUB_") and key != "FORCE_PLATFORMS"}
        env.update(GITHUB_EVENT_PATH=str(event), GITHUB_EVENT_NAME="push", GITHUB_OUTPUT=str(output))
        process = subprocess.run([sys.executable, str(SCRIPT), "--repo", str(self.repo)], env=env, check=True, capture_output=True, text=True)
        result = json.loads(process.stdout)
        self.assertEqual(result["platforms"], ALL)
        lines = output.read_text().splitlines()
        self.assertEqual(len(lines), 4)
        values = dict(line.split("=", 1) for line in lines)
        self.assertEqual(json.loads(values["selection"]), result)
        self.assertEqual(json.loads(values["platforms"]), ALL)
        self.assertEqual(values["has_platforms"], "true")
        self.assertEqual(json.loads(values["matrix"]), apple_platforms.matrix_for_platforms(ALL))

    def test_cli_documentation_outputs_allow_a_successful_aggregate_skip(self):
        self.write("docs/build.md")
        head = self.commit()
        event = self.root / "event.json"
        event.write_text(json.dumps({"before": self.base, "after": head}))
        output = self.root / "github-output"
        env = {key: value for key, value in os.environ.items() if not key.startswith("GITHUB_") and key != "FORCE_PLATFORMS"}
        env["GITHUB_OUTPUT"] = str(output)
        subprocess.run([sys.executable, str(SCRIPT), "--event", str(event), "--event-name", "push", "--repo", str(self.repo)], env=env, check=True, capture_output=True)
        values = dict(line.split("=", 1) for line in output.read_text().splitlines())
        self.assertEqual(json.loads(values["platforms"]), [])
        self.assertEqual(values["has_platforms"], "false")
        self.assertEqual(json.loads(values["matrix"]), {"include": []})


class KnownTestSourceTests(unittest.TestCase):
    """Use the complete qualified Git graph without compiling or copying app data."""

    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="apple-known-tests-")
        self.addCleanup(scratch.cleanup)
        self.repo = Path(scratch.name) / "repo"
        self.repo.mkdir()
        self.git("init", "-b", "main", "--quiet")
        self.git("config", "user.name", "CI fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        origin = SCRIPT.parents[2]
        objects = subprocess.check_output(["git", "-C", str(origin), "rev-parse", "--path-format=absolute", "--git-path", "objects"]).decode().strip()
        (self.repo / ".git/objects/info/alternates").write_text(objects + "\n")
        current = subprocess.check_output(["git", "--no-replace-objects", "-C", str(origin), "rev-parse", "HEAD"]).decode().strip()
        self.git("read-tree", current)
        self.known = sorted(apple_platforms.reviewed_test_sources())
        _, inputs = apple_platforms.tree_entries(self.repo, current)
        for path in self.known:
            if inputs.get(path, ())[:2] != (b"100644", b"blob"):
                self.store(path, b"// known test fixture baseline\n")
        # The new controller is excluded from the app graph and independently
        # sealed. Keep its exact bytes in both complete comparison trees.
        for path in apple_platforms.SELECTOR_FILES + (apple_platforms.SELECTOR_CONTRACT,):
            self.store(path, (origin / path).read_bytes())
        # A depth-one CI checkout has the complete current tree but may lack
        # its parent. Start an independent, complete fixture history at that
        # tree rather than borrowing unavailable controller ancestry.
        tree = self.git("write-tree")
        self.base = self.git("commit-tree", tree, "-m", "reviewed controller fixture")
        self.git("update-ref", "HEAD", self.base)
        # Positives test the guard against a complete fixture snapshot. App
        # changes can disable production narrowing while these fixtures still
        # exercise it. Never change the committed production fingerprint.
        rows, _ = apple_platforms.tree_entries(self.repo, self.base)
        excluded = set(self.known) | set(apple_platforms.SELECTOR_FILES) | {apple_platforms.SELECTOR_CONTRACT}
        retained = [row for row in rows if row.split(b"\t", 1)[1].decode() not in excluded]
        self.production_fingerprint = apple_platforms.TEST_SOURCE_INPUTS_SHA256
        fingerprint = hashlib.sha256(b"\0".join(retained) + b"\0").hexdigest()
        qualified_fixture = patch.object(apple_platforms, "TEST_SOURCE_INPUTS_SHA256", fingerprint)
        qualified_fixture.start()
        self.addCleanup(qualified_fixture.stop)
        self.path = "iosApp/Tests/MediaAuthorizationPlaybackTests.swift"

    def git(self, *args, input=None):
        return subprocess.run(["git", "--no-replace-objects", "-C", str(self.repo), *args], input=input,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout.decode().strip()

    def store(self, path, contents=b"// fixture modification\n", mode="100644"):
        blob = self.git("hash-object", "-w", "--stdin", input=contents)
        self.git("update-index", "--add", "--cacheinfo", mode, blob, path)

    def commit(self, message="change"):
        parent = self.git("rev-parse", "HEAD")
        tree = self.git("write-tree")
        head = self.git("commit-tree", tree, "-p", parent, "-m", message)
        self.git("update-ref", "HEAD", head)
        return head

    def reset(self):
        self.git("read-tree", self.base)
        self.git("update-ref", "HEAD", self.base)

    def selection(self, before=None, **kwargs):
        head = self.git("rev-parse", "HEAD")
        return apple_platforms.select_platforms(self.repo, {"before": before or self.base, "after": head}, "push", **kwargs)

    def modify_test(self):
        self.store(self.path)
        return self.commit()

    def test_shared_and_ios_only_known_sources_run_both_complete_mobile_suites(self):
        for path in (self.path, "iosApp/Tests/ApplePushRegistrationTests.swift"):
            with self.subTest(path=path):
                self.reset()
                self.store(path)
                self.commit()
                result = self.selection()
                self.assertEqual(result["platforms"], ["ios", "tvos"])
                self.assertEqual(result["mode"], "test_sources")
                self.assertEqual(result["test_source_guard"]["source_inputs_sha256"], apple_platforms.TEST_SOURCE_INPUTS_SHA256)

    def test_frozen_production_fingerprint_requires_all_after_an_app_change(self):
        self.store("iosApp/iosApp/macOS/UnreviewedFixtureInput.swift")
        changed_base = self.commit()
        self.modify_test()
        with patch.object(apple_platforms, "TEST_SOURCE_INPUTS_SHA256", self.production_fingerprint):
            self.assertEqual(self.selection(before=changed_base)["platforms"], ALL)

    def test_multiple_known_modifications_keep_both_mobile_suites(self):
        for path in self.known:
            self.store(path)
        self.commit()
        result = self.selection()
        self.assertEqual(result["platforms"], ["ios", "tvos"])
        self.assertEqual(result["changed_files"], 223)

    def test_actual_pull_request_merge_selects_the_complete_mobile_matrix(self):
        branch_head = self.modify_test()
        tree = self.git("rev-parse", "HEAD^{tree}")
        merge = self.git("commit-tree", tree, "-p", self.base, "-p", branch_head, "-m", "merge fixture")
        self.git("update-ref", "HEAD", merge)
        event = {"pull_request": {"base": {"sha": self.base}, "head": {"sha": branch_head}}}
        result = apple_platforms.select_platforms(self.repo, event, "pull_request", github_sha=merge)
        self.assertEqual(result["platforms"], ["ios", "tvos"])
        self.assertEqual(result["mode"], "test_sources")

    def test_qualified_guard_rejects_unknown_added_deleted_renamed_and_mode_changed_tests(self):
        for change in ("add", "delete", "rename", "executable", "symlink", "resource"):
            with self.subTest(change=change):
                self.reset()
                if change in {"delete", "rename"}:
                    self.git("update-index", "--force-remove", self.path)
                if change in {"add", "rename"}:
                    self.store("iosApp/Tests/NewUnknown.swift")
                elif change in {"executable", "symlink"}:
                    self.store(self.path, mode="100755" if change == "executable" else "120000")
                elif change == "resource":
                    self.store("iosApp/Tests/Fixtures/APIv2/get_metadata_ai_capability_ok.json")
                self.commit()
                self.assertEqual(self.selection()["platforms"], ALL)

    def test_other_changes_cannot_be_hidden_in_the_same_comparison(self):
        for path in ("README.md", "iosApp/iosApp/macOS/Unknown.swift", ".github/workflows/player-regression.yml", "scripts/ci/unknown.py"):
            with self.subTest(path=path):
                self.reset()
                self.store(path)
                self.modify_test()
                self.assertEqual(self.selection()["platforms"], ALL)

    def test_prior_non_test_changes_invalidate_ownership_even_when_the_new_diff_only_touches_tests(self):
        for path in ("README.md", "iosApp/iosApp/macOS/HiddenTestConsumer.swift", ".github/actions/install-xcodegen/action.yml", "scripts/ci/apple-build-metadata.py", "iosApp/Signing/SiloMac.xcconfig"):
            with self.subTest(path=path):
                self.reset()
                self.store(path)
                changed_base = self.commit("unreviewed input change")
                self.modify_test()
                self.assertEqual(self.selection(before=changed_base)["platforms"], ALL)

    def test_reverting_an_unreviewed_base_to_the_qualified_head_still_runs_all(self):
        path = ".github/actions/install-xcodegen/action.yml"
        original = self.git("show", f"{self.base}:{path}").encode() + b"\n"
        self.store(path)
        changed_base = self.commit()
        self.store(path, original)
        self.modify_test()
        self.assertEqual(self.selection(before=changed_base)["platforms"], ALL)
        # Exercise the fingerprint guard directly: checking only the restored
        # head must not qualify a comparison against an unreviewed base.
        with self.assertRaisesRegex(apple_platforms.SelectionUnavailable, "Other tracked inputs"):
            apple_platforms.test_source_guard(self.repo, changed_base, self.git("rev-parse", "HEAD"), frozenset(self.known))

    def test_copied_test_sources_remain_additions_and_run_every_platform(self):
        raw = subprocess.check_output(["git", "-C", str(self.repo), "show", f"{self.base}:{self.path}"])
        self.store("iosApp/Tests/CopiedUnknown.swift", raw)
        self.commit()
        self.assertEqual(self.selection()["platforms"], ALL)

    def test_unchanged_known_test_modes_are_checked_in_both_trees(self):
        other = next(path for path in self.known if path != self.path)
        self.store(other, mode="120000")
        changed_base = self.commit()
        self.modify_test()
        self.assertEqual(self.selection(before=changed_base)["platforms"], ALL)

    def test_missing_or_changed_committed_controller_seal_and_files_require_all(self):
        for path in apple_platforms.SELECTOR_FILES + (apple_platforms.SELECTOR_CONTRACT,):
            with self.subTest(path=path):
                self.reset()
                self.store(path)
                changed_base = self.commit("controller changed")
                self.modify_test()
                self.assertEqual(self.selection(before=changed_base)["platforms"], ALL)
        self.reset()
        self.git("update-index", "--force-remove", apple_platforms.SELECTOR_CONTRACT)
        missing_base = self.commit()
        self.modify_test()
        self.assertEqual(self.selection(before=missing_base)["platforms"], ALL)

    def test_manual_reusable_and_release_requests_keep_the_full_matrix(self):
        self.modify_test()
        for event_name in ("workflow_dispatch", "workflow_call", "release"):
            self.assertEqual(apple_platforms.select_platforms(self.repo, None, event_name)["platforms"], ALL)
        self.assertEqual(self.selection(force_platforms="all")["platforms"], ALL)


class AggregateResultTests(unittest.TestCase):
    HEAD = "a" * 40
    BASE = "b" * 40

    def fixture(self, platforms=ALL, *, mode="diff", result=None):
        selection = {
            "platforms": platforms, "head_sha": self.HEAD, "base_sha": self.BASE,
            "mode": mode, "reasons": ["Verified fixture comparison."],
            "comparison": f"{self.BASE}..{self.HEAD}", "changed_files": 1,
            "diff_sha256": "c" * 64, "build_inputs_sha256": apple_platforms.BUILD_INPUTS_SHA256,
        }
        outputs = {
            "selection": json.dumps(selection), "platforms": json.dumps(platforms),
            "has_platforms": str(bool(platforms)).lower(),
            "matrix": json.dumps(apple_platforms.matrix_for_platforms(platforms)),
        }
        return {
            "select": {"result": "success", "outputs": outputs},
            "validate": {"result": result or ("success" if platforms else "skipped")},
        }

    def verify(self, needs, **kwargs):
        return apple_platforms.verify_result(needs, event_name=kwargs.pop("event_name", "pull_request"), github_sha=self.HEAD, **kwargs)

    def change_selection(self, needs, **changes):
        selection = json.loads(needs["select"]["outputs"]["selection"])
        selection.update(changes)
        needs["select"]["outputs"]["selection"] = json.dumps(selection)

    def test_all_proven_automatic_selections_and_documentation_skip_pass(self):
        for platforms in (ALL, ["ios"], ["tvos"], ["macos"], ["ios", "macos"], []):
            with self.subTest(platforms=platforms):
                self.verify(self.fixture(platforms))

    def test_fallback_all_and_explicit_manual_platforms_pass_after_validation(self):
        self.verify(self.fixture(mode="all"))
        for platform in ALL:
            with self.subTest(platform=platform):
                self.verify(self.fixture([platform], mode="manual"), event_name="workflow_dispatch")

    def test_failed_cancelled_skipped_or_missing_selection_never_passes(self):
        for result in ("failure", "cancelled", "skipped", None, "pending"):
            with self.subTest(result=result), self.assertRaises(apple_platforms.SelectionUnavailable):
                needs = self.fixture()
                needs["select"]["result"] = result
                self.verify(needs)

    def test_every_nonempty_selected_matrix_must_succeed(self):
        for result in ("failure", "cancelled", "skipped", None, "pending"):
            with self.subTest(result=result), self.assertRaises(apple_platforms.SelectionUnavailable):
                needs = self.fixture(["macos"])
                needs["validate"]["result"] = result
                self.verify(needs)

    def test_only_a_skipped_matrix_passes_for_an_empty_plan(self):
        for result in ("success", "failure", "cancelled", None):
            with self.subTest(result=result), self.assertRaises(apple_platforms.SelectionUnavailable):
                needs = self.fixture([])
                needs["validate"]["result"] = result
                self.verify(needs)

    def test_missing_or_malformed_outputs_never_pass(self):
        for field in ("selection", "platforms", "matrix", "has_platforms"):
            with self.subTest(missing=field), self.assertRaises(apple_platforms.SelectionUnavailable):
                needs = self.fixture()
                del needs["select"]["outputs"][field]
                self.verify(needs)
        for field, value in (("selection", "null"), ("platforms", "{}"), ("matrix", "not JSON"), ("has_platforms", True)):
            with self.subTest(field=field, value=value), self.assertRaises(apple_platforms.SelectionUnavailable):
                needs = self.fixture()
                needs["select"]["outputs"][field] = value
                self.verify(needs)

    def test_incomplete_needs_object_never_passes(self):
        for needs in (None, [], {}, {"select": {"result": "success"}}, {"select": None, "validate": None}):
            with self.subTest(needs=needs), self.assertRaises(apple_platforms.SelectionUnavailable):
                self.verify(needs)

    def test_unknown_duplicate_or_unordered_platforms_never_pass(self):
        for platforms in (["watchos"], ["ios", "ios"], ["macos", "ios"], [None]):
            with self.subTest(platforms=platforms), self.assertRaises(apple_platforms.SelectionUnavailable):
                needs = self.fixture()
                needs["select"]["outputs"]["platforms"] = json.dumps(platforms)
                self.verify(needs)

    def test_selection_skip_decision_and_matrix_must_agree(self):
        for field, value in (
            ("platforms", "[]"),
            ("has_platforms", "false"),
            ("matrix", '{"include":[]}'),
            ("matrix", '{"include":[{"scheme":"SiloMac","action":"test"}]}'),
        ):
            with self.subTest(field=field), self.assertRaises(apple_platforms.SelectionUnavailable):
                needs = self.fixture()
                needs["select"]["outputs"][field] = value
                self.verify(needs)
        with self.assertRaises(apple_platforms.SelectionUnavailable):
            needs = self.fixture([])
            needs["select"]["outputs"]["has_platforms"] = "true"
            self.verify(needs)

    def test_empty_selection_requires_a_complete_comparison_proof(self):
        for field, value in (
            ("base_sha", None), ("base_sha", "0" * 40), ("head_sha", None),
            ("comparison", "incorrect"), ("changed_files", -1), ("changed_files", True),
            ("diff_sha256", "truncated"), ("build_inputs_sha256", "unreviewed"),
            ("mode", "all"), ("mode", "unknown"), ("reasons", []),
        ):
            with self.subTest(field=field, value=value), self.assertRaises(apple_platforms.SelectionUnavailable):
                needs = self.fixture([])
                self.change_selection(needs, **{field: value})
                self.verify(needs)
        with self.assertRaises(apple_platforms.SelectionUnavailable):
            self.verify(self.fixture([]), event_name="workflow_dispatch")

    def test_manual_selection_is_rejected_outside_dispatch_or_for_empty_full_plans(self):
        for platforms, event in ((["ios"], "push"), (["ios"], "pull_request"), ([], "workflow_dispatch"), (ALL, "workflow_dispatch")):
            with self.subTest(platforms=platforms, event=event), self.assertRaises(apple_platforms.SelectionUnavailable):
                self.verify(self.fixture(platforms, mode="manual"), event_name=event)

    def test_release_requirement_rejects_successful_partial_and_empty_plans(self):
        self.verify(self.fixture(mode="all"), require_all=True)
        for platforms in (["ios"], []):
            with self.subTest(platforms=platforms), self.assertRaises(apple_platforms.SelectionUnavailable):
                self.verify(self.fixture(platforms), require_all=True)

    def test_guarded_mobile_test_result_requires_its_fixed_reviewed_controller(self):
        controller, _ = apple_platforms.reviewed_test_controller()
        guard = {"source_inputs_sha256": apple_platforms.TEST_SOURCE_INPUTS_SHA256, "ownership_sha256": apple_platforms.TEST_SOURCE_OWNERSHIP_SHA256, "controller_sha256": controller}
        needs = self.fixture(["ios", "tvos"], mode="test_sources")
        self.change_selection(needs, test_source_guard=guard)
        self.verify(needs)
        with self.assertRaises(apple_platforms.SelectionUnavailable):
            self.verify(needs, require_all=True)
        for result in ("failure", "cancelled", "skipped", "pending"):
            with self.subTest(result=result), self.assertRaises(apple_platforms.SelectionUnavailable):
                needs["validate"]["result"] = result
                self.verify(needs)
        needs["validate"]["result"] = "success"
        for field in guard:
            with self.subTest(field=field), self.assertRaises(apple_platforms.SelectionUnavailable):
                changed = dict(guard, **{field: "0" * 64})
                self.change_selection(needs, test_source_guard=changed)
                self.verify(needs)
        for changed in ({"test_source_guard": None}, {"changed_files": 0}):
            with self.subTest(changed=changed), self.assertRaises(apple_platforms.SelectionUnavailable):
                self.change_selection(needs, test_source_guard=guard, changed_files=1)
                self.change_selection(needs, **changed)
                self.verify(needs)

    def test_workflow_cancellation_after_successful_dependencies_still_fails(self):
        with self.assertRaises(apple_platforms.SelectionUnavailable):
            self.verify(self.fixture(), cancelled=True)

    def test_cli_reports_failure_for_bad_or_cancelled_dependency_results(self):
        for needs, cancelled, expected in ((self.fixture(), "false", 0), (self.fixture(["macos"], result="failure"), "false", 1), (self.fixture(), "true", 1), (None, "false", 1)):
            with self.subTest(cancelled=cancelled, expected=expected):
                env = os.environ.copy()
                env.update(
                    APPLE_REGRESSION_NEEDS=json.dumps(needs), APPLE_REGRESSION_CANCELLED=cancelled,
                    APPLE_REGRESSION_REQUIRE_ALL="false", GITHUB_EVENT_NAME="pull_request", GITHUB_SHA=self.HEAD,
                )
                process = subprocess.run([sys.executable, str(SCRIPT), "--verify-result"], env=env, capture_output=True, text=True)
                self.assertEqual(process.returncode, expected)


if __name__ == "__main__":
    unittest.main()
