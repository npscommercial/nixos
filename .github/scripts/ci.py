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
STORE_RE = re.compile(r"^/nix/store/[0123456789abcdfghijklmnpqrsvwxyz]{32}-[A-Za-z0-9+._?=-]+$")
SHA_RE = re.compile(r"^[0-9a-f]{40}(?:[0-9a-f]{24})?$")


class ApiError(RuntimeError):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


def require(condition, message):
    if not condition:
        raise ValueError(message)


def store_path(value, field):
    require(isinstance(value, str) and STORE_RE.fullmatch(value), f"invalid {field}")
    return value


def read_json(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read valid JSON from {path}") from error


def build_record(nfb, expected_hosts, targets, revision):
    require(isinstance(expected_hosts, list), "host inventory must be an array")
    require(
        len(expected_hosts) == 6
        and all(isinstance(host, str) and host for host in expected_hosts)
        and len(set(expected_hosts)) == len(expected_hosts),
        "host inventory must contain six unique names",
    )
    expected_hosts = sorted(expected_hosts)
    require(isinstance(revision, str) and SHA_RE.fullmatch(revision), "source revision must be a Git SHA")
    require(isinstance(nfb, dict) and isinstance(nfb.get("results"), list), "NFB result must contain a results array")

    records = nfb["results"]
    require(records, "NFB result is empty")
    built = {}
    evaluated = {}
    seen = set()
    for result in records:
        require(isinstance(result, dict), "NFB result record must be an object")
        kind = result.get("type")
        attr = result.get("attr")
        require(kind in {"EVAL", "BUILD"}, f"unexpected NFB result type: {kind}")
        require(isinstance(attr, str) and attr, "NFB result attr must be a non-empty string")
        require((kind, attr) not in seen, f"duplicate NFB {kind} result for {attr}")
        seen.add((kind, attr))
        require(isinstance(result.get("success"), bool), f"NFB success is malformed for {attr}")
        require(
            isinstance(result.get("duration"), (int, float))
            and not isinstance(result.get("duration"), bool),
            f"NFB duration is malformed for {attr}",
        )
        if not result["success"]:
            raise ValueError(f"NFB {kind.lower()} failed for {attr}")
        require(result.get("error") is None, f"successful NFB result has an error for {attr}")
        outputs = result.get("outputs")
        require(isinstance(outputs, dict), f"NFB outputs are missing for {attr}")
        output = store_path(outputs.get("out"), f"NFB output for {attr}")
        (evaluated if kind == "EVAL" else built)[attr] = output

    require(sorted(evaluated) == expected_hosts, "NFB evaluation hosts do not match the flake inventory")
    require(sorted(built) == expected_hosts, "NFB build hosts do not match the flake inventory")
    require(evaluated == built, "NFB evaluation and build outputs do not match")

    require(isinstance(targets, dict) and len(targets) == 4, "deploy.targets must contain four hosts")
    require(set(targets) <= set(expected_hosts), "deploy.targets contains a host outside the flake inventory")
    captured_targets = {}
    deferred = set()
    for host in sorted(targets):
        target = targets[host]
        require(isinstance(target, dict), f"deploy target {host} must be an object")
        require(target.get("system") == "x86_64-linux", f"deploy target {host} has the wrong system")
        target_store = store_path(target.get("storePath"), f"deploy target store path for {host}")
        require(target_store == built[host], f"deploy target {host} does not match the NFB output")
        rollback = store_path(target.get("rollbackScript"), f"rollback script for {host}")
        require(target.get("deployPin") == f"deployed-host-{host}", f"deploy pin is malformed for {host}")
        is_deferred = target.get("deferred", False)
        require(isinstance(is_deferred, bool), f"deferred flag is malformed for {host}")
        if is_deferred:
            deferred.add(host)
        captured_targets[host] = {
            "system": "x86_64-linux",
            "storePath": target_store,
            "rollbackScript": rollback,
            "deployPin": target["deployPin"],
            "deferred": is_deferred,
        }
    require(deferred == {"NPSB1"}, "NPSB1 must be the only deferred deployment target")

    record = {
        "schemaVersion": 1,
        "sourceRevision": revision,
        "hosts": {host: built[host] for host in expected_hosts},
        "targets": captured_targets,
    }
    validate_record(record)
    return record


def validate_record(record):
    require(isinstance(record, dict) and record.get("schemaVersion") == 1, "unsupported build record schema")
    revision = record.get("sourceRevision")
    require(isinstance(revision, str) and SHA_RE.fullmatch(revision), "build record source revision is malformed")
    hosts = record.get("hosts")
    require(isinstance(hosts, dict) and len(hosts) == 6, "build record must contain six hosts")
    for host, path in hosts.items():
        require(isinstance(host, str) and host, "build record host name is malformed")
        store_path(path, f"build record path for {host}")
    targets = record.get("targets")
    require(isinstance(targets, dict) and len(targets) == 4, "build record must contain four targets")
    require(set(targets) <= set(hosts), "build record target is outside the host inventory")
    deferred = set()
    for host, target in targets.items():
        require(isinstance(target, dict), f"build record target is malformed for {host}")
        require(target.get("system") == "x86_64-linux", f"build record system is malformed for {host}")
        require(target.get("storePath") == hosts[host], f"build record target path does not match for {host}")
        store_path(target.get("rollbackScript"), f"build record rollback script for {host}")
        require(target.get("deployPin") == f"deployed-host-{host}", f"build record pin is malformed for {host}")
        require(isinstance(target.get("deferred"), bool), f"build record deferred flag is malformed for {host}")
        if target["deferred"]:
            deferred.add(host)
    require(deferred == {"NPSB1"}, "NPSB1 must be the only deferred deployment target")
    return record


def select_targets(record, requested, force, pins):
    require(isinstance(force, bool), "force must be a boolean")
    targets = record.get("targets")
    require(isinstance(targets, dict), "build record targets are missing")
    if requested == "all":
        names = sorted(targets)
    else:
        names = [name.strip() for name in requested.split(",") if name.strip()]
        require(names and len(names) == len(set(names)), "selected hosts must be unique and non-empty")
        unknown = sorted(set(names) - set(targets))
        require(not unknown, f"unknown deployment host: {', '.join(unknown)}")
        names.sort()

    selected = []
    skipped = {}
    for host in names:
        target = {"host": host, **targets[host]}
        if target["deferred"]:
            skipped[host] = "deferred"
        elif not force and pins.get(target["deployPin"]) == target["storePath"]:
            skipped[host] = "unchanged"
        else:
            selected.append(target)
    return selected, skipped


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
        os.environ.get("GITHUB_SHA") == record["sourceRevision"],
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
            timeout=300,
        )
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(
            f"activation outcome is unknown after the deadline for {target['host']}; deployed pin unchanged"
        ) from error
    if result.returncode:
        raise RuntimeError(f"activation failed for {target['host']}; deployed pin unchanged")


