"""Check publication must preserve the selected revision and build outcome."""

import os
import signal
import subprocess
import sys
import time
import unittest
from unittest.mock import Mock, patch

import nix_fast_build as nfb


class BuildChecksTests(unittest.TestCase):
    def test_malformed_events_do_not_publish_failures(self):
        api, publisher = self.publisher()
        for kind in ('EVAL', 'BUILD'):
            for success in (None, 'false', 0, 1):
                publisher.handle(dict(type=kind, attr='NPS03', success=success))
            publisher.handle(dict(type=kind, attr='', success=True))
        api.create.assert_not_called()
        api.update.assert_not_called()

    def test_descendant_stdout_cannot_delay_leader_failure(self):
        command = [
            sys.executable, '-c',
            'import subprocess,sys; '
            'subprocess.Popen([sys.executable,"-c","import time; time.sleep(5)"]); '
            'raise SystemExit(7)',
        ]
        start = time.monotonic()
        self.assertEqual(nfb.run(command, None), 7)
        self.assertLess(time.monotonic() - start, 3)

    def test_cancellation_terminates_child_and_finalises_check(self):
        api, publisher = self.publisher()

        def cancel(**payload):
            os.kill(os.getpid(), signal.SIGTERM)
            return 12

        api.create.side_effect = cancel
        command = [
            sys.executable, '-c',
            'import json,time; '
            'print(json.dumps(dict(type="EVAL", attr="NPS03", success=True)), flush=True); '
            'time.sleep(5)',
        ]
        self.assertNotEqual(nfb.run(command, publisher), 0)
        self.assertEqual(api.update.call_args.kwargs['conclusion'], 'cancelled')

    def publisher(self):
        api = Mock()
        api.create.return_value = 12
        return api, nfb.CheckPublisher(api, 'a' * 40, 'https://example/run', '7', '2')

    def test_host_checks_report_evaluation_and_build_failures(self):
        api, publisher = self.publisher()
        publisher.handle({'type': 'EVAL', 'attr': 'NPS03', 'success': True})
        self.assertEqual(api.create.call_args.kwargs['name'], 'Build NPS03')
        self.assertEqual(api.create.call_args.kwargs['head_sha'], 'a' * 40)
        publisher.handle({'type': 'BUILD', 'attr': 'NPS03', 'success': False})
        self.assertEqual(api.update.call_args.kwargs['conclusion'], 'failure')
        publisher.handle({'type': 'EVAL', 'attr': 'oberon', 'success': False})
        self.assertEqual(api.create.call_args.kwargs['conclusion'], 'failure')

    def test_process_failure_finalises_checks_even_if_publication_fails(self):
        for unavailable in (False, True):
            with self.subTest(unavailable=unavailable):
                api, publisher = self.publisher()
                if unavailable:
                    api.create.side_effect = RuntimeError('API unavailable')
                command = [
                    sys.executable, '-c',
                    'import json; '
                    'print(json.dumps(dict(type="EVAL", attr="NPS03", success=True))); '
                    'raise SystemExit(9)',
                ]
                self.assertEqual(nfb.run(command, publisher), 9)
                if not unavailable:
                    self.assertEqual(api.update.call_args.kwargs['conclusion'], 'failure')

    def test_cli_uses_selected_revision_not_workflow_sha(self):
        with (
            patch.dict(os.environ, {'GITHUB_SHA': 'b' * 40}),
            patch.object(nfb, 'CheckPublisher') as publisher,
            patch.object(nfb, 'run', return_value=0),
            patch.object(sys, 'argv', [
                'nfb', '--publish-checks', '--revision', 'a' * 40,
                '--', 'nix-fast-build',
            ]),
        ):
            self.assertEqual(nfb.main(), 0)
        self.assertEqual(publisher.call_args.args[1], 'a' * 40)

    def test_unpublished_build_needs_no_token(self):
        command = [
            sys.executable,
            os.path.join(os.path.dirname(__file__), 'nix_fast_build.py'),
            '--', sys.executable, '-c', 'raise SystemExit(7)',
        ]
        self.assertEqual(subprocess.run(command, capture_output=True).returncode, 7)

    def test_ambiguous_creation_reconciles_without_second_post(self):
        api = nfb.GitHubChecks('token', 'example/repo')

        def request(method, path, payload):
            if method == 'POST':
                api.last_request_ambiguous = True
                return None
            return {'check_runs': [{'id': 12, 'external_id': 'run-host'}]}
        with patch.object(api, '_request', side_effect=request) as calls:
            self.assertEqual(api.create(
                head_sha='a' * 40, status='in_progress', external_id='run-host',
            ), 12)
        self.assertEqual(
            [call.args[0] for call in calls.call_args_list], ['POST', 'GET'],
        )

    def test_successful_build_is_not_overwritten_by_later_process_failure(self):
        api, publisher = self.publisher()
        publisher.handle({'type': 'EVAL', 'attr': 'NPS03', 'success': True})
        publisher.handle({'type': 'BUILD', 'attr': 'NPS03', 'success': True})
        publisher.finalize('failure')
        api.update.assert_called_once()
        self.assertEqual(api.update.call_args.kwargs['conclusion'], 'success')


if __name__ == '__main__':
    unittest.main()
