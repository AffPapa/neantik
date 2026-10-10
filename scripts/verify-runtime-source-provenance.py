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
from chromium_154_release_evidence import M154EvidenceError, verify_candidate_document
from chromium_15498_release_evidence import (
    M15498EvidenceError,
    verify_candidate_document as verify_candidate_15498_document,
)

from chromium_15540_release_evidence import M15540EvidenceError
from chromium_15540_variant import verify_candidate_document as verify_candidate_15540_document


def verify_live_source(document: dict, source_root: Path, project_root: Path) -> None:
    if document.get("targetChromiumVersion") == "156.0.8078.12":
        from chromium_15612_release_evidence import verify_candidate_document as verify_m156
        try:
            verify_m156(document, project_root=project_root, source_root=source_root)
        except ValueError as error:
            raise SourceProvenanceError(str(error)) from error
        return
    if document.get("targetChromiumVersion") == "154.0.8037.93":
        try:
            verify_candidate_document(document, project_root=project_root, source_root=source_root)
        except M154EvidenceError as error:
            raise SourceProvenanceError(str(error)) from error
        return
    if document.get("targetChromiumVersion") == "154.0.8037.98":
        try:
            verify_candidate_15498_document(
                document, project_root=project_root, source_root=source_root
            )
        except M15498EvidenceError as error:
            raise SourceProvenanceError(str(error)) from error
        return
    if document.get("targetChromiumVersion") == "155.0.8059.40":
        try:
            verify_candidate_15540_document(
                document, project_root=project_root, source_root=source_root
            )
        except M15540EvidenceError as error:
            raise SourceProvenanceError(str(error)) from error
        return
    fresh = build_provenance(source_root, project_root=project_root)
    if document != fresh:
        raise SourceProvenanceError("Emitted provenance does not match fresh source-root evidence")


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Verify emitted Chromium source-only provenance against the "
            "checked source contract and rebase plan."
        )
    )
    parser.add_argument("provenance", type=Path)
    parser.add_argument("--source-root", type=Path)
    parser.add_argument("--built-source-root", type=Path, help="M156 only: unchanged built output and current packaging inputs, not fresh whole-tree proof")
    parser.add_argument("--build-evidence", type=Path, help="Private executed final9 build evidence")
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
        if args.built_source_root is not None or args.build_evidence is not None:
            if document.get("targetChromiumVersion") != "156.0.8078.12" or args.built_source_root is None or args.build_evidence is None or args.source_root is not None:
                raise SourceProvenanceError("Preserved build mode requires exact M156 root and evidence; cannot be combined with live mode")
            from chromium_15612_built_source import verify as verify_built_source
            try:
                verify_built_source(args.built_source_root, args.build_evidence, document, project_root)
            except ValueError as error:
                raise SourceProvenanceError(str(error)) from error
        if args.source_root is not None:
            verify_live_source(document, args.source_root, project_root)
    except (OSError, SourceProvenanceError) as error:
        print(f"Source provenance verification failed: {error}", file=sys.stderr)
        return 1
    if document.get("targetChromiumVersion") == "153.0.8010.52":
        print("PASS: Chromium 153 source provenance matches the owned port evidence.")
    else:
        print("PASS: Chromium source provenance matches contract and rebase plan.")
    print(f"SHA-256: {sha256_file(args.provenance)}")
    print("Binary binding remains pending until a new runtime report records this SHA-256.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
