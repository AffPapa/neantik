"""Bound one owned HTTPS CONNECT target to an owned DNS-on-wire answer.

This is a fixture for the next signed Dev QA, not a WebKit route qualification.
It makes a CONNECT succeed only after the local DNS fixture returns the exact
name, query ID and loopback address. It never calls the system resolver.
"""

import importlib.util
import os
from pathlib import Path
import re
import socket
import threading

import tls_fixture


DNS_SOURCE = Path(__file__).resolve().parents[2] / 'scripts/runtime-network/controlled-dns-fixture.py'
SPEC = importlib.util.spec_from_file_location('neantik_owned_dns_tls_fixture', DNS_SOURCE)
DNS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DNS)


def persistence_page(nonce):
    """Owned HTTPS page marker for a profile stop/reopen, with no external JS."""
    if not isinstance(nonce, str) or not re.fullmatch(r'[0-9a-f]{32}', nonce):
        raise ValueError('One random QA nonce is required')
    return (f'<span id="neantik-qa-persistence">PENDING</span>'
            '<script>(()=>{'
            f'const value="{nonce}",key="neantik_qa_store_{nonce}",cookie="neantik_qa_cookie_{nonce}";'
            'const state=document.getElementById("neantik-qa-persistence");'
            'try{const hadStore=localStorage.getItem(key)===value;'
            'const hadCookie=document.cookie.split("; ").some(x=>x===cookie+"="+value);'
            'state.textContent=hadStore&&hadCookie?"NEANTIK_QA_TLS_PERSIST_RESTORED":'
            '"NEANTIK_QA_TLS_PERSIST_INITIAL";'
            'localStorage.setItem(key,value);'
            'document.cookie=cookie+"="+value+"; Path=/; Max-Age=3600; SameSite=Lax; Secure";'
            'fetch("/qa-state/"+value+"/"+(hadStore&&hadCookie?"restored":"initial"),'
            '{cache:"no-store",credentials:"same-origin"}).catch(()=>{});'
            '}catch{state.textContent="NEANTIK_QA_TLS_PERSIST_STORAGE_ERROR";}'
            '})();</script>')


def reply_matches(answer, sender, *, server, identifier, name, address):
    try:
        response = DNS.question(answer, response=True)
        return (sender == server and response['identifier'] == identifier
                and response['name'] == name and response['kind'] == 1
                and response['rcode'] == 0 and response['answers'] == 1
                and answer[-4:] == socket.inet_aton(address))
    except (OSError, DNS.DNSMessageError, ValueError):
        return False


class OwnedDNSValidator:
    def __init__(self, fixture, name, origin):
        if (not isinstance(fixture, DNS.DNSFixture) or fixture.dns is None
                or name not in fixture.names.values()
                or not name.endswith('.neantik-dns.invalid')
                or not isinstance(origin, tls_fixture.TLSOrigin)
                or origin.socket.getsockname()[0] != '127.0.0.1'):
            raise ValueError('Live owned DNS and loopback TLS origin required')
        self.fixture = fixture
        self.name = name
        self.destination = origin.socket.getsockname()
        self.lock = threading.Lock()
        self.accepted = 0
        self.refused = 0

    def __call__(self, authority, destination):
        valid = False
        if authority == f'{self.name}:{self.destination[1]}' and destination == self.destination:
            try:
                identifier = int.from_bytes(os.urandom(2), 'big')
                packet = DNS.query(self.name, identifier)
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as channel:
                    channel.settimeout(2)
                    channel.sendto(packet, self.fixture.dns.server_address)
                    answer, sender = channel.recvfrom(DNS.MAX_PACKET + 1)
                valid = reply_matches(answer, sender, server=self.fixture.dns.server_address,
                                      identifier=identifier, name=self.name,
                                      address=destination[0])
            except (OSError, DNS.DNSMessageError, ValueError):
                pass
        with self.lock:
            if valid: self.accepted += 1
            else: self.refused += 1
        return valid

    def snapshot(self):
        with self.lock:
            return {'accepted': self.accepted, 'refused': self.refused}
