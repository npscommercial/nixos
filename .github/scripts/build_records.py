"""Pure validation and selection of exact build evidence."""
import json
import re
from pathlib import Path

STORE_RE = re.compile(r"^/nix/store/[0123456789abcdfghijklmnpqrsvwxyz]{32}-[A-Za-z0-9+._?=-]+$")
HOST_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]*$")
SUPPORTED_SYSTEMS = ("x86_64-linux", "aarch64-linux")
SHA_RE = re.compile(r"^[0-9a-f]{40}(?:[0-9a-f]{24})?$")


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
        bool(expected_hosts)
        and all(isinstance(host, str) and HOST_RE.fullmatch(host) for host in expected_hosts)
        and len(set(expected_hosts)) == len(expected_hosts),
        "host inventory must contain unique valid names",
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

    require(isinstance(targets, dict), "deploy.targets must be an object")
    require(set(targets) <= set(expected_hosts), "deploy.targets contains a host outside the flake inventory")
    captured_targets = {}
    for host in sorted(targets):
        target = targets[host]
        require(isinstance(target, dict), f"deploy target {host} must be an object")
        require(target.get("system") in SUPPORTED_SYSTEMS, f"deploy target {host} has the wrong system")
        target_store = store_path(target.get("storePath"), f"deploy target store path for {host}")
        require(target_store == built[host], f"deploy target {host} does not match the NFB output")
        rollback = store_path(target.get("rollbackScript"), f"rollback script for {host}")
        require(target.get("deployPin") == f"deployed-host-{host}", f"deploy pin is malformed for {host}")
        captured_targets[host] = {
            "system": target["system"],
            "storePath": target_store,
            "rollbackScript": rollback,
            "deployPin": target["deployPin"],
        }

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
    require(isinstance(hosts, dict) and hosts, "build record must contain hosts")
    for host, path in hosts.items():
        require(isinstance(host, str) and HOST_RE.fullmatch(host), "build record host name is malformed")
        store_path(path, f"build record path for {host}")
    targets = record.get("targets")
    require(isinstance(targets, dict), "build record targets must be an object")
    require(set(targets) <= set(hosts), "build record target is outside the host inventory")
    for host, target in targets.items():
        require(isinstance(target, dict), f"build record target is malformed for {host}")
        require(target.get("system") in SUPPORTED_SYSTEMS, f"build record system is malformed for {host}")
        require(target.get("storePath") == hosts[host], f"build record target path does not match for {host}")
        store_path(target.get("rollbackScript"), f"build record rollback script for {host}")
        require(target.get("deployPin") == f"deployed-host-{host}", f"build record pin is malformed for {host}")
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

    selected = []
    skipped = {}
    for host in names:
        target = {**targets[host], "host": host}
        if not force and pins.get(target["deployPin"]) == target["storePath"]:
            skipped[host] = "unchanged"
        else:
            selected.append(target)
    return selected, skipped
