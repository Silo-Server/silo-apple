#!/usr/bin/env python3
"""Find a complete main regression proof without changing GitHub state.

Every uncertainty returns reusable=false so release.yml runs its full gate.
Expected inputs come from the release checkout and its selected Xcode toolchain.
An available proof remains eligible while all tested inputs still match.
"""

import io
import json
import os
from datetime import datetime, timezone
from pathlib import Path
import re
import sys
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
import zipfile


WORKFLOW = ".github/workflows/player-regression.yml"
SCHEMES = ("Silo", "SiloTV", "SiloMac")
MAX_API_BYTES = 8 * 1024 * 1024
MAX_ARCHIVE_BYTES = 256 * 1024
MAX_PROOF_BYTES = 16 * 1024


class ProofRejected(Exception):
    """A fixed, safe explanation suitable for the release log."""


def require(condition, reason):
    if not condition:
        raise ProofRejected(reason)


def positive_integer(value):
    return type(value) is int and value > 0


def parse_json(data):
    def unique_keys(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "Duplicate JSON fields")
            result[key] = value
        return result

    return json.loads(data, object_pairs_hook=unique_keys)


def timestamp(value):
    require(isinstance(value, str), "Missing proof timestamp")
    result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    require(result.tzinfo is not None, "Missing proof timezone")
    return result.astimezone(timezone.utc)


def read_config(env):
    config = {"token": env.get("GH_TOKEN", ""),
              "repository": env.get("GH_REPOSITORY", ""),
              "sha": env.get("TARGET_SHA", ""),
              "fingerprint": env.get("EXPECTED_FINGERPRINT", ""),
              "lock": env.get("EXPECTED_LOCK_SHA256", "")}
    require(bool(config["token"]), "GitHub token unavailable")
    require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", config["repository"])
            and all(part not in (".", "..") for part in config["repository"].split("/")),
            "Invalid expected repository")
    require(re.fullmatch(r"[0-9a-f]{40}", config["sha"]), "Invalid expected commit")
    require(re.fullmatch(r"[0-9a-f]{40}", config["fingerprint"]), "Invalid expected source tree")
    require(re.fullmatch(r"[0-9a-f]{64}", config["lock"]), "Invalid expected dependency digest")
    toolchains = parse_json(env.get("EXPECTED_TOOLCHAIN_JSON", "{}"))
    require(isinstance(toolchains, dict) and set(toolchains) == set(SCHEMES),
            "Incomplete expected toolchain")
    for scheme, toolchain in toolchains.items():
        expected_fields = {"xcode_version", "xcode_build", "sdk_version", "sdk_build", "architecture"}
        if scheme != "SiloMac":
            expected_fields |= {"runtime_version", "runtime_build"}
        require(isinstance(toolchain, dict)
                and set(toolchain) == expected_fields,
                "Incomplete expected toolchain")
        for name, value in toolchain.items():
            if name == "architecture":
                require(value in ("arm64", "x86_64"), "Invalid expected architecture")
                continue
            expression = r"[A-Za-z0-9]+" if name.endswith("_build") else r"[0-9]+(?:\.[0-9]+)*"
            require(isinstance(value, str) and re.fullmatch(expression, value),
                    "Invalid expected toolchain")
    config["toolchains"] = toolchains
    return config


class ArtifactRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        require(urlsplit(newurl).scheme == "https", "Unsafe artifact redirect")
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected is not None and urlsplit(newurl).netloc != urlsplit(req.full_url).netloc:
            # GitHub redirects archives to signed storage URLs. Never forward
            # the repository token to that storage service.
            redirected.remove_header("Authorization")
        return redirected


class GitHub:
    def __init__(self, token):
        self.token = token
        self.opener = build_opener(ArtifactRedirect())

    def get(self, path, binary=False):
        require(path.startswith("/repos/") and not path.startswith("//"), "Invalid GitHub API path")
        request = Request("https://api.github.com" + path, headers={
            "Authorization": "Bearer " + self.token,
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "silo-apple-regression-proof",
        })
        limit = MAX_ARCHIVE_BYTES if binary else MAX_API_BYTES
        with self.opener.open(request, timeout=10) as response:
            data = response.read(limit + 1)
        require(len(data) <= limit, "GitHub response exceeds proof limits")
        return data if binary else parse_json(data)


