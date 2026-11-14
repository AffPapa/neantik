#!/usr/bin/env python3
"""Prepare a loopback-only same-origin A-B-A fixture for owned WebKit."""
from __future__ import annotations

import argparse
import copy
from contextlib import ExitStack
import datetime as dt
import hashlib
from importlib import import_module
import plistlib
import json
import os
from pathlib import Path
import re
import secrets
import stat
import subprocess
import sys
import tempfile
import time
import uuid

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'scripts'))
sys.path.insert(0, str(REPO / 'Experiments/OwnedWebKitNetworkBoundary'))
import dns_tls_fixture  # noqa: E402
import tls_fixture  # noqa: E402
from turn_tcp_fixture import TurnTCPFixture  # noqa: E402
import webkit_turns_qa_scope as turns_scope  # noqa: E402

BLANK_PROFILE_NAME = 'NeAntik QA Template'
PRIVATE_TMP = Path('/private/tmp')
PRIVATE_SUCCESSOR_DEV_VARIANT = 'OwnedWebKitSuccessorV1'
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


def bind_successor_candidate(plan: dict, receipt_path: Path, expected_sha: str) -> dict:
    """Associate observations with a frozen archive. The Swift launcher checks signatures."""
    if not isinstance(expected_sha, str) or not re.fullmatch(r'[0-9a-f]{64}', expected_sha):
        raise FixtureError('invalid_candidate_sha')
    stage = receipt_path.parent
    if (receipt_path.name != 'stage.json' or stage.parent != PRIVATE_TMP
            or not stage.name.startswith('neantik-owned-webkit-successor-qa-')
            or receipt_path.resolve(strict=True) != receipt_path):
        raise FixtureError('candidate_receipt_outside_private_stage')
    entry = receipt_path.lstat()
    stage_entry = stage.lstat()
    if (not stat.S_ISREG(entry.st_mode) or stat.S_IMODE(entry.st_mode) != 0o600
            or not stat.S_ISDIR(stage_entry.st_mode) or stat.S_IMODE(stage_entry.st_mode) != 0o700
            or entry.st_uid != os.geteuid() or stage_entry.st_uid != os.geteuid() or entry.st_size > 16384):
        raise FixtureError('candidate_receipt_not_private')
    raw = receipt_path.read_bytes()
    candidate = json.loads(raw)
    expected = {
        'stage': str(stage), 'app': str(stage / 'NeAntik.app'),
        'root': plan['root'], 'sha256': expected_sha, 'profileSeedSHA256': plan['seedSHA256'],
        'qaRuntimeVariant': PRIVATE_SUCCESSOR_DEV_VARIANT,
        'qaTrustAnchorSHA256': plan['qaTrustAnchorSHA256'],
        'qaTrustOrigin': plan['sameOrigin'].removesuffix('/'),
        'disposableDebugFixture': True, 'releaseQualified': False,
    }
    if (not isinstance(candidate, dict) or any(candidate.get(key) != value for key, value in expected.items())
            or candidate.get('disposableDebugFixture') is not True or candidate.get('releaseQualified') is not False):
        raise FixtureError('candidate_fixture_mismatch')
    expected_relay_policy = plan.get('turnControl', {}).get('challengeRelayPolicy', False)
    if candidate.get('qaRTCRelayQualification', False) is not expected_relay_policy:
        raise FixtureError('candidate_rtc_relay_scope_mismatch')
    if candidate.get('qaDetachedSession', False) is not plan.get('qaDetachedSession', False):
        raise FixtureError('candidate_detached_session_scope_mismatch')
    if candidate.get('qaDetachedSocketTransport', False) is not plan.get('qaDetachedSocketTransport', False):
        raise FixtureError('candidate_detached_socket_transport_mismatch')
    if candidate.get('qaMetalFrameTransport', False) is not plan.get('qaMetalFrameTransport', False):
        raise FixtureError('candidate_metal_frame_transport_mismatch')
    for key in ('managerSignedSHA256', 'hostSHA256', 'qaRuntimeBindingSHA256'):
        if not isinstance(candidate.get(key), str) or not re.fullmatch(r'[0-9a-f]{64}', candidate[key]):
            raise FixtureError('invalid_candidate_runtime_hash')
    archive = stage / 'NeAntik-private-owned-webkit-qa.zip'
    if (candidate.get('archive') != str(archive) or archive.is_symlink() or not archive.is_file()
            or digest(archive) != expected_sha):
        raise FixtureError('candidate_archive_mismatch')
    root = Path(plan['root'])
    if any(digest(root / name) != plan['seedSHA256'] for name in ('profiles.json', 'profiles.previous.json')):
        raise FixtureError('candidate_seed_drift')
    scope = turns_scope.load(root)
    scope_receipt = turns_scope.receipt(scope) if scope is not None else None
    if scope_receipt != plan.get(turns_scope.RECEIPT_KEY) or scope_receipt != candidate.get(turns_scope.RECEIPT_KEY):
        raise FixtureError('candidate_turns_scope_mismatch')
    marker = root / f'qa-{expected_sha[:12]}-single-start-consumed'
    if os.path.lexists(marker):
        raise FixtureError('candidate_already_consumed')
    if scope_receipt is not None:
        verify_bound_archive(candidate, {
            'archiveSHA256': expected_sha, 'root': str(root),
            'profileSeedSHA256': plan['seedSHA256'],
            'qaTrustAnchorSHA256': plan['qaTrustAnchorSHA256'],
            'qaTrustOrigin': plan['sameOrigin'].removesuffix('/'),
            'qaRuntimeVariant': plan['qaRuntimeVariant'],
            'qaDetachedSession': plan.get('qaDetachedSession', False),
            'qaDetachedSocketTransport': plan.get('qaDetachedSocketTransport', False),
            'qaMetalFrameTransport': plan.get('qaMetalFrameTransport', False),
            turns_scope.RECEIPT_KEY: scope_receipt,
        })
    return {'candidateSHA256': expected_sha, 'candidateApp': str(stage / 'NeAntik.app'),
            'candidateReceiptSHA256': hashlib.sha256(raw).hexdigest(),
            'managerSignedSHA256': candidate['managerSignedSHA256'], 'hostSHA256': candidate['hostSHA256'],
            'qaRuntimeBindingSHA256': candidate['qaRuntimeBindingSHA256'],
            **({turns_scope.RECEIPT_KEY: scope_receipt} if scope_receipt is not None else {})}


