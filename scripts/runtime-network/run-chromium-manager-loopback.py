#!/usr/bin/env python3
"""Run the signed manager's Chromium QA path on one owned profile and proxy."""

import argparse
from contextlib import contextmanager
from importlib import import_module
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import time
import uuid

QA = import_module('run-chromium-headless-loopback')
CUSTODY = import_module('collect-chromium-loopback-custody')
ANALYZE = import_module('analyze-chromium-loopback-lifecycle')
CORE = CUSTODY.CORE
HERE = Path(__file__).resolve().parent


@contextmanager
def control_process(args, diagnostics):
    with diagnostics.open('xb') as log:
        child = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log)
        try:
            yield child
        finally:
            child.stdin.close()
            try:
                child.wait(timeout=8)
            except subprocess.TimeoutExpired:
                child.terminate()
                try:
                    child.wait(timeout=5)
                finally:
                    child.stdout.close()
                raise
            child.stdout.close()


def receive(child, timeout=20):
    pending = getattr(child, 'pending_reply', b'')
    deadline = time.monotonic() + timeout
    while b'\n' not in pending:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([child.stdout], [], [], remaining)[0]:
            raise TimeoutError('control-response-timeout')
        data = os.read(child.stdout.fileno(), 8192)
        if not data or len(pending) + len(data) > 262144:
            raise ValueError('invalid-control-response')
        pending += data
    line, child.pending_reply = pending.split(b'\n', 1)
    return json.loads(line)


def send(child, line):
    child.stdin.write(line.encode() + b'\n')
    child.stdin.flush()


