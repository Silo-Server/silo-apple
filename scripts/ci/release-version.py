#!/usr/bin/env python3
"""Pick the version, build number and tag for a release from the repo's tags.

Every Release run makes a TestFlight build tagged vX.Y.Z-beta.B:

- X.Y.Z is the marketing version (CFBundleShortVersionString). It stays the
  same for every TestFlight build until promote.yml drafts the store release
  vX.Y.Z, so later builds skip Beta App Review. The draft counts as released,
  and the next run starts a new version with bump=minor/patch. (App Store
  Connect itself refuses more X.Y.Z builds only once it approves X.Y.Z.)
- B is the build number (CFBundleVersion), shared by iOS and tvOS: the next
  TestFlight build number (--min-build), or one more than every build already
  in a tag if that is higher.

A store release (promote.yml) later tags the same commit vX.Y.Z.

Commands print key=value lines for $GITHUB_OUTPUT:

    release-version.py next --bump build|minor|patch [--version X.Y.Z] [--draft vX.Y.Z ...] [--min-build N]
    release-version.py beta vX.Y.Z-beta.B
    release-version.py previous-release vX.Y.Z
    release-version.py store-notes LIMIT < generated-notes.md
    release-version.py titles < generated-notes.md
"""

import argparse
import re
import subprocess
import sys

TAG = re.compile(r"v(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+(\d+))?")
BETA = re.compile(r"beta\.(\d+)")
VERSION = re.compile(r"(\d+)\.(\d+)\.(\d+)")


class ReleaseError(Exception):
    pass


def parse_tag(name):
    """Return (version, prerelease, build) for a release tag, else None."""
    match = TAG.fullmatch(name)
    if not match:
        return None
    version = tuple(int(part) for part in match.group(1, 2, 3))
    prerelease = match.group(4)
    beta = BETA.fullmatch(prerelease or "")
    if beta:
        build = int(beta.group(1))
    elif match.group(5):
        build = int(match.group(5))
    else:
        build = None
    return version, prerelease, build


def version_text(version):
    return ".".join(str(part) for part in version)


def next_release(tags, bump, version=None, min_build=None, drafts=()):
    tags = [*tags, *drafts]
    parsed = {name: tag for name in tags if (tag := parse_tag(name))}
    # Only an exact vX.Y.Z tag marks a store release. Older tags with build
    # metadata (v1.0.0+21) were tester builds.
    released = {tag[0] for name, tag in parsed.items() if tag[1] is None and "+" not in name}
    latest_release = max(released, default=None)
    with_builds = [(tag[2], name) for name, tag in parsed.items() if tag[2] is not None]
    previous_build, previous_tag = max(with_builds, default=(0, None))
    betas = [(tag[2], tag[0]) for tag in parsed.values() if BETA.fullmatch(tag[1] or "")]
    # A hotfix can ship while a newer version is still in testing, so continue
    # the newest version that hasn't been released.
    unreleased = [beta for beta in betas if beta[1] not in released]

    if version:
        match = VERSION.fullmatch(version.removeprefix("v"))
        if not match:
            raise ReleaseError(f"Version must look like 1.2.0, got {version!r}.")
        target = tuple(int(part) for part in match.groups())
    elif bump == "build":
        if not betas:
            raise ReleaseError("There is no tester build to continue yet. Pass the version to start with, for example 1.0.0.")
        if not unreleased:
            raise ReleaseError(
                "There is no unreleased version to add a build to. "
                "Run with bump=minor (new features) or bump=patch (fixes only) to start the next version."
            )
        target = max(unreleased)[1]
    elif latest_release is None:
        raise ReleaseError("Nothing has been released yet, so there is nothing to bump. Pass an explicit version.")
    elif bump == "minor":
        target = (latest_release[0], latest_release[1] + 1, 0)
    elif bump == "patch":
        target = (latest_release[0], latest_release[1], latest_release[2] + 1)
    else:
        raise ReleaseError(f"Unknown bump {bump!r}.")

    if latest_release is not None and target <= latest_release:
        raise ReleaseError(
            f"{version_text(target)} is not newer than the latest release, {version_text(latest_release)}. "
            "A store release, including a draft, closes its version to new builds."
        )

    build = max(previous_build + 1, min_build or 1)
    return {
        "version": version_text(target),
        "build": str(build),
        "tag": f"v{version_text(target)}-beta.{build}",
        "previous_tag": previous_tag or "",
    }


