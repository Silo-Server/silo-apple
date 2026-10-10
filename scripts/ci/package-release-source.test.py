#!/usr/bin/env python3
import importlib.util
from concurrent.futures import Future
import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import threading
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
            executable = tarfile.TarInfo("source/tool.sh")
            executable.mode = 0o755
            executable.size = 10
            archive.addfile(executable, io.BytesIO(b"echo tool\n"))
            link = tarfile.TarInfo("source/source-link")
            link.type = tarfile.SYMTYPE
            link.linkname = "source.txt"
            archive.addfile(link)
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

    def sources(self, root):
        return [(name, f"https://github.com/fixture/{name}", str(index) * 40, root / name)
                for index, name in enumerate(("alpha", "beta", "gamma", "delta"), 1)]

    def test_two_downloads_overlap_and_results_keep_input_order(self):
        first_started = threading.Event()
        fast_finished = threading.Event()
        lock = threading.Lock()
        active = 0
        maximum = 0
        completed = []

        def download(repository, revision, destination):
            nonlocal active, maximum
            with lock:
                active += 1
                maximum = max(maximum, active)
            try:
                if destination.name == "alpha":
                    first_started.set()
                    if not fast_finished.wait(5):
                        raise TimeoutError("Other worker never finished the independent downloads")
                else:
                    if not first_started.wait(5):
                        raise TimeoutError("First download never started")
                destination.mkdir()
                with lock:
                    completed.append(destination.name)
                if destination.name == "delta":
                    fast_finished.set()
                return {"repository": repository, "revision": revision, "archive_sha256": "a" * 64}
            finally:
                with lock:
                    active -= 1

        with tempfile.TemporaryDirectory() as scratch, patch.object(
                release_source, "download_source", side_effect=download):
            sources = self.sources(Path(scratch))
            results = release_source.download_sources(sources)
        self.assertEqual(maximum, 2)
        self.assertEqual(active, 0)
        self.assertEqual(completed, ["beta", "gamma", "delta", "alpha"])
        self.assertEqual(list(results), [source[0] for source in sources])

    def test_invalid_or_duplicate_batch_rejects_before_any_download(self):
        with tempfile.TemporaryDirectory() as scratch, patch.object(
                release_source, "download_source") as download:
            sources = self.sources(Path(scratch))
            bad_batches = [
                [sources[0], sources[0]],
                [sources[0], ("another", sources[1][1], sources[1][2], sources[0][3])],
                [sources[0], ("..", sources[1][1], sources[1][2], Path(scratch) / "..")],
                [sources[0], ("../escape", sources[1][1], sources[1][2], Path(scratch) / "escape")],
                [sources[0], ("another", "http://github.com/fixture/another", "2" * 40, Path(scratch) / "another")],
                [sources[0], ("another", "https://github.com/fixture/another", "main", Path(scratch) / "another")],
            ]
            for batch in bad_batches:
                with self.subTest(batch=batch):
                    with self.assertRaises(ValueError):
                        release_source.download_sources(batch)
                    download.assert_not_called()

    def test_failed_batch_waits_for_running_download_cleanup(self):
        peer_started = threading.Event()
        failure_seen = threading.Event()
        allow_cleanup = threading.Event()
        peer_cleaned = threading.Event()
        caller_returned = threading.Event()
        errors = []

        def download(repository, revision, destination):
            if destination.name == "alpha":
                if not peer_started.wait(5):
                    raise TimeoutError("Peer never started")
                failure_seen.set()
                raise OSError("fixture download failed")
            peer_started.set()
            if not allow_cleanup.wait(5):
                raise TimeoutError("Peer cleanup was never released")
            destination.mkdir()
            peer_cleaned.set()
            return {"revision": revision}

        with tempfile.TemporaryDirectory() as scratch, patch.object(
                release_source, "download_source", side_effect=download):
            def call():
                try:
                    release_source.download_sources(self.sources(Path(scratch))[:2])
                except BaseException as error:
                    errors.append(error)
                finally:
                    caller_returned.set()

            caller = threading.Thread(target=call)
            caller.start()
            try:
                self.assertTrue(failure_seen.wait(5), "Download failure never occurred")
                self.assertFalse(caller_returned.wait(0.1), "Caller returned while its peer was still running")
                self.assertFalse(peer_cleaned.is_set())
            finally:
                allow_cleanup.set()
                caller.join(5)
            self.assertFalse(caller.is_alive())
            self.assertTrue(peer_cleaned.is_set(), "Running downloads must finish before caller cleanup")
            self.assertEqual(len(errors), 1)
            self.assertIsInstance(errors[0], OSError)
            self.assertEqual(str(errors[0]), "fixture download failed")

    def test_failed_batch_cancels_pending_downloads(self):
        failed = Future()
        failed.set_exception(OSError("fixture download failed"))
        pending = Future()
        with tempfile.TemporaryDirectory() as scratch, patch.object(
                release_source, "ThreadPoolExecutor") as executor:
            executor.return_value.__enter__.return_value.submit.side_effect = [failed, pending]
            with self.assertRaisesRegex(OSError, "fixture download failed"):
                release_source.download_sources(self.sources(Path(scratch))[:2])
        self.assertTrue(pending.cancelled(), "Queued downloads must be cancelled after a failure")

    def test_package_download_failure_creates_no_archive_and_starts_no_builder(self):
        failed_urls = []

        def fail(url, **kwargs):
            failed_urls.append(url)
            raise OSError("fixture network failure")

        with tempfile.TemporaryDirectory() as scratch, patch.object(
                release_source, "urlopen", side_effect=fail):
            with self.assertRaisesRegex(OSError, "fixture network failure"):
                release_source.package_sources(release_source.ROOT, Path(scratch))
            self.assertEqual(list(Path(scratch).iterdir()), [])
        self.assertEqual(len(failed_urls), 1)
        self.assertIn(self.pins["swift_libass_revision"], failed_urls[0])

    def test_all_native_pins_validate_before_any_native_download(self):
        # A late bad pin must prevent earlier valid libraries from downloading.
        self.pins["libraries"][-1]["tag"] = "unexpected-last-version"
        urls = []

        def response(url, **kwargs):
            urls.append(url)
            return self.source_response(url, **kwargs)

        with tempfile.TemporaryDirectory() as scratch, patch.object(
                release_source, "urlopen", side_effect=response):
            with self.assertRaisesRegex(ValueError, "Subtitle builder no longer matches"):
                release_source.package_sources(release_source.ROOT, Path(scratch))
            self.assertEqual(list(Path(scratch).iterdir()), [])
        self.assertEqual(len(urls), 2, "Only the package and validated builder may download")

    def test_package_and_builder_finish_before_dependent_downloads(self):
        self.resolved["pins"].extend([
            {"identity": "alpha", "location": "https://github.com/fixture/alpha",
             "state": {"revision": "1" * 40}},
            {"identity": "beta", "location": "https://github.com/fixture/beta",
             "state": {"revision": "2" * 40}},
        ])
        expected_packages = {pin["identity"] for pin in self.resolved["pins"]}
        finished_packages = set()
        finished_libraries = set()
        builder_finished = False
        lock = threading.Lock()
        original_download = release_source.download_source

        def download(repository, revision, destination):
            nonlocal builder_finished
            with lock:
                if destination.name == "ffmpeg-kit":
                    self.assertEqual(finished_packages, expected_packages)
                elif destination.parent.name == "src":
                    self.assertTrue(builder_finished, "Native sources require the extracted builder")
            result = original_download(repository, revision, destination)
            with lock:
                if destination.parent.name == "packages":
                    finished_packages.add(destination.name)
                elif destination.name == "ffmpeg-kit":
                    builder_finished = True
                elif destination.parent.name == "src":
                    finished_libraries.add(destination.name)
            return result

        with tempfile.TemporaryDirectory() as scratch, patch.object(
                release_source, "urlopen", side_effect=self.source_response), patch.object(
                release_source, "download_source", side_effect=download):
            release_source.package_sources(release_source.ROOT, Path(scratch))
        self.assertEqual(finished_packages, expected_packages)
        self.assertTrue(builder_finished)
        self.assertEqual(finished_libraries, {library["name"] for library in self.pins["libraries"]})

    def test_native_download_failure_creates_no_archive(self):
        failed_revision = self.pins["libraries"][0]["revision"]
        urls = []
        lock = threading.Lock()

        def response(url, **kwargs):
            with lock:
                urls.append(url)
            if url.endswith("/" + failed_revision):
                raise OSError("fixture native download failed")
            return self.source_response(url, **kwargs)

        with tempfile.TemporaryDirectory() as scratch, patch.object(
                release_source, "urlopen", side_effect=response):
            with self.assertRaisesRegex(OSError, "fixture native download failed"):
                release_source.package_sources(release_source.ROOT, Path(scratch))
            self.assertEqual(list(Path(scratch).iterdir()), [])
        self.assertTrue(any(url.endswith("/" + failed_revision) for url in urls))

    def test_archive_members_and_manifest_match_sequential_downloads(self):
        self.resolved["pins"] = [
            {"identity": "z-last", "location": "https://github.com/fixture/z-last",
             "state": {"revision": "9" * 40}},
            self.resolved["pins"][0],
            {"identity": "a-first", "location": "https://github.com/fixture/a-first",
             "state": {"revision": "1" * 40}},
        ]
        responses = {}
        response_lock = threading.Lock()

        def frozen_response(url, **kwargs):
            # Reuse exact fixture download bytes, including gzip headers.
            with response_lock:
                if url not in responses:
                    responses[url] = self.source_response(url, **kwargs).getvalue()
                return io.BytesIO(responses[url])

        def sequential(sources):
            return {name: release_source.download_source(repository, revision, destination)
                    for name, repository, revision, destination in sources}

        def members(output):
            with tarfile.open(output) as archive:
                return {member.name: (member.type, member.mode, member.linkname, member.size,
                                     archive.extractfile(member).read() if member.isfile() else None)
                        for member in archive.getmembers()}

        with tempfile.TemporaryDirectory() as scratch, patch.object(
                release_source, "urlopen", side_effect=frozen_response):
            root = Path(scratch)
            with patch.object(release_source, "download_sources", side_effect=sequential):
                baseline = release_source.package_sources(release_source.ROOT, root / "sequential")
            candidate = release_source.package_sources(release_source.ROOT, root / "concurrent")
            self.assertEqual(members(baseline), members(candidate))
            with tarfile.open(candidate) as archive:
                prefix = candidate.name.removesuffix(".tar.gz") + "/"
                manifest = json.load(archive.extractfile(prefix + "revisions.json"))
                self.assertEqual(list(manifest["packages"]), [pin["identity"] for pin in self.resolved["pins"]])
                self.assertEqual(list(manifest["subtitle_libraries"]), [library["name"] for library in self.pins["libraries"]])
                self.assertEqual(archive.getmember(prefix + "packages/swift-libass/tool.sh").mode, 0o755)
                link = archive.getmember(prefix + "packages/swift-libass/source-link")
                self.assertTrue(link.issym())
                self.assertEqual(link.linkname, "source.txt")
                self.assertIn(prefix + "app/iosApp/project.yml", archive.getnames())
                self.assertIn(prefix + "packages/swift-libass/build-local.sh", archive.getnames())
                self.assertIn(prefix + "REBUILD.md", archive.getnames())


if __name__ == "__main__":
    unittest.main()
