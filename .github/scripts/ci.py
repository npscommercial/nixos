#!/usr/bin/env python3
"""Validate NFB output and deploy the exact validated revision."""

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path


CACHE = "npscommercial"
CACHIX_API = "https://app.cachix.org/api/v1"
from build_records import (
    SHA_RE, build_record, read_json, require, select_targets, store_path, validate_record,
)


class ApiError(RuntimeError):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


def agent_is_online(payload, expected_name, now=None):
    required = {"id": str, "name": str, "version": str, "lastSeen": str}
    require(isinstance(payload, dict), f"malformed agent response for {expected_name}")
    require(
        all(isinstance(payload.get(field), kind) and payload[field] for field, kind in required.items()),
        f"malformed agent response for {expected_name}",
    )
    require(payload["name"] == expected_name, f"agent response name does not match {expected_name}")
    try:
        seen = datetime.fromisoformat(payload["lastSeen"].replace("Z", "+00:00"))
    except ValueError as error:
        raise ValueError(f"malformed lastSeen for {expected_name}") from error
    require(seen.tzinfo is not None, f"malformed lastSeen for {expected_name}")
    now = now or datetime.now(timezone.utc)
    age = (now - seen.astimezone(timezone.utc)).total_seconds()
    require(age >= -5, f"agent lastSeen is in the future for {expected_name}")
    return age < 20


def api_json(url, token, method="GET", payload=None):
    data = None if payload is None else json.dumps(payload, separators=(",", ":")).encode()
    request = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "Accept": "application/json",
            "Authorization": f"Bearer {token}",
            "User-Agent": "nps-ci",
            **({"Content-Type": "application/json"} if data is not None else {}),
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            body = response.read(1_048_577)
    except urllib.error.HTTPError as error:
        raise ApiError(error.code, f"API returned HTTP {error.code}") from None
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        raise ApiError(None, "API transport failed") from error
    if len(body) > 1_048_576:
        raise ApiError(None, "API response is too large")
    if not body:
        return None
    try:
        return json.loads(body)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ApiError(None, "API returned malformed JSON") from error


def retry_json(url, token, method="GET", payload=None):
    for attempt in range(3):
        try:
            return api_json(url, token, method, payload)
        except ApiError as error:
            if error.status not in {None, 429} and not (error.status and error.status >= 500):
                raise
            if attempt == 2:
                raise
            time.sleep(2 * (attempt + 1))
    raise AssertionError("unreachable")


def fetch_pins(token):
    payload = retry_json(f"{CACHIX_API}/cache/{CACHE}/pin", token)
    require(isinstance(payload, list), "Cachix pin API did not return an array")
    pins = {}
    for pin in payload:
        require(isinstance(pin, dict) and isinstance(pin.get("name"), str), "Cachix pin response is malformed")
        revision = pin.get("lastRevision")
        if revision is None:
            continue
        require(isinstance(revision, dict), f"Cachix pin revision is malformed for {pin['name']}")
        path = store_path(revision.get("storePath"), f"Cachix pin path for {pin['name']}")
        require(pin["name"] not in pins, f"duplicate Cachix pin: {pin['name']}")
        pins[pin["name"]] = path
    return pins


def pin_store_path(token, name, path, keep):
    store_path(path, f"pin path for {name}")
    require(isinstance(keep, int) and keep > 0, "pin revision count must be positive")
    payload = {
        "name": name,
        "storePath": path,
        "artifacts": [],
        "keep": {"tag": "Revisions", "contents": keep},
    }
    try:
        api_json(f"{CACHIX_API}/cache/{CACHE}/pin", token, "POST", payload)
    except ApiError as error:
        if error.status not in {None, 429} and not (error.status and error.status >= 500):
            raise
        if fetch_pins(token).get(name) != path:
            raise ApiError(error.status, f"Cachix pin write was not reconciled for {name}") from None


