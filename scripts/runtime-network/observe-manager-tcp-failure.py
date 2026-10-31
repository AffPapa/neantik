#!/usr/bin/env python3
"""Reduce a retained CUA AX observation of the owned failed nonce navigation.

The operator selects the verified owned app with CUA and retains only its
matching nonce address and visible connection error, one value per line.
This reducer does not drive UI or authenticate a screenshot. Kernel/lease
custody is checked again around reduction. Missing address/error is failure.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import time

SPEC = importlib.util.spec_from_file_location('tcp_failure_custody', Path(__file__).with_name('collect-manager-tcp.py'))
TCP = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(TCP)
ERRORS = ('ERR_SOCKS_CONNECTION_FAILED', 'ERR_PROXY_CONNECTION_FAILED', 'ERR_TUNNEL_CONNECTION_FAILED')


def reduce_values(raw, expected_url):
    TCP.CORE.require(isinstance(raw, str) and len(raw) <= 65536, 'unbounded-ax-result')
    values = raw.splitlines()
    # Chrome may omit the scheme in its omnibox accessibility value.
    accepted = {expected_url, expected_url.removeprefix('http://')}
    TCP.CORE.require(any(value.strip() in accepted for value in values), 'failed-nonce-url-not-observed')
    found = [code for code in ERRORS if any(code in value for value in values)]
    TCP.CORE.require(len(found) == 1, 'failed-browser-error-not-observed')
    return found[0]


def capture(state, root, ax_path):
    before = TCP.capture(state, root, 'listener-refused')
    url = state['urls']['listener-refused']
    raw = TCP.CORE.read_private(ax_path,65536)
    error = reduce_values(raw.decode('utf-8'), url)
    after = TCP.capture(state, root, 'listener-refused')
    for key in ('manager','browser','relayOwner','leaseSHA256','configurationSHA256','revision','metadataIdentitySHA256'):
        TCP.CORE.require(before[key] == after[key], 'browser-changed-during-ax-read')
    return dict(schemaVersion=1, phase='listener-refused', at=time.monotonic(), browser=before['browser'],
                leaseSHA256=before['leaseSHA256'], configurationSHA256=before['configurationSHA256'],
                expectedURLSHA256=TCP.CORE.sha(url.encode()), errorCode=error,
                observerSHA256=TCP.CORE.sha(Path(__file__).read_bytes()),
                reducedAXSHA256=TCP.CORE.sha(raw), observationMethod='operator-owned-CUA-AX',
                scope='Operator retained owned CUA AX nonce/error with live custody; not autonomous UI attestation, POSIX errno or global route proof')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state', type=Path, required=True)
    parser.add_argument('--ax-observation', type=Path, required=True)
    args = parser.parse_args()
    try:
        state, root = TCP.owned_state(args.state)
        TCP.CORE.write_new(TCP.CORE.receipt_directory(args.state) / 'tcp-browser-failure.json', capture(state, root,args.ax_observation))
    except (KeyError, TypeError, ValueError, OSError, TCP.CORE.subprocess.SubprocessError):
        parser.exit(1, 'Owned browser TCP failure observation refused.\n')
    print(json.dumps({'status':'captured','rawAXPublished':False,'releaseQualified':False}))


if __name__ == '__main__': main()
