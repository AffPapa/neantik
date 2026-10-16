#!/usr/bin/env python3
"""Offline acceptance of a bounded owned-loopback experiment, not a release gate.

The native producer must collect provider events from the OS journal and bind
them to the exact signed executable/PID. A typed fixture is not a substitute
for that collection. No process, browser, network or preferences are accessed.
"""
import argparse
import datetime
import json
import math
from pathlib import Path
import re
import uuid

PHASES = ("baseline", "active", "unavailable")
FAMILIES = ("v4", "v6")
ROLES = ("A", "B")


def finite(value):
    # Bound before float conversion: JSON integers can exceed float capacity.
    return type(value) in (int, float) and 0 < value < 10**12 and math.isfinite(value)


def normalize_journal(records, *, run_id, provider_pid, provider_sha256,
                      process_image_path, process_image_uuid, clock_anchor, clock_checks):
    """Normalize only bound OS records; never use journal text as authority.

    The collector must verify the provider's actual code/PID first. Image path
    and UUID here are matching pins, never paths to open from journal input.
    macOS timestamps are converted using measured, drift-checked clock pairs.
    """
    events, problems = [], []
    try:
        expected_run = uuid.UUID(run_id)
        expected_image = uuid.UUID(process_image_uuid)
        anchor_date = datetime.datetime.fromisoformat(clock_anchor['timestamp'])
        anchor_uptime = clock_anchor['uptime']
        if anchor_date.tzinfo is None or not finite(anchor_uptime) or not clock_checks:
            raise ValueError('clock')
        for check in clock_checks:
            stamp = datetime.datetime.fromisoformat(check['timestamp'])
            if (stamp.tzinfo is None or not finite(check['uptime'])
                    or abs((stamp - anchor_date).total_seconds() - (check['uptime'] - anchor_uptime)) > 0.01):
                raise ValueError('drift')
    except (KeyError, ValueError, TypeError, AttributeError):
        return {'events': [], 'problems': ['invalid_or_drifting_clock_or_identity'], 'collectionAuthenticated': False}
    if not isinstance(records, list):
        return {'events': [], 'problems': ['invalid_journal'], 'collectionAuthenticated': False}
    for record in records:
        if not isinstance(record, dict):
            problems.append('invalid_record')
            continue
        if (record.get('processID') != provider_pid
                or record.get('subsystem') != 'app.neantik.desktop.network-qa.proxy'
                or record.get('category') != 'owned-loopback'):
            continue  # The collector additionally scopes its command to these.
        try:
            if record.get('processImagePath') != process_image_path or uuid.UUID(record['processImageUUID']) != expected_image:
                raise ValueError('image')
            stamp = datetime.datetime.fromisoformat(record['timestamp'])
            if stamp.tzinfo is None:
                raise ValueError('timestamp')
            uptime = anchor_uptime + (stamp - anchor_date).total_seconds()
            if not finite(uptime):
                raise ValueError('uptime')
            text = record['eventMessage']
            if not isinstance(text, str) or len(text) > 512:
                raise ValueError('message')
            start = re.fullmatch(r'owned-filter-start success=(true|false) run=([0-9A-Fa-f-]+)', text)
            flow = re.fullmatch(r'owned-filter-flow role=(A|B|unknown) verdict=(drop|allow)( UNQUALIFIED)? run=([0-9A-Fa-f-]+)', text)
            if start:
                if uuid.UUID(start[2]) != expected_run:
                    raise ValueError('run')
                kind = 'applied' if start[1] == 'true' else 'apply-failed'
            elif flow:
                if uuid.UUID(flow[4]) != expected_run:
                    raise ValueError('run')
                kind = f'{flow[1]}-{flow[2]}' if not flow[3] else 'unknown-owner'
                if kind not in ('A-drop', 'B-allow'):
                    kind = 'unknown-owner'
            elif text.startswith('owned-filter-unexpected UNQUALIFIED reason='):
                kind = 'unexpected-callback'
            elif text == 'owned-filter-stop;OS failure behavior remains separately measured':
                # A stop callback is not proof the provider is unavailable.
                # A separate actual OS-state/PID observation must supply that.
                kind = 'stop-request'
            else:
                kind = 'unexpected-message'
            events.append({'kind': kind, 'uptime': uptime, 'runID': run_id,
                           'providerPID': provider_pid, 'providerExecutableSHA256': provider_sha256})
        except (KeyError, ValueError, TypeError, AttributeError):
            problems.append('unbound_or_malformed_provider_record')
    return {'events': events, 'problems': sorted(set(problems)), 'collectionAuthenticated': False,
            'boundary': 'Normalization only;native collector must establish actual OS capture and signed code/PID binding'}


