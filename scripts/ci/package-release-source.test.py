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
    def source_response(self, url, **kwargs):
        pins = json.loads((release_source.ROOT / "scripts/ci/asskit-sources.json").read_text())
        builder = "\n".join(f'{lib["version_variable"]}="{lib["tag"]}"' for lib in pins["libraries"])
        builder += "\nfetch_sources() { echo fetch; }\nfetch_sources\necho build\n"
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
            for name, body in {"source/build.sh": builder, "source/source.txt": url}.items():
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
                self.assertEqual(len(manifest["asskit_libraries"]), 5)
                self.assertIn("asskit", manifest["packages"])
                self.assertEqual(fetch.call_count, len(manifest["packages"]) + 5)
                for library, value in manifest["asskit_libraries"].items():
                    self.assertRegex(value["archive_sha256"], r"^[0-9a-f]{64}$")
                    contents = archive.extractfile(prefix + f"packages/asskit/build/src/{library}/source.txt").read().decode()
                    self.assertIn(value["revision"], contents)
                original = archive.extractfile(prefix + "packages/asskit/build.sh").read().decode()
                local = archive.extractfile(prefix + "packages/asskit/build-local.sh").read().decode()
                self.assertIn("\nfetch_sources\n", original)
                self.assertEqual(local, original.replace("\nfetch_sources\n", "\n"))
                self.assertIn(prefix + "REBUILD.md", archive.getnames())

    def test_asskit_revision_drift_blocks_publication_before_downloads(self):
        original_git = release_source.git

        def changed_pin(repo, *args):
            result = original_git(repo, *args)
            if args == ("show", f"HEAD:{release_source.RESOLVED}"):
                resolved = json.loads(result)
                for pin in resolved["pins"]:
                    if pin["identity"] == "asskit":
                        pin["state"]["revision"] = "0" * 40
                return json.dumps(resolved).encode()
            return result

        with tempfile.TemporaryDirectory() as scratch, patch.object(
                release_source, "git", side_effect=changed_pin), patch.object(release_source, "urlopen") as fetch:
            with self.assertRaisesRegex(ValueError, "Update asskit-sources.json"):
                release_source.package_sources(release_source.ROOT, Path(scratch))
            fetch.assert_not_called()


if __name__ == "__main__":
    unittest.main()
