#!/usr/bin/env python3
"""Exercise the packaged Linux GUI under an existing X display; no backend login."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tarfile
import time


def smoke(archive, source, output, timeout):
    output.mkdir(parents=True, exist_ok=True)
    output = output.resolve()
    env = {'PATH': '/usr/bin:/bin', 'DISPLAY': os.environ.get('DISPLAY', ''),
           'LANG': 'C.UTF-8', 'LIBGL_ALWAYS_SOFTWARE': '1'}
    if 'XAUTHORITY' in os.environ:
        env['XAUTHORITY'] = os.environ['XAUTHORITY']
    for key, directory in [('HOME', 'home'), ('XDG_CONFIG_HOME', 'config'),
                           ('XDG_DATA_HOME', 'data'), ('XDG_CACHE_HOME', 'cache'),
                           ('XDG_RUNTIME_DIR', 'runtime')]:
        path = output / directory
        path.mkdir(mode=0o700)
        env[key] = str(path)
    bundle = output / 'bundle'
    bundle.mkdir()
    process = None
    report = {'passed': False, 'gui_version': 'not observed; no version CLI assumed'}
    try:
        report['archive_sha256'] = hashlib.sha256(archive.read_bytes()).hexdigest()
        version = re.search(r'^version:\s*(\S+)', source.read_text(), re.MULTILINE)
        if not version:
            raise RuntimeError('source pubspec version missing')
        report['source_pubspec_version'] = version.group(1)
        report['version_provenance'] = 'same-checkout pubspec; not a GUI-reported version'
        with tarfile.open(archive) as package:
            package.extractall(bundle, filter='data')
        binary = bundle / 'nntdrive'
        if not binary.is_file() or not (bundle / 'lib/libnntdrive_ffi.so').is_file():
            raise RuntimeError('release executable/native library missing')
        binary.chmod(binary.stat().st_mode | 0o100)
        with (output / 'client.log').open('w') as log:
            process = subprocess.Popen([str(binary)], cwd=bundle, env=env,
                                       stdout=log, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            report['pid'] = process.pid
            deadline = time.monotonic() + timeout
            visible_since = None
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError(f'client exited early: {process.returncode}')
                windows = subprocess.run(['xdotool', 'search', '--onlyvisible', '--pid',
                                          str(process.pid)], env=env, capture_output=True,
                                         text=True, timeout=5)
                ids = windows.stdout.split() if windows.returncode == 0 else []
                if ids:
                    visible_since = visible_since or time.monotonic()
                    if time.monotonic() - visible_since >= 3:
                        report['window_ids'] = ids
                        report['window_title'] = subprocess.check_output(
                            ['xdotool', 'getwindowname', ids[0]], env=env,
                            text=True, timeout=5).strip()
                        subprocess.run(['import', '-window', 'root', str(output / 'screenshot.png')],
                                       env=env, check=True, timeout=10)
                        if process.poll() is not None:
                            raise RuntimeError('client exited during capture')
                        report['passed'] = True
                        break
                else:
                    visible_since = None
                time.sleep(0.25)
            if not report['passed']:
                raise RuntimeError('no sustained visible window owned by live client PID')
    except Exception as error:
        report['error'] = str(error)
        raise
    finally:
        # Best-effort failure screenshot as well; logs/report survive all failures.
        if not (output / 'screenshot.png').exists():
            try:
                subprocess.run(['import', '-window', 'root', str(output / 'screenshot.png')],
                               env=env, capture_output=True, timeout=10)
            except (OSError, subprocess.TimeoutExpired):
                pass
        if process is not None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=5)
            except ProcessLookupError:
                pass
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('pubspec', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--timeout', type=int, default=30)
    args = parser.parse_args()
    if not 3 <= args.timeout <= 120:
        parser.error('timeout must be 3..120 seconds')
    smoke(args.archive.resolve(), args.pubspec.resolve(), args.output, args.timeout)
