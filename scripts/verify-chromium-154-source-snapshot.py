#!/usr/bin/env python3
"""Verify that the live Chromium 154 checkout matches frozen candidate inputs."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from chromium_154_release_evidence import (
    M154EvidenceError,
    verify_candidate_document,
)


PROJECT_ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source_root", type=Path)
    parser.add_argument("provenance", type=Path)
    parser.add_argument("--project-root", type=Path, default=PROJECT_ROOT)
    args = parser.parse_args()
    try:
        document = json.loads(args.provenance.read_text(encoding="utf-8"))
        verify_candidate_document(
            document,
            project_root=args.project_root.resolve(),
            source_root=args.source_root,
        )
    except (OSError, json.JSONDecodeError, M154EvidenceError) as error:
        print(f"Chromium 154 source snapshot verification failed: {error}", file=sys.stderr)
        return 1
    print("PASS: live Chromium 154 checkout matches the frozen candidate source snapshot")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
