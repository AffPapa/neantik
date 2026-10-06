#!/usr/bin/env python3
"""Check the exact M154.98 build output before Developer ID signing."""

import argparse
import sys
from pathlib import Path

from chromium_15498_release_evidence import (
    M15498EvidenceError,
    read_object,
    verify_candidate_document,
    verify_unsigned_binary_binding,
)

parser = argparse.ArgumentParser()
parser.add_argument("app", type=Path)
parser.add_argument("args_gn", type=Path)
parser.add_argument("candidate", type=Path)
args = parser.parse_args()
try:
    document = read_object(args.candidate, "M154.98 candidate")
    verify_candidate_document(document, project_root=Path(__file__).resolve().parents[1])
    verify_unsigned_binary_binding(args.app, args.args_gn, document)
except (OSError, ValueError, M15498EvidenceError) as error:
    print(f"Unsigned M154.98 candidate verification failed: {error}", file=sys.stderr)
    sys.exit(1)
print("PASS: unsigned M154.98 executable, framework and build args match the candidate.")
