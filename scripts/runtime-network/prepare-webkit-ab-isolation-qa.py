#!/usr/bin/env python3
"""Prepare a loopback-only same-origin A-B-A fixture for owned WebKit."""
from __future__ import annotations

import argparse
import copy
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import secrets
import stat
import sys
import tempfile
import time
import uuid

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'scripts'))
sys.path.insert(0, str(REPO / 'Experiments/OwnedWebKitNetworkBoundary'))
import dns_tls_fixture  # noqa: E402
import tls_fixture  # noqa: E402

BLANK_PROFILE_NAME = 'NeAntik QA Template'
PRIVATE_TMP = Path('/private/tmp')
TUPLE_COUNT = 11
M2_RESIDUE = 2
MAX_SEED = 2_147_483_647
PHASE_TIMEOUT_SECONDS = 60.0
PHASE_POLL_INTERVAL_SECONDS = 0.1
PUBLIC_SITE_TARGETS = {'google': 'https://www.google.com/', 'booking': 'https://www.booking.com/'}


class FixtureError(ValueError):
    pass


def digest(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def private_file(path: Path, data: bytes, mode: int = 0o600) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, 'O_NOFOLLOW', 0), mode)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
    except BaseException:
        path.unlink(missing_ok=True)
        raise


def read_blank_template(path: Path) -> dict:
    if path.is_symlink():
        raise FixtureError('template_symlink_refused')
    file = path / 'profiles.json' if path.is_dir() else path
    if file.is_symlink() or not file.is_file() or file.stat().st_size > 16 * 1024 * 1024:
        raise FixtureError('template_file_invalid')

    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise FixtureError('duplicate_json_key')
            result[key] = value
        return result

    try:
        document = json.loads(file.read_text(encoding='utf-8'), object_pairs_hook=unique)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise FixtureError('template_unreadable') from error
    if not isinstance(document, dict):
        raise FixtureError('one_app_produced_webkit_template_required')
    profiles = document.get('profiles')
    if (document.get('schemaVersion') not in (2, 5)
            or not isinstance(profiles, list) or len(profiles) != 1
            or not isinstance(profiles[0], dict)):
        raise FixtureError('one_app_produced_webkit_template_required')
    profile = profiles[0]
    identity = profile.get('identity') if isinstance(profile, dict) else None
    if (profile.get('name') != BLANK_PROFILE_NAME or profile.get('engine') != 'webkit'
            or profile.get('webKitRuntimeGeneration') not in ('system', 'isolatedV1')
            or (document['schemaVersion'] == 2 and profile.get('webKitRuntimeGeneration') != 'system')
            or profile.get('startURL') != 'about:blank' or profile.get('proxy') is not None
            or not isinstance(identity, dict) or profile.get('note') or profile.get('tags')
            or any(key in profile for key in ('password', 'proxyPassword', 'auth'))):
        raise FixtureError('app_produced_blank_profile_contract_changed')
    return profile


def _m2_seed() -> int:
    # Keep both profiles in the same hardware cohort while assigning different
    # current-issuance seeds, so this test isolates storage rather than device class.
    max_ordinal = (MAX_SEED - M2_RESIDUE) // TUPLE_COUNT
    return secrets.randbelow(max_ordinal) * TUPLE_COUNT + M2_RESIDUE


def profile_bytes(blank: dict, *, origin_url: str, proxy_ports: tuple[int, int],
                  peer_control: bool = False) -> bytes:
    if not origin_url.startswith('https://') or len(set(proxy_ports)) != 2:
        raise FixtureError('same_https_origin_and_two_distinct_proxy_ports_required')
    if any(type(port) is not int or not 1 <= port <= 65535 for port in proxy_ports):
        raise FixtureError('proxy_port_invalid')
    now = dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z')
    profiles = []
    seeds = set()
    for letter, port in zip(('A', 'B'), proxy_ports):
        profile = copy.deepcopy(blank)
        seed = _m2_seed()
        while seed in seeds:
            seed = _m2_seed()
        seeds.add(seed)
        profile.update(
            id=str(uuid.uuid4()).upper(),
            name=f'Owned WebKit {letter} isolation QA',
            startURL=origin_url,
            startupMode='restoreSession',
            webKitRuntimeGeneration='isolatedV1',
            proxy={'kind': 'http', 'host': '127.0.0.1', 'port': port, 'username': ''},
            identity={
                **profile['identity'], 'seed': seed,
                'catalogVersion': 1, 'issuanceVersion': 2,
                'deviceTupleID': 'macbook-air-m2',
            },
            createdAt=now, updatedAt=now, lastLaunchedAt=None, revision=1,
        )
        if peer_control:
            profile["webKitBlockPeerConnections"] = letter == "A"
        profiles.append(profile)
    if profiles[0]['identity']['seed'] == profiles[1]['identity']['seed']:
        raise FixtureError('identity_seed_collision')
    return (json.dumps({'schemaVersion': 6 if peer_control else 5, 'profiles': profiles}, ensure_ascii=False,
                       sort_keys=True, separators=(',', ':')) + '\n').encode()


