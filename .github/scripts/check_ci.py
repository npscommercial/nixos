#!/usr/bin/env python3
"""Focused standard-library tests for CI metadata and deployment boundaries."""

import contextlib
import hashlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

import build_records


ROOT = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("nps_ci", ROOT / ".github/scripts/ci.py")
CI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CI)

REVISION = "a" * 40
HOSTS = ["alpha", "beta", "held", "spare"]
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
        **({"deferred": True} if host == "held" else {}),
    }
    for index, host in enumerate(HOSTS, 1)
}
DEPLOY_ENV = {
    "CACHIX_AUTH_TOKEN": "cache-token",
    "CACHIX_ACTIVATE_TOKEN": "activate-token",
    "CACHIX_STATUS_TOKEN": "status-token",
    "GITHUB_TOKEN": "github-token",
    "GITHUB_REPOSITORY": "example/nps",
    "GITHUB_SHA": REVISION,
}


def nfb_results():
    return {"results": [
        {"type": kind, "attr": host, "success": True, "duration": 0.1,
         "error": None, "outputs": {"out": PATHS[host]}}
        for host in HOSTS for kind in ("EVAL", "BUILD")
    ]}


def build_record():
    return build_records.build_record(nfb_results(), HOSTS, TARGETS, REVISION)


class BuildRecordTests(unittest.TestCase):
    def test_build_record_captures_validated_hosts_and_deferred_target(self):
        record = build_record()

        self.assertEqual(record["sourceRevision"], REVISION)
        self.assertEqual(list(record["hosts"]), HOSTS)
        self.assertTrue(record["targets"]["held"]["deferred"])

    def test_build_record_rejects_failed_nfb_result(self):
        results = nfb_results()
        results["results"][0]["success"] = False

        with self.assertRaisesRegex(ValueError, "failed"):
            build_records.build_record(results, HOSTS, TARGETS, REVISION)

    def test_build_record_rejects_target_from_another_host(self):
        targets = json.loads(json.dumps(TARGETS))
        targets["alpha"]["storePath"] = PATHS["spare"]

        with self.assertRaisesRegex(ValueError, "does not match"):
            build_records.build_record(nfb_results(), HOSTS, targets, REVISION)


class TargetSelectionTests(unittest.TestCase):
    def test_all_targets_excludes_deferred_and_unchanged_hosts(self):
        selected, skipped = build_records.select_targets(
            build_record(), "all", False, {"deployed-host-alpha": PATHS["alpha"]}
        )

        self.assertEqual([target["host"] for target in selected], ["beta", "spare"])
        self.assertEqual(skipped, {"alpha": "unchanged", "held": "deferred"})

    def test_force_selects_an_unchanged_host(self):
        selected, skipped = build_records.select_targets(
            build_record(), "alpha", True, {"deployed-host-alpha": PATHS["alpha"]}
        )

        self.assertEqual([target["host"] for target in selected], ["alpha"])
        self.assertEqual(skipped, {})

    def test_unknown_host_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "unknown"):
            build_records.select_targets(build_record(), "missing", True, {})


class AgentStatusTests(unittest.TestCase):
    NOW = datetime(2026, 9, 14, tzinfo=timezone.utc)

    def test_agent_freshness_uses_twenty_second_boundary(self):
        fresh = {"id": "1", "name": "alpha", "version": "1", "lastSeen": self.NOW.isoformat()}
        stale = fresh | {"lastSeen": (self.NOW - timedelta(seconds=20)).isoformat()}

        self.assertTrue(CI.agent_is_online(fresh, "alpha", self.NOW))
        self.assertFalse(CI.agent_is_online(stale, "alpha", self.NOW))

    def test_malformed_agent_payload_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "malformed"):
            CI.agent_is_online({"name": "alpha"}, "alpha", self.NOW)

    def test_unauthorised_agent_api_is_distinguished(self):
        with patch.object(CI, "retry_json", side_effect=CI.ApiError(401, "denied")):
            with self.assertRaisesRegex(ValueError, "unauthorised"):
                CI.agent_status("token", "alpha", True)

    def test_unavailable_agent_api_is_distinguished(self):
        with patch.object(CI, "retry_json", side_effect=CI.ApiError(None, "unavailable")):
            with self.assertRaisesRegex(ValueError, "unavailable"):
                CI.agent_status("token", "alpha", True)

    def test_missing_agent_can_be_reported_or_rejected(self):
        def unregistered(url, *_args, **_kwargs):
            if "/deploy/agent/" in url:
                raise CI.ApiError(404, "missing")
            return {}

        with patch.object(CI, "retry_json", side_effect=unregistered):
            self.assertEqual(CI.agent_status("token", "alpha", True), "unregistered")
            with self.assertRaisesRegex(ValueError, "not registered"):
                CI.agent_status("token", "alpha")


