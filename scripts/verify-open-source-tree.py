#!/usr/bin/env python3

from __future__ import annotations

import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]

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
    ".provisionprofile",
    ".pyc",
}
FORBIDDEN_NAMES = {
    ".DS_Store",
    ".env",
}
PERSONAL_USER_PATH_RE = re.compile(
    re.escape("/") + r"Users/(?P<username>[A-Za-z0-9._-]+)(?:/|$)"
)
PRIVATE_DEPLOYMENT_ENDPOINT_RE = re.compile(
    r"(?<![A-Za-z0-9._-])root@[A-Za-z0-9][A-Za-z0-9.-]*\b"
)
PRIVATE_SECRET_STORE_PATH_RE = re.compile(
    re.escape("/")
    + r"(?:Users|home)/[^\"'\r\n]{1,256}/"
    + r"(?:\.secrets|\.credentials|private[-_]?keys)(?:/|[\"'\s]|$)",
    re.IGNORECASE,
)
SYNTHETIC_TEST_USERNAMES = frozenset({"alice", "example", "test"})
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
    "Develop-NeAntik.command",
    "LICENSE",
    "Release-NeAntik.command",
    "Resources/NeAntik.entitlements",
    "SECURITY.md",
    "Sources/NeAntik/BrowserProcessInventory.swift",
    "Sources/NeAntik/ApplicationEnvironment.swift",
    "Sources/NeAntik/FingerprintEvidenceEnrollment.swift",
    "Sources/NeAntik/FingerprintEvidenceEnvelope.swift",
    "Sources/NeAntik/FingerprintEvidenceRecoveryStore.swift",
    "Sources/NeAntik/FingerprintEvidenceReleaseContext.swift",
    "Sources/NeAntik/FingerprintReleaseEvidencePayload.swift",
    "Sources/NeAntik/ProfileListProjection.swift",
    "Sources/NeAntik/ProfileListOrdering.swift",
    "Sources/NeAntik/ProxyImportParser.swift",
    "Sources/NeAntik/SecureEnclaveFingerprintEvidenceSigner.swift",
    "Sources/NeAntik/UpdateManifest.swift",
    "Sources/NeAntik/WorkspaceLayout.swift",
    "Tests/Fixtures/fingerprint-conformance/base-production-qualified.json",
    "Tests/Fixtures/fingerprint-conformance/manifest.json",
    "Tests/NeAntikTests/FingerprintEvidenceEnrollmentTests.swift",
    "Tests/NeAntikTests/ApplicationEnvironmentTests.swift",
    "Tests/NeAntikTests/BrowserProcessInventoryTests.swift",
    "Tests/NeAntikTests/FingerprintEvidenceEnvelopeTests.swift",
    "Tests/NeAntikTests/FingerprintEvidenceReleaseContextTests.swift",
    "Tests/NeAntikTests/ProfileOrganizationTests.swift",
    "Tests/NeAntikTests/ProfileListOrderingTests.swift",
    "Tests/NeAntikTests/ProxyImportParserTests.swift",
    "Tests/NeAntikTests/ResponsiveLayoutRenderTests.swift",
    "Tests/NeAntikTests/WorkspaceLayoutTests.swift",
    "Tests/NeAntikTests/SecureEnclaveFingerprintEvidenceSignerTests.swift",
    "Tests/NeAntikTests/UpdateManifestTests.swift",
    "docs/PUBLIC_FINGERPRINT_CONFORMANCE.md",
    "docs/UNIFIED_MINIMAL_UX.md",
    "docs/RUNTIME_INTEGRATION_NOTICES.md",
    "docs/FINGERPRINT_DIAGNOSTIC_EVIDENCE.md",
    "docs/security/fingerprint-evidence-schema-8.md",
    "runtime/chromium-152-source-contract.json",
    "runtime/chromium-152-toolchain-lock.json",
    "runtime/browser-identity-issuance.json",
    "scripts/Run-NeAntik-DMG-Hosted-Verification.command",
    "scripts/Run-NeAntik-DMG-Release.command",
    "scripts/Run-NeAntik-Hosted-Verification.command",
    "scripts/Run-NeAntik-Release.command",
    "scripts/Run-NeAntik-Runtime-Audit.command",
    "scripts/run-local-manager.sh",
    "scripts/generate-runtime-integration-notices.py",
    "scripts/export-runtime-source-provenance.py",
    "scripts/verify-runtime-source-provenance.py",
    "scripts/export-runtime-candidate-lock.py",
    "scripts/verify-runtime-candidate-lock.py",
    "scripts/verify-browser-identity-issuance.py",
    "scripts/promote-runtime-candidate-lock.py",
    "scripts/runtime_source_provenance.py",
    "scripts/runtime_candidate_lock.py",
    "scripts/tests/test_generate_runtime_integration_notices.py",
    "scripts/tests/fixtures/fingerprint-evidence-schema8-swift.json",
    "scripts/tests/test_direct_candidate_manifest.py",
    "scripts/tests/test_fingerprint_evidence_schema8.py",
    "scripts/generate-fingerprint-evidence-schema8-fixture.py",
    "scripts/tests/test_run_exact_command_with_timeout.py",
    "scripts/tests/test_runtime_source_provenance.py",
    "scripts/tests/test_runtime_candidate_lock.py",
    "scripts/tests/test_verify_browser_identity_issuance.py",
    "scripts/tests/test_release_input_snapshot.py",
    "scripts/tests/test_verify_public_artifact_privacy.py",
    "scripts/tests/test_verify_open_source_tree.py",
    "scripts/tests/test_runtime_audit_launcher.py",
    "scripts/tests/test_verify_direct_hosted_download_oss.py",
    "scripts/tests/test_verify_public_fingerprint_corpus.py",
    "scripts/tests/test_verify_public_workflow_references.py",
    "scripts/direct-candidate-manifest.py",
    "scripts/enroll-direct-fingerprint-authority.sh",
    "scripts/run-exact-command-with-timeout.py",
    "scripts/release_input_snapshot.py",
    "scripts/release_transaction.py",
    "scripts/release_source_receipt.py",
    "scripts/notary_transaction_state.py",
    "scripts/notary_transaction_inspector.py",
    "scripts/run-isolated-release-python.py",
    "scripts/notarize_direct_transaction.py",
    "scripts/verify-direct-hosted-download.py",
    "scripts/fingerprint_evidence_schema8.py",
    "scripts/verify-fingerprint-evidence-envelope.py",
    "scripts/verify-public-artifact-privacy.py",
    "scripts/verify-direct-update-policy.py",
    "scripts/verify-direct-provisioning-profile.py",
    "scripts/verify-secure-enclave-release-authority.py",
    "scripts/verify-public-fingerprint-corpus.py",
    "scripts/verify-public-workflow-references.py",
    "scripts/tests/test_release_launcher.py",
    "scripts/tests/test_verify_secure_enclave_release_authority.py",
    "scripts/tests/test_verify_direct_provisioning_profile.py",
    "scripts/tests/test_release_transaction.py",
    "scripts/tests/test_release_source_receipt.py",
    "scripts/tests/test_notary_transaction_state.py",
    "scripts/tests/test_notary_transaction_inspector.py",
    "scripts/tests/test_run_isolated_release_python.py",
    "scripts/tests/test_notarize_direct_transaction.py",
}


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def iter_public_files() -> list[Path]:
    git_listing = subprocess.run(
        [
            "git",
            "ls-files",
            "-z",
            "--cached",
            "--others",
            "--exclude-standard",
        ],
        cwd=PROJECT_ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if git_listing.returncode == 0:
        files: list[Path] = []
        for raw_relative in git_listing.stdout.split(b"\0"):
            if not raw_relative:
                continue
            relative = Path(raw_relative.decode("utf-8"))
            if any(part in FORBIDDEN_PARTS for part in relative.parts):
                fail(f"forbidden generated path is present: {relative}")
            path = PROJECT_ROOT / relative
            if path.is_symlink():
                fail(
                    "symbolic link is not allowed in public source: "
                    f"{relative}"
                )
            if path.is_file():
                files.append(path)
        return files

    # Exported source archives may not contain .git. In that case preserve the
    # strict filesystem walk and reject any generated/private directory.
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


def is_synthetic_test_user_path(relative: Path, username: str) -> bool:
    parts = relative.parts
    is_test_path = (
        bool(parts) and parts[0] == "Tests"
    ) or (
        len(parts) >= 2 and parts[0] == "scripts" and parts[1] == "tests"
    )
    return is_test_path and username.lower() in SYNTHETIC_TEST_USERNAMES


def text_violation(relative: Path, text: str) -> str | None:
    if PRIVATE_SECRET_STORE_PATH_RE.search(text):
        return "private secret-store path"

    for match in PERSONAL_USER_PATH_RE.finditer(text):
        if not is_synthetic_test_user_path(relative, match.group("username")):
            return "personal absolute path"

    if PRIVATE_DEPLOYMENT_ENDPOINT_RE.search(text):
        return "private deployment endpoint"

    for description, pattern in SECRET_PATTERNS.items():
        if pattern.search(text):
            return f"possible {description}"
    return None


def verify_files(files: list[Path]) -> None:
    for path in files:
        relative = path.relative_to(PROJECT_ROOT)
        if path.name in FORBIDDEN_NAMES or path.suffix.lower() in FORBIDDEN_SUFFIXES:
            fail(f"forbidden file is present: {relative}")
        if path.suffix.lower() not in TEXT_SUFFIXES:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        violation = text_violation(relative, text)
        if violation is not None:
            fail(f"{violation} found in {relative}")


def verify_release_metadata() -> None:
    metadata_files = sorted((PROJECT_ROOT / "releases").glob("v*.json"))
    if not metadata_files:
        fail("no public release metadata is present")

    parsed_metadata = [
        json.loads(path.read_text(encoding="utf-8"))
        for path in metadata_files
    ]

    def version_key(metadata: dict[str, object]) -> tuple[int, ...]:
        version = str(metadata.get("version", ""))
        if not re.fullmatch(r"\d+(?:\.\d+)+", version):
            fail(f"invalid release version in releases/v{version}.json")
        return tuple(int(part) for part in version.split("."))

    metadata = max(parsed_metadata, key=version_key)
    archive = metadata["archive"]
    sidecar = PROJECT_ROOT / "releases" / f"{archive['name']}.sha256"
    expected = f"{archive['sha256']}  {archive['name']}\n"
    if sidecar.read_text(encoding="utf-8") != expected:
        fail(
            "release checksum sidecar does not match "
            f"releases/v{metadata['version']}.json"
        )

    plist = PROJECT_ROOT / "Resources" / "Info.plist"
    with plist.open("rb") as file:
        info = plistlib.load(file)
    app_version = str(info.get("CFBundleShortVersionString", ""))
    app_build = str(info.get("CFBundleVersion", ""))
    if not re.fullmatch(r"\d+(?:\.\d+)+", app_version):
        fail("Resources/Info.plist contains an invalid release version")
    if not app_build.isdigit():
        fail("Resources/Info.plist contains an invalid build number")

    published_version = str(metadata["version"])
    published_build = str(metadata["build"])
    app_key = tuple(int(part) for part in app_version.split("."))
    published_key = version_key(metadata)
    if app_key < published_key:
        fail("manager version is older than the latest public release metadata")
    if app_key == published_key and app_build != published_build:
        fail("release build does not match Resources/Info.plist")
    if app_key > published_key:
        changelog = (PROJECT_ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
        marker = f"## Direct {app_version} ({app_build})"
        if marker not in changelog:
            fail(
                "newer release candidate is missing its version/build "
                "changelog section"
            )


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
    if "run: ./scripts/verify-native-swift-tests.sh" not in ci_text:
        fail("GitHub Actions does not enforce the complete Swift test suite")
    swift_test_runner = (
        PROJECT_ROOT / "scripts/verify-native-swift-tests.sh"
    ).read_text(encoding="utf-8")
    if "swift test" not in swift_test_runner or "--filter" in swift_test_runner:
        fail("the complete Swift test runner must execute without a suite filter")
    for marker in [
        "generate-runtime-integration-notices.py --check",
        "verify-public-fingerprint-corpus.py",
        "verify-open-source-tree.py",
        "verify-public-workflow-references.py",
        "test_direct_candidate_manifest",
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
