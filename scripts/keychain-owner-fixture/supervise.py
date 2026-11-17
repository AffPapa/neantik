#!/usr/bin/env python3
"""Supervise synthetic CI helpers; never call Keychain APIs on the client."""
import json
import os
from pathlib import Path
import pwd
import subprocess
import sys

# These guard against accidental local execution, not malicious env spoofing.
work = Path(sys.argv[1]).resolve(strict=True) if len(sys.argv) == 2 else None
root = Path(os.environ.get('RUNNER_TEMP', '/nonexistent')).resolve()
if (os.environ.get('GITHUB_ACTIONS') != 'true' or
    os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted' or
    pwd.getpwuid(os.getuid()).pw_name != 'runner' or
    not str(root).startswith('/Users/runner/') or work is None or
    root not in work.parents or not work.name.startswith('neantik-keychain-ci-')):
    print(json.dumps({'event': 'guard', 'allowed': False}))
    sys.exit(77)

allowed = {
 'setup': {'event', 'create', 'decoyCreate'},
 'afterCreate': {'event', 'searchListEqual', 'defaultEqual'},
 'afterSequence': {'event', 'searchListEqual', 'defaultEqual'},
 'seedA': {'event', 'status'},
 'scope': {'event', 'ownSeed', 'decoySeed', 'decoyInMain', 'decoyFound', 'decoyVerified'},
 'aclA': {'event', 'search', 'itemVerified', 'access', 'selectACL', 'aclSingle', 'copyContents', 'appSingle', 'trustedData', 'aRef', 'aData', 'bRef', 'bData', 'callerRef', 'callerData', 'matchesA', 'matchesB', 'callerMatchesB'},
 'aclB': {'event', 'search', 'itemVerified', 'access', 'selectACL', 'aclSingle', 'copyContents', 'appSingle', 'trustedData', 'aRef', 'aData', 'bRef', 'bData', 'callerRef', 'callerData', 'matchesA', 'matchesB', 'callerMatchesB'},
 'other': {'event', 'deniedSearch', 'deniedKeychainVerified', 'deniedAttempted', 'deniedDelete', 'matchesOwnerEdit', 'ownerStillFound', 'ownSearch', 'ownKeychainVerified', 'ownAttempted', 'ownDelete', 'ownAfter'},
 'owner': {'event', 'ownSearch', 'ownKeychainVerified', 'ownAttempted', 'ownDelete', 'ownAfter'},
 'open': {'event', 'status'},
 'decoyOpen': {'event', 'status'},
 'noninteractive': {'event', 'status'},
}

def run(executable, phase):
    try:
        proc = subprocess.run([str(work / executable), phase, str(work)],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=90, check=False, text=True)
    except subprocess.TimeoutExpired:
        print(json.dumps({'event': 'timeout', 'phase': phase}))
        return 124, []
    except OSError:
        print(json.dumps({'event': 'launchError', 'phase': phase}))
        return 125, []
    events = []
    try:
        for line in proc.stdout.splitlines():
            value = json.loads(line)
            event = value.get('event') if isinstance(value, dict) else None
            if not isinstance(event, str) or event not in allowed or set(value) != allowed[event]:
                raise ValueError('unknown event')
            if any(type(v) not in (int, bool) for k, v in value.items() if k != 'event'):
                raise ValueError('unexpected value')
            events.append(value)
            print(json.dumps(value, sort_keys=True))
    except (ValueError, json.JSONDecodeError):
        print(json.dumps({'event': 'invalidOutput', 'phase': phase}))
        return 126, []
    print(json.dumps({'event': 'phase', 'phase': phase, 'exitCode': proc.returncode}))
    return proc.returncode, events

setup_code, setup_events = run('OwnerA', 'setup')
probe_code, probe_events = (run('OwnerB', 'probe') if setup_code == 0 else (127, []))
cleanup_code, cleanup_events = (run('OwnerA', 'cleanup') if probe_code == 0 else (127, []))
# Snapshot after all attempted phases, even when controls fail, if setup persisted baseline.
snapshot_code, snapshot_events = (run('OwnerA', 'snapshot') if (work / 'baseline.plist').is_file() else (127, []))
def exactly_one(events, name):
    matches = [event for event in events if event.get('event') == name]
    return matches[0] if len(matches) == 1 else None

def known_snapshot(event):
    return (event is not None and
            type(event.get('searchListEqual')) is int and event['searchListEqual'] in (0, 1) and
            type(event.get('defaultEqual')) is int and event['defaultEqual'] in (0, 1))

setup = exactly_one(setup_events, 'setup')
seed_a = exactly_one(setup_events, 'seedA')
after_create = exactly_one(setup_events, 'afterCreate')
scope = exactly_one(probe_events, 'scope')
acl_a = exactly_one(probe_events, 'aclA')
acl_b = exactly_one(probe_events, 'aclB')
other = exactly_one(probe_events, 'other')
owner = exactly_one(cleanup_events, 'owner')
after_sequence = exactly_one(snapshot_events, 'afterSequence')
def known_acl(event, expected_a, expected_b):
    statuses = ('search', 'access', 'selectACL', 'copyContents', 'trustedData',
                'aRef', 'aData', 'bRef', 'bData', 'callerRef', 'callerData')
    if event is None or any(type(event.get(key)) is not int or event[key] != 0 for key in statuses):
        return False
    return (type(event.get('itemVerified')) is int and event['itemVerified'] == 1 and
            type(event.get('aclSingle')) is int and event['aclSingle'] == 1 and
            type(event.get('appSingle')) is int and event['appSingle'] == 1 and
            type(event.get('matchesA')) is int and event['matchesA'] == expected_a and
            type(event.get('matchesB')) is int and event['matchesB'] == expected_b and
            type(event.get('callerMatchesB')) is int and event['callerMatchesB'] == 1)

# Explicit independent evidence of every control; -1/unknown snapshots never pass.
reproduced = (setup_code == probe_code == cleanup_code == snapshot_code == 0 and
              setup is not None and setup['create'] == 0 and setup['decoyCreate'] == 0 and
              seed_a is not None and seed_a['status'] == 0 and known_snapshot(after_create) and
              scope is not None and scope['ownSeed'] == 0 and scope['decoySeed'] == 0 and
              scope['decoyInMain'] == -25300 and scope['decoyFound'] == 0 and scope['decoyVerified'] is True and
              known_acl(acl_a, 1, 0) and known_acl(acl_b, 0, 1) and
              other is not None and other['deniedSearch'] == 0 and other['deniedKeychainVerified'] is True and
              other['deniedAttempted'] is True and other['deniedDelete'] == -25244 and
              other['matchesOwnerEdit'] is True and other['ownerStillFound'] == 0 and
              other['ownSearch'] == 0 and other['ownKeychainVerified'] is True and
              other['ownAttempted'] is True and other['ownDelete'] == 0 and other['ownAfter'] == -25300 and
              owner is not None and owner['ownSearch'] == 0 and owner['ownKeychainVerified'] is True and
              owner['ownAttempted'] is True and owner['ownDelete'] == 0 and owner['ownAfter'] == -25300 and
              known_snapshot(after_sequence))
print(json.dumps({'event': 'result', 'ownerEditReproduced': reproduced,
                  'outcome': 'synthetic-reproduced' if reproduced else 'inconclusive'}))
sys.exit(0 if reproduced else 1)