def verify_bound_archive(candidate: dict, plan: dict) -> None:
    # The controller must retain its sockets and TLS context for the run.
    # Keep archive decompression and its allocator in a short-lived process.
    verifier = REPO / 'scripts/verify_owned_webkit_qa_archive.py'
    try:
        result = subprocess.run(
            [sys.executable, '-B', str(verifier), '--stdin'],
            input=json.dumps({'candidate': candidate, 'runPlan': plan}),
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=30,
        )
        report = json.loads(result.stdout)
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        raise FixtureError('candidate_archive_preflight_failed') from error
    if (result.returncode != 0 or not isinstance(report, dict) or report.get('status') != 'PASS'
            or report.get('archiveSHA256') != candidate['sha256']):
        raise FixtureError('candidate_archive_preflight_failed')


def successor_launch_consumed(root: Path, candidate_sha: str) -> bool:
    marker = root / f'qa-{candidate_sha[:12]}-single-start-consumed'
    try:
        entry = marker.lstat()
    except FileNotFoundError:
        return False
    return (stat.S_ISREG(entry.st_mode) and stat.S_IMODE(entry.st_mode) == 0o600
            and entry.st_uid == os.geteuid() and entry.st_size == 0)


def attested_networking_owner(plan, binding):
    core = import_module('collect-manager-dns')
    packager = import_module('package-webkit-host')
    app = Path(binding['candidateApp'])
    manager = app / 'Contents/MacOS/NeAntik'
    if digest(manager) != binding['managerSignedSHA256']:
        raise FixtureError('networking_candidate_manager_drift')
    with (app / 'Contents/Info.plist').open('rb') as stream:
        pin = plistlib.load(stream)[packager.NETWORK_PROCESS_PIN_KEY]
    name = pin['executable']
    if not re.fullmatch(r'[A-Za-z0-9_.-]{1,200}', name) or name in ('.', '..'):
        raise FixtureError('invalid_networking_executable_pin')
    executable = (app / packager.HOST_BUNDLE_RELATIVE_PATH / 'Contents/Frameworks'
                  / packager.NETWORK_PROCESS_RELATIVE_PATH / 'Contents/MacOS' / name)
    if executable.is_symlink() or digest(executable) != pin['sha256']:
        raise FixtureError('networking_candidate_executable_drift')
    profile_id = str(uuid.UUID(plan['profileIDs'][1])).upper()
    receipts = list(Path(plan['root']).glob(f'webkit-network-owner-{profile_id}-*-qa.json'))
    if not 1 <= len(receipts) <= 8:
        raise FixtureError('networking_owner_receipts_missing_or_ambiguous')
    live = []
    for receipt in receipts:
        record = core.load(receipt)
        try:
            generation = str(uuid.UUID(record['generation'])).upper()
            if (record['profileID'] != profile_id
                    or receipt.name != f'webkit-network-owner-{profile_id}-{generation}-qa.json'):
                raise FixtureError('networking_owner_receipt_identity_mismatch')
            observed = core.kernel_process(record['pid'], executable)
        except (KeyError, TypeError) as error:
            raise FixtureError('networking_owner_receipt_invalid') from error
        except ValueError as error:
            if isinstance(error, FixtureError):
                raise
            continue
        if all(observed[key] == record[key] for key in ('pid', 'startSeconds', 'startMicroseconds')):
            live.append(record)
    if len(live) != 1:
        raise FixtureError('live_candidate_networking_owner_not_unique')
    return live[0]


def verify_networking_replacement(previous, current):
    if previous['generation'] == current['generation'] or (
            previous['pid'], previous['startSeconds'], previous['startMicroseconds']) == (
            current['pid'], current['startSeconds'], current['startMicroseconds']):
        raise FixtureError('networking_process_generation_did_not_change')


