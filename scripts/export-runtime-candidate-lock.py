#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from runtime_candidate_lock import (
    PROJECT_ROOT,
    expected_candidate_lock,
    refuse_published_lock_output,
    verify_candidate_lock,
)
from runtime_source_provenance import (
    SourceProvenanceError,
    atomic_write_json,
    sha256_file,
)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Create a deterministic source-only schema 4 candidate lock next "
            "to emitted Chromium source provenance."
        )
    )
    parser.add_argument("provenance", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--project-root", type=Path, default=PROJECT_ROOT)
    args = parser.parse_args()
    project_root = args.project_root.resolve()
    provenance = args.provenance.resolve()
    output = args.output or provenance.parent / "runtime-candidate-lock.json"
    try:
        if not output.is_absolute():
            raise SourceProvenanceError(
                "Candidate lock output path must be absolute"
            )
        if output.parent.resolve() != provenance.parent.resolve():
            raise SourceProvenanceError(
                "Candidate lock must be emitted next to source provenance "
                "inside the build root"
            )
        refuse_published_lock_output(output, project_root=project_root)
        document = expected_candidate_lock(
            provenance,
            project_root=project_root,
        )
        atomic_write_json(output, document)
        verify_candidate_lock(
            output,
            provenance,
            project_root=project_root,
        )
    except (OSError, SourceProvenanceError) as error:
        print(f"Candidate lock export failed: {error}", file=sys.stderr)
        return 1
    print(f"Chromium candidate lock exported: {output}")
    print(f"SHA-256: {sha256_file(output)}")
    print("Binary binding: not attested by this source-only document")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
