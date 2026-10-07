#!/usr/bin/env python3
"""Bind the private device benchmark to reviewed commits and complete Git trees."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys

REPOSITORY = "Silo-Server/silo-apple"
WORKFLOW = ".github/workflows/player-regression.yml"
HELPER = "scripts/ci/device-benchmark-controls.py"
MANIFEST = "scripts/ci/device-benchmark-shipping-ci.json"
SELECTION = {"prefixes": [".github/", "scripts/ci/", "fastlane/"],
             "files": ["Gemfile", "Gemfile.lock"]}
REQUIRED_CI = {"Gemfile", "Gemfile.lock", "fastlane/Fastfile",
               ".github/actions/cache-spm/action.yml", ".github/workflows/sideload-ipa.yml",
               "scripts/ci/apple-build-metadata.py"}
SHA = re.compile(r"[0-9a-f]{40}\Z")
POSITIVE = re.compile(r"[1-9][0-9]{0,19}\Z")
MAX_FILES, MAX_BYTES = 50000, 4 * 1024 ** 3


def require(condition, message):
    if not condition:
        raise ValueError(message)


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":"),
                       ensure_ascii=False) + "\n").encode("utf-8")


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def git(root, *args):
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
               GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0", GIT_NO_LAZY_FETCH="1",
               GIT_NO_REPLACE_OBJECTS="1")
    result = subprocess.run(["git", "-c", "core.fsmonitor=false", "-c",
                             "core.hooksPath=" + os.devnull, "-c", "core.untrackedCache=false",
                             "-C", str(root), *args], env=env, capture_output=True, timeout=30)
    require(result.returncode == 0, "Git inspection failed: " + args[0])
    require(len(result.stdout) <= 16 * 1024 ** 2, "Git output exceeds inspection limit")
    return result.stdout


def is_ci(path):
    return path in SELECTION["files"] or any(path.startswith(p) for p in SELECTION["prefixes"])


def valid_path(path):
    return (isinstance(path, str) and path and not path.startswith("/") and
            "\\" not in path and not any(ord(c) < 32 or ord(c) == 127 for c in path) and
            all(component not in ("", ".", "..") for component in path.split("/")))


def tree(root):
    entries = []
    for record in git(root, "ls-tree", "-rz", "--full-tree", "HEAD").split(b"\0"):
        if not record:
            continue
        header, raw_path = record.split(b"\t", 1)
        mode, kind, oid = header.decode("ascii").split(" ")
        path = raw_path.decode("utf-8")
        require(valid_path(path), "Unsupported Git path")
        require(kind == "blob" and mode in ("100644", "100755", "120000") and SHA.fullmatch(oid),
                "Unsupported Git tree entry: " + path)
        entries.append({"path": path, "mode": mode, "type": kind, "blob": oid})
    require(0 < len(entries) <= MAX_FILES, "Git tree exceeds file limit or is empty")
    return sorted(entries, key=lambda entry: entry["path"])


def verify_files(root, entries):
    total = 0
    tracked = {entry["path"] for entry in entries}
    for entry in entries:
        relative = Path(entry["path"])
        for parent in relative.parents:
            require((root / parent).is_dir() and not (root / parent).is_symlink(),
                    "Git path has an unsafe parent: " + entry["path"])
        path = root / relative
        before = path.lstat()
        if entry["mode"] == "120000":
            require(stat.S_ISLNK(before.st_mode), "Tracked symlink changed: " + entry["path"])
            data = os.fsencode(os.readlink(path))
            try:
                require(not os.path.isabs(os.fsdecode(data)), "Symlink target must be relative")
                target = path.resolve(strict=True).relative_to(root).as_posix()
                require(target in tracked or (path.is_dir() and any(p.startswith(target + "/") for p in tracked)),
                        "Symlink target is outside the tracked tree")
            except (OSError, RuntimeError, ValueError) as error:
                raise ValueError("Symlink target is not bound to the tracked tree: " + entry["path"]) from error
            size = len(data)
            sha = hashlib.sha1(b"blob " + str(size).encode() + b"\0" + data)
        else:
            require(stat.S_ISREG(before.st_mode), "Tracked file changed type: " + entry["path"])
            executable = bool(before.st_mode & 0o111)
            require(executable == (entry["mode"] == "100755"),
                    "Tracked file changed executable mode: " + entry["path"])
            size = before.st_size
            require(size <= 512 * 1024 ** 2, "Tracked file exceeds byte limit")
            sha = hashlib.sha1(b"blob " + str(size).encode() + b"\0")
            read = 0
            with path.open("rb") as stream:
                for block in iter(lambda: stream.read(1024 ** 2), b""):
                    read += len(block)
                    require(read <= size, "Tracked file changed while reading")
                    sha.update(block)
            require(read == size, "Tracked file changed while reading")
        total += size
        require(total <= MAX_BYTES, "Tracked tree exceeds byte limit")
        after = path.lstat()
        require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_mode) ==
                (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_mode),
                "Tracked file changed while reading: " + entry["path"])
        require(sha.hexdigest() == entry["blob"], "Working file differs from HEAD: " + entry["path"])


def inspect(root, expected_sha):
    require(SHA.fullmatch(expected_sha), "Commit must be 40 lowercase hexadecimal characters")
    require(not root.is_symlink(), "Checkout root cannot be a symlink")
    root = root.resolve(strict=True)
    require(Path(os.fsdecode(git(root, "rev-parse", "--show-toplevel").strip())).resolve() == root,
            "Path must identify a checkout root")
    require(git(root, "rev-parse", "HEAD").decode().strip() == expected_sha, "Checkout HEAD differs from input")
    require(not git(root, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching"),
            "Checkout contains staged, unstaged, untracked, or ignored files")
    flags = git(root, "ls-files", "-v", "-z").split(b"\0")
    require(all(not record or record.startswith(b"H ") for record in flags),
            "Checkout uses hidden index entries")
    entries = tree(root)
    verify_files(root, entries)
    require(git(root, "rev-parse", "HEAD").decode().strip() == expected_sha,
            "Checkout HEAD changed during inspection")
    require(not git(root, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching"),
            "Checkout changed during inspection")
    ci = [entry for entry in entries if is_ci(entry["path"])]
    app = [entry for entry in entries if not is_ci(entry["path"])]
    return {"sha": expected_sha, "tree": git(root, "rev-parse", "HEAD^{tree}").decode().strip(),
            "ci": {"sha256": digest(ci), "count": len(ci)},
            "app": {"sha256": digest(app), "count": len(app)},
            "complete": {"sha256": digest(entries), "count": len(entries)}}, ci, app, entries


def load_manifest(path):
    raw = path.read_bytes()
    require(len(raw) <= 16 * 1024 ** 2, "Shipping CI manifest exceeds byte limit")
    value = json.loads(raw)
    require(isinstance(value, dict) and set(value) == {"schema", "selection", "entries"} and
            value["schema"] == 1 and type(value["schema"]) is int and value["selection"] == SELECTION,
            "Shipping CI manifest has an unsupported schema or selection")
    require(raw == canonical(value), "Shipping CI manifest is not canonical JSON")
    entries = value["entries"]
    require(isinstance(entries, list) and 0 < len(entries) <= MAX_FILES, "Invalid shipping CI entry count")
    seen = set()
    for entry in entries:
        require(isinstance(entry, dict) and set(entry) == {"path", "mode", "type", "blob"},
                "Invalid shipping CI entry")
        path = entry["path"]
        require(valid_path(path) and is_ci(path) and path not in seen, "Invalid or duplicate shipping CI path")
        require(entry["type"] == "blob" and entry["mode"] in ("100644", "100755", "120000") and
                isinstance(entry["blob"], str) and SHA.fullmatch(entry["blob"]), "Invalid shipping CI blob")
        seen.add(path)
    require(REQUIRED_CI <= seen, "Shipping CI manifest is missing benchmark dependencies")
    require(entries == sorted(entries, key=lambda entry: entry["path"]), "Shipping CI entries are not sorted")
    return value


def inputs(args, env):
    require(env.get("GITHUB_REPOSITORY") == REPOSITORY, "Unexpected GitHub repository")
    require(env.get("GITHUB_EVENT_NAME") == "workflow_dispatch", "Benchmark requires workflow_dispatch")
    branch = args.expected_branch
    require(re.fullmatch(r"refs/heads/private/[a-z0-9][a-z0-9_/-]{0,95}", branch) and
            "//" not in branch and not branch.endswith("/"), "Expected branch must be a private branch")
    require(env.get("GITHUB_REF") == branch, "Unexpected GitHub ref")
    for value in (args.controller_sha, args.source_sha, args.fixture_sha):
        require(SHA.fullmatch(value), "Commit inputs must be 40 lowercase hexadecimal characters")
    require(env.get("GITHUB_SHA") == args.controller_sha and
            env.get("GITHUB_WORKFLOW_SHA") == args.controller_sha, "GitHub SHA differs from controller input")
    require(env.get("GITHUB_WORKFLOW_REF") == REPOSITORY + "/" + WORKFLOW + "@" + branch,
            "Unexpected GitHub workflow provenance")
    require(args.profile in ("off", "prime", "warm"), "Invalid benchmark profile")
    require(re.fullmatch(r"apple-device-[a-z0-9_-]{1,16}", args.namespace), "Invalid isolated cache namespace")
    require(bool(POSITIVE.fullmatch(args.prime_run_id)) if args.profile == "warm" else args.prime_run_id == "",
            "Prime run ID is required only for warm runs and must be positive ASCII digits")
    for name in ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT"):
        require(POSITIVE.fullmatch(env.get(name, "")), "Invalid GitHub run identity")
    return {"repository": REPOSITORY, "event": "workflow_dispatch", "ref": branch,
            "workflow": WORKFLOW, "controller_sha": args.controller_sha,
            "run_id": env["GITHUB_RUN_ID"], "run_attempt": env["GITHUB_RUN_ATTEMPT"],
            "profile": args.profile, "namespace": args.namespace,
            "prime_run_id": args.prime_run_id, "source_sha": args.source_sha,
            "fixture_sha": args.fixture_sha}


def preflight(args):
    context = inputs(args, os.environ)
    root = args.controller_root.resolve(strict=True)
    require(Path(__file__).resolve(strict=True) == root / HELPER, "Executing helper is outside the controller")
    require(args.shipping_ci_manifest.resolve(strict=True) == root / MANIFEST,
            "Shipping CI manifest is outside the controller")
    description, _, _, entries = inspect(args.controller_root, args.controller_sha)
    by_path = {entry["path"]: entry for entry in entries}
    provenance = {}
    for path in (HELPER, WORKFLOW, MANIFEST):
        require(path in by_path and by_path[path]["mode"] in ("100644", "100755"),
                "Controller provenance file is missing or is not a regular file: " + path)
        provenance[path] = {"blob": by_path[path]["blob"],
                            "sha256": hashlib.sha256((root / path).read_bytes()).hexdigest()}
    manifest = load_manifest(args.shipping_ci_manifest)
    return {"schema": 1, "operation": "preflight", "context": context, "controller": description,
            "provenance": provenance, "shipping_ci": {"sha256": digest(manifest["entries"]),
                                                       "count": len(manifest["entries"])}}


def bind(args):
    result = preflight(args)
    source, source_ci, source_app, _ = inspect(args.source_root, args.source_sha)
    fixture, _, fixture_app, _ = inspect(args.fixture_root, args.fixture_sha)
    expected = load_manifest(args.shipping_ci_manifest)["entries"]
    require(source_ci == expected, "Source CI tree differs from the reviewed shipping manifest")
    require(source_app == fixture_app, "Source app tree differs from the frozen fixture")
    result.update(operation="bind", source=source, fixture=fixture, qualified=True)
    return result


def write_output(path, value, roots):
    target = path.resolve()
    require(all(target != root.resolve() and root.resolve() not in target.parents for root in roots),
            "Receipt output must be outside inspected checkouts")
    with path.open("xb") as stream:
        stream.write(canonical(value))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="operation", required=True)
    seal = commands.add_parser("seal-shipping-ci")
    seal.add_argument("--root", required=True, type=Path)
    seal.add_argument("--sha", required=True)
    seal.add_argument("--output", required=True, type=Path)
    for operation in ("preflight", "bind"):
        command = commands.add_parser(operation)
        for option in ("controller-root", "shipping-ci-manifest", "output"):
            command.add_argument("--" + option, required=True, type=Path)
        for option in ("controller-sha", "source-sha", "fixture-sha", "expected-branch", "profile", "namespace"):
            command.add_argument("--" + option, required=True)
        command.add_argument("--prime-run-id", default="")
        if operation == "bind":
            command.add_argument("--source-root", required=True, type=Path)
            command.add_argument("--fixture-root", required=True, type=Path)
    args = parser.parse_args()
    try:
        if args.operation == "seal-shipping-ci":
            _, entries, _, _ = inspect(args.root, args.sha)
            value = {"schema": 1, "selection": SELECTION, "entries": entries}
            require(REQUIRED_CI <= {entry["path"] for entry in entries}, "Missing shipping CI dependencies")
            roots = [args.root]
        else:
            value = bind(args) if args.operation == "bind" else preflight(args)
            roots = [args.controller_root]
            if args.operation == "bind":
                roots += [args.source_root, args.fixture_root]
        write_output(args.output, value, roots)
        print(json.dumps({"operation": args.operation, "receipt_sha256": digest(value)}))
    except (ValueError, OSError, UnicodeError, subprocess.TimeoutExpired) as error:
        print("Device benchmark controls rejected: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
