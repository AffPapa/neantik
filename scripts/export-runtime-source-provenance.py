#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from runtime_source_provenance import (
    PROJECT_ROOT,
    SourceProvenanceError,
    atomic_write_json,
    build_provenance,
    sha256_file,
)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Validate the pinned Chromium 150 source pair and atomically export "
            "source-only provenance. This does not attest an existing binary."
        )
    )
    parser.add_argument("source_root", type=Path)
    parser.add_argument(
        "--output",
        type=Path,
        help=(
            "Absolute JSON output. Defaults to "
            "<build-root>/build/source-provenance.json."
        ),
    )
    parser.add_argument("--project-root", type=Path, default=PROJECT_ROOT)
    args = parser.parse_args()
    source_root = args.source_root
    output = args.output or source_root.parent / "source-provenance.json"
    try:
        document = build_provenance(
            source_root,
            project_root=args.project_root.resolve(),
        )
        atomic_write_json(output, document)
    except (OSError, SourceProvenanceError) as error:
        print(f"Source provenance export failed: {error}", file=sys.stderr)
        return 1
    print(f"Chromium 150 source provenance exported: {output}")
    print(f"SHA-256: {sha256_file(output)}")
    print("Binary binding: pending-new-build")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
