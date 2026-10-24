#!/usr/bin/env python3
"""Prepare one disposable, loopback-only owned WebKit DNS/TLS QA stage.

This process keeps its fixture sockets alive until an explicit JSON ``stop``
line on stdin. Run it in a PTY or retain stdin as a pipe. It never launches an
app, changes system trust/DNS/proxy settings, or reads a production profile.
The generated run plan contains public QA coordinates, hashes and no keys.
"""
from __future__ import annotations

import argparse
import copy
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import secrets
import sys
import tempfile
import uuid

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'scripts'))
sys.path.insert(0, str(REPO / 'Experiments/OwnedWebKitNetworkBoundary'))
from verify_owned_webkit_profile import inspect_profile_store  # noqa: E402
from create_owned_webkit_proxy_pair import _safe_json  # noqa: E402
import dns_tls_fixture  # noqa: E402
import tls_fixture  # noqa: E402

PROFILE_NAME = 'QA isolated WebKit blank 20261021'
PRIVATE_TMP = Path('/private/tmp')


class QAPreflightError(ValueError):
    pass


def private_file(path: Path, data: bytes, mode: int = 0o600) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, 'O_NOFOLLOW', 0)
    descriptor = os.open(path, flags, mode)
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
    except BaseException:
        path.unlink(missing_ok=True)
        raise


def source_profile(template: Path) -> dict:
    inspect_profile_store(template, PROFILE_NAME)
    document = _safe_json(template / 'profiles.json' if template.is_dir() else template)
    if document.get('schemaVersion') != 5 or len(document.get('profiles', [])) != 1:
        raise QAPreflightError('exactly_one_app_produced_blank_profile_required')
    profile = document['profiles'][0]
    if profile.get('name') != PROFILE_NAME or profile.get('proxy') is not None:
        raise QAPreflightError('blank_profile_scope_invalid')
    # Never carry a credential-bearing or user-authored field into QA.
    if (any(key in profile for key in ('password', 'proxyPassword', 'auth'))
            or profile.get('note') or profile.get('tags')):
        raise QAPreflightError('template_contains_unexpected_private_field')
    return profile


def profile_bytes(blank: dict, *, origin_url: str, proxy_port: int) -> bytes:
    if not origin_url.startswith('https://') or not 1 <= proxy_port <= 65535:
        raise QAPreflightError('owned_https_origin_and_proxy_port_required')
    now = dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z')
    a, b = copy.deepcopy(blank), copy.deepcopy(blank)
    a.update(id=str(uuid.uuid4()).upper(), name='Owned DNS TLS QA A proxy',
             startURL=origin_url,
             proxy={'kind': 'http', 'host': '127.0.0.1', 'port': proxy_port, 'username': ''},
             createdAt=now, updatedAt=now, lastLaunchedAt=None, revision=1)
    b.update(id=str(uuid.uuid4()).upper(), name='Owned DNS TLS QA B direct control',
             startURL='about:blank', proxy=None,
             createdAt=now, updatedAt=now, lastLaunchedAt=None, revision=1)
    return (json.dumps({'schemaVersion': 5, 'profiles': [a, b]},
                       ensure_ascii=False, sort_keys=True, separators=(',', ':')) + '\n').encode()


