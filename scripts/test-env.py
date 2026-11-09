#!/usr/bin/env python3
"""Bounded test environment launcher. Python standard library only."""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = 'test-environments.yml'
TARGETS = {'linux-core', 'linux-client', 'android-build', 'android-emulator',
           'windows-build', 'windows-runtime'}


class Failure(Exception):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise Failure('GitHub redirect refused')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('target', choices=sorted(TARGETS))
    parser.add_argument('--repo', default='ravand1990/nntdrive')
    parser.add_argument('--ref', help='explicit trusted branch or tag (not a raw commit SHA)')
    parser.add_argument('--sha', help='expected full 40-character commit SHA')
    parser.add_argument('--timeout', type=int, help='shorten, never extend target deadline')
    args = parser.parse_args()
    matrix = json.loads((ROOT / 'envs/matrix.yaml').read_text())
    if (matrix['schema_version'] != 1 or set(matrix['targets']) != TARGETS
            or matrix['hosted_command']['workflow'] != WORKFLOW):
        raise Failure('Unsupported matrix schema/targets')
    target = matrix['targets'][args.target]
    limit = target['timeout_seconds']
    if args.timeout is not None:
        if not 1 <= args.timeout <= limit:
            raise Failure('Timeout must be positive and no larger than target budget')
        limit = args.timeout
    if target['executor'] == 'blocked':
        raise Failure(target['reason'])
    if target['executor'] == 'local':
        # Do not pass the dispatch credential into build tools/containers.
        env = dict(os.environ)
        env.pop('GITHUB_TOKEN', None)
        process = subprocess.Popen(target['command'], cwd=ROOT, env=env,
                                   start_new_session=True)
        try:
            return process.wait(timeout=limit)
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            # Stop the shell and its children, allowing the wrapper's EXIT trap
            # a bounded grace period to tear down its own Compose project.
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
            raise Failure('Local deadline/interruption; inspect wrapper cleanup before retry') from None
    if target['executor'] != 'github':
        raise Failure('Unknown executor')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repo):
        raise Failure('Invalid repository')
    if not args.ref or not args.sha or not re.fullmatch(r'[0-9a-f]{40}', args.sha):
        raise Failure('Hosted targets require --ref and full lowercase --sha')
    if re.fullmatch(r'[0-9a-fA-F]{7,40}', args.ref):
        raise Failure('--ref must be a branch or tag, not a raw commit SHA')
    token = os.environ.get('GITHUB_TOKEN')
    if not token:
        raise Failure('GITHUB_TOKEN is required at runtime (Actions write, Contents read)')
    deadline = time.monotonic() + limit
    def check_deadline(*_):
        if time.monotonic() >= deadline:
            raise Failure('Deadline exceeded; remote run is NOT cancelled')

    # Socket timeouts are per operation, not a wall-clock bound (DNS and
    # trickling responses can exceed them). Fail closed on unsupported hosts.
    if not hasattr(signal, 'setitimer'):
        raise Failure('Hosted deadline enforcement requires POSIX setitimer')
    signal.signal(signal.SIGALRM, check_deadline)
    signal.setitimer(signal.ITIMER_REAL, limit)
    base = f'https://api.github.com/repos/{args.repo}'
    opener = urllib.request.build_opener(NoRedirect())

    def api(path, payload=None) -> Any:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise Failure('Deadline exceeded; remote run is NOT cancelled')
        request = urllib.request.Request(base + path,
            data=None if payload is None else json.dumps(payload).encode(),
            headers={'Authorization': 'Bearer ' + token,
                     'Accept': 'application/vnd.github+json',
                     'X-GitHub-Api-Version': '2022-11-28',
                     'Content-Type': 'application/json'},
            method='GET' if payload is None else 'POST')
        try:
            with opener.open(request, timeout=min(30, remaining)) as response:
                body = response.read()
                check_deadline()
                data = json.loads(body) if body else None
                check_deadline()
                return data
        except urllib.error.HTTPError as error:
            raise Failure(f'GitHub HTTP {error.code}; no response body logged') from None
        except (OSError, ValueError):
            raise Failure('GitHub transport/JSON failure; no credentials logged') from None

    def pages(path, key):
        result = []
        for page in range(1, 101):
            data = api(path + ('&' if '?' in path else '?') + f'per_page=100&page={page}')
            batch = data[key]
            result.extend(batch)
            if len(batch) < 100:
                return result
        raise Failure('Pagination bound exceeded')

    def resolve():
        commit = api('/commits/' + urllib.parse.quote(args.ref, safe=''))
        if commit['sha'] != args.sha:
            raise Failure('Ref does not resolve to expected SHA')

    resolve()
    correlation = uuid.uuid4().hex
    title = f'test-env:{args.target}:{correlation}'
    api(f'/actions/workflows/{WORKFLOW}/dispatches',
        {'ref': args.ref, 'inputs': {'target': args.target,
         'expected_sha': args.sha, 'correlation': correlation}})
    print(f'Dispatched {title} expected_head={args.sha}', flush=True)
    run_id = None
    while True:
        if run_id is None:
            runs = pages(f'/actions/workflows/{WORKFLOW}/runs?event=workflow_dispatch', 'workflow_runs')
            matches = [r for r in runs if r.get('display_title') == title
                       and r.get('head_sha') == args.sha and r.get('event') == 'workflow_dispatch']
            if len(matches) > 1:
                raise Failure('Ambiguous dispatch correlation')
            if matches:
                run_id = matches[0]['id']
                print(f'https://github.com/{args.repo}/actions/runs/{run_id}', flush=True)
        if run_id is not None:
            run = api(f'/actions/runs/{run_id}')
            if (run['head_sha'] != args.sha or run['display_title'] != title
                    or run['event'] != 'workflow_dispatch' or run.get('run_attempt') != 1):
                raise Failure('Run identity/attempt mismatch')
            if run['status'] == 'completed':
                if run['conclusion'] != 'success':
                    raise Failure('Remote run did not succeed: ' + str(run['conclusion']))
                resolve()
                jobs = pages(f'/actions/runs/{run_id}/attempts/1/jobs', 'jobs')
                required = {'identity', 'analyze', 'build-linux', 'build-android',
                            'build-windows', 'android-native-smoke', 'windows-app-smoke'}
                if args.target == 'linux-client':
                    required.add('linux-runtime')
                for name in sorted(required):
                    # Reusable workflow jobs may be reported as clients / job.
                    names = {name} if name in {'identity', 'linux-runtime'} else {name, 'clients / ' + name}
                    found = [j for j in jobs if j['name'] in names]
                    if (len(found) != 1 or found[0]['status'] != 'completed'
                            or found[0]['conclusion'] != 'success'):
                        raise Failure('Expected exactly one successful job: ' + name)
                artifacts = pages(f'/actions/runs/{run_id}/artifacts', 'artifacts')
                if args.target == 'linux-client':
                    evidence = [a for a in artifacts
                                if a['name'] == 'nntdrive-linux-runtime-evidence'
                                and not a['expired'] and a.get('size_in_bytes', 0) > 0]
                    if len(evidence) != 1:
                        raise Failure('Expected exactly one nonexpired Linux runtime evidence artifact')
                matches = [a for a in artifacts if a['name'] == target['artifact']
                           and not a['expired'] and a.get('size_in_bytes', 0) > 0]
                if len(matches) != 1:
                    raise Failure('Expected exactly one nonexpired target artifact')
                check_deadline()
                print(f'https://github.com/{args.repo}/actions/runs/{run_id}/artifacts/{matches[0]["id"]}')
                print(target['coverage'])
                check_deadline()
                return 0
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise Failure('Deadline exceeded; remote run is NOT cancelled')
        time.sleep(min(5, remaining))


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (Failure, KeyError, TypeError, ValueError) as error:
        # Unexpected API shapes fail closed without dumping request/response data.
        message = str(error) if isinstance(error, Failure) else 'Invalid matrix/API response shape'
        print('test-env: ' + message, file=sys.stderr)
        sys.exit(1)
    finally:
        if hasattr(signal, 'setitimer'):
            signal.setitimer(signal.ITIMER_REAL, 0)