def agent_status(token, host, allow_unregistered=False):
    url = f"{CACHIX_API}/deploy/agent/{CACHE}/{urllib.parse.quote(host, safe='')}"
    for observation in range(2):
        try:
            payload = retry_json(url, token)
        except ApiError as error:
            if error.status in {401, 403}:
                raise ValueError(f"Cachix status token is unauthorised for agent status (HTTP {error.status})") from None
            if error.status in {400, 404}:
                try:
                    workspace = retry_json(f"{CACHIX_API}/deploy/workspace/settings/{CACHE}", token)
                except ApiError:
                    raise ValueError("Cachix Deploy workspace status is unavailable") from None
                require(isinstance(workspace, dict), "Cachix Deploy workspace response is malformed")
                if allow_unregistered:
                    return "unregistered"
                raise ValueError(f"Cachix agent is not registered correctly: {host}") from None
            raise ValueError(f"Cachix agent status is unavailable for {host}") from None
        if agent_is_online(payload, host):
            return "online"
        if observation == 0:
            time.sleep(5)
    return "offline"


def agent_online(token, host):
    return agent_status(token, host) == "online"


def status_record(record):
    validate_record(record)
    require(
        os.environ.get("SOURCE_REVISION", os.environ.get("GITHUB_SHA")) == record["sourceRevision"],
        "build record does not match the workflow revision",
    )
    token = os.environ.get("CACHIX_STATUS_TOKEN", "")
    require(token, "CACHIX_STATUS_TOKEN is empty")

    statuses = {}
    valid_agent_response = False
    for host, target in sorted(record["targets"].items()):
        if target["deferred"]:
            statuses[host] = "deferred"
            print(f"{host}: deferred (unbootstrapped); agent not queried")
            continue
        status = agent_status(token, host, allow_unregistered=True)
        statuses[host] = status
        if status == "unregistered":
            print(f"{host}: unregistered; workspace authenticated, agent permission/schema unproven")
        else:
            valid_agent_response = True
            print(f"{host}: {status}")

    if valid_agent_response:
        print("Cachix agent status permission/schema confirmed by a valid agent response")
    else:
        print("Cachix agent status permission/schema remains unproven until a valid agent response")
    return statuses


def github_current_revision(token, repository, branch):
    url = (
        f"https://api.github.com/repos/{repository}/git/ref/heads/"
        f"{urllib.parse.quote(branch, safe='')}"
    )
    payload = retry_json(url, token)
    try:
        revision = payload["object"]["sha"]
    except (KeyError, TypeError) as error:
        raise ValueError("GitHub branch response is malformed") from error
    require(isinstance(revision, str) and SHA_RE.fullmatch(revision), "GitHub branch revision is malformed")
    return revision


def verify_remote_paths(target):
    result = subprocess.run(
        [
            "nix",
            "path-info",
            "--store",
            f"https://{CACHE}.cachix.org",
            target["storePath"],
            target["rollbackScript"],
        ],
        timeout=90,
    )
    if result.returncode:
        raise RuntimeError(f"Cachix does not have the system and rollback paths for {target['host']}")


def activate(tools, token, target, directory):
    specification = {
        "agents": {target["host"]: target["storePath"]},
        "rollbackScript": {target["system"]: target["rollbackScript"]},
    }
    path = directory / f"deploy-{target['host']}.json"
    path.write_text(json.dumps(specification, indent=2, sort_keys=True) + "\n")
    environment = os.environ | {"CACHIX_ACTIVATE_TOKEN": token}
    environment.pop("CACHIX_STATUS_TOKEN", None)
    try:
        result = subprocess.run(
            [str(Path(tools) / "bin/cachix"), "deploy", "activate", str(path)],
            env=environment,
            timeout=2400,
        )
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(
            f"activation outcome is unknown after the deadline for {target['host']}; deployed pin unchanged"
        ) from error
    if result.returncode:
        raise RuntimeError(f"activation did not confirm success for {target['host']}; outcome requires reconciliation; deployed pin unchanged")


def deployment_api(path, method="GET", payload=None):
    token = os.environ.get("GITHUB_TOKEN", "")
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    require(token and re.fullmatch(r"[^/]+/[^/]+", repository), "GitHub deployment credentials are missing")
    # Never repeat a POST whose response was lost.
    call = retry_json if method == "GET" else api_json
    return call(f"https://api.github.com/repos/{repository}/deployments{path}", token, method, payload)


