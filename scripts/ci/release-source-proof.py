#!/usr/bin/env python3
"""Reuse a published source asset only with a completed, matching source-job proof.

Proofs are optional: unavailable metadata always takes the full packaging path.
The existing same-tag concurrency lock covers lookup, publication and proof upload.
"""

from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from urllib.parse import quote, unquote, urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
import zipfile


ROOT = Path(__file__).resolve().parents[2]
REPOSITORY = "Silo-Server/silo-apple"
CALLERS = (".github/workflows/release.yml", ".github/workflows/sideload-ipa.yml")
RESOLVED = "iosApp/Silo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
PINS = "scripts/ci/swift-libass-sources.json"
INPUTS = (RESOLVED, PINS, "scripts/ci/package-release-source.py",
          "scripts/ci/REBUILD-SOURCE.md", "scripts/ci/release-source-proof.py",
          ".github/workflows/release-source.yml")
PROOF_FILE = "release-source-proof.json"
MAX_ZIP_BYTES = 64 * 1024
MAX_PROOF_BYTES = 32 * 1024


class Rejected(Exception):
    """A fixed explanation that can safely appear in release logs."""


def require(condition, reason):
    if not condition:
        raise Rejected(reason)


def positive(value):
    return type(value) is int and value > 0


def parse_json(data):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "Duplicate proof fields")
            result[key] = value
        return result
    return json.loads(data, object_pairs_hook=unique)


def timestamp(value):
    require(isinstance(value, str), "Missing source proof timestamp")
    result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    require(result.tzinfo is not None, "Missing source proof timezone")
    return result.astimezone(timezone.utc)


def git(*args):
    return subprocess.check_output(["git", "--no-replace-objects", "-C", str(ROOT), *args],
                                   stderr=subprocess.DEVNULL, timeout=5)


def identity(env):
    require(env.get("GITHUB_REPOSITORY", "").lower() == REPOSITORY.lower(),
            "Source repository does not match")
    sha = git("rev-parse", "HEAD").decode().strip()
    require(re.fullmatch(r"[0-9a-f]{40}", sha) and sha == env.get("GITHUB_SHA"),
            "Source commit does not match")
    tree = git("rev-parse", "HEAD^{tree}").decode().strip()
    require(re.fullmatch(r"[0-9a-f]{40}", tree), "Invalid source tree")
    git("diff", "--quiet", "HEAD", "--")
    contents = {path: git("show", f"HEAD:{path}") for path in INPUTS}
    require(all((ROOT / path).read_bytes() == data for path, data in contents.items()),
            "Source packaging inputs changed after checkout")
    locked, native = parse_json(contents[RESOLVED]), parse_json(contents[PINS])
    graph = [{"kind": "package", "name": pin["identity"], "repository": pin["location"],
              "revision": pin["state"]["revision"]} for pin in locked["pins"]]
    require(len(graph) == 11 and len({item["name"] for item in graph}) == 11,
            "Incomplete locked package graph")
    require(any(item["name"] == "swift-libass"
                and item["revision"] == native["swift_libass_revision"] for item in graph),
            "Subtitle package and native pins differ")
    graph.append({"kind": "builder", "name": "ffmpeg-kit", "repository": native["builder"]["repository"],
                  "revision": native["builder"]["revision"]})
    graph.extend({"kind": "native", "name": item["name"], "repository": item["repository"],
                  "revision": item["revision"], "tag": item["tag"]} for item in native["libraries"])
    require(len(graph) == 18 and len({item["name"] for item in graph[12:]}) == 6,
            "Incomplete native source graph")
    for item in graph:
        require(isinstance(item["name"], str) and re.fullmatch(r"[A-Za-z0-9_.-]+", item["name"])
                and item["name"] not in (".", "..")
                and isinstance(item["revision"], str) and re.fullmatch(r"[0-9a-f]{40}", item["revision"])
                and isinstance(item["repository"], str)
                and re.fullmatch(r"https://github.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", item["repository"]),
                "Invalid immutable source pin")
    return {"sha": sha, "tree": tree, "graph": graph,
            "inputs": {path: hashlib.sha256(data).hexdigest() for path, data in contents.items()}}


