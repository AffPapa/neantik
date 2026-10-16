"""Physical upstream listener loss; no system network or resolver changes.

Only the operator can stop/rebind this owned loopback listener. The independent
origin remains reachable for a deliberate Direct sensitivity control. An errno
from our socket probe establishes the fixture condition, not Chromium's errno.
"""
import errno
import importlib.util
from pathlib import Path
import socket
import threading
import uuid

SPEC = importlib.util.spec_from_file_location('physical_tcp_route_base', Path(__file__).with_name('manager-route-fixture.py'))
BASE = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(BASE)
PHASES = ('proxy-success', 'listener-refused', 'direct-control', 'proxy-recovered')


class ManagerTCPFixture(BASE.Fixture):
    def __init__(self, root):
        self.control_lock = threading.RLock()
        self.peer_inspector = None
        self.fault_epoch, self.listener_active = 0, True
        super().__init__(root)
        self.nonces = {phase: uuid.uuid4().hex for phase in PHASES}
        self.proxy_address = self.proxy.server_address
        # Inherit reuse on accepted sockets, so recovery can bind the same
        # endpoint even after normal earlier connections entered TIME_WAIT.
        self.proxy.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.proxy_class, self.proxy_handler = type(self.proxy), self.proxy.RequestHandlerClass
        self.ledger.record('tcp-listener-control', **self.control_snapshot())

    def navigation_phases(self): return PHASES

    def control_snapshot(self):
        with self.control_lock:
            return dict(faultEpoch=self.fault_epoch, listenerActive=self.listener_active)

    def apply_control(self, action):
        if action not in ('stop-listener', 'recover-listener'):
            raise ValueError('physical-tcp-control')
        with self.control_lock:
            active = action == 'recover-listener'
            if active == self.listener_active:
                raise ValueError('physical-tcp-duplicate-control')
            if not active:
                self.proxy.shutdown()
                self.proxy.server_close()
                # These are fixture-owned accepted connections, never the
                # browser's relay listener or another application's socket.
                with self.socket_lock: channels = list(self.sockets)
                closed = 0
                for channel in channels:
                    try:
                        channel.shutdown(socket.SHUT_RDWR)
                        closed += 1
                    except OSError:
                        pass
                self.listener_active = False
                with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
                    probe.settimeout(1)
                    refusal = probe.connect_ex(self.proxy_address)
                if refusal != errno.ECONNREFUSED:
                    raise ValueError('physical-listener-not-refused')
                self.fault_epoch += 1
                self.ledger.record('tcp-listener-control', **self.control_snapshot(),
                                   socketProbeRefused=True, acceptedChannelsShutdown=closed)
            else:
                restored = self.proxy_class(self.proxy_address, self.proxy_handler, bind_and_activate=False)
                try:
                    restored.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                    restored.server_bind(); restored.server_activate()
                except BaseException:
                    restored.server_close()
                    raise
                self.proxy = restored
                self.listener_active = True
                self.fault_epoch += 1
                thread = threading.Thread(target=restored.serve_forever, daemon=True)
                self.threads.append(thread); thread.start()
                self.ledger.record('tcp-listener-control', **self.control_snapshot(),
                                   sameEndpoint=restored.server_address == self.proxy_address)
            return self.control_snapshot()

    def observe_proxy_peer(self, context, client):
        if self.peer_inspector is not None:
            self.ledger.record('tcp-request-peer', **self.peer_inspector(client, False), **self.control_snapshot())

    def observe_origin_arrival(self, phase, protected):
        # Count arrival BEFORE custody checking; an invalid Direct arrival is
        # still a failed isolation check, even if its request is refused later.
        self.ledger.record('tcp-origin-arrival', phase=phase, throughOwnedUpstream=protected,
                           **self.control_snapshot())
        return {}

    def observe_origin_peer(self, channel, phase, protected, observation):
        if not protected and self.peer_inspector is not None:
            self.ledger.record('tcp-direct-peer', phase=phase,
                               **self.peer_inspector(channel, True), **self.control_snapshot())

    def description(self):
        return dict(schemaVersion=1, mode='manager-physical-tcp', urls={p:self.url(p) for p in PHASES},
                    controlScope='owned loopback upstream listener only; no system network change',
                    **self.control_snapshot())