def peer_probe_fragment(port: int, nonce: str) -> str:
    """Loopback-only peer probe; exposes booleans/errors, never ICE addresses."""
    if type(port) is not int or not 1024 <= port <= 65535:
        raise FixtureError('peer_probe_loopback_port_invalid')
    if not isinstance(nonce, str) or len(nonce) != 32 or any(c not in '0123456789abcdef' for c in nonce):
        raise FixtureError('peer_probe_nonce_invalid')
    return f"""<pre id="peer-probe">pending</pre><script>
(async () => {{
  const run = async w => {{
    const result = {{constructorPresent: typeof w.RTCPeerConnection === 'function', created: false, error: null}};
    if (!result.constructorPresent) return result;
    let pc;
    try {{
      pc = new w.RTCPeerConnection({{iceServers: [{{urls: 'stun:127.0.0.1:{port}'}}]}});
      pc.createDataChannel('local-probe');
      await pc.setLocalDescription(await pc.createOffer());
      result.created = true;
      await new Promise(resolve => setTimeout(resolve, 1200));
    }} catch (error) {{ result.error = String(error && error.name || 'Error'); }}
    finally {{ if (pc) pc.close(); }}
    return result;
  }};
  const frame = document.createElement('iframe'); frame.src = 'about:blank';
  document.body.appendChild(frame);
  const bounded = w => Promise.race([run(w), new Promise(resolve => setTimeout(() => resolve({{timeout: true}}), 5000))]);
  const result = {{top: await bounded(window), frame: await bounded(frame.contentWindow)}};
  document.getElementById('peer-probe').textContent = JSON.stringify(result);
  const category = r => r.timeout ? 'timeout' : !r.constructorPresent ? 'absent' : r.created ? 'created' : 'error';
  fetch('/qa-peer/{nonce}/' + category(result.top) + '/' + category(result.frame),
        {{cache: 'no-store', credentials: 'same-origin'}}).catch(() => {{}});
}})();
</script>"""


def gpu_probe_fragment(nonce: str) -> str:
    """Ask only for an adapter and report a bounded category to the owned origin."""
    if not isinstance(nonce, str) or len(nonce) != 32 or any(c not in '0123456789abcdef' for c in nonce):
        raise FixtureError('gpu_probe_nonce_invalid')
    return f'''<pre id="gpu-probe">pending</pre><script>
(async () => {{
  let result = 'absent';
  if (navigator.gpu && typeof navigator.gpu.requestAdapter === 'function') {{
    try {{
      result = await Promise.race([
        navigator.gpu.requestAdapter().then(adapter => adapter ? 'adapter' : 'unavailable'),
        new Promise(resolve => setTimeout(() => resolve('timeout'), 5000))]);
    }} catch (_) {{ result = 'error'; }}
  }}
  document.getElementById('gpu-probe').textContent = result;
  fetch('/qa-gpu/{nonce}/' + result, {{cache: 'no-store', credentials: 'same-origin'}}).catch(() => {{}});
}})();
</script>'''