def artifact_name(source, tag):
    require(isinstance(tag, str) and 0 < len(tag) <= 200 and not any(ord(c) < 32 for c in tag),
            "Invalid release tag")
    return "release-source-" + source["sha"] + "-" + hashlib.sha256(tag.encode()).hexdigest()


class ArtifactRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        require(urlsplit(newurl).scheme == "https", "Unsafe proof redirect")
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected is not None and urlsplit(newurl).netloc != urlsplit(req.full_url).netloc:
            redirected.remove_header("Authorization")
        return redirected


class GitHub:
    def __init__(self, token):
        require(bool(token), "Source proof token unavailable")
        self.token = token
        self.deadline = time.monotonic() + 20
        self.opener = build_opener(ArtifactRedirect())

    def get(self, path, binary=False):
        remaining = self.deadline - time.monotonic()
        require(remaining > 0 and path.startswith("/repos/" + REPOSITORY + "/"),
                "Source proof lookup budget exhausted")
        request = Request("https://api.github.com" + path, headers={
            "Authorization": "Bearer " + self.token, "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "silo-apple-source-proof"})
        limit = MAX_ZIP_BYTES if binary else 2 * 1024 * 1024
        with self.opener.open(request, timeout=min(5, remaining)) as response:
            data = response.read(limit + 1)
        require(time.monotonic() <= self.deadline and len(data) <= limit,
                "Source proof response exceeds lookup limits")
        return data if binary else parse_json(data)


def asset_identity(release, source, tag):
    name = "Silo-source-" + source["sha"] + ".tar.gz"
    require(isinstance(release, dict) and positive(release.get("id"))
            and release.get("tag_name") == tag and release.get("draft") is False
            and timestamp(release.get("published_at")) <= datetime.now(timezone.utc),
            "Source release is not published")
    assets = release.get("assets")
    require(isinstance(assets, list) and all(isinstance(item, dict) for item in assets),
            "Source asset metadata is incomplete")
    matches = [item for item in assets if item.get("name") == name]
    require(len(matches) == 1, "Source asset is missing or duplicated")
    asset = matches[0]
    url = asset.get("browser_download_url")
    require(isinstance(url, str), "Source asset URL is missing")
    parsed = urlsplit(url)
    digest = asset.get("digest")
    require(positive(asset.get("id")) and positive(asset.get("size"))
            and asset.get("state") == "uploaded" and isinstance(digest, str)
            and re.fullmatch(r"sha256:[0-9a-f]{64}", digest)
            and parsed.scheme == "https" and parsed.netloc == "github.com"
            and not parsed.query and not parsed.fragment
            and unquote(parsed.path) == f"/{REPOSITORY}/releases/download/{tag}/{name}"
            and not any(ord(c) < 32 for c in url), "Source asset identity is incomplete")
    return {"release_id": release["id"], "id": asset["id"], "name": name,
            "size": asset["size"], "sha256": digest[7:], "url": url}


def validate_producer(run, producer, source):
    require(isinstance(run, dict) and positive(producer.get("run_id"))
            and positive(producer.get("run_attempt")) and run.get("id") == producer["run_id"]
            and run.get("run_attempt") == producer["run_attempt"]
            and run.get("head_sha") == source["sha"] and producer.get("workflow_sha") == source["sha"]
            and isinstance(run.get("head_branch"), str) and bool(run["head_branch"])
            and producer.get("workflow_path") in CALLERS
            and run.get("path", "").split("@", 1)[0] == producer["workflow_path"]
            and producer.get("event") in ("push", "workflow_dispatch")
            and run.get("event") == producer["event"], "Source producer run does not match")
    repositories = [run.get(key) for key in ("repository", "head_repository")]
    require(all(isinstance(repo, dict) and positive(repo.get("id"))
                and repo.get("full_name", "").lower() == REPOSITORY.lower() for repo in repositories)
            and repositories[0]["id"] == repositories[1]["id"], "Source producer is not trusted")


def validate_job(response, run, artifact, now):
    require(isinstance(response, dict) and isinstance(response.get("jobs"), list)
            and type(response.get("total_count")) is int
            and 0 < response["total_count"] == len(response["jobs"]) <= 100
            and all(isinstance(job, dict) and positive(job.get("id")) for job in response["jobs"])
            and len({job["id"] for job in response["jobs"]}) == len(response["jobs"]),
            "Incomplete source job metadata")
    jobs = [job for job in response["jobs"] if job.get("name") in
            ("Publish release source", "source / Publish release source")]
    require(len(jobs) == 1, "Source producer job is missing or duplicated")
    job = jobs[0]
    require(job.get("run_id") == run["id"] and job.get("head_sha") == run["head_sha"]
            and job.get("status") == "completed" and job.get("conclusion") == "success",
            "Source producer job did not complete successfully")
    started, completed = timestamp(job.get("started_at")), timestamp(job.get("completed_at"))
    require(started <= timestamp(artifact.get("created_at")) <= completed <= now,
            "Source artifact was not produced by this completed job")
    steps = job.get("steps")
    require(isinstance(steps, list) and all(isinstance(step, dict) for step in steps),
            "Source producer steps are missing")
    for name in ("Package exact app and library sources", "Publish source before distributing binaries",
                 "Record published source proof", "Upload published source proof"):
        matched = [step for step in steps if step.get("name") == name]
        require(len(matched) == 1 and matched[0].get("status") == "completed"
                and matched[0].get("conclusion") == "success", "Source producer work is incomplete")


def read_proof(archive, artifact):
    digest = artifact.get("digest")
    require(isinstance(archive, bytes) and 0 < len(archive) <= MAX_ZIP_BYTES
            and isinstance(digest, str) and re.fullmatch(r"sha256:[0-9a-f]{64}", digest)
            and hashlib.sha256(archive).hexdigest() == digest[7:], "Source artifact digest does not match")
    with zipfile.ZipFile(io.BytesIO(archive)) as zipped:
        entries = zipped.infolist()
        require(len(entries) == 1 and entries[0].filename == PROOF_FILE
                and 0 < entries[0].file_size <= MAX_PROOF_BYTES and not entries[0].flag_bits & 1
                and not (entries[0].external_attr >> 16) & 0o170000 == 0o120000,
                "Invalid source proof artifact")
        return parse_json(zipped.read(entries[0]))


def find(source, tag, api, now):
    root = "/repos/" + REPOSITORY
    name = artifact_name(source, tag)
    response = api.get(root + "/actions/artifacts?" + urlencode({"name": name, "per_page": 2}))
    require(isinstance(response, dict) and isinstance(response.get("artifacts"), list)
            and type(response.get("total_count")) is int
            and 0 <= len(response["artifacts"]) <= min(2, response["total_count"]),
            "Source proof listing is incomplete")
    for artifact in response["artifacts"]:
        try:
            require(isinstance(artifact, dict) and positive(artifact.get("id"))
                    and artifact.get("name") == name and artifact.get("expired") is False
                    and positive(artifact.get("size_in_bytes"))
                    and artifact["size_in_bytes"] <= MAX_ZIP_BYTES
                    and timestamp(artifact.get("expires_at")) > now, "Source proof is unavailable")
            proof = read_proof(api.get(root + f"/actions/artifacts/{artifact['id']}/zip", binary=True), artifact)
            require(isinstance(proof, dict) and type(proof.get("schema_version")) is int
                    and proof["schema_version"] == 1 and proof.get("repository") == REPOSITORY
                    and proof.get("source") == source and proof.get("release_tag") == tag
                    and isinstance(proof.get("producer"), dict), "Source proof inputs do not match")
            producer = proof["producer"]
            require(positive(producer.get("run_id")) and positive(producer.get("run_attempt")),
                    "Source producer attempt is invalid")
            run = api.get(root + f"/actions/runs/{producer['run_id']}")
            validate_producer(run, producer, source)
            provenance = artifact.get("workflow_run")
            require(isinstance(provenance, dict) and provenance.get("id") == run["id"]
                    and provenance.get("repository_id") == run["repository"]["id"]
                    and provenance.get("head_repository_id") == run["repository"]["id"]
                    and provenance.get("head_sha") == source["sha"]
                    and provenance.get("head_branch") == run.get("head_branch"),
                    "Source artifact provenance does not match")
            jobs = api.get(root + f"/actions/runs/{run['id']}/attempts/{run['run_attempt']}/jobs?per_page=100")
            validate_job(jobs, run, artifact, now)
            # A rerun or replaced/clobbered asset invalidates the old receipt.
            validate_producer(api.get(root + f"/actions/runs/{run['id']}"), producer, source)
            current = asset_identity(api.get(root + "/releases/tags/" + quote(tag, safe="")), source, tag)
            require(json.dumps(proof.get("asset"), sort_keys=True) == json.dumps(current, sort_keys=True),
                    "Published source asset changed after its proof")
            return {"reusable": True, "source_url": current["url"],
                    "reason": "Completed source job and published asset match exact source inputs"}
        except (Rejected, OSError, ValueError, TypeError, KeyError, AttributeError, zipfile.BadZipFile):
            continue
    return {"reusable": False, "source_url": "", "reason": "No matching completed source proof; package exact sources"}


def record(source, tag, api, env, archive_dir):
    ref = env.get("GITHUB_WORKFLOW_REF", "")
    caller = ref.removeprefix(REPOSITORY + "/").split("@", 1)[0]
    require(ref.startswith(REPOSITORY + "/") and "@" in ref and caller in CALLERS
            and env.get("GITHUB_WORKFLOW_SHA") == source["sha"]
            and env.get("GITHUB_EVENT_NAME") in ("push", "workflow_dispatch"),
            "Source producer workflow is not trusted")
    producer = {"run_id": int(env["GITHUB_RUN_ID"]), "run_attempt": int(env["GITHUB_RUN_ATTEMPT"]),
                "workflow_path": caller, "workflow_sha": env["GITHUB_WORKFLOW_SHA"],
                "event": env["GITHUB_EVENT_NAME"]}
    require(positive(producer["run_id"]) and positive(producer["run_attempt"]), "Invalid source producer attempt")
    asset = asset_identity(api.get("/repos/" + REPOSITORY + "/releases/tags/" + quote(tag, safe="")), source, tag)
    archive = archive_dir / asset["name"]
    digest = hashlib.sha256()
    with archive.open("rb") as source_file:
        for block in iter(lambda: source_file.read(1024 * 1024), b""):
            digest.update(block)
    require(archive.stat().st_size == asset["size"] and digest.hexdigest() == asset["sha256"],
            "Published source digest differs from the packaged archive")
    output = Path(env["RUNNER_TEMP"]) / "release-source-proof" / PROOF_FILE
    payload = json.dumps({"schema_version": 1, "repository": REPOSITORY, "release_tag": tag,
                          "source": source, "asset": asset, "producer": producer}, sort_keys=True) + "\n"
    require(len(payload.encode()) <= MAX_PROOF_BYTES, "Source proof exceeds artifact limits")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(payload)
    return {"created": True, "artifact_name": artifact_name(source, tag),
            "reason": "Published source digest matches the packaged archive"}


def execute(mode, env, archive_dir=None, api=None):
    try:
        source = identity(env)
        tag = env.get("RELEASE_TAG", "")
        artifact_name(source, tag)
        api = api or GitHub(env.get("GH_TOKEN", ""))
        if mode == "find":
            return find(source, tag, api, datetime.now(timezone.utc))
        require(mode == "record" and archive_dir is not None, "Invalid source proof operation")
        return record(source, tag, api, env, archive_dir)
    except (Rejected, OSError, ValueError, TypeError, KeyError, AttributeError, RuntimeError,
            subprocess.SubprocessError, zipfile.BadZipFile):
        # Never print HTTP bodies, credentials, signed artifact URLs or raw exceptions.
        if mode == "find":
            return {"reusable": False, "source_url": "", "reason": "Source proof unavailable; package exact sources"}
        return {"created": False, "artifact_name": "", "reason": "Source proof unavailable; published source remains the full path"}


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "find"
    result = execute(mode, os.environ, Path(sys.argv[2]) if len(sys.argv) > 2 else None)
    print(json.dumps(result, sort_keys=True))
    try:
        buffer = "".join(f"{key}={str(value).lower() if isinstance(value, bool) else value}\n"
                         for key, value in result.items())
        with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
            output.write(buffer)
    except (OSError, KeyError):
        print("Unable to write source proof outputs; use the full packaging path", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
