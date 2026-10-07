#!/usr/bin/env python3
"""Private fixed gzip assessment over one qualified real source tar."""
import argparse
import gzip
import hashlib
import inspect
import json
import os
from pathlib import Path
import resource
import shutil
import subprocess
import sys
import tarfile
import time
import traceback
import zlib

sys.dont_write_bytecode = True
import compare as pilot

LEVELS = (9, 6, 1)


def context():
    if sys.version_info[:2] != (3, 12) or sys.platform != "linux":
        raise ValueError("Assessment requires actual Python 3.12 on Linux")
    if (os.environ.get("GITHUB_EVENT_NAME") != "workflow_dispatch"
            or os.environ.get("GITHUB_REPOSITORY") != "Silo-Server/silo-apple"
            or os.environ.get("GITHUB_REF") != "refs/heads/private/apple-source-gzip-pilot"):
        raise ValueError("Assessment requires the reviewed manual private branch")
    root = pilot.HERE.parents[2]
    if pilot.git(root, "rev-parse", "HEAD") != os.environ.get("GITHUB_SHA"):
        raise ValueError("Controller differs from dispatched commit")
    if pilot.git(root, "status", "--porcelain", "--untracked-files=all", "--ignored"):
        raise ValueError("Controller contains unreviewed changes")
    if inspect.signature(tarfile.TarFile.gzopen).parameters["compresslevel"].default != 9:
        raise ValueError("Accepted helper's default gzip level changed")


def compressed(level, output):
    raw = output / "source.tar"
    directory = output / "levels" / f"{LEVELS.index(level) + 1:02}-level-{level}"
    target = directory / "source.tar.gz"
    receipt = {"level": level, "input_bytes": raw.stat().st_size,
               "header_filename": "source.tar", "header_mtime": 0,
               "memory_scope": "Exact lifetime self max RSS includes interpreter/imports; no sampling observer"}
    before = resource.getrusage(resource.RUSAGE_SELF)
    receipt["self_maxrss_before_kib"] = before.ru_maxrss
    started = time.perf_counter()
    try:
        with raw.open("rb") as source, target.open("xb") as destination:
            with gzip.GzipFile(filename="source.tar", mode="wb", fileobj=destination,
                               compresslevel=level, mtime=0) as archive:
                shutil.copyfileobj(source, archive, length=64 * 1024)
        receipt["result"] = "passed"
    except BaseException as error:
        receipt.update(result="failed", error_type=type(error).__name__, error=str(error))
        traceback.print_exc()
    finally:
        receipt["compression_wall_seconds"] = time.perf_counter() - started
        after = resource.getrusage(resource.RUSAGE_SELF)
        receipt.update(compression_user_seconds=after.ru_utime - before.ru_utime,
                       compression_system_seconds=after.ru_stime - before.ru_stime,
                       self_maxrss_kib=after.ru_maxrss,
                       compressed_bytes=target.stat().st_size if target.exists() else None)
        pilot.write_json(directory / "timing.json", receipt)
    return receipt


def decompressed_digest(path, destination=None):
    digest, size = hashlib.sha256(), 0
    with gzip.open(path, "rb") as source:
        while block := source.read(1024 * 1024):
            digest.update(block)
            size += len(block)
            if destination is not None:
                destination.write(block)
    return digest.hexdigest(), size


def members(path):
    result = {}
    with tarfile.open(path) as archive:
        for member in archive:
            if member.name in result:
                raise ValueError("Compressed tar contains duplicate members")
            digest = None
            if member.isfile():
                with archive.extractfile(member) as source:
                    digest = hashlib.file_digest(source, "sha256").hexdigest()
            result[member.name] = {"type": member.type.decode("ascii"), "mode": member.mode,
                                   "link": member.linkname, "size": member.size, "sha256": digest}
    return result


def owned(command, directory, report):
    directory.mkdir()
    scratch = directory / "tmp"
    scratch.mkdir()
    try:
        with (directory / "process.log").open("wb") as log:
            code = pilot.run_owned(command, log, scratch, report)
    except BaseException as error:
        report.update(error_type=type(error).__name__, error=str(error))
        raise
    finally:
        if (directory / "timing.json").exists():
            try:
                report["timing"] = json.loads((directory / "timing.json").read_text())
            except (OSError, ValueError) as error:
                report["timing_error"] = str(error)
    if code or report.get("timing", {}).get("result") != "passed":
        raise ValueError(f"Owned process failed: {directory.name}")