def prepare(template: Path, *, peer_control: bool = False, peer_stun_port: int | None = None,
            gpu_probe: bool = False):
    blank = read_blank_template(template)
    if peer_control != (peer_stun_port is not None):
        raise FixtureError('peer_control_requires_loopback_probe_port')
    stage = Path(tempfile.mkdtemp(prefix='neantik-webkit-ab-stage-', dir=PRIVATE_TMP))
    # The production-ID diagnostic runtime accepts only this owner-only root
    # namespace. Keep the QA A/B profile store isolated from user app support.
    root = Path(tempfile.mkdtemp(prefix='neantik-production-diagnostic-', dir=PRIVATE_TMP))
    os.chmod(stage, 0o700)
    os.chmod(root, 0o700)
    dns = origin = validator = None
    tunnels = []
    try:
        dns = dns_tls_fixture.DNS.DNSFixture(root, name_suffix='.neantik-dns.invalid')
        host = dns.names['proxy-success']
        certs = tls_fixture.certificates(root / 'certificates', '127.0.0.1', host)
        nonce = secrets.token_hex(16)
        page = dns_tls_fixture.persistence_page(nonce)
        if peer_control:
            page += peer_probe_fragment(peer_stun_port, nonce)
        if gpu_probe:
            page += gpu_probe_fragment(nonce)
        origin = tls_fixture.TLSOrigin(
            '127.0.0.1', page, certs,
            persistence_nonce=nonce,
        )
        validator = dns_tls_fixture.OwnedDNSValidator(dns, host, origin)
        authority = f'{host}:{origin.port}'
        tunnels = [
            tls_fixture.Tunnel({authority: origin}, None, dns_validator=validator),
            tls_fixture.Tunnel({authority: origin}, None, dns_validator=validator),
        ]
        url = f'https://{authority}/'
        payload = profile_bytes(blank, origin_url=url,
                                proxy_ports=(tunnels[0].port, tunnels[1].port), peer_control=peer_control)
        seed_hash = hashlib.sha256(payload).hexdigest()
        private_file(stage / 'profiles.seed.json', payload, 0o400)
        private_file(root / 'profiles.json', payload)
        private_file(root / 'profiles.previous.json', payload)
        ca_der = certs / 'ca.der'
        plan = {
            'schemaVersion': 1,
            'status': 'offline-fixture-ready; browser-not-started',
            'scope': 'two synthetic owned-WebKit profiles; same HTTPS origin; separate loopback proxies and browser stores',
            'stage': str(stage), 'root': str(root), 'seedSHA256': seed_hash,
            'peerControl': peer_control,
            'gpuProbe': gpu_probe,
            'peerProbeLoopbackPort': peer_stun_port,
            'profileCount': 2, 'profileIDs': [p['id'] for p in json.loads(payload)['profiles']],
            'identitySeedsDistinct': True, 'sameDeviceTuple': 'macbook-air-m2',
            'proxyA': f'127.0.0.1:{tunnels[0].port}',
            'proxyB': f'127.0.0.1:{tunnels[1].port}',
            'proxyAuthorization': 'absent; header rejected', 'dnsPort': dns.dns.server_address[1],
            'sameOrigin': url, 'persistenceNonceSHA256': hashlib.sha256(nonce.encode()).hexdigest(),
            'qaTrustAnchorDER': str(ca_der),
            'qaTrustAnchorSHA256': hashlib.sha256(ca_der.read_bytes()).hexdigest(),
            'fixtureSourceSHA256': digest(Path(__file__)),
            'expectedPhases': [
                {'phase': 'A1', 'profile': 'A', 'state': 'initial'},
                {'phase': 'B1', 'profile': 'B', 'state': 'initial'},
                {'phase': 'A2', 'profile': 'A', 'state': 'restored'},
            ],
            'phaseCapture': {
                'timeoutSeconds': PHASE_TIMEOUT_SECONDS,
                'rule': 'Keep each profile running until its phase command returns phase-recorded; the fixture waits for the matching page/state responses and refuses contaminated snapshots.',
            },
            'faultControls': ['proxy-A-refuse', 'proxy-A-recover', 'proxy-B-refuse', 'proxy-B-recover'],
        }
        private_file(stage / 'run-plan.json', (json.dumps(plan, sort_keys=True, indent=2) + '\n').encode())
        return plan, dns, origin, tunnels, validator
    except BaseException:
        for tunnel in reversed(tunnels):
            tunnel.stop()
        if origin is not None:
            origin.stop()
        if dns is not None:
            dns.close()
        import shutil
        shutil.rmtree(stage)
        shutil.rmtree(root)
        raise