def assess(report, *, run_id, archive_sha256, provider_sha256):
    """Fail on missing cases, unknown callbacks, Direct or unmatched events."""
    problems = []
    if not isinstance(report, dict):
        report = {}
    if (report.get("schemaVersion") != 1 or report.get("runID") != run_id
            or report.get("signedArchiveSHA256") != archive_sha256):
        problems.append("candidate_or_run_mismatch")
    cases = report.get("cases", [])
    if not isinstance(cases, list):
        cases = []
        problems.append("invalid_cases")
    indexed = {}
    for case in cases:
        if not isinstance(case, dict):
            problems.append("invalid_case")
            continue
        key = (case.get("phase"), case.get("family"), case.get("role"))
        if (not all(isinstance(value, str) for value in key)
                or key in indexed or key[0] not in PHASES or key[1] not in FAMILIES or key[2] not in ROLES):
            problems.append("duplicate_or_unexpected_case")
            continue
        indexed[key] = case
    expected = {(phase, family, role) for phase in PHASES for family in FAMILIES for role in ROLES}
    if set(indexed) != expected:
        problems.append("incomplete_case_matrix")

    events = report.get("providerEvents", [])
    if not isinstance(events, list):
        events = []
        problems.append("invalid_provider_events")
    provider_pid = report.get("providerPID")
    if type(provider_pid) is not int or not 0 < provider_pid < 2**31:
        problems.append("missing_provider_pid")
    valid_events = []
    for event in events:
        if (not isinstance(event, dict) or event.get("runID") != run_id
                or event.get("providerPID") != provider_pid
                or event.get("providerExecutableSHA256") != provider_sha256
                or not finite(event.get("uptime"))):
            problems.append("foreign_or_unbound_provider_event")
            continue
        if event.get("kind") not in ("applied", "A-drop", "B-allow", "unavailable", "stop-request"):
            # Unknown-owner/unexpected callbacks are disqualifying, even when
            # A happens not to reach the origin. Never discard them as noise.
            problems.append("unqualified_provider_event")
            continue
        valid_events.append(event)

    applied = [x["uptime"] for x in valid_events if x["kind"] == "applied"]
    unavailable = [x["uptime"] for x in valid_events if x["kind"] == "unavailable"]
    if len(applied) != 1 or len(unavailable) != 1 or applied[0] >= unavailable[0]:
        problems.append("missing_or_ambiguous_lifecycle_barriers")
    active_intervals = []
    for (phase, family, role), case in indexed.items():
        label = f"{phase}/{family}/{role}"
        observation = case.get("observation")
        if (case.get("exitCode") != 0 or case.get("outerTimeout") is not False
                or case.get("forcedKill") is not False or not isinstance(observation, dict)
                or observation.get("runID") != run_id or observation.get("role") != role):
            problems.append(label + ":host_not_completed")
            continue
        origins = case.get("originEvents")
        if not isinstance(origins, list):
            problems.append(label + ":missing_origin_evidence")
            continue
        if any(not isinstance(event, dict) or not finite(event.get("uptime")) for event in origins):
            problems.append(label + ":invalid_origin_event")
        should_load = phase == "baseline" or role == "B"
        if should_load:
            if observation.get("outcome") != "loaded" or observation.get("httpStatus") != 200 or len(origins) != 1:
                problems.append(label + ":positive_control_failed")
        elif (observation.get("outcome") != "failure" or len(origins) != 0
              or observation.get("errorDomain") not in ("NSURLErrorDomain", "WKErrorDomain")
              or type(observation.get("errorCode")) is not int):
            problems.append(label + ":direct_or_unproved_block")
        if phase == "baseline":
            # Retained baseline receipts predate launch-interval capture. They
            # do have the real origin and headed-completion uptimes. Use those
            # facts without fabricating a launch time; both must precede apply.
            completed = observation.get("uptime")
            if (not finite(completed) or len(applied) != 1 or completed >= applied[0]
                    or any(not isinstance(event, dict) or not finite(event.get("uptime"))
                           or not 0 <= completed - event["uptime"] <= 30 for event in origins)):
                problems.append(label + ":stale_or_unordered_baseline")
            if "startUptime" in case or "endUptime" in case:
                start, end = case.get("startUptime"), case.get("endUptime")
                if (not finite(start) or not finite(end) or not finite(completed) or len(applied) != 1
                        or not start < completed <= end < applied[0]
                        or any(not isinstance(event, dict) or not finite(event.get("uptime"))
                               or not start <= event["uptime"] <= completed for event in origins)):
                    problems.append(label + ":invalid_baseline_interval")
            continue
        start, end = case.get("startUptime"), case.get("endUptime")
        if not finite(start) or not finite(end) or not start < end or end - start > 30:
            problems.append(label + ":missing_exact_interval")
            continue
        if any(isinstance(event, dict) and finite(event.get("uptime")) and not start <= event["uptime"] <= end for event in origins):
            problems.append(label + ":stale_origin_event")
        if phase == "active":
            active_intervals.append((start, end))
            if len(applied) != 1 or len(unavailable) != 1 or not applied[0] < start < end < unavailable[0]:
                problems.append(label + ":outside_active_generation")
            kind = "A-drop" if role == "A" else "B-allow"
            if not any(x["kind"] == kind and start <= x["uptime"] <= end for x in valid_events):
                problems.append(label + ":no_matching_original_owner_event")
        elif len(unavailable) != 1 or start <= unavailable[0]:
            problems.append(label + ":provider_failure_not_observed_before_request")
    # One event must not be recycled as proof for two overlapping requests.
    ordered = sorted(active_intervals)
    if any(left[1] >= right[0] for left, right in zip(ordered, ordered[1:])):
        problems.append("overlapping_active_cases")
    problems = sorted(set(problems))
    return {"schemaVersion": 1,
            "status": "OBSERVATION COMPLETE;OWNED LOOPBACK SCOPE ONLY" if not problems else "INCOMPLETE OR FAILED;NOT QUALIFIED",
            "problems": problems, "caseCount": len(indexed),
            "productionQualified": False, "workingProxyProved": False,
            "boundary": "Requires authentic OS-journal and exact-code/PID collection;does not cover external network,DNS,UDP,existing flows or full proxy integration"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("receipt", type=Path)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--archive-sha256", required=True)
    parser.add_argument("--provider-sha256", required=True)
    args = parser.parse_args()
    with args.receipt.open("rb") as source:
        raw = source.read(1024 * 1024 + 1)
    if len(raw) > 1024 * 1024:
        raise ValueError("Observation exceeds bounded input size")
    result = assess(json.loads(raw), run_id=args.run_id, archive_sha256=args.archive_sha256,
                    provider_sha256=args.provider_sha256)
    print(json.dumps(result, indent=2))
    return 0 if not result["problems"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
