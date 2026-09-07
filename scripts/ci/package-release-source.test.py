#!/usr/bin/env python3
import importlib.util
import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch


sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("release_source", Path(__file__).with_name("package-release-source.py"))
release_source = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release_source)


class ReleaseSourceTests(unittest.TestCase):
    def setUp(self):
        # Use a small package graph fixture. git archive still reads the real
        # committed app tree, proving that untracked files are excluded.
        self.original_git = release_source.git
        self.pins = json.loads((release_source.ROOT / "scripts/ci/swift-libass-sources.json").read_text())
        self.resolved = {"pins": [{
            "identity": "swift-libass",
            "location": "https://github.com/mihai8804858/swift-libass",
            "state": {"revision": self.pins["swift_libass_revision"]},
        }]}

        def fixture_git(repo, *args):
            if args == ("show", f"HEAD:{release_source.RESOLVED}"):
                return json.dumps(self.resolved).encode()
            return self.original_git(repo, *args)

        stub = patch.object(release_source, "git", side_effect=fixture_git)
        stub.start()
        self.addCleanup(stub.stop)

    def source_response(self, url, **kwargs):
        builder = "checkout() { echo fetch; }\ncheckout\necho build\n"
        source_map = "\n".join(
            f'  {lib["name"]})\n    SOURCE_REPO_URL="{lib["repository"]}"\n'
            f'    SOURCE_ID="{lib["tag"]}"\n    ;;' for lib in self.pins["libraries"])
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
            for name, body in {"source/build-libraries.sh": builder,
                               "source/scripts/source.sh": source_map,
                               "source/source.txt": url}.items():
                data = body.encode()
                member = tarfile.TarInfo(name)
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
        buffer.seek(0)
        return buffer

    def test_archive_has_exact_sources_and_preserves_local_library_edits(self):
        marker = release_source.ROOT / ".release-source-untracked-test"
        self.assertFalse(marker.exists())
        marker.write_text("This local file must never be published")
        self.addCleanup(marker.unlink)
        with tempfile.TemporaryDirectory() as scratch, patch.object(
                release_source, "urlopen", side_effect=self.source_response) as fetch:
            output = release_source.package_sources(release_source.ROOT, Path(scratch))
            with tarfile.open(output) as archive:
                prefix = output.name.removesuffix(".tar.gz") + "/"
                self.assertNotIn(prefix + "app/" + marker.name, archive.getnames())
                self.assertIn(prefix + "app/iosApp/project.yml", archive.getnames())
                manifest = json.load(archive.extractfile(prefix + "revisions.json"))
                self.assertEqual(manifest["app_revision"], release_source.git(
                    release_source.ROOT, "rev-parse", "HEAD").decode().strip())
                self.assertEqual(len(manifest["subtitle_libraries"]), 6)
                self.assertIn("swift-libass", manifest["packages"])
                self.assertNotIn("asskit", manifest["packages"])
                self.assertEqual(fetch.call_count, len(manifest["packages"]) + 7)
                for library, value in manifest["subtitle_libraries"].items():
                    self.assertRegex(value["archive_sha256"], r"^[0-9a-f]{64}$")
                    contents = archive.extractfile(prefix + f"packages/swift-libass/.source/ffmpeg-kit/src/{library}/source.txt").read().decode()
                    self.assertIn(value["revision"], contents)
                original = archive.extractfile(prefix + "packages/swift-libass/build-libraries.sh").read().decode()
                local = archive.extractfile(prefix + "packages/swift-libass/build-local.sh").read().decode()
                self.assertIn("\ncheckout\n", original)
                self.assertEqual(local, original.replace("\ncheckout\n", "\n"))
                self.assertIn(prefix + "REBUILD.md", archive.getnames())

    def test_revision_drift_blocks_publication_before_downloads(self):
        self.resolved["pins"][0]["state"]["revision"] = "0" * 40
        with tempfile.TemporaryDirectory() as scratch, patch.object(release_source, "urlopen") as fetch:
            with self.assertRaisesRegex(ValueError, "Update swift-libass-sources.json"):
                release_source.package_sources(release_source.ROOT, Path(scratch))
            fetch.assert_not_called()

    def test_builder_tag_drift_blocks_source_archive(self):
        self.pins["libraries"][0]["tag"] = "unexpected-version"
        with tempfile.TemporaryDirectory() as scratch, patch.object(
                release_source, "urlopen", side_effect=self.source_response):
            with self.assertRaisesRegex(ValueError, "Subtitle builder no longer matches"):
                release_source.package_sources(release_source.ROOT, Path(scratch))
            self.assertEqual(list(Path(scratch).iterdir()), [])


if __name__ == "__main__":
    unittest.main()
