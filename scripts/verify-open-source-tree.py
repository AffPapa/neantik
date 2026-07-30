#!/usr/bin/env python3

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
RELEASE_METADATA = PROJECT_ROOT / "releases" / "v0.3.12.json"

FORBIDDEN_PARTS = {
    ".build",
    ".build-support",
    ".swiftpm",
    "DerivedData",
    "StoreEdition",
    "StoreSubmission",
    "TelemetryDashboard",
    "dist",
    "node_modules",
    "__pycache__",
}
FORBIDDEN_SUFFIXES = {
    ".p12",
    ".pem",
    ".key",
    ".mobileprovision",
    ".pyc",
}
FORBIDDEN_NAMES = {
    ".DS_Store",
    ".env",
}
FORBIDDEN_TEXT = {
    "/Users/dumay": "personal absolute path",
    "root@135.181.253.143": "private deployment endpoint",
    "/Users/dumay/AFF.job/.secrets": "private secret-store path",
}
SECRET_PATTERNS = {
    "private key": re.compile(r"BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY"),
    "GitHub token": re.compile(r"\bgh[opsu]_[A-Za-z0-9_]{20,}\b"),
    "AWS access key": re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
}
TEXT_SUFFIXES = {
    "",
    ".command",
    ".css",
    ".html",
    ".json",
    ".md",
    ".mjs",
    ".plist",
    ".py",
    ".sh",
    ".swift",
    ".toml",
    ".ts",
    ".tsx",
    ".txt",
    ".yml",
    ".yaml",
}
REQUIRED_PUBLIC_PATHS = {
    ".github/workflows/ci.yml",
    "CONTRIBUTING.md",
    "LICENSE",
    "SECURITY.md",
    "Sources/NeAntik/SecureEnclaveFingerprintEvidenceSigner.swift",
    "Sources/NeAntik/UpdateManifest.swift",
    "Tests/Fixtures/fingerprint-conformance/base-production-qualified.json",
    "Tests/Fixtures/fingerprint-conformance/manifest.json",
    "Tests/NeAntikTests/SecureEnclaveFingerprintEvidenceSignerTests.swift",
    "Tests/NeAntikTests/UpdateManifestTests.swift",
    "docs/PUBLIC_FINGERPRINT_CONFORMANCE.md",
    "docs/RUNTIME_INTEGRATION_NOTICES.md",
    "docs/FINGERPRINT_DIAGNOSTIC_EVIDENCE.md",
    "docs/security/fingerprint-evidence-schema-8.md",
    "runtime/chromium-150-source-contract.json",
    "runtime/chromium-150-toolchain-lock.json",
    "scripts/Run-NeAntik-Runtime-Audit.command",
    "scripts/generate-runtime-integration-notices.py",
    "scripts/export-runtime-source-provenance.py",
    "scripts/verify-runtime-source-provenance.py",
    "scripts/export-runtime-candidate-lock.py",
    "scripts/verify-runtime-candidate-lock.py",
    "scripts/promote-runtime-candidate-lock.py",
    "scripts/runtime_source_provenance.py",
    "scripts/runtime_candidate_lock.py",
    "scripts/tests/test_generate_runtime_integration_notices.py",
    "scripts/tests/fixtures/fingerprint-evidence-schema8-swift.json",
    "scripts/tests/test_fingerprint_evidence_schema8.py",
    "scripts/tests/test_runtime_source_provenance.py",
    "scripts/tests/test_runtime_candidate_lock.py",
    "scripts/tests/test_verify_public_artifact_privacy.py",
    "scripts/tests/test_runtime_audit_launcher.py",
    "scripts/tests/test_verify_direct_hosted_download_oss.py",
    "scripts/tests/test_verify_public_fingerprint_corpus.py",
    "scripts/tests/test_verify_public_workflow_references.py",
    "scripts/verify-direct-hosted-download.py",
    "scripts/fingerprint_evidence_schema8.py",
    "scripts/verify-fingerprint-evidence-envelope.py",
    "scripts/verify-public-artifact-privacy.py",
    "scripts/verify-direct-update-policy.py",
    "scripts/verify-public-fingerprint-corpus.py",
    "scripts/verify-public-workflow-references.py",
}


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def iter_public_files() -> list[Path]:
    files: list[Path] = []
    for path in PROJECT_ROOT.rglob("*"):
        relative = path.relative_to(PROJECT_ROOT)
        if ".git" in relative.parts:
            continue
        if any(part in FORBIDDEN_PARTS for part in relative.parts):
            fail(f"forbidden generated path is present: {relative}")
        if path.is_symlink():
            fail(f"symbolic link is not allowed in public source: {relative}")
        if path.is_file():
            files.append(path)
    return files


