#!/usr/bin/env python3
"""Linked, redacted DNS observations behind the real manager's upstream.

The operator controls faults through stdin of manager-route-fixture.py. Page
requests cannot change fault state. No OS resolver or trust settings change.
"""
import importlib.util
import os
from pathlib import Path
import re
import stat
import threading
import uuid

SOURCE = Path(__file__).with_name('controlled-dns-fixture.py')
SPEC = importlib.util.spec_from_file_location('manager_owned_dns_base', SOURCE)
DNS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DNS)
PHASES = ('proxy-success', 'dns-refused', 'proxy-recovered', 'direct-control')


class ManagerDNSFixture(DNS.DNSFixture):
    def __init__(self, root, *, allow_manager_preflight=False):
        self.control_lock = threading.RLock()
        self.request_local = threading.local()
        self.requests = {}
        self.peer_inspector = None  # Main supervisor installs the live collector.
        self.fault_epoch, self.fault_enabled = 0, False
        super().__init__(root)
        self.public_tls_hosts = frozenset(DNS.BASE.Fixture.public_tls_hosts) if allow_manager_preflight else frozenset()
        self.allow_manager_preflight = allow_manager_preflight
        self.ledger.record('dns-control', **self.control_snapshot())

    def navigation_phases(self): return PHASES

    def phase(self, target):
        phase = super().phase(target)
        return phase if phase in PHASES else None

    def url(self, phase):
        if phase not in PHASES: raise ValueError('manager-dns-phase')
        # A shipping Direct profile cannot resolve the private .test name.
        # This proves origin sensitivity only, not a Direct DNS route.
        if phase == 'direct-control': return DNS.BASE.Fixture.url(self, phase)
        return super().url(phase)

    def control_snapshot(self):
        with self.control_lock:
            try:
                info = (self.root / 'fail-dns').lstat()
                present = True
                safe = (stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                        and info.st_nlink == 1 and not info.st_mode & 0o077)
            except FileNotFoundError:
                present, safe = False, True
            return dict(faultEpoch=self.fault_epoch, faultEnabled=self.fault_enabled,
                        controlConsistent=safe and present == self.fault_enabled)

    def apply_control(self, action):
        if action not in ('fail-dns', 'recover'): raise ValueError('manager-dns-control')
        enabled = action == 'fail-dns'
        with self.control_lock:
            if not self.control_snapshot()['controlConsistent']: raise ValueError('foreign-fault-marker')
            if enabled == self.fault_enabled: return self.control_snapshot()
            marker = self.root / 'fail-dns'
            if enabled:
                fd = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
                os.close(fd)
            else:
                info = marker.lstat()
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
                    raise ValueError('unsafe-fault-marker')
                marker.unlink()
            self.fault_enabled = enabled
            self.fault_epoch += 1
            state = self.control_snapshot()
            self.ledger.record('dns-control', **state)
            return state

    def begin_owned_request(self, host, port):
        with self.control_lock:
            if len(self.requests) >= 256: raise ValueError('bounded-manager-dns-requests')
            phase = self.reverse_names.get(host)
            if phase not in PHASES and host != '127.0.0.1': raise ValueError('manager-dns-host')
            context = dict(requestID=uuid.uuid4().hex, phase=phase,
                           requestEpoch=self.fault_epoch, originObserved=False)
            self.requests[context['requestID']] = context
            self.request_local.context = context
            self.ledger.record('dns-request-begin', requestID=context['requestID'], phase=phase,
                               requestEpoch=context['requestEpoch'], **self.control_snapshot())
            return context

    def validate_owned_request(self, context, target):
        phase = self.phase(target)
        if phase is None or context.get('phase') not in (None, phase):
            raise ValueError('manager-dns-host-nonce-mismatch')
        context['phase'] = phase

    def observe_proxy_peer(self, context, client):
        if self.peer_inspector is not None:
            peer = self.peer_inspector(client, False)
            self.ledger.record('dns-request-peer', requestID=context['requestID'], **peer)

    def observe_origin_peer(self, channel, phase, protected, observation):
        if not protected and self.peer_inspector is not None:
            if phase != 'direct-control': raise ValueError('unexpected-direct-origin')
            peer = self.peer_inspector(channel, True)
            self.ledger.record('dns-direct-peer', requestID=observation['requestID'], **peer)

    def observe_origin_arrival(self, phase, protected):
        # Record before ANY peer/header rejection. Reaching the canary via an
        # unintended Direct connection is a failed gate even if we refuse it.
        arrival = dict(arrivalID=uuid.uuid4().hex)
        self.ledger.record('dns-origin-arrival', phase=phase, throughOwnedUpstream=protected,
                           **arrival, **self.control_snapshot())
        return arrival

    def resolution_result(self, host, *, accepted, rcode):
        context = getattr(self.request_local, 'context', None)
        if context is None or context['phase'] != self.reverse_names.get(host):
            raise ValueError('unbound-manager-dns-resolution')
        self.ledger.record('dns-resolution-accepted' if accepted else 'dns-resolution-rejected',
                           phase=context['phase'], requestID=context['requestID'],
                           requestEpoch=context['requestEpoch'], rcode=rcode, **self.control_snapshot())

    def owned_request_headers(self, context):
        return b'X-NeAntik-Owned-Request: ' + context['requestID'].encode('ascii') + b'\r\n'

    def origin_observation(self, request, phase, protected):
        with self.control_lock:
            if protected:
                values = [line.split(b':', 1)[1].strip().decode('ascii') for line in request.split(b'\r\n')[1:]
                          if line.lower().startswith(b'x-neantik-owned-request:')]
                if len(values) != 1 or not re.fullmatch('[0-9a-f]{32}', values[0]):
                    raise ValueError('missing-owned-request')
                context = self.requests.get(values[0])
                if context is None or context['phase'] != phase or context['originObserved']:
                    raise ValueError('stale-owned-request')
                context['originObserved'] = True
                return dict(requestID=context['requestID'], requestEpoch=context['requestEpoch'],
                            **self.control_snapshot())
            return dict(requestID=uuid.uuid4().hex, requestEpoch=self.fault_epoch,
                        **self.control_snapshot())

    def description(self):
        return dict(schemaVersion=1, mode='manager-dns', urls={p:self.url(p) for p in PHASES},
                    allowManagerPreflight=self.allow_manager_preflight,
                    directControlScope='literal-IP origin sensitivity only; no Direct DNS measurement',
                    **self.control_snapshot())
