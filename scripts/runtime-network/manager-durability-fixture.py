"""Normal own data page for a real beforeunload-delayed manager close.

Only the initial page writes synthetic data. The later read page must observe
it without repairing it. This does not test crash recovery or backup restore.
"""
import importlib.util
import json
from pathlib import Path
import threading
import uuid
from urllib.parse import parse_qs, urlsplit

SPEC = importlib.util.spec_from_file_location('durability_route_base', Path(__file__).with_name('manager-route-fixture.py'))
BASE = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(BASE)
KEYS = {'cookie', 'localStorage', 'sessionStorage', 'indexedDB', 'cacheStorage'}


def require(value):
    if not value: raise ValueError('owned-durability-input')


def validate_result(value, phase, marker):
    require(isinstance(value, dict) and set(value) == {'phase', 'before', 'after', 'errors', 'wrote', 'strictIDB'} and value['phase'] == phase
            and value['errors'] == [] and type(value['wrote']) is bool and type(value['strictIDB']) is bool)
    for key in ('before', 'after'):
        require(isinstance(value[key], dict) and set(value[key]) == KEYS and all(v is None or v == marker for v in value[key].values()))
    if phase == 'write':
        require(all(v is None for v in value['before'].values()) and all(v == marker for v in value['after'].values())
                and value['wrote'] is True and value['strictIDB'] is True)
    else:
        require(phase == 'read' and value['wrote'] is False and value['strictIDB'] is False and value['before'] == value['after']
                and all(v == (None if k == 'sessionStorage' else marker) for k, v in value['after'].items()))
    # Export only matching booleans, not the synthetic marker values.
    return dict(phase=phase, freshBeforeWrite=phase == 'write', allPersistentValuesMatch=True,
                sessionStorageFresh=phase == 'read', wrote=value['wrote'], strictIDB=value['strictIDB'])


class ManagerDurabilityFixture(BASE.Fixture):
    def __init__(self, root):
        self.control_lock = threading.RLock(); self.phase_name = 'write'; self.served = set(); self.completed = set()
        self.peer_inspector = None; self.marker = uuid.uuid4().hex
        super().__init__(root); self.nonce = uuid.uuid4().hex

    def navigation_phases(self): return ('proxy-success', 'direct-control')

    def url(self, phase):
        return 'http://127.0.0.1:' + str(self.origin.server_address[1]) + '/owned-data?nonce=' + (self.nonce if phase == 'direct-control' else 'unused-sibling')

    def description(self): return dict(mode='manager-data-durability', exercisedProfileIndex=1, abruptCrashQualified=False, backupRestoreQualified=False)

    def parse(self, target, path):
        parsed = urlsplit(target); query = parse_qs(parsed.query, keep_blank_values=True)
        require(len(target) <= 256 and parsed.path == path and query == {'nonce': [self.nonce]})

    def origin_request(self, channel):
        self.track(channel); channel.settimeout(10)
        try:
            lines = BASE.header(channel).split(b'\r\n'); first = lines[0].split(); require(len(first) == 3)
            method, target = first[0], first[1].decode('ascii'); path = urlsplit(target).path
            if path == '/favicon.ico': BASE.answer(channel, b'404 Not Found', b''); return
            require(self.peer_inspector is not None)
            # Only the actual Direct browser/helper chain is accepted. A page
            # declaration or same-user process alone cannot establish custody.
            peer = self.peer_inspector(channel, True)
            with self.control_lock:
                phase = self.phase_name
                if method == b'GET':
                    self.parse(target, '/owned-data'); require(phase not in self.served); self.served.add(phase)
                    config = dict(phase=phase, nonce=self.nonce, marker=self.marker)
                    text = Path(__file__).with_name('manager-durability-probe.js').read_text()
                    body = ('<!doctype html><meta charset="utf-8"><body data-owned="' + self.nonce + '"><h1>Owned data durability</h1><p id="status">Running</p><p id="hold-state">Own close fence off</p><button id="hold">Arm own close fence</button><button id="release">Disarm own close fence</button><script>globalThis.OWN_DURABILITY=' + json.dumps(config) + ';' + text + '</script>').encode()
                    self.ledger.record('durability-page', phase=phase, peer=peer)
                else:
                    require(method == b'POST'); self.parse(target, '/owned-receipt'); lengths = [line.split(b':', 1)[1].strip() for line in lines[1:] if line.lower().startswith(b'content-length:')]
                    require(len(lengths) == 1 and lengths[0].isdigit() and 0 < int(lengths[0]) <= 4096)
                    length = int(lengths[0]); raw = bytearray()
                    while len(raw) < length:
                        chunk = channel.recv(length - len(raw)); require(bool(chunk)); raw.extend(chunk)
                    value = validate_result(json.loads(raw), phase, self.marker)
                    require(phase in self.served and phase not in self.completed); self.completed.add(phase)
                    self.ledger.record('durability-result', **value, peer=peer)
                    # The same startup URL serves a read-only page on the next
                    # normal manager launch. No profile metadata is edited.
                    if phase == 'write': self.phase_name = 'read'
                    body = b'owned data receipt accepted'
            BASE.answer(channel, b'200 OK', body)
        except (ValueError, OSError, KeyError, UnicodeError, IndexError):
            self.ledger.record('durability-http-refused')
            try: BASE.answer(channel, b'400 Bad Request', b'')
            except OSError: pass
        finally: self.untrack(channel)