def _counts(origin, tunnels, validator):
    return {
        'origin': origin.snapshot(),
        'proxyA': tunnels[0].snapshot(),
        'proxyB': tunnels[1].snapshot(),
        'proxyAAuthorizedOrigins': tunnels[0].authenticated_for(origin),
        'proxyBAuthorizedOrigins': tunnels[1].authenticated_for(origin),
        'dns': validator.snapshot(),
    }


def _phase_observation(name, prior, current):
    expected_state = {'A1': (1, 0), 'B1': (1, 0), 'A2': (0, 1)}[name]
    expected_proxy = 'A' if name in ('A1', 'A2') else 'B'
    origin_delta = {key: current['origin'].get(key, 0) - prior['origin'].get(key, 0)
                    for key in ('pageResponses', 'stateInitial', 'stateRestored')}
    prior_trace = prior['origin'].get('requestTrace', [])
    current_trace = current['origin'].get('requestTrace', [])
    auth_a = current['proxyAAuthorizedOrigins'] - prior['proxyAAuthorizedOrigins']
    auth_b = current['proxyBAuthorizedOrigins'] - prior['proxyBAuthorizedOrigins']
    route_ok = auth_a > 0 and auth_b == 0 if expected_proxy == 'A' else auth_b > 0 and auth_a == 0
    state_ok = (origin_delta['pageResponses'] == 1
                and (origin_delta['stateInitial'], origin_delta['stateRestored']) == expected_state)
    response_count = (origin_delta['stateInitial'] + origin_delta['stateRestored'])
    if origin_delta['pageResponses'] > 1 or response_count > 1:
        classification = 'contaminated'
    elif route_ok and state_ok:
        classification = 'pass'
    elif (auth_b > 0 if expected_proxy == 'A' else auth_a > 0) or (
            origin_delta['pageResponses'] == 1 and response_count == 1):
        classification = 'fail'
    else:
        classification = 'pending'
    return {
        'phase': name,
        'classification': classification,
        'expectedState': 'initial' if expected_state[0] else 'restored',
        'stateDelta': origin_delta,
        'proxyAAuthorizedOriginDelta': auth_a,
        'proxyBAuthorizedOriginDelta': auth_b,
        'originRequestTrace': current_trace[len(prior_trace):],
        'routeBoundary': 'PASS' if route_ok else 'FAIL',
        'storageBoundary': 'PASS' if state_ok else 'FAIL',
    }


def _wait_for_phase(name, prior, read_counts, *, timeout_seconds=PHASE_TIMEOUT_SECONDS,
                    poll_interval=PHASE_POLL_INTERVAL_SECONDS):
    deadline = time.monotonic() + timeout_seconds
    while True:
        current = read_counts()
        observation = _phase_observation(name, prior, current)
        if observation['classification'] != 'pending':
            return observation, current
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            observation['classification'] = 'timeout'
            return observation, current
        time.sleep(min(poll_interval, remaining))


def public_site_page(nonce: str, target: str) -> str:
    """Closed-list optional public-site smoke, with no arbitrary URL input."""
    if target not in PUBLIC_SITE_TARGETS:
        raise FixtureError('public_site_target_invalid')
    # persistence_page validates the nonce; delay leaves its acknowledgement a
    # chance to settle before the isolated profile navigates to the chosen site.
    return (dns_tls_fixture.persistence_page(nonce)
            + '<script>setTimeout(() => location.replace('
            + json.dumps(PUBLIC_SITE_TARGETS[target]) + '), 350);</script>')


