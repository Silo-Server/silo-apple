#!/usr/bin/env python3
"""Private fixed comparison of the two reviewed source packagers."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import resource
import signal
import subprocess
import sys
import tarfile
import threading
import time
import traceback
import types

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
ORDER = ("sequential", "candidate", "sequential", "candidate")
RESOLVED = "iosApp/Silo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
PINS = "scripts/ci/swift-libass-sources.json"


def digest(path):
    with Path(path).open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2) + "\n")


def git(source, *args):
    return subprocess.check_output(["git", "--no-replace-objects", "-C", str(source), *args]).decode().strip()


def binding():
    value = json.loads((HERE / "binding.json").read_text())
    if any(not isinstance(value[key], str) or not re.fullmatch(r"[0-9a-f]{40}", value[key])
           for key in ("source_sha", "source_tree")):
        raise ValueError("Final app source has not been frozen and reviewed")
    return value


def validate_helpers(expected):
    for kind in ("sequential", "candidate"):
        if digest(HERE / f"{kind}.py") != expected["helpers"][kind]:
            raise ValueError(f"Reviewed {kind} helper bytes changed")


def validate_context():
    if (os.environ.get("GITHUB_EVENT_NAME") != "workflow_dispatch"
            or os.environ.get("GITHUB_REPOSITORY") != "Silo-Server/silo-apple"
            or os.environ.get("GITHUB_REF") != "refs/heads/private/apple-source-download-pilot"):
        raise ValueError("Pilot requires the reviewed manual private-branch context")
    if git(HERE.parents[2], "rev-parse", "HEAD") != os.environ.get("GITHUB_SHA"):
        raise ValueError("Controller checkout differs from the dispatched commit")
    if git(HERE.parents[2], "status", "--porcelain", "--untracked-files=all", "--ignored"):
        raise ValueError("Controller checkout has unreviewed local changes")


def validate_source(source, expected):
    if git(source, "rev-parse", "HEAD") != expected["source_sha"] or git(source, "rev-parse", "HEAD^{tree}") != expected["source_tree"]:
        raise ValueError("App checkout does not match the frozen commit/tree")
    if git(source, "status", "--porcelain", "--untracked-files=all", "--ignored"):
        raise ValueError("App checkout must have no changed, untracked or ignored files")
    for path, expected_digest in expected["source_inputs"].items():
        if digest(source / path) != expected_digest:
            raise ValueError(f"Frozen source input changed: {path}")


def identities(source):
    resolved = json.loads((source / RESOLVED).read_text())["pins"]
    pins = json.loads((source / PINS).read_text())
    result = {"packages/" + pin["identity"]: {"repository": pin["location"], "revision": pin["state"]["revision"]}
              for pin in resolved}
    result["subtitle_builder"] = dict(pins["builder"])
    result.update({"subtitle_libraries/" + pin["name"]: {"repository": pin["repository"], "revision": pin["revision"]}
                   for pin in pins["libraries"]})
    if len(resolved) != 11 or len(pins["libraries"]) != 6 or len(result) != 18:
        raise ValueError("The reviewed 18-component source graph changed")
    return result


def owned_bytes(root):
    logical = allocated = 0
    for directory, _, files in os.walk(root):
        for name in files:
            try:
                stat = (Path(directory) / name).lstat()
                logical += stat.st_size
                allocated += stat.st_blocks * 512
            except FileNotFoundError:
                pass
    return logical, allocated


def tree_rss_kib():
    pending, seen, total = [os.getpid()], set(), 0
    while pending:
        pid = pending.pop()
        if pid in seen:
            continue
        seen.add(pid)
        try:
            match = re.search(r"^VmRSS:\s+(\d+) kB$", Path(f"/proc/{pid}/status").read_text(), re.MULTILINE)
            total += int(match[1]) if match else 0
            for task in Path(f"/proc/{pid}/task").iterdir():
                pending.extend(map(int, (task / "children").read_text().split()))
        except (FileNotFoundError, ProcessLookupError):
            pass
    return total if sys.platform == "linux" else None


class Observations:
    def __init__(self, root):
        self.root, self.stop = root, threading.Event()
        self.samples = self.rss = self.logical = self.allocated = 0
        self.observer_seconds = 0.0
        self.error = None
        self.thread = threading.Thread(target=self.sample)

    def sample(self):
        try:
            while not self.stop.is_set():
                started = time.perf_counter()
                self.rss = max(self.rss, tree_rss_kib() or 0)
                if self.samples % 10 == 0:
                    logical, allocated = owned_bytes(self.root)
                    self.logical, self.allocated = max(self.logical, logical), max(self.allocated, allocated)
                self.samples += 1
                self.observer_seconds += time.perf_counter() - started
                self.stop.wait(0.1)
        except BaseException as error:
            self.error = f"{type(error).__name__}: {error}"

    def finish(self):
        self.stop.set()
        self.thread.join()
        own, children = resource.getrusage(resource.RUSAGE_SELF), resource.getrusage(resource.RUSAGE_CHILDREN)
        return {"platform": sys.platform, "samples": self.samples,
                "sampled_process_tree_rss_peak_kib": self.rss if sys.platform == "linux" else None,
                "self_maxrss_kib": own.ru_maxrss / (1024 if sys.platform == "darwin" else 1),
                "self_user_seconds": own.ru_utime, "self_system_seconds": own.ru_stime,
                "children_user_seconds": children.ru_utime, "children_system_seconds": children.ru_stime,
                "sampled_owned_logical_peak_bytes": self.logical, "sampled_owned_allocated_peak_bytes": self.allocated,
                "observer_seconds": self.observer_seconds, "observer_error": self.error,
                "scope": "Owned child/descendants; owned arm TMPDIR/output/logs. RSS every 0.1s, disk every 1s; peaks can be missed. Observer work is included in packager wall time."}


def phases(events):
    result = {}
    for phase in sorted({event["phase"] for event in events}):
        intervals = sorted((event["start"], event["end"]) for event in events if event["phase"] == phase)
        covered = 0.0
        left, right = intervals[0]
        for start, end in intervals[1:]:
            if start > right:
                covered += right - left
                left, right = start, end
            else:
                right = max(right, end)
        result[phase] = {"operations": len(intervals), "operation_seconds_sum": sum(end - start for start, end in intervals),
                         "active_wall_seconds": covered + right - left,
                         "span_seconds": max(end for _, end in intervals) - intervals[0][0]}
    return result


def acquisition_concurrency(events):
    edges = [(event[point], delta) for event in events if event["phase"] == "component_acquisition"
             for point, delta in (("start", 1), ("end", -1))]
    active = maximum = 0
    for _, delta in sorted(edges):
        active += delta
        maximum = max(maximum, active)
    return maximum


def execute_arm(kind, source, output, expected, app_tar_digest):
    validate_helpers(expected)
    validate_source(source, expected)
    graph = identities(source)
    spec = importlib.util.spec_from_file_location("packager", HERE / f"{kind}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.ROOT = source
    events, downloads, app_digests = [], {}, []
    local, lock, origin = threading.local(), threading.Lock(), time.perf_counter()

    def timed(phase, function, *args, **kwargs):
        start = time.perf_counter() - origin
        try:
            return function(*args, **kwargs)
        finally:
            with lock:
                events.append({"phase": phase, "component": getattr(local, "component", None),
                               "start": start, "end": time.perf_counter() - origin})

    original_download = module.download_source

    def download(repository, revision, destination):
        local.component = next(name for name, identity in graph.items() if identity == {"repository": repository, "revision": revision})
        result = timed("component_acquisition", original_download, repository, revision, destination)
        with lock:
            downloads[local.component] = result
        return result

    original_urlopen = module.urlopen

    class Response:
        def __init__(self, response, started):
            self.response, self.started, self.bytes = response, started, 0

        def __enter__(self):
            self.response.__enter__()
            return self

        def read(self, size=-1):
            data = self.response.read(size)
            self.bytes += len(data)
            return data

        def __exit__(self, *args):
            try:
                return self.response.__exit__(*args)
            finally:
                with lock:
                    events.append({"phase": "download_stream", "component": local.component, "start": self.started,
                                   "end": time.perf_counter() - origin, "bytes": self.bytes})

    def urlopen(*args, **kwargs):
        start = time.perf_counter() - origin
        try:
            return Response(original_urlopen(*args, **kwargs), start)
        except BaseException:
            with lock:
                events.append({"phase": "download_stream", "component": local.component, "start": start,
                               "end": time.perf_counter() - origin, "bytes": 0, "failed_before_response": True})
            raise

    original_open = module.tarfile.open

    class Archive:
        def __init__(self, archive, path, mode, started):
            self.archive, self.path, self.mode, self.started = archive, path, mode, started

        def __enter__(self):
            self.archive.__enter__()
            return self

        def __getattr__(self, name):
            return getattr(self.archive, name)

        def extractall(self, *args, **kwargs):
            return timed("app_extraction" if self.path.name == "app.tar" else "source_extraction", self.archive.extractall, *args, **kwargs)

        def __exit__(self, *args):
            try:
                return self.archive.__exit__(*args)
            finally:
                if self.mode == "w:gz":
                    with lock:
                        events.append({"phase": "final_compression", "component": None, "start": self.started,
                                       "end": time.perf_counter() - origin})

    def archive_open(path, mode="r", **kwargs):
        start = time.perf_counter() - origin
        return Archive(original_open(path, mode, **kwargs), Path(path), mode, start)

    original_run, original_check_output = module.subprocess.run, module.subprocess.check_output

    def run(command, **kwargs):
        result = timed("app_git_archive", original_run, [command[0], "--no-replace-objects", *command[1:]], **kwargs)
        app_digests.append(timed("app_snapshot_verification", digest, command[command.index("-o") + 1]))
        return result

    def check_output(command, **kwargs):
        return original_check_output([command[0], "--no-replace-objects", *command[1:]], **kwargs)

    module.download_source, module.urlopen = download, urlopen
    module.tarfile = types.SimpleNamespace(open=archive_open)
    module.subprocess = types.SimpleNamespace(run=run, check_output=check_output)
    observations = Observations(output.parent)
    observations.thread.start()
    record = {"kind": kind, "source_sha": expected["source_sha"], "helper_sha256": digest(HERE / f"{kind}.py")}
    started = time.perf_counter()
    try:
        archive = module.package_sources(source, output)
        record.update(result="passed", archive=str(archive), archive_bytes=archive.stat().st_size)
    except BaseException as error:
        record.update(result="failed", error_type=type(error).__name__, error=str(error)[:1000])
        traceback.print_exc()
    finally:
        record["packager_wall_seconds"] = time.perf_counter() - started
        record["resources"] = observations.finish()
        record.update(events=events, phases=phases(events), download_results=downloads,
                      app_archive_digests=app_digests, app_archive_matches_committed_snapshot=app_digests == [app_tar_digest])
        record["observed_acquisition_concurrency"] = acquisition_concurrency(events)
        record["thread_leaks"] = [thread.name for thread in threading.enumerate() if thread is not threading.main_thread()]
        try:
            validate_source(source, expected)
        except Exception as error:
            record.update(result="failed", source_error=str(error))
        write_json(output.parent / "timing.json", record)
    return record


def manifest_acquisitions(manifest):
    result = {"packages/" + key: value for key, value in manifest["packages"].items()}
    result["subtitle_builder"] = manifest["subtitle_builder"]
    result.update({"subtitle_libraries/" + key: value for key, value in manifest["subtitle_libraries"].items()})
    return result


def inspect_archive(record, source, expected):
    if record["result"] != "passed" or not record["app_archive_matches_committed_snapshot"] or record["thread_leaks"]:
        raise ValueError("Arm failed, changed app archive inputs or left running workers")
    if record["resources"]["observer_error"] or not record["resources"]["samples"]:
        raise ValueError("Arm resource observations failed")
    graph = identities(source)
    if set(record["download_results"]) != set(graph):
        raise ValueError("Arm did not download exactly the required sources")
    if record["observed_acquisition_concurrency"] > (1 if record["kind"] == "sequential" else 2):
        raise ValueError("Arm exceeded its reviewed download concurrency")
    prefix, members = f'Silo-source-{expected["source_sha"]}/', {}
    with tarfile.open(record["archive"]) as archive:
        manifest = json.load(archive.extractfile(prefix + "revisions.json"))
        if manifest["app_revision"] != expected["source_sha"] or set(manifest) != {"app_revision", "packages", "subtitle_libraries", "subtitle_builder"}:
            raise ValueError("Manifest does not describe the frozen source")
        observed = manifest_acquisitions(manifest)
        if observed != record["download_results"]:
            raise ValueError("Manifest digests do not match actual acquisitions")
        for name, identity in graph.items():
            if {key: observed[name][key] for key in ("repository", "revision")} != identity or set(observed[name]) != {"repository", "revision", "archive_sha256"}:
                raise ValueError(f"Unexpected immutable source identity: {name}")
            if not re.fullmatch(r"[0-9a-f]{64}", observed[name]["archive_sha256"]):
                raise ValueError(f"Invalid downloaded archive digest: {name}")
        if list(manifest["packages"]) != [pin["identity"] for pin in json.loads((source / RESOLVED).read_text())["pins"]]:
            raise ValueError("Package manifest order changed")
        native = json.loads((source / PINS).read_text())["libraries"]
        if list(manifest["subtitle_libraries"]) != [pin["name"] for pin in native]:
            raise ValueError("Native manifest order changed")
        for member in archive:
            if member.name in members:
                raise ValueError("Archive has duplicate members")
            file_digest = None
            if member.isfile():
                with archive.extractfile(member) as contents:
                    file_digest = hashlib.file_digest(contents, "sha256").hexdigest()
            members[member.name] = {"type": member.type.decode("ascii"), "mode": member.mode, "link": member.linkname,
                                    "size": member.size, "sha256": file_digest}
    required = ["app/iosApp/project.yml", "REBUILD.md", "revisions.json", "packages/swift-libass/build-libraries.sh",
                "packages/swift-libass/build-local.sh", "packages/swift-libass/.source/ffmpeg-kit/scripts/source.sh"]
    required.extend("packages/swift-libass/.source/ffmpeg-kit/src/" + pin["name"] for pin in native)
    if any(prefix + path not in members for path in required):
        raise ValueError("Source archive is missing a required rebuild path")
    normalized = json.loads(json.dumps(manifest))
    for value in list(normalized["packages"].values()) + list(normalized["subtitle_libraries"].values()) + [normalized["subtitle_builder"]]:
        del value["archive_sha256"]
    raw_manifest_hash = members[prefix + "revisions.json"]["sha256"]
    members[prefix + "revisions.json"]["sha256"] = hashlib.sha256(json.dumps(normalized, separators=(",", ":")).encode()).hexdigest()
    return {"members": members, "manifest": manifest, "normalized_manifest": normalized,
            "raw_manifest_sha256": raw_manifest_hash,
            "policy": "Exact member paths/types/modes/links/sizes/content and manifest identities/order. Normalize only downloaded tar.gz provenance digests, after verifying actual acquisitions. Exclude timestamps."}


def run_owned(command, log, scratch, receipt):
    started = time.perf_counter()
    receipt.update(started_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), timeout_seconds=480,
                   termination_signals=[], cleanup_complete=False)
    try:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                                   env=dict(os.environ, TMPDIR=str(scratch)), start_new_session=True)
    except BaseException as error:
        receipt.update(wait_error_type=type(error).__name__, invocation_wall_seconds=time.perf_counter() - started,
                       cleanup_complete=True, owned_process_group=None, exit_code=None)
        raise
    receipt["owned_process_group"] = process.pid

    def send(signum):
        try:
            os.killpg(process.pid, signum)
            sent = True
        except ProcessLookupError:
            sent = False
        receipt["termination_signals"].append({"signal": signal.Signals(signum).name, "sent": sent,
                                                "seconds_since_start": time.perf_counter() - started})

    def group_alive():
        try:
            os.killpg(process.pid, 0)
            return True
        except ProcessLookupError:
            return False

    try:
        returncode = process.wait(timeout=480)
        if group_alive():
            raise ValueError("Arm exited with an owned descendant still running")
        receipt["cleanup_complete"] = True
        return returncode
    except BaseException as error:
        receipt.update(wait_error_type=type(error).__name__, timed_out=isinstance(error, subprocess.TimeoutExpired))
        send(signal.SIGTERM)
        try:
            process.wait(timeout=10)
        except BaseException as cleanup_error:
            receipt["cleanup_wait_error_type"] = type(cleanup_error).__name__
            send(signal.SIGKILL)
            try:
                process.wait(timeout=10)
            except BaseException as final_error:
                receipt["cleanup_error"] = f"Owned parent wait after SIGKILL: {type(final_error).__name__}"
        if group_alive():
            send(signal.SIGKILL)
            # The owner waits only for this group; allow the kernel to finish
            # terminating descendants without blocking the controller indefinitely.
            for _ in range(100):
                if not group_alive():
                    break
                time.sleep(0.05)
        receipt["cleanup_complete"] = process.returncode is not None and not group_alive()
        if isinstance(error, subprocess.TimeoutExpired):
            raise ValueError("Owned arm exceeded the eight-minute limit") from error
        raise
    finally:
        receipt.update(exit_code=process.returncode, invocation_wall_seconds=time.perf_counter() - started)


def compare(source, output, expected):
    comparison_started = time.perf_counter()
    validate_helpers(expected)
    validate_source(source, expected)
    output.mkdir(parents=True, exist_ok=False)
    app_tar = output / "committed-app.tar"
    subprocess.run(["git", "--no-replace-objects", "-C", str(source), "archive", "HEAD", "-o", str(app_tar)], check=True)
    app_tar_digest = digest(app_tar)
    app_tar.unlink()
    write_json(output / "binding.json", dict(expected, committed_app_tar_sha256=app_tar_digest,
                                            controller_sha=os.environ.get("GITHUB_SHA"), python=sys.version))
    report = {"qualified": False, "order": list(ORDER), "arms": [],
              "interpretation": "Ordered live network comparisons with fresh per-arm processes/storage. Ambient filesystem/CDN state is uncontrolled. Payload verification follows timed packaging; app-tar hashing and observer overhead are recorded inside packaging. Overlapping phase totals are not elapsed savings."}
    reference = None
    try:
        for index, kind in enumerate(ORDER, 1):
            arm = output / f"{index:02}-{kind}"
            arm.mkdir()
            scratch = arm / "tmp"
            scratch.mkdir()
            command = [sys.executable, str(HERE / "compare.py"), "--source", str(source), "--output", str(arm),
                       "--arm", str(index - 1), "--app-tar-digest", app_tar_digest]
            report_arm = {"kind": kind}
            report["arms"].append(report_arm)
            try:
                with (arm / "process.log").open("wb") as log:
                    returncode = run_owned(command, log, scratch, report_arm)
            except BaseException as error:
                report_arm.update(result="failed", error_type=type(error).__name__, error=str(error))
                raise
            finally:
                if (arm / "timing.json").exists():
                    try:
                        report_arm["packager_record"] = json.loads((arm / "timing.json").read_text())
                    except (ValueError, OSError) as error:
                        report_arm["packager_record_error"] = str(error)
            record = report_arm["packager_record"]
            report_arm.update(record)
            if returncode:
                raise ValueError(f"Arm {index} exited {returncode}")
            verification_started = time.perf_counter()
            try:
                verified = inspect_archive(record, source, expected)
                write_json(arm / "members.json", verified)
            finally:
                report_arm["verification_wall_seconds"] = time.perf_counter() - verification_started
            report_arm["raw_manifest_sha256"] = verified["raw_manifest_sha256"]
            if reference is None:
                reference = verified
            elif verified["members"] != reference["members"] or verified["normalized_manifest"] != reference["normalized_manifest"]:
                raise ValueError(f"Arm {index} archive payload or source identity differs")
            reference_downloads = manifest_acquisitions(reference["manifest"])
            report_arm["downloaded_archive_digest_changes"] = [name for name, value in record["download_results"].items()
                                                               if value["archive_sha256"] != reference_downloads[name]["archive_sha256"]]
        report["qualified"] = True
        report["parity"] = "All four actual archives match under the recorded provenance policy"
    except BaseException as error:
        report["failure"] = f"{type(error).__name__}: {error}"
        raise
    finally:
        report["comparison_wall_seconds"] = time.perf_counter() - comparison_started
        write_json(output / "comparison.json", report)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-sha", action="store_true")
    parser.add_argument("--source", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--arm", type=int, choices=range(4), help=argparse.SUPPRESS)
    parser.add_argument("--app-tar-digest", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if sys.version_info[:2] != (3, 12) or sys.platform != "linux":
        raise ValueError("Hosted pilot requires actual Python 3.12 on Linux")
    validate_context()
    expected = binding()
    validate_helpers(expected)
    if args.source_sha:
        print("sha=" + expected["source_sha"])
    elif args.arm is not None:
        record = execute_arm(ORDER[args.arm], args.source.resolve(), args.output / "archive", expected, args.app_tar_digest)
        if record["result"] != "passed":
            raise SystemExit(1)
    else:
        compare(args.source.resolve(), args.output.resolve(), expected)


if __name__ == "__main__":
    main()