def ensure_no_pending_deployment(host):
    environment = urllib.parse.quote(f"nixos/{host}", safe="")
    deployments = deployment_api(f"?environment={environment}&per_page=1")
    require(isinstance(deployments, list), "GitHub deployment list is malformed")
    if not deployments:
        return
    deployment = deployments[0]
    require(isinstance(deployment, dict) and type(deployment.get("id")) is int, "GitHub deployment is malformed")
    statuses = deployment_api(f"/{deployment['id']}/statuses?per_page=1")
    require(isinstance(statuses, list), "GitHub deployment statuses are malformed")
    state = statuses[0].get("state") if statuses and isinstance(statuses[0], dict) else None
    require(state in {"success", "failure", "error", "inactive"},
            f"unresolved deployment for {host}: inspect the previous activation and reconcile its GitHub deployment status before resubmitting")


def start_deployment(record, host):
    result = deployment_api("", "POST", {
        "ref": record["sourceRevision"], "environment": f"nixos/{host}",
        "auto_merge": False, "required_contexts": [],
        "description": f"Activate validated NixOS closure on {host}",
    })
    require(isinstance(result, dict) and type(result.get("id")) is int, "GitHub deployment creation is ambiguous")
    finish_deployment(result["id"], "in_progress")
    return result["id"]


def finish_deployment(deployment_id, state):
    deployment_api(f"/{deployment_id}/statuses", "POST", {
        "state": state, "auto_inactive": False,
        "log_url": f"https://github.com/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ.get('GITHUB_RUN_ID', '')}",
    })


def deploy_record(record, requested, force, tools, directory, default_branch, ref, mode="automatic"):
    require("," not in requested and requested != "all", "executor requires exactly one host")
    validate_record(record)
    revision = record.get("sourceRevision")
    require(os.environ.get("SOURCE_REVISION", os.environ.get("GITHUB_SHA")) == revision, "build record does not match the workflow revision")
    require(ref == f"refs/heads/{default_branch}", "deployment controller must run from the default branch")
    cache_token = os.environ.get("CACHIX_AUTH_TOKEN", "")
    activate_token = os.environ.get("CACHIX_ACTIVATE_TOKEN", "")
    status_token = os.environ.get("CACHIX_STATUS_TOKEN", "")
    github_token = os.environ.get("GITHUB_TOKEN", "")
    require(cache_token, "CACHIX_AUTH_TOKEN is empty")
    require(activate_token, "CACHIX_ACTIVATE_TOKEN is empty")
    require(status_token, "CACHIX_STATUS_TOKEN is empty")
    require(github_token, "GITHUB_TOKEN is empty")
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    require(re.fullmatch(r"[^/]+/[^/]+", repository or ""), "GITHUB_REPOSITORY is malformed")

    pins = fetch_pins(cache_token)
    selected, skipped = select_targets(record, requested, force, pins)
    for host, reason in skipped.items():
        detail = "unbootstrapped" if reason == "deferred" else reason
        print(f"Skipping {host}: {detail}; deployed pin unchanged")

    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    if not selected:
        return []
    target = selected[0]
    host = target["host"]
    ensure_no_pending_deployment(host)
    if not agent_online(status_token, host):
        print(f"Skipping {host}: agent offline on two probes; deployed pin unchanged")
        print(f"{host} will be reconsidered on the next deployment run")
        return []
    verify_remote_paths(target)
    if not agent_online(status_token, host):
        print(f"Skipping {host}: agent offline before submission; deployed pin unchanged")
        print(f"{host} will be reconsidered on the next deployment run")
        return []
    if not revision_allowed(record, mode, default_branch):
        return []
    # Re-read under the per-host workflow lock immediately before activation.
    if not force and fetch_pins(cache_token).get(target["deployPin"]) == target["storePath"]:
        print(f"Skipping {host}: unchanged before submission")
        return []
    operation = start_deployment(record, host)
    # Any interruption from here leaves the operation pending. A subsequent
    # job must reconcile it, not blindly repeat an uncertain activation.
    activate(tools, activate_token, target, directory)
    pin_store_path(cache_token, target["deployPin"], target["storePath"], 2)
    finish_deployment(operation, "success")
    print(f"Activated {host} successfully and advanced {target['deployPin']}")
    return [host]


def revision_allowed(record, mode, default_branch):
    require(mode in {"automatic", "manual"}, "unknown deployment mode")
    if mode == "manual":
        return True
    token = os.environ.get("GITHUB_TOKEN", "")
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    require(token and re.fullmatch(r"[^/]+/[^/]+", repository), "GitHub freshness credentials are missing")
    current = github_current_revision(token, repository, default_branch)
    if current != record["sourceRevision"]:
        print(f"Skipping stale revision: built={record['sourceRevision']} current={current}", file=sys.stderr)
        return False
    return True


