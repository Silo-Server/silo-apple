#!/usr/bin/env python3

import importlib.util
from pathlib import Path
import unittest


SCRIPT_DIR = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("release_version", SCRIPT_DIR / "release-version.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

# Tags in the repository before the first vX.Y.Z-beta.B release: a sideload
# build tag and the source-<sha> tags that manual TestFlight runs created.
LEGACY_TAGS = ["v1.0.0-build.1", "source-a85bbf07", "wip/sign-in-redesign-pre-rebase"]


class NextReleaseTest(unittest.TestCase):
    def test_first_release_needs_an_explicit_version(self):
        with self.assertRaisesRegex(release.ReleaseError, "explicit version"):
            release.next_release(LEGACY_TAGS, "minor", min_build=66)
        with self.assertRaisesRegex(release.ReleaseError, "Pass the version"):
            release.next_release(LEGACY_TAGS, "build", min_build=66)
        result = release.next_release(LEGACY_TAGS, "build", "1.0.0", min_build=66)
        self.assertEqual(
            {"version": "1.0.0", "build": "66", "tag": "v1.0.0-beta.66", "previous_tag": ""}, result
        )

    def test_testflight_build_number_wins_when_higher(self):
        tags = LEGACY_TAGS + ["v1.0.0-beta.66"]
        self.assertEqual("v1.0.0-beta.70", release.next_release(tags, "build", min_build=70)["tag"])

    def test_continues_after_the_last_shipped_build(self):
        tags = LEGACY_TAGS + ["v1.0.0-beta.66"]
        result = release.next_release(tags, "build", min_build=67)
        self.assertEqual("v1.0.0-beta.67", result["tag"])
        self.assertEqual("v1.0.0-beta.66", result["previous_tag"])

    def test_build_continues_the_newest_unreleased_version(self):
        tags = LEGACY_TAGS + ["v1.0.0-beta.66", "v1.0.0", "v1.0.1-beta.67", "v1.1.0-beta.68"]
        self.assertEqual("v1.1.0-beta.69", release.next_release(tags, "build", min_build=69)["tag"])

    def test_build_continues_testing_after_a_hotfix_ships(self):
        tags = LEGACY_TAGS + ["v1.0.0-beta.66", "v1.0.0", "v1.1.0-beta.67", "v1.0.1-beta.68", "v1.0.1"]
        self.assertEqual("v1.1.0-beta.69", release.next_release(tags, "build", min_build=69)["tag"])

    def test_a_draft_store_release_counts_as_released(self):
        tags = LEGACY_TAGS + ["v1.0.0-beta.66"]
        with self.assertRaisesRegex(release.ReleaseError, "bump=minor"):
            release.next_release(tags, "build", min_build=67, drafts=["v1.0.0"])
        self.assertEqual("v1.1.0-beta.67", release.next_release(tags, "minor", min_build=67, drafts=["v1.0.0"])["tag"])
        with self.assertRaisesRegex(release.ReleaseError, "including a draft"):
            release.next_release(tags, "build", "1.0.0", min_build=67, drafts=["v1.0.0"])

    def test_rejected_version_needs_an_explicit_version_once_the_next_started(self):
        # The draft v1.0.0 was deleted after App Review rejected the build.
        tags = LEGACY_TAGS + ["v1.0.0-beta.66", "v1.0.1-beta.67"]
        self.assertEqual("v1.0.1-beta.68", release.next_release(tags, "build", min_build=68)["tag"])
        self.assertEqual("v1.0.0-beta.68", release.next_release(tags, "build", "1.0.0", min_build=68)["tag"])

    def test_build_refuses_an_approved_version(self):
        tags = LEGACY_TAGS + ["v1.0.0-beta.66", "v1.0.0"]
        with self.assertRaisesRegex(release.ReleaseError, "bump=minor"):
            release.next_release(tags, "build", min_build=67)

    def test_minor_and_patch_bump_the_latest_release(self):
        tags = LEGACY_TAGS + ["v1.0.0-beta.66", "v1.0.0"]
        self.assertEqual("v1.1.0-beta.67", release.next_release(tags, "minor", min_build=67)["tag"])
        self.assertEqual("v1.0.1-beta.67", release.next_release(tags, "patch", min_build=67)["tag"])

    def test_explicit_version_must_be_newer_than_the_latest_release(self):
        tags = LEGACY_TAGS + ["v1.0.0-beta.66", "v1.0.0"]
        with self.assertRaisesRegex(release.ReleaseError, "closes its version"):
            release.next_release(tags, "build", "1.0.0", min_build=67)
        with self.assertRaisesRegex(release.ReleaseError, "look like"):
            release.next_release(tags, "build", "1.1", min_build=67)


class PreviousReleaseTest(unittest.TestCase):
    def test_newest_older_store_release(self):
        tags = LEGACY_TAGS + ["v1.0.0-beta.66", "v1.0.0", "v1.1.0-beta.70", "v1.1.0", "v1.2.0-beta.75"]
        self.assertEqual({"previous_release": "v1.1.0"}, release.previous_release(tags, "v1.2.0"))
        self.assertEqual({"previous_release": "v1.0.0"}, release.previous_release(tags, "v1.1.0"))

    def test_first_store_release_has_none(self):
        self.assertEqual({"previous_release": ""}, release.previous_release(LEGACY_TAGS, "v1.0.0"))

    def test_needs_a_store_release_tag(self):
        with self.assertRaises(release.ReleaseError):
            release.previous_release(LEGACY_TAGS, "v1.0.0-beta.66")


class BetaReleaseTest(unittest.TestCase):
    def test_beta_tag_resolves_to_its_store_release(self):
        self.assertEqual(
            {"version": "1.0.0", "build": "66", "tag": "v1.0.0-beta.66", "release_tag": "v1.0.0"},
            release.beta_release("v1.0.0-beta.66"),
        )

    def test_other_tags_are_rejected(self):
        for name in ("v1.0.0", "v1.0.0-build.1", "source-a85bbf07"):
            with self.subTest(name), self.assertRaises(release.ReleaseError):
                release.beta_release(name)


GENERATED = """## What's Changed
### 🚀 Features
* feat(player): skip recaps automatically by @dev in https://github.com/Silo-Server/silo-apple/pull/764
### 🐛 Fixes
* fix(home): reload Home when the app returns by @dev in https://github.com/Silo-Server/silo-apple/pull/760
### Other changes
* ci: cache packages by @dev in https://github.com/Silo-Server/silo-apple/pull/700
* Fix: restore the Up Next row by @dev in https://github.com/Silo-Server/silo-apple/pull/701

**Full Changelog**: https://github.com/Silo-Server/silo-apple/compare/a...b
"""


class StoreNotesTest(unittest.TestCase):
    def test_titles_keep_sections_and_titles_only(self):
        notes = GENERATED.replace("**Full Changelog**", "## New Contributors\n* @newcomer made their first contribution in https://github.com/x/y/pull/9\n\n**Full Changelog**")
        self.assertEqual(
            "Features:\n"
            "- feat(player): skip recaps automatically\n"
            "Fixes:\n"
            "- fix(home): reload Home when the app returns\n"
            "Other changes:\n"
            "- ci: cache packages\n"
            "- Fix: restore the Up Next row",
            release.pr_titles(notes),
        )

    def test_keeps_features_and_fixes_as_plain_text(self):
        self.assertEqual(
            "• Skip recaps automatically\n• Reload Home when the app returns\n• Restore the Up Next row",
            release.store_notes(GENERATED, 3800),
        )

    def test_only_a_leading_prefix_is_removed(self):
        notes = "### 🐛 Fixes\n* Fix crash when the server says: hello by @dev in https://x/1\n"
        self.assertEqual("• Fix crash when the server says: hello", release.store_notes(notes, 3800))

    def test_without_user_facing_changes(self):
        self.assertEqual("Bug fixes and improvements.", release.store_notes("## What's Changed\n", 3800))

    def test_fits_the_limit(self):
        many = "### 🐛 Fixes\n" + "\n".join(f"* fix: change number {n} by @dev in https://x/{n}" for n in range(500))
        notes = release.store_notes(many, 3800)
        self.assertLessEqual(len(notes), 3800)
        self.assertTrue(notes.endswith("• And more."))


if __name__ == "__main__":
    unittest.main()
