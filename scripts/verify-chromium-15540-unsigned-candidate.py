#!/usr/bin/env python3
"""Check the exact M155.40 build output before Developer ID signing."""

import argparse
import sys
from pathlib import Path

from chromium_15540_release_evidence import (
    M15540EvidenceError,
    read_object,
    verify_unsigned_binary_binding,
)

from chromium_15540_variant import verify_candidate_document

parser = argparse.ArgumentParser()
parser.add_argument("app", type=Path)
parser.add_argument("args_gn", type=Path)
parser.add_argument("candidate", type=Path)
args = parser.parse_args()
try:
    document = read_object(args.candidate, "M155.40 candidate")
    source_root=args.candidate.parent/"src" if "semanticCorrectionSet" in document else None
    verify_candidate_document(document, project_root=Path(__file__).resolve().parents[1],source_root=source_root)
    verify_unsigned_binary_binding(args.app, args.args_gn, document)
except (OSError, ValueError, M15540EvidenceError) as error:
    print(f"Unsigned M155.40 candidate verification failed: {error}", file=sys.stderr)
    sys.exit(1)
print("PASS: unsigned M155.40 executable, framework and build args match the candidate.")
