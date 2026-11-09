#!/usr/bin/env python3
"""Subprocess contracts: every hosted response is mocked, never live GitHub."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
SHA = 'a' * 40
# Run the real CLI entry point in a fresh process with a stdlib transport fixture.
FIXTURE = r'''
import io, json, os, runpy, sys, urllib.request
from unittest.mock import patch
scenario = sys.argv.pop(1)
entry = sys.argv.pop(1)
sha = 'a' * 40
state = {}
class Response(io.BytesIO):
    def __enter__(self): return self
    def __exit__(self, *a): self.close()
    def read(self, *a):
        if scenario == 'blocked-body':
            import time
            time.sleep(10)
        return super().read(*a)
class Mock:
    def open(self, request, timeout):
        assert request.full_url.startswith('https://api.github.com/repos/ravand1990/nntdrive/')
        assert 0 < timeout <= 30
        path = request.full_url.split('/nntdrive')[1]
        if scenario == 'http':
            import urllib.error
            raise urllib.error.HTTPError(request.full_url, 403, 'denied', {}, None)
        if scenario == 'transport': raise OSError('fixture-secret-never-print')
        if scenario == 'malformed': return Response(b'{}')
        title = 'test-env:' + state.get('target', 'android-build') + ':' + state.get('correlation', '')
        run = dict(id=71, head_sha=sha, display_title=title, event='workflow_dispatch',
                   status='completed', conclusion='success', run_attempt=1)
        if path.startswith('/commits/'):
            data = {'sha': 'b'*40 if scenario == 'moved' else sha}
        elif path.endswith('/dispatches'):
            payload = json.loads(request.data)
            assert payload['ref'] == 'task/example'
            assert payload['inputs']['expected_sha'] == sha
            state.update(payload['inputs'])
            return Response(b'')
        elif '/artifacts?' in path:
            if scenario in ('late-final', 'late-no-signal'):
                import time
                time.sleep(1.2)
            artifact = dict(id=91, name='nntdrive-android', expired=False, size_in_bytes=123)
            if state['target'] == 'linux-client': artifact['name'] = 'nntdrive-linux-x64'
            if scenario == 'expired': artifact['expired'] = True
            data = {'artifacts': [] if scenario == 'missing-artifact' else [artifact]}
            if state['target'] == 'linux-client' and scenario != 'missing-evidence':
                data['artifacts'].append(dict(id=92, name='nntdrive-linux-runtime-evidence', expired=False, size_in_bytes=123))
        elif '/attempts/1/jobs?' in path:
            names = ['identity', 'analyze', 'build-linux', 'build-android', 'build-windows', 'android-native-smoke', 'windows-app-smoke']
            if state['target'] == 'linux-client': names.append('linux-runtime')
            jobs = [dict(name=n if n in ('identity', 'linux-runtime') or scenario == 'unprefixed' else 'clients / ' + n,
                         status='completed', conclusion='success') for n in names]
            if scenario == 'missing-job': jobs.pop(1)
            if scenario == 'missing-smoke': jobs = [j for j in jobs if not j['name'].endswith('android-native-smoke')]
            if scenario == 'missing-windows-smoke': jobs = [j for j in jobs if not j['name'].endswith('windows-app-smoke')]
            if scenario == 'missing-runtime': jobs.pop()
            if scenario in ('skipped-job', 'cancelled-job', 'failure-job'): jobs[1]['conclusion'] = scenario.split('-')[0]
            if scenario == 'unfinished-job': jobs[1]['status'] = 'in_progress'
            if scenario == 'duplicate-job': jobs.append(dict(jobs[1], name='analyze'))
            if scenario.startswith('paginated'):
                from urllib.parse import parse_qs, urlsplit
                page = parse_qs(urlsplit(request.full_url).query)['page'][0]
                if page == '1': jobs = [dict(name='irrelevant', status='completed', conclusion='success')] * 99 + [jobs[0]]
                else:
                    jobs = jobs[1:]
                    if scenario == 'paginated-duplicate': jobs.append(dict(name='identity', status='completed', conclusion='success'))
            data = {'jobs': jobs}
        elif path == '/actions/runs/71':
            if scenario == 'failed': run['conclusion'] = 'failure'
            if scenario == 'rerun': run['run_attempt'] = 2
            data = run
        elif '/runs?' in path:
            # A simultaneous unrelated run must never be selected.
            unrelated = dict(run, id=99, display_title='another-dispatch')
            if scenario == 'wrong-head': run['head_sha'] = 'b'*40
            if scenario == 'unrelated': run['display_title'] = 'another-dispatch'
            data = {'workflow_runs': [unrelated, run, run] if scenario == 'duplicate' else [unrelated, run]}
        else: raise AssertionError(path)
        return Response(json.dumps(data).encode())
if scenario == 'late-no-signal':
    import signal
    signal.setitimer = lambda *a: None
with patch.object(urllib.request, 'build_opener', return_value=Mock()):
    sys.argv[0] = entry
    runpy.run_path(entry, run_name='__main__')
'''


class Contracts(unittest.TestCase):
    def invoke(self, scenario='success', extra=(), token=True, target='android-build'):
        env = dict(os.environ)
        env.pop('GITHUB_TOKEN', None)
        if token:
            env['GITHUB_TOKEN'] = 'fixture-secret-never-print'
        command = [sys.executable, '-c', FIXTURE, scenario,
                   str(ROOT / 'scripts/test-env.py'), target,
                   '--ref', 'task/example', '--sha', SHA, '--timeout', '1', *extra]
        result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True,
                                text=True, timeout=5)
        self.assertNotIn('fixture-secret-never-print', result.stdout + result.stderr)
        return result

    def test_correlated_run_and_exact_artifact(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('/actions/runs/71/artifacts/91', result.stdout)
        self.assertNotIn('/runs/99', result.stdout)

    def test_fail_closed(self):
        for scenario in ['moved', 'expired', 'missing-artifact', 'failed', 'rerun',
                         'wrong-head', 'unrelated', 'duplicate', 'http', 'transport', 'malformed']:
            with self.subTest(scenario=scenario):
                result = self.invoke(scenario)
                self.assertNotEqual(result.returncode, 0)

    def test_required_jobs(self):
        for scenario in ['missing-job', 'skipped-job', 'cancelled-job', 'failure-job', 'unfinished-job', 'duplicate-job', 'missing-smoke', 'missing-windows-smoke', 'paginated-duplicate']:
            with self.subTest(scenario=scenario):
                result = self.invoke(scenario, target='android-emulator')
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn('successful job', result.stderr)
        for scenario in ['unprefixed', 'paginated']:
            result = self.invoke(scenario)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_linux_runtime_job_and_evidence(self):
        self.assertEqual(self.invoke(target='linux-client').returncode, 0)
        for scenario in ['missing-runtime', 'missing-evidence']:
            result = self.invoke(scenario, target='linux-client')
            self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_outer_deadline_and_late_final_response(self):
        for scenario in ['late-final', 'late-no-signal', 'blocked-body']:
            started = time.monotonic()
            result = self.invoke(scenario)
            elapsed = time.monotonic() - started
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn('Deadline exceeded', result.stderr)
            self.assertNotIn('/artifacts/91', result.stdout)
            if scenario != 'late-no-signal': self.assertLess(elapsed, 1.2)

    def test_raw_sha_ref_rejected(self):
        result = self.invoke(extra=('--ref', SHA))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('branch or tag', result.stderr)
        self.assertNotIn('Dispatched', result.stdout)

    def test_missing_token_and_invalid_inputs(self):
        self.assertNotEqual(self.invoke(token=False).returncode, 0)
        for extra in [('--sha', 'short'), ('--timeout', '0'), ('--timeout', '999999'),
                      ('--repo', 'bad/repo/other')]:
            self.assertNotEqual(self.invoke(extra=extra).returncode, 0)

    def test_windows_runtime_blocked_without_dispatch(self):
        result = subprocess.run(['bash', 'scripts/test-env.sh', 'windows-runtime'],
                                cwd=ROOT, capture_output=True, text=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('No approved isolated Windows', result.stderr)

    def test_local_delegation(self):
        fixture = '''import runpy,sys
from unittest.mock import patch
from types import SimpleNamespace
with patch('subprocess.Popen') as run:
    run.return_value.wait.return_value = 7
    sys.argv = ['test-env.py', 'linux-core']
    try: runpy.run_path('scripts/test-env.py', run_name='__main__')
    except SystemExit as e: assert e.code == 7
    assert run.call_args.args[0] == ['bash','scripts/dev-check.sh','all']
    assert 'GITHUB_TOKEN' not in run.call_args.kwargs['env']
'''
        result = subprocess.run([sys.executable, '-c', fixture], cwd=ROOT,
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_matrix_and_workflow_guardrails(self):
        matrix = json.loads((ROOT / 'envs/matrix.yaml').read_text())
        self.assertEqual(len(matrix['targets']), 6)
        workflow = (ROOT / '.github/workflows/test-environments.yml').read_text()
        self.assertIn('needs: identity', workflow)
        self.assertIn('uses: ./.github/workflows/clients.yml', workflow)
        for forbidden in ['pull_request:', 'push:', 'self-hosted', 'secrets: inherit']:
            self.assertNotIn(forbidden, workflow)


if __name__ == '__main__':
    unittest.main()
