#!/usr/bin/env python3
"""Select Apple regression platforms from a complete local Git comparison.

Checkout with fetch-depth: 0 before calling this helper. A missing comparison,
unknown input, deletion, rename, or changed project input configuration runs every
platform. Release calls and manual runs default to every platform; an explicit
FORCE_PLATFORMS platform is accepted only for a manual comparison.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess


PLATFORMS = ("ios", "tvos", "macos")
MATRIX_ENTRIES = {
    "ios": {"scheme": "Silo", "destination": "platform=iOS Simulator,name=iPhone 17 Pro", "action": "test", "platform": "iOS", "test_target": "SiloTests"},
    "tvos": {"scheme": "SiloTV", "destination": "platform=tvOS Simulator,name=Apple TV 4K (3rd generation)", "action": "test", "platform": "tvOS", "test_target": "SiloTVTests"},
    "macos": {"scheme": "SiloMac", "destination": "generic/platform=macOS", "action": "build", "platform": "macOS"},
}
PROJECT = "iosApp/project.yml"
# The meaningful lines of project.yml and every committed Signing/*.xcconfig.
# Settings and includes can introduce build inputs outside a source directory.
# Review ownership and update this snapshot when project configuration changes.
BUILD_INPUTS_SHA256 = "c723fb5aebf3bf907125d7abda0df91845ac1d8f40f1ace108bbca3cb25e5998"
SHA_PATTERN = re.compile(r"^[0-9a-fA-F]{40}$")
ROOT_DOCUMENTATION = frozenset({"README.md", "CONTRIBUTING.md", "AGENTS.md", "SECURITY.md", "CHANGELOG.md"})
# These 223 existing Swift inputs belong exclusively to the mobile test targets.
# Refresh their ownership review after any other tracked input changes. Both Git
# trees must retain every other path, mode and blob from the reviewed graph.
TEST_SOURCE_OWNERSHIP = "scripts/ci/apple-test-source-ownership.json"
TEST_SOURCE_OWNERSHIP_SHA256 = "cfbabb4be7fd3f3316cea06e14590dc347a5dce607ba39c9616046f642c6dfb7"
TEST_SOURCE_INPUTS_SHA256 = "ccffff0f25127480afa371b6fdc7613b914efa532f5dcf51aa52a896fb49f91e"
SELECTOR_FILES = ("scripts/ci/select-apple-platforms.py", "scripts/ci/select-apple-platforms.test.py", TEST_SOURCE_OWNERSHIP)
SELECTOR_CONTRACT = "scripts/ci/apple-test-selector-contract.json"


class SelectionUnavailable(Exception):
    """The available inputs cannot prove that skipping a platform is safe."""


def git(repo, *args):
    return subprocess.run(
        ["git", "--no-replace-objects", "-C", str(repo), *args],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True,
    ).stdout


def build_inputs_fingerprint(project, configs):
    """Snapshot every setting that can affect input ownership, without YAML parsing."""
    records = {PROJECT: [
        line.rstrip() for line in project.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]}
    for path, config in configs.items():
        records[path] = [
            line.rstrip() for line in config.splitlines()
            if line.strip() and not line.lstrip().startswith("//")
        ]
    encoded = json.dumps(records, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def commit_sha(value, repo):
    if not isinstance(value, str) or not SHA_PATTERN.fullmatch(value) or set(value) == {"0"}:
        raise SelectionUnavailable("The event does not supply a complete commit SHA.")
    sha = git(repo, "rev-parse", "--verify", value + "^{commit}").decode().strip()
    if sha.lower() != value.lower():
        raise SelectionUnavailable("The event commit could not be verified.")
    return sha


def require_ancestor(repo, ancestor, head):
    try:
        git(repo, "merge-base", "--is-ancestor", ancestor, head)
    except subprocess.CalledProcessError as exc:
        raise SelectionUnavailable("The event commits do not match the checkout history.") from exc


def parse_changes(raw):
    """Read Git's NUL-delimited statuses and every old/new rename path."""
    if not raw:
        return []
    if not raw.endswith(b"\0"):
        raise SelectionUnavailable("The changed-file comparison is incomplete.")
    fields = raw[:-1].split(b"\0")
    changes = []
    index = 0
    while index < len(fields):
        status = fields[index].decode("ascii")
        index += 1
        if not re.fullmatch(r"[AMDTUXB]|[RC][0-9]{1,3}", status):
            raise SelectionUnavailable("The comparison contains an unfamiliar file status.")
        count = 2 if status[0] in "RC" else 1
        if index + count > len(fields) or any(not path for path in fields[index:index + count]):
            raise SelectionUnavailable("The changed-file comparison is incomplete.")
        paths = tuple(path.decode("utf-8", errors="surrogateescape") for path in fields[index:index + count])
        changes.append((status, paths))
        index += count
    return changes