def previous_release(tags, name):
    """The newest App Store release (an exact vX.Y.Z tag) older than name."""
    target = parse_tag(name)
    if not target or target[1] is not None or "+" in name:
        raise ReleaseError(f"{name!r} is not a store release tag like v1.2.0.")
    older = [tag[0] for tag_name, tag in ((n, parse_tag(n)) for n in tags)
             if tag and tag[1] is None and "+" not in tag_name and tag[0] < target[0]]
    return {"previous_release": f"v{version_text(max(older))}" if older else ""}


def beta_release(name):
    tag = parse_tag(name)
    if not tag or not BETA.fullmatch(tag[1] or ""):
        raise ReleaseError(f"{name!r} is not a TestFlight build tag like v1.2.0-beta.42.")
    version, _, build = tag
    return {
        "version": version_text(version),
        "build": str(build),
        "tag": name,
        "release_tag": f"v{version_text(version)}",
    }


ENTRY = re.compile(r"\* (.+?)(?: by @\S+)?(?: in https://\S+)?")
CONVENTIONAL = re.compile(r"([a-z]+)(?:\([^)]*\))?!?: ", re.IGNORECASE)
USER_FACING = {"feat", "fix", "perf"}


def store_notes(markdown, limit):
    """Plain-text store notes from GitHub's generated release notes.

    Keeps the entries filed under Features or Fixes, plus any other entry whose
    Conventional Commit type is feat, fix or perf (not every pull request is
    labeled). Drops PR links, authors and the type prefix, and fits the result
    into the store's length limit.
    """
    lines, labeled = [], False
    for line in markdown.splitlines():
        if line.startswith("#"):
            labeled = "Features" in line or "Fixes" in line
            continue
        match = ENTRY.fullmatch(line.strip())
        if not match:
            continue
        text = match.group(1)
        prefix = CONVENTIONAL.match(text)
        if not labeled and not (prefix and prefix.group(1).lower() in USER_FACING):
            continue
        if prefix:
            text = text[prefix.end():]
        lines.append(f"• {text[:1].upper()}{text[1:]}")
    if not lines:
        return "Bug fixes and improvements."

    more = "• And more."
    notes = []
    for line in lines:
        reserve = 0 if len(notes) + 1 == len(lines) else len(more) + 1
        if len("\n".join(notes + [line])) + reserve > limit:
            notes.append(more)
            break
        notes.append(line)
    return "\n".join(notes)


def pr_titles(markdown):
    """The generated notes reduced to section names and pull request titles.

    This is all summarize-what-to-test.sh sends to the model: no authors,
    links, pull request bodies or the New Contributors list.
    """
    lines = []
    for line in markdown.splitlines():
        if line.startswith("## ") and "What's Changed" not in line:
            break
        if line.startswith("### "):
            lines.append(re.sub(r"^###\s*\W*", "", line).strip() + ":")
            continue
        match = ENTRY.fullmatch(line.strip())
        if match:
            lines.append(f"- {match.group(1)}")
    return "\n".join(lines)


def git_tags():
    return subprocess.run(
        ["git", "tag", "--list", "v*"], check=True, capture_output=True, text=True
    ).stdout.split()


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    next_parser = commands.add_parser("next")
    next_parser.add_argument("--bump", choices=["build", "minor", "patch"], default="build")
    next_parser.add_argument("--version", default="")
    # A draft store release (vX.Y.Z) has no git tag yet but counts as released.
    next_parser.add_argument("--draft", action="append", default=[])
    next_parser.add_argument("--min-build", type=int)
    beta_parser = commands.add_parser("beta")
    beta_parser.add_argument("tag")
    previous_parser = commands.add_parser("previous-release")
    previous_parser.add_argument("tag")
    notes_parser = commands.add_parser("store-notes")
    notes_parser.add_argument("limit", type=int)
    commands.add_parser("titles")
    args = parser.parse_args(argv)

    try:
        if args.command == "store-notes":
            print(store_notes(sys.stdin.read(), args.limit))
            return 0
        if args.command == "titles":
            print(pr_titles(sys.stdin.read()))
            return 0
        if args.command == "next":
            result = next_release(git_tags(), args.bump, args.version, args.min_build, args.draft)
        elif args.command == "previous-release":
            result = previous_release(git_tags(), args.tag)
        else:
            result = beta_release(args.tag)
    except ReleaseError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1
    for key, value in result.items():
        print(f"{key}={value}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