def serve(template: Path, *, peer_control: bool = False, peer_stun_port: int | None = None,
          gpu_probe: bool = False, public_site_controls: bool = False) -> int:
    plan, dns, origin, tunnels, validator = prepare(template, peer_control=peer_control, peer_stun_port=peer_stun_port, gpu_probe=gpu_probe)
    root = Path(plan['root'])
    phases = []
    phase_names = ('A1', 'B1', 'A2')
    prior = _counts(origin, tunnels, validator)
    private_file(root / 'phase-results.json', b'{"phases":[]}\n')
    try:
        print(json.dumps({'status': 'ready', **plan}, sort_keys=True), flush=True)
        while True:
            line = sys.stdin.readline(1025)
            if not line:
                raise FixtureError('stdin_closed_before_explicit_stop')
            if len(line) > 1024:
                raise FixtureError('control_line_too_large')
            command = json.loads(line)
            if command == {'action': 'stop'}:
                break
            if command == {'action': 'status'}:
                print(json.dumps({'status': 'snapshot', 'counts': _counts(origin, tunnels, validator)},
                                 sort_keys=True), flush=True)
                continue
            if public_site_controls and command in ({'action': 'public-google'}, {'action': 'public-booking'}):
                target = command['action'].removeprefix('public-')
                origin.marker = public_site_page(origin.persistence_nonce, target)
                print(json.dumps({'status': 'public-site-selected', 'site': target}), flush=True)
                continue
            if command in ({'action': 'proxy-A-refuse'}, {'action': 'proxy-A-recover'},
                           {'action': 'proxy-B-refuse'}, {'action': 'proxy-B-recover'}):
                which = 0 if command['action'].startswith('proxy-A') else 1
                tunnels[which].refusing = command['action'].endswith('refuse')
                print(json.dumps({'status': 'control-applied', 'action': command['action']},
                                 sort_keys=True), flush=True)
                continue
            if set(command) != {'action', 'phase'} or command.get('action') != 'phase':
                raise FixtureError('unsupported_control_action')
            name = command.get('phase')
            expected_index = len(phases)
            if expected_index >= len(phase_names) or name != phase_names[expected_index]:
                raise FixtureError('phase_order_must_be_A1_B1_A2')
            row, current = _wait_for_phase(name, prior, lambda: _counts(origin, tunnels, validator))
            if row['classification'] == 'timeout':
                print(json.dumps({'status': 'phase-timeout', **row}, sort_keys=True), flush=True)
                continue
            if row['classification'] == 'contaminated':
                print(json.dumps({'status': 'phase-contaminated', **row}, sort_keys=True), flush=True)
                continue
            phases.append(row)
            private_file(root / f'phase-{name}.json', (json.dumps(row, sort_keys=True) + '\n').encode())
            results = {'schemaVersion': 1, 'candidateSHA256': None, 'phases': phases,
                       'status': 'partial' if len(phases) < 3 else
                       'PASS' if all(p['routeBoundary'] == p['storageBoundary'] == 'PASS' for p in phases)
                       else 'FAIL'}
            temporary = root / 'phase-results.next.json'
            if temporary.exists():
                temporary.unlink()
            private_file(temporary, (json.dumps(results, sort_keys=True, indent=2) + '\n').encode())
            os.replace(temporary, root / 'phase-results.json')
            prior = current
            print(json.dumps({'status': 'phase-recorded', **row}, sort_keys=True), flush=True)
    finally:
        tunnel_closed = [t.stop() for t in reversed(tunnels)]
        origin_closed = origin.stop()
        dns_closed = dns.close()
        print(json.dumps({'status': 'fixture-stopped',
                          'allChannelsDrained': all(tunnel_closed) and origin_closed and dns_closed,
                          'finalCounts': _counts(origin, tunnels, validator),
                          'phaseCount': len(phases)}, sort_keys=True), flush=True)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--template', type=Path, required=True,
                        help='Exact app-produced blank isolatedV1 profiles.json')
    parser.add_argument('--peer-control', action='store_true',
                        help='Seed A with peer connections blocked and B as an enabled control')
    parser.add_argument('--peer-stun-port', type=int, help='Loopback-only UDP counter port')
    parser.add_argument('--gpu-probe', action='store_true', help='Request a WebGPU adapter on the synthetic page')
    parser.add_argument('--public-site-controls', action='store_true', help='Opt in to fixed Google/Booking redirects on local control commands')
    args = parser.parse_args()
    try:
        return serve(args.template, peer_control=args.peer_control, peer_stun_port=args.peer_stun_port,
                     gpu_probe=args.gpu_probe, public_site_controls=args.public_site_controls)
    except (FixtureError, OSError, ValueError, TypeError, json.JSONDecodeError) as error:
        print(json.dumps({'status': 'REFUSED', 'reason': str(error)}, sort_keys=True), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