def run(stage, archive_sha, root, output):
    candidate = CORE.load(stage)
    archive = Path(candidate['archive'])
    CORE.require(QA.retained_stage(archive) == stage.parent and candidate['sha256'] == archive_sha,
                 'wrong-candidate')
    subprocess.run([sys.executable, '-B', str(HERE / 'run-chromium-headless-loopback.py'),
                    '--zip', str(archive), '--sha256', archive_sha, '--retained-bundle', '--check-only'],
                   stdout=subprocess.DEVNULL, check=True, timeout=60)
    manager = Path(candidate['app']) / 'Contents/MacOS/NeAntik'
    CORE.require(QA.digest(manager) == candidate['managerSignedSHA256'], 'manager-hash-mismatch')
    admission = subprocess.run([sys.executable, '-B', str(HERE.parent / 'native-qa-readiness.py'), '--check'],
                               capture_output=True, timeout=10)
    readiness = json.loads(admission.stdout)
    CORE.write_new(output / 'admission.json', readiness)
    if admission.returncode or readiness.get('eligibleForAttempt') is not True:
        return 75

    with control_process([sys.executable, '-B', str(HERE / 'run-chromium-headless-loopback.py'),
                          '--serve-manager-fixture'], output / 'fixture.stderr') as fixture:
        ready = receive(fixture)
        CORE.require(ready['status'] == 'ready', 'fixture-not-ready')
        port = ready['proxyPort']
        CORE.write_new(output / 'fixture-ready.json', ready)
        with control_process([str(manager), '--neantik-mcp-stdio', '--neantik-mcp-loopback-qa-v1',
                              str(root), str(port)], output / 'manager.stderr') as mcp:
            sequence = 0

            def rpc(method, params):
                nonlocal sequence
                sequence += 1
                send(mcp, json.dumps(dict(jsonrpc='2.0', id=sequence, method=method, params=params)))
                reply = receive(mcp)
                CORE.require(reply.get('id') == sequence and 'error' not in reply
                             and not reply['result'].get('isError'), 'mcp-operation-refused')
                return reply['result']

            def tool(name, args):
                return rpc('tools/call', dict(name=name, arguments=args))['structuredContent']

            rpc('initialize', dict(protocolVersion='2025-11-25', capabilities={},
                clientInfo={'name': 'owned-chromium-route-qa', 'version': '1'}))
            send(mcp, '{"jsonrpc":"2.0","method":"notifications/initialized"}')
            created = tool('profile_create', {
                'name': f"2026 QA — {candidate['version']}/{candidate['managerSignedSHA256'][:12]}",
                'engine': 'chromium', 'changes': {'startURL': 'about:blank'},
                'proxy': {'kind': 'http', 'host': '127.0.0.1', 'port': port}})
            profile_id = uuid.UUID(created['id'])
            profile_args = {'profileID': str(profile_id)}
            evidence = {'phases': []}

            def launch(label):
                profile = tool('profile_get', profile_args)
                port_file = root / 'Profiles' / str(profile_id).upper() / 'BrowserData' / 'DevToolsActivePort'
                try:
                    previous_endpoint = port_file.read_bytes()
                except FileNotFoundError:
                    previous_endpoint = None
                start = tool('profile_start', dict(profile_args, expectedRevision=profile['revision']))
                try:
                    CORE.require(start.get('qaOnly') is True, 'manager-did-not-use-qa-route')
                    deadline = time.monotonic() + 12
                    while True:
                        try:
                            if port_file.read_bytes() != previous_endpoint:
                                break
                        except FileNotFoundError:
                            pass
                        if time.monotonic() >= deadline:
                            raise TimeoutError('fresh-devtools-endpoint-not-observed')
                        time.sleep(.1)
                    custody = CUSTODY.collect(stage, archive_sha, root, profile_id, mcp.pid, port)
                    CORE.write_new(output / f'{label}.json', custody)
                except Exception:
                    tool('profile_stop', profile_args)
                    raise
                evidence[label] = custody
                return custody

            def snapshot(command='status'):
                send(fixture, command)
                return receive(fixture)

            def page(name, label, mode, control='status'):
                before = snapshot(control)
                result = subprocess.run(['node', str(HERE / 'observe-chromium-loopback-page.mjs'),
                                         str(output / f'{label}.json'), str(output / 'fixture-ready.json'), mode],
                                        capture_output=True, timeout=30)
                if result.returncode:
                    with (output / f'phase-{name}.stderr').open('xb') as diagnostic:
                        diagnostic.write(result.stderr)
                    CORE.write_new(output / f'phase-{name}-failure.json', {'before': before, 'after': snapshot()})
                    result.check_returncode()
                phase = {'name': name, 'before': before, 'page': json.loads(result.stdout), 'after': snapshot()}
                CORE.write_new(output / f'phase-{name}.json', phase)
                evidence['phases'].append(phase)

            def stop(custody):
                tool('profile_stop', profile_args)
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline:
                    status = tool('profile_status', profile_args)
                    if status['processState'] == 'stopped':
                        return CUSTODY.observe_stop(custody, Path(custody['browserData']), status)
                    time.sleep(.2)
                raise TimeoutError('owned-browser-stop-timeout')

            active = None
            try:
                active = launch('firstLaunch')
                page('fresh', 'firstLaunch', 'fresh')
                page('refused', 'firstLaunch', 'refused', 'refuse')
                page('recovered', 'firstLaunch', 'restored', 'recover')
                evidence['firstStop'] = stop(active)
                active = None
                active = launch('reopened')
                page('reopened', 'reopened', 'restored')
                page('webrtc', 'reopened', 'rtc')
                evidence['finalStop'] = stop(active)
                active = None
            finally:
                if active is not None:
                    stop(active)
            evidence['afterFinalStop'] = snapshot()
            evidence['stunCanary'] = ready['stunCanary']
        send(fixture, 'stop')
        evidence['fixtureTerminal'] = receive(fixture)
    CORE.write_new(output / 'observations.json', evidence)
    CORE.require(fixture.returncode == 0, 'fixture-failed-to-stop')
    CORE.write_new(output / 'result.json', ANALYZE.evaluate(evidence))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--archive-sha256', required=True)
    args = parser.parse_args()
    identity = uuid.uuid4()
    output = Path('/private/tmp') / f'neantik-chromium-manager-run-{identity}'
    root = Path('/private/tmp') / f'neantik-{identity}'
    for directory in (output, root):
        directory.mkdir(mode=0o700)
    print(output, flush=True)
    try:
        return run(args.candidate, args.archive_sha256, root, output)
    except (OSError, KeyError, ValueError, TypeError, subprocess.SubprocessError) as error:
        parser.exit(1, f'Chromium manager QA stopped ({type(error).__name__}).\n')


if __name__ == '__main__':
    raise SystemExit(main())
