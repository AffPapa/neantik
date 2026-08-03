#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from runtime_candidate_lock import PROJECT_ROOT, verify_candidate_lock
from runtime_source_provenance import SourceProvenanceError, sha256_file


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Verify a deterministic schema 4 candidate lock against checked "
            "source provenance and reviewed project manifests."
        )
    )
    parser.add_argument("candidate_lock", type=Path)
    parser.add_argument("provenance", type=Path)
    parser.add_argument("--project-root", type=Path, default=PROJECT_ROOT)
    args = parser.parse_args()
    try:
        verify_candidate_lock(
            args.candidate_lock,
            args.provenance,
            project_root=args.project_root.resolve(),
        )
    except (OSError, SourceProvenanceError) as error:
        print(f"Candidate lock verification failed: {error}", file=sys.stderr)
        return 1
    print("PASS: candidate lock matches source contract and provenance.")
    print(f"SHA-256: {sha256_file(args.candidate_lock)}")
    print("Binary binding is outside this source-only document.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
