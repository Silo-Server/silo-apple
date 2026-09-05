#!/usr/bin/env python3
"""Archive a release's tracked app and pinned AssKit rebuild sources."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
from urllib.parse import urlparse
from urllib.request import urlopen


ROOT = Path(__file__).resolve().parents[2]
RESOLVED = "iosApp/Silo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args])


def download_source(repository, revision, destination):
    parsed = urlparse(repository.removesuffix(".git"))
    if (parsed.scheme != "https" or parsed.netloc != "github.com"
            or not re.fullmatch(r"/[\w.-]+/[\w.-]+", parsed.path)
            or not re.fullmatch(r"[0-9a-f]{40}", revision)):
        raise ValueError(f"Expected a GitHub repository and immutable revision: {repository}")
    url = f"https://codeload.github.com{parsed.path}/tar.gz/{revision}"
    with tempfile.TemporaryDirectory() as scratch:
        archive = Path(scratch) / "source.tar.gz"
        with urlopen(url, timeout=120) as response, archive.open("wb") as output:
            shutil.copyfileobj(response, output)
        with archive.open("rb") as downloaded:
            digest = hashlib.file_digest(downloaded, "sha256").hexdigest()
        unpacked = Path(scratch) / "unpacked"
        with tarfile.open(archive) as source:
            source.extractall(unpacked, filter="data")
        roots = list(unpacked.iterdir())
        if len(roots) != 1 or not roots[0].is_dir():
            raise ValueError(f"Unexpected source archive layout: {url}")
        shutil.move(str(roots[0]), destination)
    return {"repository": repository, "revision": revision, "archive_sha256": digest}


def package_sources(repo, output_directory):
    revision = git(repo, "rev-parse", "HEAD").decode().strip()
    pins = json.loads(git(repo, "show", f"HEAD:{RESOLVED}"))["pins"]
    source_pins = json.loads((ROOT / "scripts/ci/asskit-sources.json").read_text())
    asskit = next(pin for pin in pins if pin["identity"] == "asskit")
    if asskit["state"]["revision"] != source_pins["asskit_revision"]:
        raise ValueError("Update asskit-sources.json for the resolved AssKit revision before release")

    output_directory.mkdir(parents=True, exist_ok=True)
    output = output_directory / f"Silo-source-{revision}.tar.gz"
    with tempfile.TemporaryDirectory() as scratch:
        tree = Path(scratch) / f"Silo-source-{revision}"
        tree.mkdir()
        app_archive = Path(scratch) / "app.tar"
        subprocess.run(["git", "-C", str(repo), "archive", "HEAD", "-o", str(app_archive)], check=True)
        with tarfile.open(app_archive) as source:
            source.extractall(tree / "app", filter="data")
        packages = tree / "packages"
        packages.mkdir()
        manifest = {"app_revision": revision, "packages": {}, "asskit_libraries": {}}
        for pin in pins:
            name = pin["identity"]
            if not re.fullmatch(r"[\w.-]+", name):
                raise ValueError(f"Invalid package identity: {name}")
            print(f"Archiving {name} at {pin['state']['revision']}", flush=True)
            manifest["packages"][name] = download_source(
                pin["location"], pin["state"]["revision"], packages / name)

        asskit_path = packages / "asskit"
        builder = (asskit_path / "build.sh").read_text()
        source_directory = asskit_path / "build/src"
        source_directory.mkdir(parents=True)
        for library in source_pins["libraries"]:
            expected = f'{library["version_variable"]}="{library["tag"]}"'
            if expected not in builder.splitlines():
                raise ValueError(f"AssKit build.sh no longer matches source pin: {library['name']}")
            print(f"Archiving {library['name']} at {library['revision']}", flush=True)
            manifest["asskit_libraries"][library["name"]] = download_source(
                library["repository"], library["revision"], source_directory / library["name"])

        # Upstream fetch_sources checks out its tags on every run. This copy uses
        # the included trees, preserving the recipient's library modifications.
        (asskit_path / "build-local.sh").write_text(
            "\n".join(line for line in builder.splitlines() if line != "fetch_sources") + "\n")
        (tree / "revisions.json").write_text(json.dumps(manifest, indent=2) + "\n")
        shutil.copyfile(ROOT / "scripts/ci/REBUILD-SOURCE.md", tree / "REBUILD.md")
        with tarfile.open(output, "w:gz") as archive:
            archive.add(tree, arcname=tree.name)
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output_directory", type=Path)
    options = parser.parse_args()
    print(package_sources(ROOT, options.output_directory.resolve()))
