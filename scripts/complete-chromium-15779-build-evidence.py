#!/usr/bin/env python3
"""Seal the finished Chromium .79 source build before Direct runtime signing."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile

import chromium_15779_source as chromium


def encode_json(document):
    return (json.dumps(document, indent=2, ensure_ascii=False) + "\n").encode()


def complete(source, project, transcript, exit_code):
    runtime = project / "runtime"
    contract_path = runtime / chromium.CONTRACT
    evidence_path = runtime / chromium.BUILD_EVIDENCE
    before = contract_path.read_bytes()
    contract = chromium.verify_contract(project)
    evidence = chromium.capture_build_evidence(source, project, transcript, exit_code)
    encoded_evidence = encode_json(evidence)
    if contract["binaryBindingStatus"] == "pending-runtime-report":
        if evidence_path.read_bytes() != encoded_evidence:
            raise ValueError("Completed Chromium .79 contract already binds different evidence")
        return evidence_path
    baseline = chromium._checked_file(runtime, "security-baseline.json")
    contract.update(
        status="build-complete-runtime-report-pending",
        binaryBindingStatus="pending-runtime-report",
        buildEvidenceFile=f"runtime/{chromium.BUILD_EVIDENCE}",
        buildEvidenceSHA256=hashlib.sha256(encoded_evidence).hexdigest(),
        securityBaselineSHA256=chromium._sha256(baseline),
    )
    try:
        with evidence_path.open("xb") as output:
            output.write(encoded_evidence)
    except FileExistsError:
        if evidence_path.is_symlink() or evidence_path.read_bytes() != encoded_evidence:
            raise ValueError("A different Chromium .79 build evidence file already exists")
    with tempfile.NamedTemporaryFile(dir=runtime, delete=False) as output:
        temporary = Path(output.name)
        output.write(encode_json(contract))
    try:
        os.chmod(temporary, contract_path.stat().st_mode & 0o777)
        if contract_path.read_bytes() != before:
            raise ValueError("Source contract changed while collecting Chromium .79 evidence")
        temporary.replace(contract_path)
    finally:
        temporary.unlink(missing_ok=True)
    chromium.verify_contract(project)
    return evidence_path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_root", type=Path)
    parser.add_argument("--project-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--ninja-log", type=Path, required=True, help="Full watched chrome build transcript")
    parser.add_argument("--ninja-exit-code", type=int, required=True, help="Actual terminal result of the watched chrome invocation")
    args = parser.parse_args()
    try:
        evidence = complete(args.source_root, args.project_root.resolve(), args.ninja_log, args.ninja_exit_code)
    except (OSError, ValueError, KeyError) as error:
        print(f"Chromium .79 build evidence rejected: {error}", file=sys.stderr)
        return 1
    print(f"Recorded unsigned Chromium .79 build evidence: {evidence}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