class StatusRecordTests(unittest.TestCase):
    def test_status_requires_a_dedicated_token(self):
        with patch.dict(os.environ, {"GITHUB_SHA": REVISION}, clear=True):
            with self.assertRaisesRegex(ValueError, "CACHIX_STATUS_TOKEN is empty"):
                CI.status_record(build_record())

    def test_status_reports_agents_without_crossing_mutating_boundaries(self):
        reported = {"alpha": "online", "beta": "offline", "spare": "unregistered"}
        output = io.StringIO()

        with patch.dict(
            os.environ,
            {"GITHUB_SHA": REVISION, "CACHIX_STATUS_TOKEN": "status-token"},
            clear=True,
        ), patch.object(
            CI, "agent_status", side_effect=lambda _token, host, **_kwargs: reported[host]
        ), patch.object(CI, "verify_remote_paths") as verify, patch.object(
            CI, "activate"
        ) as activate, patch.object(CI, "pin_store_path") as pin, contextlib.redirect_stdout(output):
            statuses = CI.status_record(build_record())

        self.assertEqual(
            statuses,
            {"alpha": "online", "held": "deferred", "beta": "offline", "spare": "unregistered"},
        )
        verify.assert_not_called()
        activate.assert_not_called()
        pin.assert_not_called()

@contextlib.contextmanager
def deployment_context():
    """Isolate external boundaries; each case changes only its failure trigger."""
    with contextlib.ExitStack() as stack:
        directory = stack.enter_context(tempfile.TemporaryDirectory())
        stack.enter_context(patch.dict(os.environ, DEPLOY_ENV, clear=True))
        defaults = {
            "fetch_pins": {}, "ensure_no_pending_deployment": None,
            "agent_online": True, "verify_remote_paths": None,
            "github_current_revision": REVISION, "start_deployment": 17,
            "activate": None, "pin_store_path": None, "finish_deployment": None,
        }
        mocks = {name: stack.enter_context(patch.object(CI, name, return_value=value))
                 for name, value in defaults.items()}
        yield directory, mocks


