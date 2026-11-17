#!/usr/bin/env python3
"""Report only allowlisted regression-test outcomes from a private CI log."""
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
LOG = ROOT / '.build/neantik-ci/diagnostic/receipts/ProfileStoreTests.log'
FENCE = 'deletedProfileCleanupKeepsProcessFenceThroughCallback'
MARKER = 'markerRemovalFailureIsReportedAfterCommittedDeletionAndPrunesOrganization'


def evaluate(log: str) -> dict:
    def lines_for(symbol: str, name: str) -> list[str]:
        pattern = re.compile(r'^\s*' + re.escape(symbol) + r' Test ' + re.escape(name)
                             + r'\([^\n]*\)[^\n]*$', re.MULTILINE)
        return pattern.findall(log)

    fence_pass = lines_for('✔', FENCE)
    marker_pass = lines_for('✔', MARKER)
    fence_skip = lines_for('➜', FENCE)
    marker_skip = lines_for('➜', MARKER)
    fence_fail = lines_for('✘', FENCE)
    marker_fail = lines_for('✘', MARKER)
    passed_fence = len(fence_pass) == 1 and bool(re.search(r'\bpassed(?: after |\.)', fence_pass[0]))
    passed_marker = len(marker_pass) == 1 and bool(re.search(r'\bpassed(?: after |\.)', marker_pass[0]))
    started = {
        value: bool(re.search(r'^\s*◇ Test case passing 1 argument failLegacy → ' + value +
                              r' to ' + re.escape(FENCE) + r'\(failLegacy:\) started\.$',
                              log, re.MULTILINE))
        for value in ('false', 'true')
    }
    case_summary = bool(fence_pass and re.search(r'\bwith 2 test cases passed(?: after |\.)', fence_pass[0]))
    target_skip_count = len(fence_skip) + len(marker_skip)
    target_fail_count = len(fence_fail) + len(marker_fail)
    valid = passed_fence and passed_marker and target_skip_count == 0 and target_fail_count == 0
    return {'schemaVersion': 1, 'fenceTestPassed': passed_fence, 'markerTestPassed': passed_marker,
            'targetSkipCount': target_skip_count, 'targetFailCount': target_fail_count,
            'falseCaseStarted': started['false'], 'trueCaseStarted': started['true'],
            'twoCasePassedSummary': case_summary,
            'bothCasesVerified': valid and started['false'] and started['true'] and case_summary,
            'status': 'pass' if valid else 'incomplete'}


def main() -> int:
    try:
        # The optional path is for isolated fixture tests; never print its content.
        path = Path(sys.argv[1]) if len(sys.argv) == 2 else LOG
        if len(sys.argv) > 2:
            raise ValueError('invalid arguments')
        result = evaluate(path.read_text(encoding='utf-8', errors='replace'))
    except (OSError, ValueError):
        result = {'schemaVersion': 1, 'status': 'unavailable'}
    print(json.dumps(result, sort_keys=True))
    return 0 if result['status'] == 'pass' else 1


if __name__ == '__main__':
    sys.exit(main())