def assess(source, output, expected):
    pilot.validate_source(source, expected)
    output.mkdir(parents=True, exist_ok=False)
    binding = dict(expected, controller_sha=os.environ["GITHUB_SHA"], python=sys.version,
                   zlib_compile_version=zlib.ZLIB_VERSION, zlib_runtime_version=zlib.ZLIB_RUNTIME_VERSION,
                   gzip_default_level=9, levels=list(LEVELS))
    pilot.write_json(output / "binding.json", binding)
    report = {"qualified": False, "source_preparation": {}, "levels": [],
              "measurement_scope": "Compression-only over the same prepared real tar. Fresh owned processes; fixed gzip header. Source acquisition, tar construction and verification are separate. Filesystem warmth is uncontrolled."}
    started = time.perf_counter()
    command = [sys.executable, str(Path(__file__).resolve()), "--source", str(source), "--output", str(output)]
    try:
        app = output / "committed-app.tar"
        subprocess.run(["git", "--no-replace-objects", "-C", str(source), "archive", "HEAD", "-o", str(app)], check=True)
        app_digest = pilot.digest(app)
        app.unlink()
        owned(command + ["--prepare", "--app-tar-digest", app_digest],
              output / "input", report["source_preparation"])
        prepared = report["source_preparation"]["timing"]
        verified = pilot.inspect_archive(prepared, source, expected)
        reference = dict(verified["members"])
        # Restore the actual raw manifest hash for exact contents comparison.
        manifest_path = f'Silo-source-{expected["source_sha"]}/revisions.json'
        reference[manifest_path] = dict(reference[manifest_path], sha256=verified["raw_manifest_sha256"])
        pilot.write_json(output / "input" / "members.json", dict(verified, members=reference,
                         policy="Exact actual member paths/types/modes/links/sizes/content and order; raw manifest hash restored, immutable source acquisition already verified"))
        with (output / "source.tar").open("xb") as destination:
            payload_digest, payload_size = decompressed_digest(prepared["archive"], destination)
        payload = {"tar_sha256": payload_digest, "tar_bytes": payload_size,
                   "app_archive_sha256": app_digest, "member_count": len(reference),
                   "source_graph": pilot.identities(source), "manifest": verified["manifest"],
                   "source_download_count": len(prepared["download_results"]),
                   "preparation_archive_bytes": prepared["archive_bytes"]}
        pilot.write_json(output / "payload.json", payload)
        (output / "levels").mkdir()
        for index, level in enumerate(LEVELS):
            row = {"level": level}
            report["levels"].append(row)
            directory = output / "levels" / f"{index + 1:02}-level-{level}"
            owned(command + ["--level-index", str(index)], directory, row)
            archive = directory / "source.tar.gz"
            verification = time.perf_counter()
            digest, size = decompressed_digest(archive)
            observed = members(archive)
            pilot.write_json(directory / "members.json", observed)
            row.update(verification_wall_seconds=time.perf_counter() - verification,
                       decompressed_tar_sha256=digest, decompressed_bytes=size,
                       members_equal=observed == reference and list(observed) == list(reference))
            if digest != payload_digest or size != payload_size or not row["members_equal"]:
                raise ValueError(f"Level {level} changed the real tar payload")
        if pilot.digest(output / "source.tar") != payload_digest:
            raise ValueError("Shared real tar changed during compression")
        pilot.validate_source(source, expected)
        baseline = report["levels"][0]["timing"]
        for row in report["levels"]:
            timing = row["timing"]
            extra = timing["compressed_bytes"] - baseline["compressed_bytes"]
            saved = baseline["compression_wall_seconds"] - timing["compression_wall_seconds"]
            row["tradeoff_against_level9"] = {
                "extra_compressed_bytes": extra,
                "extra_percent": 100 * extra / baseline["compressed_bytes"],
                "compression_seconds_saved": saved,
                "extra_transfer_seconds_at_mib_per_second": {str(rate): extra / (rate * 1024 * 1024) for rate in (1, 10, 100)},
                "break_even_transfer_mib_per_second": extra / (saved * 1024 * 1024) if extra > 0 and saved > 0 else None,
                "interpretation": "Mathematical extra bytes / throughput; delivery rate, upload concurrency and total CI gain are unmeasured"}
        report.update(qualified=True, parity="All three gzip streams decompress to the exact same real tar bytes and member contents/order")
    except BaseException as error:
        report["failure"] = f"{type(error).__name__}: {error}"
        raise
    finally:
        report["assessment_wall_seconds"] = time.perf_counter() - started
        pilot.write_json(output / "compression.json", report)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-sha", action="store_true")
    parser.add_argument("--source", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--prepare", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--app-tar-digest", help=argparse.SUPPRESS)
    parser.add_argument("--level-index", type=int, choices=range(3), help=argparse.SUPPRESS)
    args = parser.parse_args()
    context()
    expected = pilot.binding()
    pilot.validate_helpers(expected)
    if args.source_sha:
        print("sha=" + expected["source_sha"])
        return
    if args.source is None or args.output is None:
        parser.error("source and output are required")
    source, output = args.source.resolve(), args.output.resolve()
    pilot.validate_source(source, expected)
    if args.prepare:
        receipt = pilot.execute_arm("candidate", source, output / "input" / "archive", expected, args.app_tar_digest)
    elif args.level_index is not None:
        receipt = compressed(LEVELS[args.level_index], output)
    else:
        assess(source, output, expected)
        return
    if receipt["result"] != "passed":
        raise SystemExit(1)


if __name__ == "__main__":
    main()