def collection(api, path, key, query=None):
    """Fetch complete bounded pages; missing pages cannot become proof."""
    result, expected_count = [], None
    for page in range(1, 11):
        params = dict(query or {}, per_page=100, page=page)
        response = api.get(path + "?" + urlencode(params))
        require(isinstance(response, dict) and isinstance(response.get(key), list),
                "Incomplete GitHub metadata")
        count = response.get("total_count")
        require(type(count) is int and 0 <= count <= 1000, "Incomplete GitHub metadata")
        if expected_count is None:
            expected_count = count
        require(count == expected_count, "GitHub metadata changed during lookup")
        values = response[key]
        require(all(isinstance(value, dict) and positive_integer(value.get("id"))
                    for value in values), "Incomplete GitHub metadata")
        result.extend(values)
        require(len({value["id"] for value in result}) == len(result),
                "Duplicate GitHub metadata")
        require(len(result) <= count, "Incomplete GitHub metadata")
        if len(result) == count:
            return result
        require(bool(values), "Incomplete GitHub pagination")
    raise ProofRejected("GitHub proof lookup exceeds page limit")


def validate_run(run, config, workflow_id, run_id=None):
    require(isinstance(run, dict) and positive_integer(run.get("id")), "Incomplete run metadata")
    require(run_id is None or run["id"] == run_id, "Regression run changed during lookup")
    require(run.get("workflow_id") == workflow_id and run.get("path") in (
        WORKFLOW, WORKFLOW + "@main", WORKFLOW + "@refs/heads/main"),
        "Regression workflow does not match")
    for key in ("repository", "head_repository"):
        repository = run.get(key)
        require(isinstance(repository, dict) and positive_integer(repository.get("id"))
                and isinstance(repository.get("full_name"), str)
                and repository["full_name"].lower() == config["repository"].lower(),
                "Regression repository does not match")
    require(run["repository"]["id"] == run["head_repository"]["id"],
            "Regression repository does not match")
    require(run.get("event") == "push" and run.get("head_branch") == "main",
            "Regression run is not a trusted main push")
    require(run.get("head_sha") == config["sha"], "Regression commit does not match")
    require(run.get("status") == "completed" and run.get("conclusion") == "success",
            "Latest regression run did not complete successfully")
    require(positive_integer(run.get("run_attempt")), "Missing regression attempt")


def validate_jobs(jobs, run, config, now):
    matched = {}
    for scheme in SCHEMES:
        candidates = [job for job in jobs if job.get("name") == f"Regression ({scheme})"]
        require(len(candidates) == 1, "Missing or duplicate regression platform")
        job = candidates[0]
        require(job.get("run_id") == run["id"] and job.get("head_sha") == config["sha"],
                "Regression job provenance does not match")
        require(job.get("status") == "completed" and job.get("conclusion") == "success",
                "Regression platform did not complete successfully")
        started, completed = timestamp(job.get("started_at")), timestamp(job.get("completed_at"))
        require(started <= completed <= now, "Invalid regression completion timestamp")
        steps = job.get("steps")
        require(isinstance(steps, list) and all(isinstance(step, dict) for step in steps),
                "Missing regression steps")
        names = ["Build player", "Record regression proof", "Upload regression proof"]
        if scheme != "SiloMac":
            names.append("Run complete simulator suite")
        for name in names:
            required = [step for step in steps if step.get("name") == name]
            require(len(required) == 1 and required[0].get("status") == "completed"
                    and required[0].get("conclusion") == "success",
                    "Required regression work did not complete successfully")
        matched[scheme] = job
    require(not any(job.get("name", "").startswith("Regression (")
                    and job.get("name") not in {f"Regression ({scheme})" for scheme in SCHEMES}
                    for job in jobs), "Unexpected regression platform")
    return matched


def read_proof(archive):
    require(isinstance(archive, bytes) and len(archive) <= MAX_ARCHIVE_BYTES,
            "Invalid regression proof artifact")
    with zipfile.ZipFile(io.BytesIO(archive)) as zipped:
        entries = zipped.infolist()
        require(len(entries) == 1 and entries[0].filename == "regression-proof.json"
                and 0 < entries[0].file_size <= MAX_PROOF_BYTES
                and not entries[0].flag_bits & 1, "Invalid regression proof artifact")
        return parse_json(zipped.read(entries[0]))


