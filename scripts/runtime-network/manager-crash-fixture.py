"""Own settled baseline, acknowledged strict-IDB, aborted write and crash read.

Only the separate custody collector can crash a verified own main process.
This HTTP fixture never sends a signal and cannot choose a target PID.
"""
import importlib.util
import json
from pathlib import Path
import threading
import uuid
from urllib.parse import parse_qs, urlsplit

SPEC = importlib.util.spec_from_file_location('crash_route_base', Path(__file__).with_name('manager-route-fixture.py'))
BASE = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(BASE)
STORES = {'cookie', 'localStorage', 'indexedDB', 'cacheStorage'}
PHASES = ('baseline', 'mutate', 'read')


def require(value):
    if not value: raise ValueError('owned-crash-protocol')


def validate_result(value, phase, baseline, fresh):
    require(isinstance(value, dict) and set(value) == {'phase', 'before', 'after', 'wrote', 'strictCompleted', 'abortedAfterRequestSuccess', 'errors'}
            and value['phase'] == phase and value['errors'] == []
            and all(type(value[k]) is bool for k in ('wrote', 'strictCompleted', 'abortedAfterRequestSuccess')))
    for sample in ('before', 'after'):
        snapshot = value[sample]
        require(isinstance(snapshot, dict) and set(snapshot) == {'baseline', 'fresh', 'aborted', 'sessionStorage'}
                and snapshot['aborted'] is None and snapshot['sessionStorage'] in (None, fresh))
        for group, marker in (('baseline', baseline), ('fresh', fresh)):
            require(isinstance(snapshot[group], dict) and set(snapshot[group]) == STORES
                    and all(v is None or type(v) is str and v == marker for v in snapshot[group].values()))
    before, after = value['before'], value['after']
    settled = {key:baseline for key in STORES}; empty = {key:None for key in STORES}
    require(value['wrote'] is (phase != 'read') and value['strictCompleted'] is (phase != 'read')
            and value['abortedAfterRequestSuccess'] is (phase == 'mutate'))
    if phase == 'baseline':
        require(before == dict(baseline=empty, fresh=empty, aborted=None, sessionStorage=None)
                and after == dict(baseline=settled, fresh=empty, aborted=None, sessionStorage=None))
    elif phase == 'mutate':
        require(before == dict(baseline=settled, fresh=empty, aborted=None, sessionStorage=None)
                and after == dict(baseline=settled, fresh={key:fresh for key in STORES}, aborted=None, sessionStorage=fresh))
    else:
        require(phase == 'read' and before == after and after['baseline'] == settled and after['fresh']['indexedDB'] == fresh)
    return dict(phase=phase, baselineIntact=phase != 'baseline' or after['baseline'] == settled,
                strictIDBRetained=after['fresh']['indexedDB'] == fresh, abortedValueAbsent=True,
                strictCompleted=value['strictCompleted'], abortedAfterRequestSuccess=value['abortedAfterRequestSuccess'],
                wrote=value['wrote'], freshPresence={key:after['fresh'][key] == fresh for key in STORES},
                sessionRestored=after['sessionStorage'] == fresh)


class ManagerCrashFixture(BASE.Fixture):
    def __init__(self, root):
        self.control_lock = threading.RLock(); self.phase = 'baseline'; self.served = set(); self.completed = set()
        self.peer_inspector = None; self.baseline = uuid.uuid4().hex; self.fresh = uuid.uuid4().hex
        super().__init__(root); self.nonce = uuid.uuid4().hex

    def navigation_phases(self): return ('proxy-success', 'direct-control')

    def url(self, phase):
        return 'http://127.0.0.1:' + str(self.origin.server_address[1]) + '/own-crash?nonce=' + (self.nonce if phase == 'direct-control' else 'unused-sibling')

    def description(self):
        return dict(mode='manager-main-crash', exercisedProfileIndex=1, signalTarget='exact own main only',
                    powerLossQualified=False, relayCrashQualified=False)

    def parse(self, target, path):
        parsed = urlsplit(target)
        require(len(target) <= 256 and parsed.path == path and parse_qs(parsed.query, keep_blank_values=True) == {'nonce':[self.nonce]})

    def origin_request(self, channel):
        self.track(channel); channel.settimeout(10)
        try:
            lines = BASE.header(channel).split(b'\r\n'); first = lines[0].split(); require(len(first) == 3)
            method, target = first[0], first[1].decode('ascii')
            if urlsplit(target).path == '/favicon.ico': BASE.answer(channel, b'404 Not Found', b''); return
            require(self.peer_inspector is not None); peer = self.peer_inspector(channel, True)
            with self.control_lock:
                phase = self.phase
                if method == b'GET':
                    self.parse(target, '/own-crash'); require(phase not in self.served); self.served.add(phase)
                    config = dict(phase=phase, nonce=self.nonce, baseline=self.baseline, fresh=self.fresh)
                    text = Path(__file__).with_name('manager-crash-probe.js').read_text()
                    body = ('<!doctype html><meta charset="utf-8"><body data-owned="' + self.nonce + '"><h1>Owned main crash recovery</h1><p id="status">Running</p><script>globalThis.OWN_CRASH=' + json.dumps(config) + ';' + text + '</script>').encode()
                    self.ledger.record('crash-page', phase=phase, peer=peer)
                else:
                    require(method == b'POST'); self.parse(target, '/own-crash-receipt')
                    lengths = [line.split(b':',1)[1].strip() for line in lines[1:] if line.lower().startswith(b'content-length:')]
                    require(len(lengths) == 1 and lengths[0].isdigit() and 0 < int(lengths[0]) <= 8192)
                    length = int(lengths[0]); raw = bytearray()
                    while len(raw) < length:
                        chunk = channel.recv(length-len(raw)); require(bool(chunk)); raw.extend(chunk)
                    value = validate_result(json.loads(raw), phase, self.baseline, self.fresh)
                    require(phase in self.served and phase not in self.completed); self.completed.add(phase)
                    self.ledger.record('crash-result', **value, peer=peer)
                    if phase != 'read': self.phase = PHASES[PHASES.index(phase)+1]
                    body = b'owned crash receipt accepted'
            BASE.answer(channel, b'200 OK', body)
        except (ValueError, OSError, KeyError, UnicodeError, IndexError, TypeError):
            self.ledger.record('crash-http-refused')
            try: BASE.answer(channel, b'400 Bad Request', b'')
            except OSError: pass
        finally: self.untrack(channel)
