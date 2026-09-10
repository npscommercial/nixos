#!/usr/bin/env python3
"""One focused local probe for the CI metadata, deployment and seed boundaries."""

import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("nps_ci", ROOT / ".github/scripts/ci.py")
CI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CI)

HOSTS = ["LS1", "NPS03", "NPS04", "NPSB1", "NPSB2", "oberon"]
PATHS = {
    host: f"/nix/store/{str(index).zfill(32)}-nixos-system-{host}"
    for index, host in enumerate(HOSTS, 1)
}
TARGETS = {
    host: {
        "system": "x86_64-linux",
        "storePath": PATHS[host],
        "rollbackScript": f"/nix/store/{str(index + 10).zfill(32)}-rollback-{host}",
        "deployPin": f"deployed-host-{host}",
        **({"deferred": True} if host == "NPSB1" else {}),
    }
    for index, host in enumerate(("LS1", "NPSB1", "NPSB2", "oberon"), 1)
}


def expect_error(call, text):
    try:
        call()
    except ValueError as error:
        assert text in str(error), error
    else:
        raise AssertionError(f"expected ValueError containing {text!r}")


def main():
    results = {
        "results": [
            result
            for index, host in enumerate(HOSTS, 1)
            for result in (
                {
                    "type": "EVAL",
                    "attr": host,
                    "success": True,
                    "duration": 0.1,
                    "error": None,
                    "outputs": {"out": PATHS[host]},
                    "drvPath": f"/nix/store/{str(index + 20).zfill(32)}-{host}.drv",
                    "cacheStatus": "notBuilt",
                },
                {
                    "type": "BUILD",
                    "attr": host,
                    "success": True,
                    "duration": 1.0,
                    "error": None,
                    "outputs": {"out": PATHS[host]},
                },
            )
        ]
    }
    record = CI.build_record(results, HOSTS, TARGETS, "a" * 40)
    assert record["sourceRevision"] == "a" * 40
    assert list(record["hosts"]) == HOSTS
    assert record["targets"]["NPSB1"]["deferred"] is True

    broken = json.loads(json.dumps(results))
    broken["results"][0]["success"] = False
    expect_error(lambda: CI.build_record(broken, HOSTS, TARGETS, "a" * 40), "failed")

    broken_targets = json.loads(json.dumps(TARGETS))
    broken_targets["LS1"]["storePath"] = PATHS["oberon"]
    expect_error(
        lambda: CI.build_record(results, HOSTS, broken_targets, "a" * 40),
        "does not match",
    )

    pins = {"deployed-host-LS1": PATHS["LS1"]}
    selected, skipped = CI.select_targets(record, "all", False, pins)
    assert [target["host"] for target in selected] == ["NPSB2", "oberon"]
    assert skipped == {"LS1": "unchanged", "NPSB1": "deferred"}
    forced, _ = CI.select_targets(record, "LS1", True, pins)
    assert [target["host"] for target in forced] == ["LS1"]
    expect_error(lambda: CI.select_targets(record, "NPS03", True, pins), "unknown")

    now = datetime.now(timezone.utc)
    assert CI.agent_is_online(
        {"id": "1", "name": "LS1", "version": "1", "lastSeen": now.isoformat()},
        "LS1",
        now,
    )
    assert not CI.agent_is_online(
        {
            "id": "1",
            "name": "LS1",
            "version": "1",
            "lastSeen": (now - timedelta(seconds=20)).isoformat(),
        },
        "LS1",
        now,
    )
    expect_error(lambda: CI.agent_is_online({"name": "LS1"}, "LS1", now), "malformed")

    os.environ.update(
        {
            "CACHIX_ACTIVATE_TOKEN": "activate-token",
            "CACHIX_STATUS_TOKEN": "status-token",
            "GITHUB_SHA": "a" * 40,
        }
    )
    original_boundaries = {
        name: getattr(CI, name)
        for name in (
            "agent_status",
            "verify_remote_paths",
            "activate",
            "pin_store_path",
        )
    }
    reported = {
        "LS1": "online",
        "NPSB2": "offline",
        "oberon": "unregistered",
    }
    def reported_status(token, host, allow_unregistered=False):
        assert token == "status-token"
        return reported[host]

    CI.agent_status = reported_status

    def forbidden(*_args, **_kwargs):
        raise AssertionError("status-only probe crossed a mutating boundary")

    CI.verify_remote_paths = forbidden
    CI.activate = forbidden
    CI.pin_store_path = forbidden
    output = io.StringIO()
    del os.environ["CACHIX_STATUS_TOKEN"]
    expect_error(lambda: CI.status_record(record), "CACHIX_STATUS_TOKEN is empty")
    os.environ["CACHIX_STATUS_TOKEN"] = "status-token"
    with contextlib.redirect_stdout(output):
        statuses = CI.status_record(record)
    assert statuses == {
        "LS1": "online",
        "NPSB1": "deferred",
        "NPSB2": "offline",
        "oberon": "unregistered",
    }
    text = output.getvalue()
    assert "LS1: online" in text
    assert "NPSB1: deferred" in text
    assert "NPSB2: offline" in text
    assert "oberon: unregistered" in text
    assert "permission/schema confirmed" in text

    reported = {host: "unregistered" for host in ("LS1", "NPSB2", "oberon")}
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        CI.status_record(record)
    assert "permission/schema remains unproven" in output.getvalue()
    for name, value in original_boundaries.items():
        setattr(CI, name, value)

    original_retry = CI.retry_json

    def api_failure(status):
        raise CI.ApiError(status, "expected probe failure")

    CI.retry_json = lambda *_args, **_kwargs: api_failure(401)
    expect_error(lambda: CI.agent_status("token", "LS1", True), "unauthorised")
    CI.retry_json = lambda *_args, **_kwargs: api_failure(None)
    expect_error(lambda: CI.agent_status("token", "LS1", True), "unavailable")

    def unregistered(url, *_args, **_kwargs):
        if "/deploy/agent/" in url:
            raise CI.ApiError(404, "missing")
        return {}

    CI.retry_json = unregistered
    assert CI.agent_status("token", "LS1", True) == "unregistered"
    expect_error(lambda: CI.agent_status("token", "LS1"), "not registered")
    CI.retry_json = original_retry

    originals = {
        name: getattr(CI, name)
        for name in (
            "fetch_pins",
            "agent_online",
            "github_current_revision",
            "verify_remote_paths",
            "activate",
            "pin_store_path",
        )
    }
    transitions = []
    CI.fetch_pins = lambda _token: {}
    def agent_online(token, host):
        assert token == "status-token"
        return host == "oberon"

    CI.agent_online = agent_online
    CI.github_current_revision = lambda *_args: "a" * 40
    CI.verify_remote_paths = lambda target: transitions.append(("verified", target["host"]))
    CI.activate = lambda _tools, _token, target, _directory: transitions.append(("activated", target["host"]))
    CI.pin_store_path = lambda _token, name, path, keep: transitions.append(("pinned", name, path, keep))
    os.environ.update(
        {
            "CACHIX_AUTH_TOKEN": "cache-token",
            "CACHIX_ACTIVATE_TOKEN": "activate-token",
            "GITHUB_TOKEN": "github-token",
            "GITHUB_REPOSITORY": "example/nps",
            "GITHUB_SHA": "a" * 40,
        }
    )
    with tempfile.TemporaryDirectory() as directory:
        deployed = CI.deploy_record(
            record,
            "NPSB2,oberon",
            False,
            directory,
            directory,
            "main",
            "main",
        )
        assert deployed == ["oberon"]
        assert transitions == [
            ("verified", "oberon"),
            ("activated", "oberon"),
            ("pinned", "deployed-host-oberon", PATHS["oberon"], 2),
        ]

        transitions.clear()
        observations = iter((True, False))
        CI.agent_online = lambda *_args: next(observations)
        assert CI.deploy_record(record, "NPSB2", False, directory, directory, "main", "main") == []
        assert transitions == [("verified", "NPSB2")]

        transitions.clear()
        CI.agent_online = lambda *_args: True
        CI.github_current_revision = lambda *_args: "b" * 40
        assert CI.deploy_record(record, "NPSB2", False, directory, directory, "main", "main") == []
        assert transitions == [("verified", "NPSB2")]

        transitions.clear()
        CI.github_current_revision = lambda *_args: "a" * 40
        CI.activate = lambda *_args: (_ for _ in ()).throw(RuntimeError("activation failed"))
        try:
            CI.deploy_record(record, "NPSB2", False, directory, directory, "main", "main")
        except RuntimeError:
            pass
        else:
            raise AssertionError("failed activation was accepted")
        assert all(transition[0] != "pinned" for transition in transitions)
    for name, value in originals.items():
        setattr(CI, name, value)

    with tempfile.TemporaryDirectory() as directory, patch.object(subprocess, "run") as run:
        run.return_value = subprocess.CompletedProcess([], 0)
        CI.activate(
            directory, "activate-token", {"host": "LS1", **record["targets"]["LS1"]}, Path(directory)
        )
        activation_env = run.call_args.kwargs["env"]
        assert activation_env["CACHIX_ACTIVATE_TOKEN"] == "activate-token"
        assert "CACHIX_STATUS_TOKEN" not in activation_env

    with tempfile.TemporaryDirectory() as directory:
        temporary = Path(directory)
        cache = temporary / "cache"
        cache.mkdir()
        image = cache / "image.erofs"
        image.write_bytes(b"seed")
        digest = __import__("hashlib").sha256(b"seed").hexdigest()
        manifest = {
            "schemaVersion": 1,
            "system": "x86_64-linux",
            "runner": "ubuntu-24.04",
            "nixVersion": "2.34.7",
            "format": "erofs-lz4hc",
            "compatibilityHash": "b" * 64,
            "imageSha256": digest,
            "roots": [PATHS["LS1"]],
        }
        (cache / "manifest.json").write_text(json.dumps(manifest))
        environment = os.environ | {
            "CI": "true",
            "RUNNER_OS": "Linux",
            "RUNNER_ARCH": "X64",
            "RUNNER_TEMP": directory,
            "NIX_SEED_COMPATIBILITY_HASH": "c" * 64,
        }
        (cache / "image.erofs.sha256").write_text(f"{digest}  image.erofs\n")
        subprocess.run(
            [ROOT / ".github/scripts/nix-seed.sh", "validate", cache],
            env=environment,
            check=True,
        )
        manifest["compatibilityHash"] = "not-a-hash"
        (cache / "manifest.json").write_text(json.dumps(manifest))
        malformed = subprocess.run(
            [ROOT / ".github/scripts/nix-seed.sh", "validate", cache],
            env=environment,
            capture_output=True,
            text=True,
        )
        assert malformed.returncode != 0
        assert "seed manifest does not match the required contract" in malformed.stderr
        rejected = subprocess.run(
            [ROOT / ".github/scripts/nix-seed.sh", "validate", temporary.parent],
            env=environment,
            capture_output=True,
            text=True,
        )
        assert rejected.returncode != 0
        assert "cache must be an exact child of RUNNER_TEMP" in rejected.stderr

    print("CI boundary probe passed")


if __name__ == "__main__":
    main()
