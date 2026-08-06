#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from runtime_source_provenance import (
    PROJECT_ROOT,
    SourceProvenanceError,
    build_provenance,
    load_object,
    sha256_file,
    verify_document,
)
from runtime_candidate_lock import verify_candidate_lock


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Verify emitted Chromium source-only provenance against the "
            "checked source contract and rebase plan."
        )
    )
    parser.add_argument("provenance", type=Path)
    parser.add_argument("--source-root", type=Path)
    parser.add_argument(
        "--runtime-lock",
        type=Path,
        help=(
            "Also require a new-candidate runtime lock coherent with the "
            "source contract. The published 0.3.12 legacy lock intentionally "
            "fails this release-only gate."
        ),
    )
    parser.add_argument("--project-root", type=Path, default=PROJECT_ROOT)
    args = parser.parse_args()
    try:
        if not args.provenance.is_absolute():
            raise SourceProvenanceError(
                "Source provenance path must be absolute"
            )
        document = load_object(
            args.provenance,
            "emitted Chromium source provenance",
        )
        project_root = args.project_root.resolve()
        verify_document(document, project_root=project_root)
        if args.runtime_lock is not None:
            verify_candidate_lock(
                args.runtime_lock,
                args.provenance,
                project_root=project_root,
            )
        if args.source_root is not None:
            fresh = build_provenance(
                args.source_root,
                project_root=project_root,
            )
            if document != fresh:
                raise SourceProvenanceError(
                    "Emitted provenance does not match fresh source-root evidence"
                )
    except (OSError, SourceProvenanceError) as error:
        print(f"Source provenance verification failed: {error}", file=sys.stderr)
        return 1
    print("PASS: Chromium source provenance matches contract and rebase plan.")
    print(f"SHA-256: {sha256_file(args.provenance)}")
    print("Binary binding remains pending until a new runtime report records this SHA-256.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