def classify_path(path):
    # These directories are separate target sources, or explicitly excluded
    # from both other app targets. Swift #if guards alone prove no ownership.
    if path.startswith("iosApp/iosApp/macOS/"):
        return {"macos"}, "Changes touch the macOS source directory."
    if path.startswith("iosApp/TopShelf/"):
        return {"tvos"}, "Changes touch the tvOS Top Shelf extension."
    if path.startswith(("iosApp/NotificationService/", "iosApp/DownloadsActivity/")):
        return {"ios"}, "Changes touch an iOS extension."
    if path in ROOT_DOCUMENTATION or (path.startswith("docs/") and path.endswith(".md")):
        return set(), "Changes touch documentation outside the build inputs."
    # APPSTORE-EXCEPTION.md and LICENSE are bundled resources. Markdown under
    # iosApp and unrecognized root files must also remain build inputs.
    return set(PLATFORMS), f"Changes touch a shared or unclassified input: {path}"


def regular_controller_bytes(path):
    mode = path.lstat().st_mode
    if not stat.S_ISREG(mode) or mode & 0o111:
        raise SelectionUnavailable("The reviewed test selector requires regular controller files.")
    return path.read_bytes()


def reviewed_test_sources():
    raw = regular_controller_bytes(Path(__file__).resolve().parents[2] / TEST_SOURCE_OWNERSHIP)
    if hashlib.sha256(raw).hexdigest() != TEST_SOURCE_OWNERSHIP_SHA256:
        raise SelectionUnavailable("The test source ownership list needs a review.")
    paths = json.loads(raw)
    if (not isinstance(paths, list) or len(paths) != 223
            or any(not isinstance(path, str) or not path.startswith("iosApp/Tests/") or not path.endswith(".swift") for path in paths)
            or paths != sorted(set(paths))):
        raise SelectionUnavailable("The reviewed test source list is malformed.")
    return frozenset(paths)


