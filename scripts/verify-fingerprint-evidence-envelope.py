#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from fingerprint_evidence_schema8 import (
    FingerprintEvidenceVerificationError,
    MAXIMUM_ENVELOPE_BYTES,
    MAXIMUM_MANIFEST_BYTES,
    read_bounded_regular_file,
    verify_fingerprint_evidence,
)


class SafeArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        self.exit(
            2,
            "Fingerprint evidence verification failed: "
            "invalid command arguments.\n",
        )


def main() -> int:
    parser = SafeArgumentParser(
        description=(
            "Verify one canonical candidate-bound NeAntik schema-8 "
            "fingerprint evidence envelope."
        )
    )
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--envelope", type=Path, required=True)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    try:
        result = verify_fingerprint_evidence(
            candidate_manifest_raw=read_bounded_regular_file(
                args.manifest,
                maximum_bytes=MAXIMUM_MANIFEST_BYTES,
                label="Candidate manifest",
            ),
            envelope_raw=read_bounded_regular_file(
                args.envelope,
                maximum_bytes=MAXIMUM_ENVELOPE_BYTES,
                label="Fingerprint evidence envelope",
            ),
        )
    except FingerprintEvidenceVerificationError as error:
        print(
            f"Fingerprint evidence verification failed: {error}",
            file=sys.stderr,
        )
        return 1

    summary = {
        "schemaVersion": 1,
        "candidateManifestSHA256":
            result.candidate_manifest_sha256,
        "payloadSHA256": result.payload_sha256,
        "authenticatedEvidenceID":
            result.authenticated_evidence_id,
        "transportSHA256": result.transport_sha256,
    }
    if args.json:
        print(
            json.dumps(
                summary,
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
            )
        )
    else:
        print(
            "PASS: authenticated schema-8 fingerprint evidence verified; "
            f"evidence ID {result.authenticated_evidence_id}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