def command_plan(args):
    record = validate_record(read_json(args.record))
    require(record["sourceRevision"] == args.revision, "build record does not match validated revision")
    token = os.environ.get("CACHIX_AUTH_TOKEN", "")
    require(token, "CACHIX_AUTH_TOKEN is empty")
    selected, skipped = select_targets(record, args.hosts, args.force == "true", fetch_pins(token))
    if not revision_allowed(record, args.mode, args.default_branch):
        selected = []
    for host, reason in skipped.items():
        print(f"Skipping {host}: {reason}", file=sys.stderr)
    matrix = {"include": [{"host": target["host"]} for target in selected]}
    Path(args.output).write_text(json.dumps(matrix) + "\n")
    print(json.dumps(matrix))


def command_capture(args):
    record = build_record(
        read_json(args.nfb),
        read_json(args.hosts),
        read_json(args.targets),
        args.revision,
    )
    Path(args.output).write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")


def command_pin_builds(args):
    record = validate_record(read_json(args.record))
    token = os.environ.get("CACHIX_AUTH_TOKEN", "")
    require(token, "CACHIX_AUTH_TOKEN is empty")
    require(record["sourceRevision"] == os.environ.get("SOURCE_REVISION", os.environ.get("GITHUB_SHA")), "build record revision mismatch")
    pins = fetch_pins(token)
    for host, path in record["hosts"].items():
        if not revision_allowed(record, "automatic", args.default_branch):
            return
        name = f"built-host-{host}"
        if pins.get(name) == path:
            print(f"Build pin already current: {name}")
            continue
        pin_store_path(token, name, path, 3)
        print(f"Pinned build closure: {name} -> {path}")


def command_status(args):
    status_record(read_json(args.record))


def command_deploy(args):
    force = args.force == "true"
    tools = store_path(args.tools, "CI tools path")
    require(os.access(Path(tools) / "bin/cachix", os.X_OK), "CI tools closure has no cachix executable")
    runner_temp = Path(os.environ.get("RUNNER_TEMP", "")).resolve()
    directory = Path(args.directory)
    require(
        os.environ.get("RUNNER_TEMP")
        and not directory.is_symlink()
        and directory.parent.resolve() == runner_temp,
        "deployment directory must be an exact child of RUNNER_TEMP",
    )
    deploy_record(
        read_json(args.record),
        args.hosts,
        force,
        tools,
        directory,
        args.default_branch,
        args.ref,
        args.mode,
    )


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(required=True)

    capture = commands.add_parser("capture")
    capture.add_argument("--nfb", required=True)
    capture.add_argument("--hosts", required=True)
    capture.add_argument("--targets", required=True)
    capture.add_argument("--revision", required=True)
    capture.add_argument("--output", required=True)
    capture.set_defaults(run=command_capture)

    pins = commands.add_parser("pin-builds")
    pins.add_argument("--record", required=True)
    pins.add_argument("--default-branch", required=True)
    pins.set_defaults(run=command_pin_builds)

    plan = commands.add_parser("plan")
    plan.add_argument("--record", required=True)
    plan.add_argument("--revision", required=True)
    plan.add_argument("--hosts", default="all")
    plan.add_argument("--force", choices=("true", "false"), default="false")
    plan.add_argument("--mode", choices=("automatic", "manual"), required=True)
    plan.add_argument("--default-branch", required=True)
    plan.add_argument("--output", required=True)
    plan.set_defaults(run=command_plan)

    status = commands.add_parser("status")
    status.add_argument("--record", required=True)
    status.set_defaults(run=command_status)

    deploy = commands.add_parser("deploy")
    deploy.add_argument("--mode", choices=("automatic", "manual"), required=True)
    deploy.add_argument("--record", required=True)
    deploy.add_argument("--hosts", required=True)
    deploy.add_argument("--force", choices=("true", "false"), required=True)
    deploy.add_argument("--tools", required=True)
    deploy.add_argument("--directory", required=True)
    deploy.add_argument("--default-branch", required=True)
    deploy.add_argument("--ref", required=True)
    deploy.set_defaults(run=command_deploy)

    args = parser.parse_args()
    try:
        args.run(args)
    except (ApiError, OSError, RuntimeError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