def controller_digest(files):
    records = {path: {"mode": "100644", "sha256": hashlib.sha256(raw).hexdigest()} for path, raw in files.items()}
    return hashlib.sha256(json.dumps(records, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def reviewed_test_controller():
    root = Path(__file__).resolve().parents[2]
    raw = regular_controller_bytes(root / SELECTOR_CONTRACT)
    seal = json.loads(raw)
    if (not isinstance(seal, dict) or set(seal) != {"schema_version", "controller_sha256"}
            or type(seal["schema_version"]) is not int or seal["schema_version"] != 1
            or not isinstance(seal["controller_sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", seal["controller_sha256"])):
        raise SelectionUnavailable("The reviewed test selector seal is malformed.")
    files = {path: regular_controller_bytes(root / path) for path in SELECTOR_FILES}
    if controller_digest(files) != seal["controller_sha256"]:
        raise SelectionUnavailable("The test selector changed and needs a complete review.")
    return seal["controller_sha256"], raw


def tree_entries(repo, commit):
    raw = git(repo, "ls-tree", "-r", "--full-tree", "-z", commit)
    records = [record for record in raw.split(b"\0") if record]
    entries = {}
    for record in records:
        metadata, path = record.split(b"\t", 1)
        mode, kind, blob = metadata.split(b" ")
        entries[path.decode("utf-8", errors="surrogateescape")] = (mode, kind, blob)
    return records, entries


def test_source_guard(repo, base, head, known):
    controller, seal = reviewed_test_controller()
    excluded = known | set(SELECTOR_FILES) | {SELECTOR_CONTRACT}
    for commit in (base, head):
        records, entries = tree_entries(repo, commit)
        retained = [record for record in records if record.split(b"\t", 1)[1].decode("utf-8", errors="surrogateescape") not in excluded]
        if hashlib.sha256(b"\0".join(retained) + b"\0").hexdigest() != TEST_SOURCE_INPUTS_SHA256:
            raise SelectionUnavailable("Other tracked inputs changed and need a test source ownership review.")
        for path in known | set(SELECTOR_FILES) | {SELECTOR_CONTRACT}:
            if entries.get(path, ())[:2] != (b"100644", b"blob"):
                raise SelectionUnavailable("Known test modifications require the same regular file mode in both commits.")
        if git(repo, "show", f"{commit}:{SELECTOR_CONTRACT}") != seal:
            raise SelectionUnavailable("The fixed test selector seal must match both compared commits.")
        files = {path: git(repo, "show", f"{commit}:{path}") for path in SELECTOR_FILES}
        if controller_digest(files) != controller:
            raise SelectionUnavailable("Both compared commits must retain the reviewed test selector bytes.")
    return {"source_inputs_sha256": TEST_SOURCE_INPUTS_SHA256, "ownership_sha256": TEST_SOURCE_OWNERSHIP_SHA256, "controller_sha256": controller}


def select_platforms(repo, event, event_name, *, github_sha=None, force_platforms=None):
    selection = {"platforms": list(PLATFORMS), "reasons": [], "head_sha": None, "base_sha": None, "mode": "all"}
    try:
        head = git(repo, "rev-parse", "--verify", "HEAD^{commit}").decode().strip()
        selection["head_sha"] = head
        if github_sha and commit_sha(github_sha, repo) != head:
            raise SelectionUnavailable("The checkout differs from the workflow commit.")
        if force_platforms:
            if force_platforms in PLATFORMS and event_name == "workflow_dispatch":
                selection.update(platforms=[force_platforms], mode="manual", reasons=[f"The manual run explicitly requests the {force_platforms} comparison."])
                return selection
            if force_platforms == "all":
                selection["reasons"] = ["The workflow explicitly requests every platform."]
                return selection
            raise SelectionUnavailable("The requested platform override is unsupported for this event.")
        if event_name not in {"pull_request", "push"}:
            selection["reasons"] = ["Manual and reusable workflow runs default to every platform."]
            return selection
        if not isinstance(event, dict):
            raise SelectionUnavailable("The workflow event could not be read.")
        if git(repo, "rev-parse", "--is-shallow-repository").decode().strip() != "false":
            raise SelectionUnavailable("The checkout has incomplete history; use fetch-depth: 0.")
        if event_name == "pull_request":
            pull_request = event.get("pull_request")
            if not isinstance(pull_request, dict):
                raise SelectionUnavailable("The pull request comparison is unavailable.")
            base = commit_sha(pull_request.get("base", {}).get("sha"), repo)
            branch_head = commit_sha(pull_request.get("head", {}).get("sha"), repo)
            require_ancestor(repo, branch_head, head)
        else:
            base = commit_sha(event.get("before"), repo)
            if commit_sha(event.get("after"), repo) != head or event.get("deleted"):
                raise SelectionUnavailable("The push event does not match the checkout.")
        require_ancestor(repo, base, head)
        selection["base_sha"] = base
        selection["comparison"] = f"{base}..{head}"
        raw = git(repo, "diff", "--no-ext-diff", "--no-textconv", "--find-renames", "--name-status", "-z", base, head, "--")
        changes = parse_changes(raw)
        selection["changed_files"] = len(changes)
        selection["diff_sha256"] = hashlib.sha256(raw).hexdigest()
        project = git(repo, "show", f"{head}:{PROJECT}").decode("utf-8")
        paths = git(repo, "ls-tree", "-r", "--name-only", "-z", head, "--", "iosApp/Signing").split(b"\0")
        configs = {}
        for path in paths:
            if path.endswith(b".xcconfig"):
                decoded = path.decode("utf-8")
                configs[decoded] = git(repo, "show", f"{head}:{decoded}").decode("utf-8")
        fingerprint = build_inputs_fingerprint(project, configs)
        selection["build_inputs_sha256"] = fingerprint
        if fingerprint != BUILD_INPUTS_SHA256 or (repo / "iosApp/Signing/Local.xcconfig").exists():
            raise SelectionUnavailable("The project input configuration changed and needs an ownership review.")
        # Only an entire comparison of existing, proven test modifications may
        # omit Mac. Additions, resources and mixed changes use normal fallback.
        if changes and all(status == "M" and paths[0].startswith("iosApp/Tests/") for status, paths in changes):
            known = reviewed_test_sources()
            changed_paths = {paths[0] for _, paths in changes}
            if changed_paths <= known:
                selection["test_source_guard"] = test_source_guard(repo, base, head, known)
                selection.update(platforms=["ios", "tvos"], mode="test_sources", reasons=["Only reviewed existing mobile test sources were modified; both complete mobile suites are required."])
                return selection
        platforms = set()
        reasons = []
        for status, paths in changes:
            if status not in {"A", "M"}:
                raise SelectionUnavailable("A deletion, rename, or unusual file change requires every platform.")
            affected, reason = classify_path(paths[0])
            platforms.update(affected)
            if reason not in reasons:
                reasons.append(reason)
        selection["platforms"] = [platform for platform in PLATFORMS if platform in platforms]
        selection["mode"] = "diff"
        selection["reasons"] = reasons or ["The complete comparison contains no changed files."]
    except SelectionUnavailable as exc:
        selection["platforms"] = list(PLATFORMS)
        selection["reasons"] = [str(exc)]
    except (subprocess.CalledProcessError, OSError, UnicodeError, AttributeError, TypeError, ValueError):
        selection["platforms"] = list(PLATFORMS)
        selection["reasons"] = ["The local comparison could not be verified; every platform is required."]
    return selection


def matrix_for_platforms(platforms):
    return {"include": [MATRIX_ENTRIES[platform] for platform in platforms]}


def verify_result(needs, *, event_name, github_sha, cancelled=False, require_all=False):
    """Reject incomplete plans, skipped builds and any failed/cancelled gate."""
    if cancelled:
        raise SelectionUnavailable("The workflow was cancelled.")
    if not isinstance(needs, dict) or set(needs) != {"select", "validate"}:
        raise SelectionUnavailable("The regression dependencies are incomplete.")
    select = needs["select"]
    validate = needs["validate"]
    if not isinstance(select, dict) or select.get("result") != "success":
        raise SelectionUnavailable("Platform selection did not succeed.")
    if not isinstance(validate, dict):
        raise SelectionUnavailable("The validation result is unavailable.")
    try:
        outputs = select["outputs"]
        selection = json.loads(outputs["selection"])
        platforms = json.loads(outputs["platforms"])
        matrix = json.loads(outputs["matrix"])
        has_platforms = outputs["has_platforms"]
    except (KeyError, TypeError, ValueError) as exc:
        raise SelectionUnavailable("The platform selection outputs are missing or malformed.") from exc
    if not isinstance(platforms, list) or any(platform not in PLATFORMS for platform in platforms):
        raise SelectionUnavailable("The selection contains an unknown platform.")
    if platforms != [platform for platform in PLATFORMS if platform in platforms]:
        raise SelectionUnavailable("The selection contains duplicate or unordered platforms.")
    if require_all and platforms != list(PLATFORMS):
        raise SelectionUnavailable("A release gate must validate every platform.")
    if not isinstance(selection, dict) or selection.get("platforms") != platforms or matrix != matrix_for_platforms(platforms):
        raise SelectionUnavailable("The selected platforms and matrix disagree.")
    if has_platforms != str(bool(platforms)).lower():
        raise SelectionUnavailable("The selected platforms and skip decision disagree.")
    head = selection.get("head_sha")
    if not isinstance(head, str) or not SHA_PATTERN.fullmatch(head) or set(head) == {"0"} or head != github_sha:
        raise SelectionUnavailable("The selection does not match the workflow commit.")
    reasons = selection.get("reasons")
    if not isinstance(reasons, list) or not reasons or any(not isinstance(reason, str) or not reason for reason in reasons):
        raise SelectionUnavailable("The platform selection has no valid explanation.")
    mode = selection.get("mode")
    if mode == "all":
        if platforms != list(PLATFORMS):
            raise SelectionUnavailable("The fallback selection must include every platform.")
    elif mode == "manual":
        if event_name != "workflow_dispatch" or len(platforms) != 1:
            raise SelectionUnavailable("A manual selection is invalid for this workflow event.")
    elif mode in {"diff", "test_sources"}:
        base = selection.get("base_sha")
        count = selection.get("changed_files")
        fingerprint = selection.get("diff_sha256")
        if (event_name not in {"pull_request", "push"}
                or not isinstance(base, str) or not SHA_PATTERN.fullmatch(base) or set(base) == {"0"}
                or selection.get("comparison") != f"{base}..{head}"
                or type(count) is not int or count < 0
                or not isinstance(fingerprint, str) or not re.fullmatch(r"[0-9a-f]{64}", fingerprint)
                or selection.get("build_inputs_sha256") != BUILD_INPUTS_SHA256):
            raise SelectionUnavailable("The comparison proof is missing or malformed.")
        if mode == "test_sources":
            try:
                controller, _ = reviewed_test_controller()
            except (OSError, ValueError, TypeError) as exc:
                raise SelectionUnavailable("The reviewed test selector contract could not be verified.") from exc
            if (platforms != ["ios", "tvos"] or count < 1
                    or selection.get("test_source_guard") != {"source_inputs_sha256": TEST_SOURCE_INPUTS_SHA256, "ownership_sha256": TEST_SOURCE_OWNERSHIP_SHA256, "controller_sha256": controller}):
                raise SelectionUnavailable("The mobile test comparison proof is missing or differs from the reviewed controller.")
    else:
        raise SelectionUnavailable("The platform selection mode is unknown.")
    required_result = "success" if platforms else "skipped"
    if validate.get("result") != required_result:
        raise SelectionUnavailable("Every selected regression job must succeed; only an empty plan may skip validation.")
    return "Every selected regression platform passed." if platforms else "The verified comparison requires no Apple build."


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event", default=os.environ.get("GITHUB_EVENT_PATH"))
    parser.add_argument("--event-name", default=os.environ.get("GITHUB_EVENT_NAME", ""))
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--verify-result", action="store_true", help="Validate the aggregate needs JSON supplied in APPLE_REGRESSION_NEEDS")
    args = parser.parse_args()
    if args.verify_result:
        try:
            needs = json.loads(os.environ.get("APPLE_REGRESSION_NEEDS", ""))
            message = verify_result(
                needs, event_name=os.environ.get("GITHUB_EVENT_NAME", ""),
                github_sha=os.environ.get("GITHUB_SHA"),
                cancelled=os.environ.get("APPLE_REGRESSION_CANCELLED", "false") != "false",
                require_all=os.environ.get("APPLE_REGRESSION_REQUIRE_ALL", "false") != "false",
            )
        except (ValueError, SelectionUnavailable) as exc:
            parser.exit(1, f"Regression gate failed: {exc}\n")
        print(message)
        return
    try:
        event = json.loads(Path(args.event).read_text()) if args.event else None
    except (OSError, ValueError, TypeError):
        event = None
    selection = select_platforms(
        args.repo, event, args.event_name,
        github_sha=os.environ.get("GITHUB_SHA"), force_platforms=os.environ.get("FORCE_PLATFORMS"),
    )
    encoded = json.dumps(selection, separators=(",", ":"))
    print(encoded)
    if os.environ.get("GITHUB_OUTPUT"):
        # JSON escapes file names containing line breaks before they enter the
        # Actions output file. Event data never becomes a shell command.
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write("platforms=" + json.dumps(selection["platforms"], separators=(",", ":")) + "\n")
            output.write("selection=" + encoded + "\n")
            output.write("has_platforms=" + str(bool(selection["platforms"])).lower() + "\n")
            output.write("matrix=" + json.dumps(matrix_for_platforms(selection["platforms"]), separators=(",", ":")) + "\n")


if __name__ == "__main__":
    main()
