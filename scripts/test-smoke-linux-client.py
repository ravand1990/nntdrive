#!/usr/bin/env python3
"""Headless helper contracts with fake bundle/tools, not real GUI evidence."""
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = r'''
import os, runpy, subprocess, sys
from pathlib import Path
from unittest.mock import patch
scenario, entry, archive, pubspec, output = sys.argv[1:]
real_run = subprocess.run
seen = []
def tool(argv, **kw):
    env = kw['env']
    assert 'GITHUB_TOKEN' not in env and 'AWS_SECRET_ACCESS_KEY' not in env
    assert env['HOME'].startswith(output)
    assert env['XDG_RUNTIME_DIR'].startswith(output)
    if argv[0] == 'xdotool':
        assert argv[1:4] == ['search', '--onlyvisible', '--pid']
        pid = int(argv[4]); os.kill(pid, 0)
        seen.append(pid)
        return subprocess.CompletedProcess(argv, 1 if scenario == 'no-window' else 0,
                                           '' if scenario == 'no-window' else '123\n', '')
    assert argv[:3] == ['import', '-window', 'root']
    Path(argv[3]).write_bytes(b'fixture screenshot, not a real image')
    return subprocess.CompletedProcess(argv, 0)
def title(argv, **kw):
    assert argv == ['xdotool', 'getwindowname', '123']
    return 'NNTDrive fixture\n'
sys.argv = [entry, archive, pubspec, output, '--timeout', '4']
with patch('subprocess.run', side_effect=tool), patch('subprocess.check_output', side_effect=title):
    runpy.run_path(entry, run_name='__main__')
'''


class SmokeContracts(unittest.TestCase):
    def invoke(self, scenario):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / 'bundle.tar.gz'
            script = (b'#!/bin/sh\nexit 9\n' if scenario == 'exit' else
                      b'#!/bin/sh\necho fake-client-started\nexec /bin/sleep 20\n')
            with tarfile.open(archive, 'w:gz') as package:
                for name, content in [('nntdrive', script), ('lib/libnntdrive_ffi.so', b'fixture')]:
                    info = tarfile.TarInfo(name)
                    info.mode = 0o755
                    info.size = len(content)
                    package.addfile(info, io.BytesIO(content))
                if scenario == 'traversal':
                    info = tarfile.TarInfo('../escape')
                    info.size = 1
                    package.addfile(info, io.BytesIO(b'x'))
            pubspec = root / 'pubspec.yaml'
            pubspec.write_text('version: 1.2.3+4\n')
            output = root / 'output'
            result = subprocess.run([sys.executable, '-c', FIXTURE, scenario,
                                     str(ROOT / 'scripts/smoke-linux-client.py'),
                                     str(archive), str(pubspec), str(output)],
                                    env={'PATH': '/usr/bin:/bin', 'GITHUB_TOKEN': 'never-print',
                                         'AWS_SECRET_ACCESS_KEY': 'never-print'},
                                    capture_output=True, text=True, timeout=15)
            report = json.loads((output / 'report.json').read_text())
            self.assertNotIn('never-print', result.stdout + result.stderr)
            self.assertTrue((output / 'screenshot.png').exists())
            if 'pid' in report:
                with self.assertRaises(ProcessLookupError):
                    import os
                    os.kill(report['pid'], 0)
            self.assertFalse((root / 'escape').exists())
            return result, report

    def test_live_process_window_and_cleanup(self):
        result, report = self.invoke('success')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(report['passed'])
        self.assertEqual(report['source_pubspec_version'], '1.2.3+4')
        self.assertIn('not observed', report['gui_version'])
        self.assertEqual(report['window_ids'], ['123'])
        self.assertEqual(len(report['archive_sha256']), 64)

    def test_early_exit_and_no_window_fail(self):
        for scenario in ['exit', 'no-window', 'traversal']:
            with self.subTest(scenario=scenario):
                result, report = self.invoke(scenario)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(report['passed'])
                self.assertIn('error', report)

    def test_workflow_gates_and_isolation(self):
        workflow = (ROOT / '.github/workflows/test-environments.yml').read_text()
        self.assertIn("if: inputs.target == 'linux-client'", workflow)
        self.assertIn('needs: clients', workflow)
        self.assertIn('unshare --net -- xvfb-run', workflow)
        self.assertIn('sudo env -i PATH=/usr/bin:/bin', workflow)
        self.assertIn('persist-credentials: false', workflow)
        self.assertIn('if: always()', workflow)
        self.assertIn('actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093', workflow)
        for target in ['linux-client', 'android-build', 'android-emulator', 'windows-build']:
            self.assertIn(target, workflow)


if __name__ == '__main__':
    unittest.main()
