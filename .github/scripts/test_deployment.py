"""Regression checks for deployment decisions that must precede mutations."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import argparse
import sys
from unittest.mock import patch

import build_records

import ci

SHA = 'a' * 40
PATH = '/nix/store/' + '1' * 32 + '-system'
ROLLBACK = '/nix/store/' + '2' * 32 + '-health'


def record():
    return {'schemaVersion': 1, 'sourceRevision': SHA,
            'hosts': {'new-host': PATH}, 'targets': {'new-host': {
                'system': 'aarch64-linux', 'storePath': PATH,
                'rollbackScript': ROLLBACK, 'deployPin': 'deployed-host-new-host'}}}


class DeploymentTests(unittest.TestCase):
    def test_unresolved_operation_blocks_resubmission(self):
        for state in (None, 'pending', 'in_progress', 'queued', 'unknown'):
            with self.subTest(state=state), patch.object(ci, 'deployment_api', side_effect=[
                [{'id': 42}], [] if state is None else [{'state': state}],
            ]):
                with self.assertRaisesRegex(ValueError, 'unresolved'):
                    ci.ensure_no_pending_deployment('new-host')
        with patch.object(ci, 'deployment_api', side_effect=[[{'id': 42}], [{'state': 'success'}]]):
            ci.ensure_no_pending_deployment('new-host')

    def test_preview_cli_only_reads_pins_and_writes_a_matrix(self):
        with tempfile.TemporaryDirectory() as directory:
            source, output = Path(directory) / 'record.json', Path(directory) / 'matrix.json'
            source.write_text(json.dumps(record()))
            arguments = ['ci.py', 'plan', '--record', str(source), '--revision', SHA,
                         '--mode', 'manual', '--default-branch', 'main', '--output', str(output)]
            with patch.object(sys, 'argv', arguments), patch.dict(os.environ, {'CACHIX_AUTH_TOKEN': 't'}), \
                 patch.object(ci, 'fetch_pins', return_value={}), \
                 patch.object(ci, 'activate', side_effect=AssertionError('preview activated')), \
                 patch.object(ci, 'pin_store_path', side_effect=AssertionError('preview pinned')), \
                 patch.object(ci, 'github_current_revision', side_effect=AssertionError('manual freshness gate')):
                ci.main()
            self.assertEqual(json.loads(output.read_text()), {'include': [{'host': 'new-host'}]})

    def test_stale_build_pin_publication_does_not_mutate(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'record.json'
            source.write_text(json.dumps(record()))
            with patch.dict(os.environ, {'CACHIX_AUTH_TOKEN': 't', 'GITHUB_SHA': SHA}), \
                 patch.object(ci, 'fetch_pins', return_value={}), \
                 patch.object(ci, 'revision_allowed', return_value=False), \
                 patch.object(ci, 'pin_store_path', side_effect=AssertionError('stale pin mutation')):
                ci.command_pin_builds(argparse.Namespace(record=source, default_branch='main'))

    def test_inventory_can_grow_without_named_host_policy(self):
        self.assertEqual(build_records.validate_record(record()), record())

    def test_requested_order_is_preserved(self):
        value = record()
        value['targets']['another'] = dict(value['targets']['new-host'])
        selected, _ = build_records.select_targets(value, 'new-host,another', False, {})
        self.assertEqual([t['host'] for t in selected], ['new-host', 'another'])

    def test_target_metadata_cannot_override_validated_host_name(self):
        value = record()
        value['targets']['new-host']['host'] = '../../escape'
        selected, _ = build_records.select_targets(value, 'all', False, {})
        self.assertEqual(selected[0]['host'], 'new-host')

    def test_malformed_evidence_cannot_reach_planning(self):
        for change in ('outside-inventory', 'wrong-path', 'unsafe-name', 'unsupported-system'):
            with self.subTest(change=change):
                value = record()
                if change == 'outside-inventory':
                    value['hosts'] = {'other': PATH}
                elif change == 'wrong-path':
                    value['targets']['new-host']['storePath'] = ROLLBACK
                elif change == 'unsafe-name':
                    value['hosts']['../bad'] = PATH
                else:
                    value['targets']['new-host']['system'] = 'x86_64-darwin'
                with self.assertRaises(ValueError):
                    build_records.validate_record(value)

    def test_timeout_is_unknown_and_not_retried(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(ci.subprocess, 'run', side_effect=subprocess.TimeoutExpired('cachix', 2400)) as run:
            with self.assertRaisesRegex(RuntimeError, 'unknown'):
                ci.activate('/tools', 'token', {'host': 'new-host', **record()['targets']['new-host']}, Path(directory))
            self.assertEqual(run.call_count, 1)

    def test_ambiguous_pin_write_is_reconciled_without_second_post(self):
        with patch.object(ci, 'api_json', side_effect=ci.ApiError(None, 'lost response')) as post, \
             patch.object(ci, 'fetch_pins', return_value={'deployed-host-new-host': PATH}):
            ci.pin_store_path('token', 'deployed-host-new-host', PATH, 2)
            self.assertEqual(post.call_count, 1)
        with patch.object(ci, 'api_json', side_effect=ci.ApiError(None, 'lost response')), \
             patch.object(ci, 'fetch_pins', return_value={}):
            with self.assertRaises(ci.ApiError):
                ci.pin_store_path('token', 'deployed-host-new-host', PATH, 2)


if __name__ == '__main__':
    unittest.main()