def validate_proof(proof, scheme, run, config):
    require(isinstance(proof, dict), "Invalid regression proof metadata")
    expected = {"schema_version": 1, "repository": config["repository"],
                "workflow_path": WORKFLOW, "event": "push", "branch": "main",
                "sha": config["sha"], "run_id": run["id"], "run_attempt": run["run_attempt"],
                "scheme": scheme, "fingerprint": config["fingerprint"],
                "dependency_lock_sha256": config["lock"], "frozen_dependencies": True,
                "full_suite": True, "toolchain": config["toolchains"][scheme]}
    require(all(type(proof.get(key)) is type(value) and proof.get(key) == value
                for key, value in expected.items()), "Regression proof does not match current inputs")


def find_proof(config, api, now):
    root = "/repos/" + config["repository"] + "/actions"
    workflow = api.get(root + "/workflows/player-regression.yml")
    require(isinstance(workflow, dict) and positive_integer(workflow.get("id"))
            and workflow.get("path") == WORKFLOW, "Regression workflow does not match")
    runs = collection(api, root + "/workflows/player-regression.yml/runs", "workflow_runs",
                      {"event": "push", "branch": "main", "head_sha": config["sha"]})
    require(bool(runs), "No main regression proof exists for this commit")
    # A newer failing or active run invalidates reuse of an older success.
    run_id = max(run["id"] for run in runs)
    run = api.get(root + f"/runs/{run_id}")
    validate_run(run, config, workflow["id"], run_id)
    jobs = collection(api, root + f"/runs/{run_id}/attempts/{run['run_attempt']}/jobs", "jobs")
    matched = validate_jobs(jobs, run, config, now)
    artifacts = collection(api, root + f"/runs/{run_id}/artifacts", "artifacts")
    for scheme, job in matched.items():
        candidates = [artifact for artifact in artifacts
                      if artifact.get("name") == f"apple-regression-proof-{scheme}-{run['run_attempt']}"]
        require(len(candidates) == 1, "Missing or duplicate regression proof artifact")
        artifact = candidates[0]
        require(artifact.get("expired") is False
                and type(artifact.get("size_in_bytes")) is int
                and 0 < artifact["size_in_bytes"] <= MAX_ARCHIVE_BYTES,
                "Regression proof artifact is unavailable")
        provenance = artifact.get("workflow_run")
        require(isinstance(provenance, dict) and provenance.get("id") == run_id
                and provenance.get("repository_id") == run["repository"]["id"]
                and provenance.get("head_repository_id") == run["repository"]["id"]
                and provenance.get("head_sha") == config["sha"]
                and provenance.get("head_branch") == "main", "Artifact provenance does not match")
        require(timestamp(job["started_at"]) <= timestamp(artifact.get("created_at")) <= now
                and timestamp(artifact.get("expires_at")) > now, "Regression proof artifact is unavailable")
        proof = read_proof(api.get(root + f"/artifacts/{artifact['id']}/zip", binary=True))
        validate_proof(proof, scheme, run, config)
    latest = api.get(root + f"/runs/{run_id}")
    validate_run(latest, config, workflow["id"], run_id)
    require(latest["run_attempt"] == run["run_attempt"], "Regression attempt changed during lookup")
    return {"reusable": True, "reason": "Complete main regression proof matches current inputs",
            "run_id": run_id,
            "run_url": f"https://github.com/{config['repository']}/actions/runs/{run_id}"}


def lookup(env, api=None, now=None):
    try:
        config = read_config(env)
        return find_proof(config, api or GitHub(config["token"]), now or datetime.now(timezone.utc))
    except ProofRejected as error:
        reason = str(error)
    except (OSError, ValueError, TypeError, KeyError, AttributeError, zipfile.BadZipFile,
            RuntimeError):
        # Do not print HTTP bodies, signed download URLs, tokens or raw errors.
        reason = "Regression proof lookup unavailable; run the full gate"
    return {"reusable": False, "reason": reason, "run_id": "", "run_url": ""}


def main():
    result = lookup(os.environ)
    print(json.dumps(result, sort_keys=True))
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        try:
            with Path(output).open("a") as target:
                for key, value in result.items():
                    target.write(f"{key}={str(value).lower() if isinstance(value, bool) else value}\n")
        except OSError:
            # Missing output is also treated as false by the release gate.
            print("Unable to write proof outputs; run the full gate", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