def prepare(template: Path):
    blank = source_profile(template)
    stage = Path(tempfile.mkdtemp(prefix='neantik-dns-tls-stage-', dir=PRIVATE_TMP))
    root = Path(tempfile.mkdtemp(prefix='neantik-dns-tls-root-', dir=PRIVATE_TMP))
    os.chmod(stage, 0o700)
    os.chmod(root, 0o700)
    dns = origin = tunnel = None
    try:
        dns = dns_tls_fixture.DNS.DNSFixture(root, name_suffix='.neantik-dns.invalid')
        name = dns.names['proxy-success']
        certificates = tls_fixture.certificates(root / 'certificates', '127.0.0.1', name)
        nonce = secrets.token_hex(16)
        origin = tls_fixture.TLSOrigin('127.0.0.1', dns_tls_fixture.persistence_page(nonce),
                                       certificates, persistence_nonce=nonce)
        validator = dns_tls_fixture.OwnedDNSValidator(dns, name, origin)
        authority = f'{name}:{origin.port}'
        # None means no Proxy-Authorization header is accepted. The exact
        # destination and DNS-on-wire answer are still mandatory.
        tunnel = tls_fixture.Tunnel({authority: origin}, None, dns_validator=validator)
        url = f'https://{authority}/'
        payload = profile_bytes(blank, origin_url=url, proxy_port=tunnel.port)
        digest = hashlib.sha256(payload).hexdigest()
        private_file(stage / 'profiles.seed.json', payload, 0o400)
        private_file(root / 'profiles.json', payload)
        private_file(root / 'profiles.previous.json', payload)
        public_ca = certificates / 'ca.der'
        plan = {
            'schemaVersion': 1,
            'status': 'offline-fixture-ready; browser-not-started',
            'scope': 'one disposable owned WebKit DNS/TLS QA; no production credentials',
            'stage': str(stage), 'root': str(root),
            'seedSHA256': digest,
            'profileCount': 2,
            'proxyA': '127.0.0.1:' + str(tunnel.port),
            'proxyAuthorization': 'absent; header rejected',
            'directB': 'about:blank only; cite independent QA21 control separately',
            'dnsPort': dns.dns.server_address[1],
            'tlsOrigin': url,
            'qaTrustAnchorDER': str(public_ca),
            'qaTrustAnchorSHA256': hashlib.sha256(public_ca.read_bytes()).hexdigest(),
            'fixtureSourceSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            'faultControls': ['dns-refuse', 'dns-recover', 'proxy-refuse', 'proxy-recover'],
        }
        private_file(stage / 'run-plan.json', (json.dumps(plan, sort_keys=True, indent=2) + '\n').encode())
        return plan, dns, origin, tunnel, validator
    except BaseException:
        if tunnel is not None: tunnel.stop()
        if origin is not None: origin.stop()
        if dns is not None: dns.close()
        # Preserve only a successful immutable stage. Failed temporary QA
        # material is removed, never a user-provided template or profile.
        import shutil
        shutil.rmtree(stage)
        shutil.rmtree(root)
        raise


def serve(template: Path) -> int:
    plan, dns, origin, tunnel, validator = prepare(template)
    root = Path(plan['root'])
    try:
        print(json.dumps(plan, sort_keys=True), flush=True)
        while True:
            line = sys.stdin.readline(1025)
            if not line:
                raise QAPreflightError('stdin_closed_before_explicit_stop')
            if len(line) > 1024:
                raise QAPreflightError('control_line_too_large')
            command = json.loads(line)
            if command == {'action': 'stop'}:
                break
            if command == {'action': 'dns-refuse'}:
                (root / 'fail-dns').touch(exist_ok=False)
            elif command == {'action': 'dns-recover'}:
                (root / 'fail-dns').unlink()
            elif command == {'action': 'proxy-refuse'}:
                tunnel.refusing = True
            elif command == {'action': 'proxy-recover'}:
                tunnel.refusing = False
            elif command != {'action': 'status'}:
                raise QAPreflightError('unsupported_control_action')
            print(json.dumps({'status': 'control-applied', 'action': command['action'],
                              'tunnel': tunnel.snapshot(), 'origin': origin.snapshot(),
                              'dnsValidation': validator.snapshot()}, sort_keys=True), flush=True)
        return 0
    finally:
        tunnel_closed = tunnel.stop()
        origin_closed = origin.stop()
        dns_closed = dns.close()
        closed = tunnel_closed and origin_closed and dns_closed
        print(json.dumps({'status': 'fixture-stopped', 'allChannelsDrained': closed,
                          'tunnel': tunnel.snapshot(), 'origin': origin.snapshot(),
                          'dnsValidation': validator.snapshot()}, sort_keys=True), flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--template', type=Path, required=True,
                        help='Exact app-produced blank isolatedV1 profiles.json')
    args = parser.parse_args()
    try:
        return serve(args.template)
    except (QAPreflightError, OSError, ValueError, TypeError, json.JSONDecodeError):
        print(json.dumps({'status': 'REFUSED', 'reason': 'QA preflight or control validation failed'}),
              file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