def require_networking_restart_receipt(root, binding, previous):
    core = import_module('collect-manager-dns')
    try:
        result = json.loads(core.read_private(root / 'networking-restart-result.json', limit=4096))
    except (OSError, ValueError) as error:
        raise FixtureError('networking_restart_receipt_missing_or_invalid') from error
    if (not isinstance(result, dict)
            or result.get('candidateSHA256') != binding['candidateSHA256']
            or result.get('previousGeneration') != previous['generation']
            or result.get('signalIssued') is not True
            or result.get('previousGenerationExited') is not True):
        raise FixtureError('networking_restart_receipt_missing_or_invalid')


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
    version = document.get('schemaVersion')
    if (type(version) is not int or version not in (2, 5, 7)
            or not isinstance(profiles, list) or len(profiles) != 1
            or not isinstance(profiles[0], dict)):
        raise FixtureError('one_app_produced_webkit_template_required')
    profile = profiles[0]
    identity = profile.get('identity') if isinstance(profile, dict) else None
    if (profile.get('name') != BLANK_PROFILE_NAME or profile.get('engine') != 'webkit'
            or profile.get('webKitRuntimeGeneration') not in ('system', 'isolatedV1')
            or (version == 2 and profile.get('webKitRuntimeGeneration') != 'system')
            or (version == 7 and (profile.get('privacyPolicy') != 'legacy'
                                 or profile.get('webKitBlockPeerConnections') is not False))
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


def peer_probe_fragment(port: int, nonce: str, *, require_gathering: bool = False) -> str:
    """Loopback-only peer probe; exposes booleans/errors, never ICE addresses."""
    if type(port) is not int or not 1024 <= port <= 65535:
        raise FixtureError('peer_probe_loopback_port_invalid')
    if not isinstance(nonce, str) or len(nonce) != 32 or any(c not in '0123456789abcdef' for c in nonce):
        raise FixtureError('peer_probe_nonce_invalid')
    return f"""<pre id="peer-probe">pending</pre><script>
(async () => {{
  const requireGathering = {json.dumps(require_gathering)};
  const run = async w => {{
    const result = {{constructorPresent: typeof w.RTCPeerConnection === 'function', created: false, error: null}};
    let timer;
    if (!result.constructorPresent) return result;
    let pc;
    try {{
      try {{
        pc = new w.RTCPeerConnection({{iceServers: [{{urls: 'stun:127.0.0.1:{port}'}}]}});
      }} catch (error) {{
        if (error?.name === 'InvalidAccessError') return {{...result, rejected: true}};
        throw error;
      }}
      const gather = async () => {{
        pc.createDataChannel('local-probe');
        await pc.setLocalDescription(await pc.createOffer());
        if (requireGathering && pc.iceGatheringState !== 'complete') {{
          await new Promise(resolve => {{
            const observe = () => {{
              if (pc.iceGatheringState === 'complete') resolve();
            }};
            pc.addEventListener('icegatheringstatechange', observe);
            observe();
          }});
        }} else if (!requireGathering) {{
          await new Promise(resolve => setTimeout(resolve, 1200));
        }}
        return {{...result, created: true}};
      }};
      return await Promise.race([
        gather(),
        new Promise(resolve => {{ timer = setTimeout(() => resolve({{timeout: true}}), 5000); }})
      ]);
    }} catch (error) {{ result.error = String(error && error.name || 'Error'); }}
    finally {{ clearTimeout(timer); if (pc) pc.close(); }}
    return result;
  }};
  const frame = document.createElement('iframe'); frame.src = 'about:blank';
  document.body.appendChild(frame);
  const result = {{top: await run(window), frame: await run(frame.contentWindow)}};
  document.getElementById('peer-probe').textContent = JSON.stringify(result);
  const category = r => r.timeout ? 'timeout' : !r.constructorPresent ? 'absent' : r.rejected ? 'rejected' : r.created ? 'created' : 'error';
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


def click_probe_fragment(nonce: str) -> str:
    if re.fullmatch(r'[0-9a-f]{32}', nonce) is None:
        raise FixtureError('click_probe_nonce_invalid')
    return f'''<div id="qa-click-color" aria-hidden="true" style="position:fixed;left:8vw;top:45vh;
    width:10vw;height:10vh;background:#ff0000;pointer-events:none;z-index:9999"></div>
    <button type="button" id="qa-click-target" style="position:fixed;left:35vw;top:38vh;
    width:30vw;height:24vh;background:#74240d;color:white;font: bold 24px sans-serif">
    Click probe ready</button><script>
    document.getElementById('qa-click-target').addEventListener('click', event => {{
      const result = event.isTrusted ? 'trusted' : 'untrusted';
      if (event.isTrusted) {{
        document.getElementById('qa-click-color').style.backgroundColor = '#00ff00';
        event.currentTarget.style.backgroundColor = '#14532d';
        event.currentTarget.textContent = 'Trusted click received';
      }}
      fetch('/qa-click/{nonce}/' + result, {{cache: 'no-store', credentials: 'same-origin'}})
        .catch(() => {{}});
    }}, {{once: true}});
    </script>'''


def prepare(template: Path, *, peer_control: bool = False, peer_stun_port: int | None = None,
            gpu_probe: bool = False, click_probe: bool = False, private_successor_dev: bool = False,
            turn_target: TurnTCPFixture | None = None, detached_session_qa: bool = False, metal_frame_qa: bool = False,
            managed_stun: bool = False):
    if metal_frame_qa and (not private_successor_dev or not detached_session_qa):
        raise FixtureError('metal_frames_require_private_detached_session')
    if turn_target is not None and not (private_successor_dev and peer_control):
        raise FixtureError('turn_requires_private_successor_peer_control')
    if detached_session_qa and not private_successor_dev:
        raise FixtureError('detached_session_requires_private_successor')
    if click_probe and not (private_successor_dev and detached_session_qa):
        raise FixtureError('click_probe_requires_private_detached_session')
    blank = read_blank_template(template)
    if peer_control != (peer_stun_port is not None):
        raise FixtureError('peer_control_requires_loopback_probe_port')
    stage = Path(tempfile.mkdtemp(prefix='neantik-webkit-ab-stage-', dir=PRIVATE_TMP))
    # Match the candidate's data-root contract. The explicit Debug lane uses
    # the app's disposable fixture namespace for its in-memory Keychain.
    root_prefix = 'neantik-dev-fixture.' if private_successor_dev else 'neantik-production-diagnostic-'
    root = Path(tempfile.mkdtemp(prefix=root_prefix, dir=PRIVATE_TMP))
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
            page += peer_probe_fragment(peer_stun_port, nonce, require_gathering=managed_stun)
        if gpu_probe:
            page += gpu_probe_fragment(nonce)
        if click_probe:
            page += click_probe_fragment(nonce)
        origin = tls_fixture.TLSOrigin(
            '127.0.0.1', page, certs,
            persistence_nonce=nonce, click_probe=click_probe, attribute_routes=True,
        )
        validator = dns_tls_fixture.OwnedDNSValidator(dns, host, origin)
        authority = f'{host}:{origin.port}'
        tunnels = [
            tls_fixture.Tunnel({authority: origin}, None, dns_validator=validator, route='A'),
            tls_fixture.Tunnel({authority: origin}, None, dns_validator=validator, turn_target=turn_target, route='B'),
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
            'clickProbe': click_probe,
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
        if managed_stun:
            plan['peerSTUNBoundary'] = 'owned-loopback-zero-direct-udp'
        if private_successor_dev:
            plan['qaRuntimeVariant'] = PRIVATE_SUCCESSOR_DEV_VARIANT
        if detached_session_qa:
            plan['qaDetachedSession'] = True
            plan['qaDetachedSocketTransport'] = True
        if metal_frame_qa:
            plan['qaMetalFrameTransport'] = True
        negative_tls = (turn_target is not None and
                        turn_target.qa_tls_case in ('wrong-host', 'missing-intermediate'))
        if turn_target is not None and turn_target.challenge_relay_policy and not negative_tls:
            plan['expectedPhases'][2:2] = [
                {'phase': 'B2', 'profile': 'B', 'state': 'restored'},
                {'phase': 'B3', 'profile': 'B', 'state': 'restored'},
            ]
        if turn_target is not None:
            # Each peer can open one socket for each IP family even when the
            # broker connects both sockets to the same TURN authority.
            positive_phases = 2 if turn_target.challenge_relay_policy else 1
            plan['turnControl'] = {'phase': 'B1', 'authority': turn_target.authority,
                                   'armAction': 'arm-turn-B1',
                                   'expectedAllocations': (0 if negative_tls else
                                                           2 * positive_phases),
                                   'maximumAllocations': (0 if negative_tls else
                                                          4 * positive_phases),
                                   'fixtureBinarySHA256': digest(turn_target.executable),
                                   'browserProbeSHA256': hashlib.sha256(turn_target.browser_probe_source).hexdigest(),
                                   'challengeRelayPolicy': turn_target.challenge_relay_policy}
        if turn_target is not None and turn_target.scheme == 'turns':
            if not turn_target.challenge_relay_policy or turn_target.qa_anchor_der is None:
                raise FixtureError('turns_requires_fixture_anchor_and_relay_policy')
            scope = {'profileID': str(uuid.UUID(plan['profileIDs'][1])),
                     'port': turn_target.port, 'anchorDER': turn_target.qa_anchor_der}
            plan[turns_scope.RECEIPT_KEY] = turns_scope.receipt(scope)
            private_file(root / turns_scope.FILE, plistlib.dumps(scope))
            if turn_target.qa_tls_case is not None:
                plan['turnControl']['tlsCertificateCase'] = turn_target.qa_tls_case
                plan['turnControl']['aiaPositiveControlRequests'] = 1
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
    counts = {
        'origin': origin.snapshot(),
        'proxyA': tunnels[0].snapshot(),
        'proxyB': tunnels[1].snapshot(),
        'proxyAAuthorizedOrigins': tunnels[0].authenticated_for(origin),
        'proxyBAuthorizedOrigins': tunnels[1].authenticated_for(origin),
        'dns': validator.snapshot(),
        'originRouteAttribution': True,
    }
    if origin.click_probe:
        counts['clickProbe'] = True
    if tunnels[1].turn_target is not None:
        counts['proxyBTurn'] = tunnels[1].authenticated_turn_count()
        counts['proxyBTurnOutageRefused'] = tunnels[1].turn_outage_count()
        target = tunnels[1].turn_target
        if target.qa_aia_count is not None:
            counts['turnAIARequests'] = target.qa_aia_count() - 1
            counts['turnTLSCertificateCase'] = target.qa_tls_case
    return counts


def metal_click_pixels(root: Path, profile_id: str) -> dict | None:
    """Read only bounded, owner-only receipts from the exact profile fixture."""
    profile = str(uuid.UUID(profile_id)).upper()

    def read(name):
        try:
            fd = os.open(root / name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        except OSError:
            return ''
        with os.fdopen(fd, 'rb') as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o600:
                return ''
            raw = stream.read(257)
        return raw.decode('ascii', errors='replace') if len(raw) <= 256 else ''

    uuid_pattern = r'[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}'
    # The manager emits this receipt only after both sampled drawables were
    # presented. Frame 1 can be dropped while the window is becoming visible.
    pixels = re.fullmatch(rf'stage=qa-metal-click-pixels generation=({uuid_pattern}) red=([1-9][0-9]{{0,19}}) green=([1-9][0-9]{{0,19}})\n',
                          read(f'webkit-metal-click-{profile}-qa.txt'))
    if pixels is None:
        return None
    try:
        owner = json.loads(read(f'webkit-network-owner-{profile}-{pixels[1]}-qa.json'))
    except ValueError:
        return None
    if (not isinstance(owner, dict) or owner.get('generation') != pixels[1]
            or owner.get('profileID') != profile):
        return None
    baseline, changed = int(pixels[2]), int(pixels[3])
    if not baseline < changed < 2**64:
        return None
    return {'generation': pixels[1], 'baselineSequence': baseline, 'changedSequence': changed}


def _phase_observation(name, prior, current):
    expected_state = {'A1': (1, 0), 'B1': (1, 0), 'B2': (0, 1), 'B3': (0, 1), 'A2': (0, 1)}[name]
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
    trace = current_trace[len(prior_trace):]
    if current.get('originRouteAttribution'):
        wrong_route = (current['origin'].get('unattributedConnections', 0) != 0
                       or any(event.get('route') != expected_proxy for event in trace))
        required_requests = {'page', 'initial' if expected_state[0] else 'restored'}
        responded = {event['category'] for event in trace if event['result'] == 'responded'}
        route_ok = route_ok and not wrong_route and required_requests <= responded
        if wrong_route:
            classification = 'contaminated'
        elif classification == 'pass' and not route_ok:
            classification = 'pending'
    result = {
        'phase': name,
        'classification': classification,
        'expectedState': 'initial' if expected_state[0] else 'restored',
        'stateDelta': origin_delta,
        'proxyAAuthorizedOriginDelta': auth_a,
        'proxyBAuthorizedOriginDelta': auth_b,
        'originRequestTrace': trace,
        'routeBoundary': 'PASS' if route_ok else 'FAIL',
        'storageBoundary': 'PASS' if state_ok else 'FAIL',
    }
    if 'proxyBTurn' in current:
        turn_delta = current['proxyBTurn'] - prior['proxyBTurn']
        acknowledgements = [event['category'] for event in trace
                            if event['category'].startswith('turn-') and event['result'] == 'responded']
        refused_delta = current.get('proxyBTurnOutageRefused', 0) - prior.get('proxyBTurnOutageRefused', 0)
        positive_turn = name in ('B1', 'B3')
        expected = positive_turn or name == 'B2'
        negative_tls = current.get('turnTLSCertificateCase') in ('wrong-host', 'missing-intermediate')
        without_relay = acknowledgements in (['turn-relay-candidate-missing'], ['turn-timeout'],
                                              ['turn-timeout-offer'], ['turn-timeout-answer'])
        max_connections = current.get('turnPositivePhaseConnectionLimit', 2)
        if positive_turn and negative_tls:
            # This records route and browser acknowledgement only. The
            # server must separately report an explicit certificate alert.
            valid = turn_delta in (1, 2) and refused_delta == 0 and without_relay
        elif positive_turn:
            valid = (2 <= turn_delta <= max_connections and refused_delta == 0
                     and acknowledgements == ['turn-relay-nonce-delivered'])
        elif name == 'B2':
            valid = turn_delta == 0 and refused_delta > 0 and without_relay
        else:
            valid = turn_delta == refused_delta == 0 and not acknowledgements
        contaminated = turn_delta > (max_connections if positive_turn and not negative_tls else 2 if positive_turn else 0)
        contaminated = contaminated or len(acknowledgements) > int(expected)
        if 'turnAIARequests' in current:
            aia_delta = current['turnAIARequests'] - prior['turnAIARequests']
            result['turnAIARequestsDelta'] = aia_delta
            valid = valid and current['turnAIARequests'] == 0
            contaminated = contaminated or current['turnAIARequests'] != 0
        if classification != 'contaminated' and contaminated:
            result['classification'] = 'contaminated'
        elif classification == 'pass' and not valid:
            result['classification'] = 'pending' if expected and not acknowledgements else 'fail'
        result.update(proxyBTurnDelta=turn_delta, proxyBTurnOutageRefusedDelta=refused_delta,
                      turnAcknowledgements=acknowledgements,
                      turnBoundary='PASS' if valid else 'FAIL')
    if 'ownedPeerSTUN' in current:
        reports = [event['category'] for event in trace
                   if event['category'].startswith('peer-') and event['result'] == 'responded']
        expected = 'peer-absent-absent' if expected_proxy == 'A' else 'peer-rejected-rejected'
        stun = current['ownedPeerSTUN']
        no_direct = stun == {'browserRequests': 0, 'invalidRequests': 0}
        peer_ok = reports == [expected]
        result['peerAPIBoundary'] = 'PASS' if peer_ok else 'PENDING' if not reports else 'FAIL'
        result['directSTUNBoundary'] = 'PASS' if no_direct else 'FAIL'
        result['ownedPeerSTUN'] = stun
        if classification != 'contaminated' and result['classification'] != 'contaminated':
            if len(reports) > 1:
                result['classification'] = 'contaminated'
            elif not no_direct or (reports and not peer_ok):
                result['classification'] = 'fail'
            elif result['classification'] == 'pass' and not peer_ok:
                result['classification'] = 'pending'
    if current.get('clickProbe'):
        clicks = [event['category'] for event in trace
                  if event['category'].startswith('click-') and event['result'] == 'responded']
        expected_clicks = ['click-trusted'] if name == 'A1' else []
        click_ok = clicks == expected_clicks
        result['clickEventBoundary'] = 'PASS' if click_ok else 'FAIL'
        if not click_ok:
            if clicks:
                result['classification'] = 'contaminated'
            elif result['classification'] == 'pass':
                result['classification'] = 'pending'
    if name == 'A1' and 'metalClickPixels' in current:
        pixels = current['metalClickPixels']
        result['metalClickPixelBoundary'] = 'PASS' if pixels is not None else 'PENDING'
        if pixels is not None:
            result['metalClickPixels'] = pixels
        elif result['classification'] == 'pass':
            result['classification'] = 'pending'
    return result


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


def _late_http_activity(prior, final):
    """Detect traffic that arrived after the last recorded phase."""
    origin_before = prior['origin']
    origin_after = final['origin']
    return (
        any(origin_after.get(key, 0) != origin_before.get(key, 0)
            for key in ('pageResponses', 'stateInitial', 'stateRestored', 'unattributedConnections'))
        or origin_after.get('requestTrace', []) != origin_before.get('requestTrace', [])
        or any(final[key] != prior[key] for key in ('proxyAAuthorizedOrigins', 'proxyBAuthorizedOrigins'))
    )


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
          gpu_probe: bool = False, click_probe: bool = False, public_site_controls: bool = False,
          private_successor_dev: bool = False, turn_target: TurnTCPFixture | None = None,
          detached_session_qa: bool = False, metal_frame_qa: bool = False,
          owned_stun=None) -> int:
    if private_successor_dev and public_site_controls:
        raise FixtureError('private_successor_dev_requires_loopback_only')
    plan, dns, origin, tunnels, validator = prepare(
        template, peer_control=peer_control, peer_stun_port=peer_stun_port,
        gpu_probe=gpu_probe, click_probe=click_probe, private_successor_dev=private_successor_dev, turn_target=turn_target,
        detached_session_qa=detached_session_qa, metal_frame_qa=metal_frame_qa,
        managed_stun=owned_stun is not None)

    def observed_counts():
        counts = _counts(origin, tunnels, validator)
        if turn_target is not None and 'maximumAllocations' in plan['turnControl']:
            counts['turnPositivePhaseConnectionLimit'] = 4
        if owned_stun is not None:
            counts['ownedPeerSTUN'] = owned_stun.snapshot()
        return counts

    root = Path(plan['root'])
    phases = []
    phase_names = tuple(phase['phase'] for phase in plan['expectedPhases'])
    prior = observed_counts()
    base_page = origin.marker
    turn_armed = None
    binding = None
    before_restart = None
    explicit_stop = False
    private_file(root / 'phase-results.json', b'{"phases":[]}\n')

    def write_phase_results(status, **evidence):
        results = {'schemaVersion': 1, 'candidateSHA256': None, **(binding or {}),
                   'phases': phases, 'status': status, **evidence}
        temporary = root / 'phase-results.next.json'
        private_file(temporary, (json.dumps(results, sort_keys=True, indent=2) + '\n').encode())
        os.replace(temporary, root / 'phase-results.json')

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
                explicit_stop = True
                break
            if command == {'action': 'status'}:
                print(json.dumps({'status': 'snapshot', 'counts': observed_counts()},
                                 sort_keys=True), flush=True)
                continue
            if private_successor_dev and command.get('action') == 'bind-candidate':
                if (set(command) != {'action', 'receipt', 'sha256'} or binding is not None
                        or not isinstance(command['receipt'], str)):
                    raise FixtureError('candidate_binding_requires_one_receipt')
                binding = bind_successor_candidate(plan, Path(command['receipt']), command['sha256'])
                private_file(root / 'candidate-binding.json', (json.dumps(binding, sort_keys=True) + '\n').encode())
                print(json.dumps({'status': 'candidate-bound', **binding}), flush=True)
                continue
            if command == {'action': 'arm-turn-B1'} and turn_target is not None:
                if [row['phase'] for row in phases] != ['A1'] or phases[0]['classification'] != 'pass' or turn_armed:
                    raise FixtureError('turn_requires_one_completed_A1')
                origin.arm_turn_probe(turn_target, secrets.token_hex(16))
                turn_armed = 'B1'
                print(json.dumps({'status': 'turn-armed', 'phase': 'B1'}), flush=True)
                continue
            if command == {'action': 'arm-turn-B2-outage'} and 'B2' in phase_names:
                if [row['phase'] for row in phases] != ['A1', 'B1'] or phases[-1]['classification'] != 'pass' or turn_armed:
                    raise FixtureError('turn_outage_requires_one_completed_B1')
                tunnels[1].set_turn_outage(True)
                origin.arm_turn_probe(turn_target, secrets.token_hex(16), outage=True)
                turn_armed = 'B2'
                print(json.dumps({'status': 'turn-outage-armed', 'phase': 'B2'}), flush=True)
                continue
            if command == {'action': 'arm-turn-B3-restart'} and 'B3' in phase_names:
                if before_restart is None or [row['phase'] for row in phases] != ['A1', 'B1', 'B2'] or turn_armed:
                    raise FixtureError('turn_restart_requires_completed_B2')
                require_networking_restart_receipt(root, binding, before_restart)
                if not import_module('collect-manager-crash').generation_absent(before_restart):
                    raise FixtureError('previous_networking_generation_still_live')
                origin.arm_turn_probe(turn_target, secrets.token_hex(16))
                turn_armed = 'B3'
                print(json.dumps({'status': 'turn-restart-armed', 'phase': 'B3'}), flush=True)
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
            if private_successor_dev and (binding is None or not successor_launch_consumed(root, binding['candidateSHA256'])):
                raise FixtureError('exact_successor_launch_required_before_phase')
            expected_index = len(phases)
            if expected_index >= len(phase_names) or name != phase_names[expected_index]:
                raise FixtureError('unexpected_phase_order')
            if turn_target is not None and name in ('B1', 'B2', 'B3') and turn_armed != name:
                raise FixtureError('turn_probe_must_be_armed_before_phase')
            def phase_counts():
                current = observed_counts()
                if name == 'A1' and plan.get('qaMetalFrameTransport') and plan.get('clickProbe'):
                    current['metalClickPixels'] = metal_click_pixels(root, plan['profileIDs'][0])
                return current

            row, current = _wait_for_phase(name, prior, phase_counts)
            if row['classification'] == 'timeout':
                print(json.dumps({'status': 'phase-timeout', **row}, sort_keys=True), flush=True)
                continue
            if row['classification'] == 'contaminated':
                print(json.dumps({'status': 'phase-contaminated', **row}, sort_keys=True), flush=True)
                continue
            if row['classification'] == 'pass' and name == 'B2':
                before_restart = attested_networking_owner(plan, binding)
                row['networkingOwner'] = before_restart
            if row['classification'] == 'pass' and name == 'B3':
                current_owner = attested_networking_owner(plan, binding)
                verify_networking_replacement(before_restart, current_owner)
                row['networkingOwner'] = current_owner
                row['networkingReplacement'] = 'PASS'
            phases.append(row)
            if turn_armed == name:
                origin.disarm_turn_probe(base_page)
                tunnels[1].set_turn_outage(False)
                turn_armed = None
            private_file(root / f'phase-{name}.json', (json.dumps(row, sort_keys=True) + '\n').encode())
            write_phase_results('partial' if len(phases) < len(phase_names) else 'awaiting-fixture-stop')
            prior = current
            print(json.dumps({'status': 'phase-recorded', **row}, sort_keys=True), flush=True)
    finally:
        tunnel_closed = [t.stop() for t in reversed(tunnels)]
        origin_closed = origin.stop()
        dns_closed = dns.close()
        turn = turn_target.stop() if turn_target is not None else None
        stun_closed = owned_stun is None or owned_stun.stop()
        final_counts = observed_counts()
        drained = all(tunnel_closed) and origin_closed and dns_closed and stun_closed
        late_http = _late_http_activity(prior, final_counts)
        if turn_target is not None:
            if binding is not None:
                turn['candidateSHA256'] = binding['candidateSHA256']
            late = _phase_observation('A2', prior, final_counts)
            expected_allocations = plan['turnControl']['expectedAllocations']
            maximum_allocations = plan['turnControl'].get('maximumAllocations', expected_allocations)
            broker_connections = final_counts['proxyBTurn']
            tls_ok = True
            if turn_target.qa_tls_case in ('wrong-host', 'missing-intermediate'):
                tls_ok = (broker_connections in (1, 2)
                          and turn['tcpAccepts'] == turn['tlsCertificateRejected'] == broker_connections
                          and turn['tlsAccepted'] == turn['tlsOtherFailure'] == 0)
                turn['certificateRejectionBoundary'] = 'PASS' if tls_ok else 'FAIL'
            elif turn_target.qa_tls_case == 'complete':
                tls_ok = (turn['tlsAccepted'] == broker_connections
                          and turn['tlsCertificateRejected'] == turn['tlsOtherFailure'] == 0)
            allocation_ok = (expected_allocations <= turn['allocations'] <= maximum_allocations
                             and (expected_allocations == 0 or turn['allocations'] == broker_connections))
            turn['observedPhaseControlsPassed'] = (explicit_stop and tls_ok and allocation_ok
                                                    and len(phases) == len(phase_names)
                                                    and ('B3' not in phase_names or turn['tcpAccepts'] == broker_connections)
                                                    and all(row['classification'] == 'pass' for row in phases)
                                                    and not late_http
                                                    and late['turnBoundary'] == 'PASS'
                                                    and late.get('directSTUNBoundary', 'PASS') == 'PASS'
                                                    and (owned_stun is None or late['peerAPIBoundary'] == 'PENDING')
                                                    and late.get('clickEventBoundary', 'PASS') == 'PASS'
                                                    and final_counts.get('turnAIARequests', 0) == 0
                                                    and drained)
            if owned_stun is not None:
                turn['directSTUNBoundary'] = late['directSTUNBoundary']
                turn['ownedPeerSTUN'] = final_counts['ownedPeerSTUN']
            private_file(root / 'turn-fixture-results.json', (json.dumps(turn, sort_keys=True) + '\n').encode())
        complete = (explicit_stop and drained and not late_http and len(phases) == len(phase_names)
                    and all(row['classification'] == 'pass' for row in phases)
                    and (turn is None or turn['observedPhaseControlsPassed']))
        verdict = 'PASS' if complete else 'INCOMPLETE' if not phases else 'FAIL'
        final_evidence = {'allChannelsDrained': drained, 'lateHTTPActivity': late_http,
                          'explicitStop': explicit_stop, 'finalCounts': final_counts,
                          **({'turn': turn} if turn is not None else {})}
        write_phase_results(verdict, **final_evidence)
        print(json.dumps({'status': 'fixture-stopped', 'verdict': verdict, 'phaseCount': len(phases),
                          **final_evidence}, sort_keys=True), flush=True)
    return 0 if complete else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--template', type=Path, required=True,
                        help='Exact app-produced blank isolatedV1 profiles.json')
    parser.add_argument('--peer-control', action='store_true',
                        help='Seed A with peer connections blocked and B as an enabled control')
    peer_stun = parser.add_mutually_exclusive_group()
    peer_stun.add_argument('--peer-stun-port', type=int, help='External loopback STUN fixture port')
    peer_stun.add_argument('--own-peer-stun', action='store_true',
                           help='Verify and observe a controller-owned loopback STUN canary in every TURN phase')
    parser.add_argument('--gpu-probe', action='store_true', help='Request a WebGPU adapter on the synthetic page')
    parser.add_argument('--click-probe', action='store_true',
                        help='Add a private trusted-click target to the synthetic HTTPS page')
    parser.add_argument('--public-site-controls', action='store_true', help='Opt in to fixed Google/Booking redirects on local control commands')
    parser.add_argument('--private-successor-dev', action='store_true',
                        help='Prepare an owner-only Debug fixture root for the private successor runtime')
    parser.add_argument('--turn-test-binary', type=Path, help='Use the owned TURN control on profile B only')
    tls = parser.add_mutually_exclusive_group()
    tls.add_argument('--turn-tls-certificate-case', choices=('complete', 'wrong-host', 'missing-intermediate'),
                     help='Generate a fresh TURN chain with a measured local issuer endpoint')
    tls.add_argument('--turn-tls-material', type=Path,
                        help='Owner-only directory containing chain.pem, leaf.key and ca.der')
    parser.add_argument('--rtc-relay-policy', action='store_true',
                        help='Require native relay policy under hostile page configuration')
    parser.add_argument('--qa-detached-session', action='store_true',
                        help='Bind observations to a private detached session candidate')
    parser.add_argument('--qa-metal-frames', action='store_true')
    args = parser.parse_args()
    try:
        if args.own_peer_stun and not (
                args.peer_control and args.rtc_relay_policy and args.turn_test_binary):
            raise FixtureError('owned_peer_stun_requires_relay_turn_control')
        if (args.turn_tls_material is not None or args.turn_tls_certificate_case is not None) and not (
                args.rtc_relay_policy and args.turn_test_binary):
            raise FixtureError('turns_requires_fixture_and_relay_policy')
        if args.rtc_relay_policy and args.turn_test_binary is None:
            raise FixtureError('rtc_relay_policy_requires_turn_fixture')
        if args.turn_test_binary is not None:
            if not (args.private_successor_dev and args.peer_control and (args.peer_stun_port is not None or args.own_peer_stun)) or args.public_site_controls:
                raise FixtureError('turn_requires_private_successor_peer_control')
            with ExitStack() as resources:
                owned_stun = None
                if args.own_peer_stun:
                    from stun_fixture import OwnedSTUN
                    owned_stun = OwnedSTUN('127.0.0.1')
                    resources.callback(lambda: owned_stun.stop() if not owned_stun.stopping.is_set() else None)
                    owned_stun.verify_canary()
                    args.peer_stun_port = owned_stun.port
                turn_root = Path(resources.enter_context(
                    tempfile.TemporaryDirectory(prefix='neantik-owned-turn-', dir=PRIVATE_TMP)))
                tls_files = None
                anchor = None
                count_aia = None
                if args.turn_tls_certificate_case is not None:
                    from turn_tls_aia_fixture import material as generate_tls_material
                    tls_files, anchor, canary = resources.enter_context(
                        generate_tls_material(turn_root, args.turn_tls_certificate_case))
                    count_aia = canary.count
                if args.turn_tls_material is not None:
                    material = args.turn_tls_material
                    info = material.lstat()
                    if (material.resolve(strict=True) != material or not stat.S_ISDIR(info.st_mode)
                            or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700):
                        raise FixtureError('turns_material_directory_not_private')
                    for name in ('chain.pem', 'leaf.key', 'ca.der'):
                        fd = os.open(material / name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                        with os.fdopen(fd, 'rb') as stream:
                            entry = os.fstat(stream.fileno())
                            limit = 4096 if name == 'ca.der' else 65536
                            if (not stat.S_ISREG(entry.st_mode) or entry.st_uid != os.geteuid()
                                    or stat.S_IMODE(entry.st_mode) != 0o600 or not 1 <= entry.st_size <= limit):
                                raise FixtureError('turns_material_file_not_private')
                            data = stream.read(limit + 1)
                            if not 1 <= len(data) <= limit:
                                raise FixtureError('turns_material_size_changed')
                        if name == 'ca.der':
                            anchor = data
                        else:
                            private_file(turn_root / name, data)
                    tls_files = (turn_root / 'chain.pem', turn_root / 'leaf.key')
                target = TurnTCPFixture(args.turn_test_binary, turn_root,
                                        challenge_relay_policy=args.rtc_relay_policy,
                                        tls_files=tls_files, qa_anchor_der=anchor,
                                        qa_tls_case=args.turn_tls_certificate_case, qa_aia_count=count_aia)
                try:
                    return serve(args.template, peer_control=True, peer_stun_port=args.peer_stun_port,
                                 gpu_probe=args.gpu_probe, click_probe=args.click_probe, private_successor_dev=True, turn_target=target,
                                 detached_session_qa=args.qa_detached_session, metal_frame_qa=args.qa_metal_frames,
                                 owned_stun=owned_stun)
                finally:
                    if target.process.poll() is None:
                        target.stop()
        return serve(args.template, peer_control=args.peer_control, peer_stun_port=args.peer_stun_port,
                     gpu_probe=args.gpu_probe, click_probe=args.click_probe, public_site_controls=args.public_site_controls,
                     private_successor_dev=args.private_successor_dev,
                     detached_session_qa=args.qa_detached_session, metal_frame_qa=args.qa_metal_frames)
    except (FixtureError, OSError, ValueError, TypeError, json.JSONDecodeError) as error:
        print(json.dumps({'status': 'REFUSED', 'reason': str(error)}, sort_keys=True), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