class DeploymentTests(unittest.TestCase):
    def test_controller_requires_the_full_default_branch_ref(self):
        for ref in ("main", "refs/tags/main", "refs/heads/topic"):
            with self.subTest(ref=ref), deployment_context() as (directory, mocks):
                with self.assertRaisesRegex(ValueError, "default branch"):
                    CI.deploy_record(build_record(), "beta", False, directory, directory, "main", ref)
                mocks["fetch_pins"].assert_not_called()

    def test_executor_rejects_multiple_hosts(self):
        with self.assertRaisesRegex(ValueError, "exactly one host"):
            CI.deploy_record(build_record(), "beta,spare", False, "/tools", "/tmp/deploy", "main", "refs/heads/main")

    def test_online_host_is_activated_pinned_and_recorded(self):
        record = build_record()
        with deployment_context() as (directory, mocks):
            deployed = CI.deploy_record(record, "spare", False, directory, directory, "main", "refs/heads/main")

        self.assertEqual(deployed, ["spare"])
        mocks["ensure_no_pending_deployment"].assert_called_once_with("spare")
        mocks["verify_remote_paths"].assert_called_once()
        mocks["start_deployment"].assert_called_once_with(record, "spare")
        mocks["activate"].assert_called_once()
        mocks["pin_store_path"].assert_called_once_with("cache-token", "deployed-host-spare", PATHS["spare"], 2)
        mocks["finish_deployment"].assert_called_once_with(17, "success")

    def test_offline_host_is_skipped_before_remote_validation(self):
        with deployment_context() as (directory, mocks):
            mocks["agent_online"].return_value = False
            deployed = CI.deploy_record(build_record(), "beta", False, directory, directory, "main", "refs/heads/main")

        self.assertEqual(deployed, [])
        mocks["verify_remote_paths"].assert_not_called()
        for name in ("start_deployment", "activate", "pin_store_path", "finish_deployment"):
            mocks[name].assert_not_called()

    def test_host_going_offline_after_validation_is_not_submitted(self):
        with deployment_context() as (directory, mocks):
            mocks["agent_online"].side_effect = [True, False]
            deployed = CI.deploy_record(build_record(), "beta", False, directory, directory, "main", "refs/heads/main")

        self.assertEqual(deployed, [])
        mocks["verify_remote_paths"].assert_called_once()
        for name in ("start_deployment", "activate", "pin_store_path", "finish_deployment"):
            mocks[name].assert_not_called()

    def test_stale_revision_is_not_submitted(self):
        with deployment_context() as (directory, mocks):
            mocks["github_current_revision"].return_value = "b" * 40
            deployed = CI.deploy_record(build_record(), "beta", False, directory, directory, "main", "refs/heads/main")

        self.assertEqual(deployed, [])
        for name in ("start_deployment", "activate", "pin_store_path", "finish_deployment"):
            mocks[name].assert_not_called()

    def test_pin_is_rechecked_before_submission(self):
        with deployment_context() as (directory, mocks):
            mocks["fetch_pins"].side_effect = [{}, {"deployed-host-beta": PATHS["beta"]}]
            deployed = CI.deploy_record(build_record(), "beta", False, directory, directory, "main", "refs/heads/main")

        self.assertEqual(deployed, [])
        for name in ("start_deployment", "activate", "pin_store_path", "finish_deployment"):
            mocks[name].assert_not_called()

    def test_failed_activation_neither_pins_nor_finishes_successfully(self):
        with deployment_context() as (directory, mocks):
            mocks["activate"].side_effect = RuntimeError("activation failed")
            with self.assertRaisesRegex(RuntimeError, "activation failed"):
                CI.deploy_record(build_record(), "beta", False, directory, directory, "main", "refs/heads/main")

        mocks["pin_store_path"].assert_not_called()
        mocks["finish_deployment"].assert_not_called()

    def test_activation_passes_only_the_activate_token(self):
        target = {"host": "alpha", **build_record()["targets"]["alpha"]}
        with tempfile.TemporaryDirectory() as directory, patch.dict(
            os.environ, {"CACHIX_STATUS_TOKEN": "status-token"}, clear=True
        ), patch.object(
            subprocess, "run", return_value=subprocess.CompletedProcess([], 0)
        ) as run:
            CI.activate(directory, "activate-token", target, Path(directory))

        activation_environment = run.call_args.kwargs["env"]
        self.assertEqual(activation_environment["CACHIX_ACTIVATE_TOKEN"], "activate-token")
        self.assertNotIn("CACHIX_STATUS_TOKEN", activation_environment)


class SeedValidationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.runner_temp = Path(self.temporary.name)
        self.cache = self.runner_temp / "cache"
        self.cache.mkdir()
        (self.cache / "image.erofs").write_bytes(b"seed")
        self.digest = hashlib.sha256(b"seed").hexdigest()
        self.manifest = {
            "schemaVersion": 1,
            "system": "x86_64-linux",
            "runner": "ubuntu-24.04",
            "nixVersion": "2.34.7",
            "format": "erofs-lz4hc",
            "compatibilityHash": "b" * 64,
            "imageSha256": self.digest,
            "roots": [PATHS["alpha"]],
        }
        self.write_manifest()
        (self.cache / "image.erofs.sha256").write_text(f"{self.digest}  image.erofs\n")
        self.environment = os.environ | {
            "CI": "true",
            "RUNNER_OS": "Linux",
            "RUNNER_ARCH": "X64",
            "RUNNER_TEMP": str(self.runner_temp),
            "NIX_SEED_COMPATIBILITY_HASH": "c" * 64,
        }

    def tearDown(self):
        self.temporary.cleanup()

    def write_manifest(self):
        (self.cache / "manifest.json").write_text(json.dumps(self.manifest))

    def validate(self, cache=None):
        return subprocess.run(
            [ROOT / ".github/scripts/nix-seed.sh", "validate", cache or self.cache],
            env=self.environment,
            capture_output=True,
            text=True,
        )

    def test_seed_with_a_different_compatibility_hash_is_structurally_valid(self):
        self.assertEqual(self.validate().returncode, 0)

    def test_seed_rejects_a_malformed_manifest(self):
        self.manifest["compatibilityHash"] = "not-a-hash"
        self.write_manifest()

        result = self.validate()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("seed manifest does not match the required contract", result.stderr)

    def test_seed_rejects_a_directory_outside_runner_temp(self):
        result = self.validate(self.runner_temp.parent)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cache must be an exact child of RUNNER_TEMP", result.stderr)


if __name__ == "__main__":
    unittest.main()