def verify_files(files: list[Path]) -> None:
    for path in files:
        relative = path.relative_to(PROJECT_ROOT)
        if path.resolve() == Path(__file__).resolve():
            continue
        if path.name in FORBIDDEN_NAMES or path.suffix.lower() in FORBIDDEN_SUFFIXES:
            fail(f"forbidden file is present: {relative}")
        if path.suffix.lower() not in TEXT_SUFFIXES:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        for needle, description in FORBIDDEN_TEXT.items():
            if needle in text:
                fail(f"{description} found in {relative}")
        for description, pattern in SECRET_PATTERNS.items():
            if pattern.search(text):
                fail(f"possible {description} found in {relative}")


def verify_release_metadata() -> None:
    metadata = json.loads(RELEASE_METADATA.read_text(encoding="utf-8"))
    archive = metadata["archive"]
    sidecar = PROJECT_ROOT / "releases" / f"{archive['name']}.sha256"
    expected = f"{archive['sha256']}  {archive['name']}\n"
    if sidecar.read_text(encoding="utf-8") != expected:
        fail("release checksum sidecar does not match releases/v0.3.12.json")

    plist = PROJECT_ROOT / "Resources" / "Info.plist"
    plist_text = plist.read_text(encoding="utf-8")
    if f"<string>{metadata['version']}</string>" not in plist_text:
        fail("release version does not match Resources/Info.plist")
    if f"<string>{metadata['build']}</string>" not in plist_text:
        fail("release build does not match Resources/Info.plist")


def verify_required_contracts() -> None:
    missing = sorted(
        path
        for path in REQUIRED_PUBLIC_PATHS
        if not (PROJECT_ROOT / path).is_file()
    )
    if missing:
        fail("required public source files are missing: " + ", ".join(missing))

    ci_text = (
        PROJECT_ROOT / ".github/workflows/ci.yml"
    ).read_text(encoding="utf-8")
    for marker in [
        "UpdateManifestTests",
        "SecureEnclaveFingerprintEvidenceSignerTests",
        "generate-runtime-integration-notices.py --check",
        "verify-public-fingerprint-corpus.py",
        "verify-open-source-tree.py",
        "verify-public-workflow-references.py",
        "test_fingerprint_evidence_schema8",
    ]:
        if marker not in ci_text:
            fail(f"GitHub Actions does not enforce {marker}")

    result = subprocess.run(
        [
            sys.executable,
            str(
                PROJECT_ROOT
                / "scripts/verify-public-fingerprint-corpus.py"
            ),
        ],
        cwd=PROJECT_ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        fail(f"public fingerprint corpus failed: {detail}")

    workflow_result = subprocess.run(
        [
            sys.executable,
            str(
                PROJECT_ROOT
                / "scripts/verify-public-workflow-references.py"
            ),
        ],
        cwd=PROJECT_ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    if workflow_result.returncode != 0:
        detail = (workflow_result.stderr or workflow_result.stdout).strip()
        fail(f"public workflow reference gate failed: {detail}")


def main() -> None:
    files = iter_public_files()
    verify_files(files)
    verify_release_metadata()
    verify_required_contracts()
    print(
        "PASS: open-source tree contains no generated build roots, "
        "private deployment paths, or recognized secret material; "
        f"{len(files)} file(s) checked."
    )


if __name__ == "__main__":
    main()