def deploy_record(record, requested, force, tools, directory, default_branch, ref_name):
    validate_record(record)
    revision = record.get("sourceRevision")
    require(os.environ.get("GITHUB_SHA") == revision, "build record does not match the workflow revision")
    require(ref_name == default_branch, "deployment is restricted to the default branch")
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
    deployed = []
    for target in selected:
        host = target["host"]
        if not agent_online(status_token, host):
            print(f"Skipping {host}: agent offline on two probes; deployed pin unchanged")
            print(f"{host} will be reconsidered on the next deployment run")
            continue
        verify_remote_paths(target)
        if not agent_online(status_token, host):
            print(f"Skipping {host}: agent offline before submission; deployed pin unchanged")
            print(f"{host} will be reconsidered on the next deployment run")
            continue
        current = github_current_revision(github_token, repository, default_branch)
        if current != revision:
            print(f"Skipping stale deployment: built={revision} current={current}")
            break
        activate(tools, activate_token, target, directory)
        pin_store_path(cache_token, target["deployPin"], target["storePath"], 2)
        deployed.append(host)
        print(f"Activated {host} successfully and advanced {target['deployPin']}")
    return deployed


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
    pins = fetch_pins(token)
    for host, path in record["hosts"].items():
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
        args.ref_name,
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
    pins.set_defaults(run=command_pin_builds)

    status = commands.add_parser("status")
    status.add_argument("--record", required=True)
    status.set_defaults(run=command_status)

    deploy = commands.add_parser("deploy")
    deploy.add_argument("--record", required=True)
    deploy.add_argument("--hosts", required=True)
    deploy.add_argument("--force", choices=("true", "false"), required=True)
    deploy.add_argument("--tools", required=True)
    deploy.add_argument("--directory", required=True)
    deploy.add_argument("--default-branch", required=True)
    deploy.add_argument("--ref-name", required=True)
    deploy.set_defaults(run=command_deploy)

    args = parser.parse_args()
    try:
        args.run(args)
    except (ApiError, OSError, RuntimeError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
