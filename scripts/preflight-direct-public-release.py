#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.util
import hashlib
import json
import os
import plistlib
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlparse


PROJECT_ROOT = Path(__file__).resolve().parents[1]
GUI_VERIFIER_PATH = PROJECT_ROOT / "scripts" / "verify-gui-fingerprint-report.py"
SPEC = importlib.util.spec_from_file_location(
    "verify_gui_fingerprint_report",
    GUI_VERIFIER_PATH,
)
assert SPEC and SPEC.loader
GUI_VERIFIER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = GUI_VERIFIER
SPEC.loader.exec_module(GUI_VERIFIER)
EVIDENCE_SCHEMA_PATH = (
    PROJECT_ROOT / "scripts" / "fingerprint_evidence_schema8.py"
)
EVIDENCE_SPEC = importlib.util.spec_from_file_location(
    "fingerprint_evidence_schema8_for_preflight",
    EVIDENCE_SCHEMA_PATH,
)
assert EVIDENCE_SPEC and EVIDENCE_SPEC.loader
EVIDENCE_SCHEMA = importlib.util.module_from_spec(EVIDENCE_SPEC)
sys.modules[EVIDENCE_SPEC.name] = EVIDENCE_SCHEMA
EVIDENCE_SPEC.loader.exec_module(EVIDENCE_SCHEMA)
NOTARY_INSPECTOR_PATH = (
    PROJECT_ROOT / "scripts" / "notary_transaction_inspector.py"
)
if str(NOTARY_INSPECTOR_PATH.parent) not in sys.path:
    sys.path.insert(0, str(NOTARY_INSPECTOR_PATH.parent))
NOTARY_INSPECTOR_SPEC = importlib.util.spec_from_file_location(
    "notary_transaction_inspector_for_preflight",
    NOTARY_INSPECTOR_PATH,
)
assert NOTARY_INSPECTOR_SPEC and NOTARY_INSPECTOR_SPEC.loader
NOTARY_INSPECTOR = importlib.util.module_from_spec(
    NOTARY_INSPECTOR_SPEC
)
sys.modules[NOTARY_INSPECTOR_SPEC.name] = NOTARY_INSPECTOR
NOTARY_INSPECTOR_SPEC.loader.exec_module(NOTARY_INSPECTOR)


VERSION_RE = re.compile(r"^(?P<parts>[0-9]+(?:\.[0-9]+){1,3})")


@dataclass(frozen=True)
class GateResult:
    name: str
    passed: bool
    details: str


def read_plist(path: Path) -> dict[str, Any]:
    with path.open("rb") as file:
        return plistlib.load(file)


def read_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return value


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_version(value: str) -> tuple[int, ...]:
    match = VERSION_RE.match(value)
    if not match:
        raise ValueError(f"Invalid version: {value}")
    return tuple(int(part) for part in match.group("parts").split("."))


def version_at_least(actual: str, minimum: str) -> bool:
    actual_parts = parse_version(actual)
    minimum_parts = parse_version(minimum)
    width = max(len(actual_parts), len(minimum_parts))
    return actual_parts + (0,) * (width - len(actual_parts)) >= minimum_parts + (
        0,
    ) * (width - len(minimum_parts))


def args_enable_metal(args_path: Path) -> bool:
    text = args_path.read_text(encoding="utf-8")
    true_count = len(
        re.findall(r"(?m)^[ \t]*angle_enable_metal[ \t]*=[ \t]*true[ \t]*$", text)
    )
    false_count = len(
        re.findall(r"(?m)^[ \t]*angle_enable_metal[ \t]*=[ \t]*false[ \t]*$", text)
    )
    return true_count == 1 and false_count == 0


def validate_download_url(url: str, *, archive_name: str) -> str:
    parsed = urlparse(url)
    if parsed.scheme != "https" or not parsed.hostname:
        raise ValueError("download URL must be absolute HTTPS")
    if parsed.username or parsed.password:
        raise ValueError("download URL must not include credentials")
    basename = Path(unquote(parsed.path)).name
    if basename != archive_name:
        raise ValueError(
            f"download URL basename must be {archive_name!r}, got {basename!r}"
        )
    return url


def default_runtime_app(integrated_app: Path) -> Path:
    return integrated_app / "Contents" / "Resources" / "NeAntik Browser.app"


def default_args_gn(integrated_app: Path) -> Path:
    return (
        integrated_app
        / "Contents"
        / "Resources"
        / "NeAntikRuntimeEvidence"
        / "args.gn"
    )


def gate(name: str, func) -> GateResult:
    try:
        details = func()
        return GateResult(name, True, details or "ok")
    except Exception as error:
        return GateResult(name, False, str(error))


def verify_direct_public_release_plan(
    *,
    project_root: Path,
    integrated_app: Path,
    runtime_app: Path,
    args_gn: Path,
    gui_fingerprint_report: Path,
    runtime_lock: Path,
    download_url: str | None,
    release_channel: str | None = None,
    candidate_manifest: Path | None = None,
    notary_transaction_report: dict[str, object] | None = None,
    env: dict[str, str] | None = None,
) -> list[GateResult]:
    env = env if env is not None else os.environ
    effective_release_channel = (
        release_channel or env.get("NEANTIK_RELEASE_CHANNEL", "")
    ).strip()
    candidate_manifest = (
        candidate_manifest
        if candidate_manifest is not None
        else gui_fingerprint_report.with_name(
            "direct-candidate-manifest.json"
        )
    )
    info_plist = read_plist(project_root / "Resources" / "Info.plist")
    version = str(info_plist["CFBundleShortVersionString"])
    expected_archive_name = f"NeAntik-{version}-arm64-notarized.zip"
    transaction_report = (
        notary_transaction_report
        if notary_transaction_report is not None
        else NOTARY_INSPECTOR.inspect_dist(
            project_root / "dist",
            expected_archive_name=expected_archive_name,
        )
    )

    def release_channel_contract() -> str:
        if effective_release_channel not in {"public-alpha", "production"}:
            raise ValueError(
                "NEANTIK_RELEASE_CHANNEL must be public-alpha or production"
            )
        return effective_release_channel

    def integrated_bundle() -> str:
        if not integrated_app.is_dir():
            raise FileNotFoundError(f"Integrated app is missing: {integrated_app}")
        manager_plist = read_plist(integrated_app / "Contents" / "Info.plist")
        if manager_plist.get("CFBundleIdentifier") != "app.neantik.desktop":
            raise ValueError("Integrated app bundle identifier is not app.neantik.desktop")
        if manager_plist.get("CFBundleShortVersionString") != version:
            raise ValueError("Integrated app version does not match Resources/Info.plist")
        return f"NeAntik {version}"

    def runtime_security() -> str:
        baseline = read_json(project_root / "runtime" / "security-baseline.json")
        minimum = str(baseline["minimumPublicChromiumVersion"])
        runtime_plist = read_plist(runtime_app / "Contents" / "Info.plist")
        runtime_version = str(runtime_plist["CFBundleShortVersionString"])
        if not version_at_least(runtime_version, minimum):
            raise ValueError(f"runtime {runtime_version} is below public baseline {minimum}")
        return f"{runtime_version} >= {minimum}"

    def runtime_identity() -> str:
        if not runtime_app.is_dir():
            raise FileNotFoundError(f"Runtime app is missing: {runtime_app}")
        runtime_plist = read_plist(runtime_app / "Contents" / "Info.plist")
        expected = {
            "CFBundleIdentifier": "app.neantik.runtime",
            "NeAntikRuntimeFlavor": "fingerprint-chromium",
        }
        for key, value in expected.items():
            if runtime_plist.get(key) != value:
                raise ValueError(f"runtime {key} must be {value}")
        build_mode = runtime_plist.get("NeAntikRuntimeBuildMode")
        if build_mode not in {"source-build", "metal-integration"}:
            raise ValueError(
                "runtime NeAntikRuntimeBuildMode must be source-build or metal-integration"
            )
        return f"source-branded fingerprint Chromium runtime ({build_mode})"

    def runtime_lock_contract() -> str:
        runtime_plist = read_plist(runtime_app / "Contents" / "Info.plist")
        runtime_version = str(runtime_plist["CFBundleShortVersionString"])
        candidate_lock = read_json(runtime_lock)
        lock_version = str(
            candidate_lock.get("fingerprintChromium", {}).get(
                "chromiumVersion",
                "",
            )
        )
        if candidate_lock.get("schemaVersion") != 4:
            raise ValueError("runtime candidate lock must use schema 4")
        if runtime_version != lock_version:
            raise ValueError(
                "runtime app version does not match runtime lock: "
                f"{runtime_version} != {lock_version}"
            )
        distributed_runtime = GUI_VERIFIER.expected_runtime_evidence_from_app(
            integrated_app
        )
        if runtime_version != distributed_runtime["runtimeVersion"]:
            raise ValueError(
                "runtime app version does not match freshly hashed distributed runtime"
            )
        return (
            f"{runtime_version} matches runtime lock; distributed binary hashes "
            "match embedded evidence"
        )

    def runtime_source_provenance() -> str:
        evidence_root = args_gn.parent
        report_path = evidence_root / "runtime-verification.json"
        provenance_path = evidence_root / "source-provenance.json"
        embedded_candidate_path = (
            evidence_root / "fingerprint-chromium.lock.json"
        )
        embedded_contract_path = (
            evidence_root / "chromium-152-source-contract.json"
        )
        project_contract_path = (
            project_root / "runtime" / "chromium-152-source-contract.json"
        )
        for path, label in (
            (report_path, "runtime verification report"),
            (provenance_path, "source provenance"),
            (embedded_candidate_path, "embedded candidate lock"),
            (embedded_contract_path, "embedded source contract"),
            (project_contract_path, "project source contract"),
        ):
            if not path.is_file() or path.is_symlink():
                raise ValueError(f"{label} must be a regular non-symlinked file")
        report = read_json(report_path)
        if report.get("schemaVersion") != 3:
            raise ValueError(
                "new Direct candidate requires runtime provenance schema 3"
            )
        if report.get("sourceProvenanceSHA256") != sha256_file(provenance_path):
            raise ValueError(
                "runtime report is not bound to embedded source provenance"
            )
        candidate_sha = sha256_file(embedded_candidate_path)
        if report.get("candidateLockSHA256") != candidate_sha:
            raise ValueError(
                "runtime report is not bound to embedded candidate lock"
            )
        if report.get("sourceLockSHA256") != candidate_sha:
            raise ValueError(
                "runtime report source lock hash differs from candidate lock"
            )
        if report.get("sourceContractSHA256") != sha256_file(
            embedded_contract_path
        ):
            raise ValueError(
                "runtime report is not bound to embedded source contract"
            )
        if embedded_contract_path.read_bytes() != project_contract_path.read_bytes():
            raise ValueError(
                "embedded Chromium source contract differs from project contract"
            )
        provenance = read_json(provenance_path)
        contract = read_json(embedded_contract_path)
        candidate_lock = read_json(embedded_candidate_path)
        if embedded_candidate_path.read_bytes() != runtime_lock.read_bytes():
            raise ValueError(
                "embedded candidate lock differs from explicit release candidate"
            )
        if provenance.get("contractSHA256") != sha256_file(
            embedded_contract_path
        ):
            raise ValueError(
                "source provenance is not bound to embedded source contract"
            )
        if contract.get("binaryBindingStatus") != "pending-new-build":
            raise ValueError(
                "checked source contract has an unexpected binary-binding claim"
            )
        if candidate_lock.get("sourceContractSHA256") != sha256_file(
            embedded_contract_path
        ):
            raise ValueError(
                "new-candidate runtime lock is not bound to source contract"
            )
        if candidate_lock.get("sourceProvenanceSHA256") != sha256_file(
            provenance_path
        ):
            raise ValueError(
                "new-candidate runtime lock is not bound to source provenance"
            )
        if candidate_lock.get("schemaVersion") != 4:
            raise ValueError(
                "new-candidate runtime lock must use source-contract schema 4"
            )
        stale_text = json.dumps(
            {
                "contract": contract,
                "provenance": provenance,
                "runtimeLock": candidate_lock,
            },
            sort_keys=True,
        )
        if (
            "6bbb0dbdeae887af207c75c9e5173cceddbd381b" in stale_text
            or "144.0.7559.96" in stale_text
        ):
            raise ValueError("source evidence contains stale Chromium 144 provenance")
        return "schema 3 runtime report is bound to Chromium source provenance"

    def metal_args() -> str:
        if not args_gn.is_file():
            raise FileNotFoundError(f"args.gn is missing: {args_gn}")
        if not args_enable_metal(args_gn):
            raise ValueError("args.gn must contain exactly one angle_enable_metal=true and no false declaration")
        return "angle_enable_metal=true"

    def gui_report() -> str:
        if not gui_fingerprint_report.is_file():
            raise FileNotFoundError(f"GUI report is missing: {gui_fingerprint_report}")
        if not candidate_manifest.is_file():
            raise FileNotFoundError(
                f"Candidate manifest is missing: {candidate_manifest}"
            )
        verified = EVIDENCE_SCHEMA.verify_fingerprint_evidence(
            candidate_manifest_raw=(
                EVIDENCE_SCHEMA.read_bounded_regular_file(
                    candidate_manifest,
                    maximum_bytes=EVIDENCE_SCHEMA.MAXIMUM_MANIFEST_BYTES,
                    label="Candidate manifest",
                )
            ),
            envelope_raw=EVIDENCE_SCHEMA.read_bounded_regular_file(
                gui_fingerprint_report,
                maximum_bytes=EVIDENCE_SCHEMA.MAXIMUM_ENVELOPE_BYTES,
                label="Fingerprint evidence envelope",
            ),
        )
        payload = EVIDENCE_SCHEMA.load_canonical_json(
            verified.payload,
            maximum_bytes=EVIDENCE_SCHEMA.MAXIMUM_PAYLOAD_BYTES,
            label="Fingerprint evidence payload",
        )
        expected_runtime = GUI_VERIFIER.expected_runtime_evidence_from_app(
            integrated_app
        )
        for payload_key, expected_key in (
            ("managerVersion", "managerVersion"),
            ("managerBuild", "managerBuild"),
            ("runtimeVersion", "runtimeVersion"),
            ("runtimeExecutableSHA256", "runtimeExecutableSHA256"),
            ("runtimeFrameworkSHA256", "runtimeFrameworkSHA256"),
        ):
            if payload[payload_key] != expected_runtime[expected_key]:
                raise ValueError(
                    "authenticated GUI evidence does not match exact app"
                )
        if payload["releaseChannel"] != effective_release_channel:
            raise ValueError(
                "authenticated GUI evidence release channel mismatch"
            )
        if effective_release_channel == "production":
            if not payload["productionQualified"]:
                raise ValueError(
                    "authenticated GUI evidence is not production-qualified"
                )
            return "production-qualified authenticated GUI A -> B -> A evidence"
        if effective_release_channel == "public-alpha":
            if not payload["publicAlphaQualified"]:
                raise ValueError(
                    "authenticated GUI evidence is not public-alpha-qualified"
                )
        else:
            raise ValueError(
                "release channel must be validated before GUI qualification"
            )
        if not payload["productionQualified"]:
            return (
                "public-alpha authenticated GUI A -> B -> A evidence; "
                "strict coherent production hardening remains incomplete"
            )
        return "production-qualified authenticated GUI A -> B -> A evidence"

    def signing_env() -> str:
        identity = env.get("NEANTIK_SIGNING_IDENTITY", "").strip()
        if not identity:
            raise ValueError("NEANTIK_SIGNING_IDENTITY is missing")
        if not (
            identity.startswith("Developer ID Application:")
            or re.fullmatch(r"[0-9A-Fa-f]{40}", identity)
        ):
            raise ValueError("NEANTIK_SIGNING_IDENTITY must be a Developer ID Application name or SHA-1")
        return "Developer ID signing identity declared"

    def notary_env() -> str:
        if not env.get("NEANTIK_NOTARY_PROFILE", "").strip():
            raise ValueError("NEANTIK_NOTARY_PROFILE is missing")
        return "notarytool keychain profile declared"

    def archive_name_url_contract() -> str:
        if download_url:
            validate_download_url(download_url, archive_name=expected_archive_name)
            return f"expected archive name {expected_archive_name}; HTTPS URL basename matches"
        return (
            f"expected archive name {expected_archive_name}; "
            "download URL not provided to this read-only preflight"
        )

    def local_transaction_continuity() -> str:
        summary = transaction_report.get("summary")
        if not isinstance(summary, dict):
            raise ValueError(
                "local notarization transaction report is invalid"
            )
        if not transaction_report.get("safe"):
            raise ValueError(
                "local notarization transaction metadata is unsafe; "
                f"unsafe entries: {summary.get('unsafeCount', 'unknown')}"
            )
        if not transaction_report.get("releaseReady"):
            raise ValueError(
                "local notarization transaction requires reconciliation; "
                "no new Apple submission is allowed; "
                "blocking entries: "
                f"{summary.get('releaseBlockingCount', 'unknown')}"
            )
        return (
            "read-only transaction continuity verified; "
            f"active {summary.get('activeCount', 0)}, "
            f"retired history {summary.get('retiredCount', 0)}"
        )

    return [
        gate("Explicit Direct release channel", release_channel_contract),
        gate("Integrated Direct bundle", integrated_bundle),
        gate("Source-branded fingerprint runtime", runtime_identity),
        gate("Runtime app matches runtime lock", runtime_lock_contract),
        gate("Chromium source provenance", runtime_source_provenance),
        gate("Runtime security baseline", runtime_security),
        gate("Metal runtime arguments", metal_args),
        gate("GUI fingerprint qualification", gui_report),
        gate("Developer ID signing environment", signing_env),
        gate("Notary profile environment", notary_env),
        gate(
            "Local notarization transaction continuity",
            local_transaction_continuity,
        ),
        gate("Expected notarized archive name/download URL", archive_name_url_contract),
    ]


def format_report(results: list[GateResult]) -> str:
    lines = ["NeAntik Direct public release preflight"]
    for result in results:
        marker = "PASS" if result.passed else "BLOCKED"
        lines.append(f"{marker}  {result.name}")
        if result.details:
            lines.append(f"       {result.details}")
    failed = [result for result in results if not result.passed]
    if failed:
        lines.append(f"Result: blocked by {len(failed)} gate(s).")
    else:
        lines.append("Result: Direct public release plan is locally ready.")
    return "\n".join(lines)


def results_to_json(
    results: list[GateResult],
    *,
    download_url: str | None = None,
    release_channel: str | None = None,
    notary_transaction_report: dict[str, object] | None = None,
) -> dict[str, Any]:
    blocked = [result for result in results if not result.passed]
    return {
        "schemaVersion": 1,
        "channel": "Direct",
        "releaseQualification": release_channel,
        "ready": not blocked,
        "downloadURLProvided": bool((download_url or "").strip()),
        "gateCount": len(results),
        "blockedCount": len(blocked),
        "passedGates": [result.name for result in results if result.passed],
        "blockedGates": [
            {"name": result.name, "details": result.details}
            for result in results
            if not result.passed
        ],
        "gates": [
            {
                "name": result.name,
                "passed": result.passed,
                "details": result.details,
            }
            for result in results
        ],
        "notaryTransactionDiagnostics": notary_transaction_report,
        "releaseBoundary": (
            "This is a read-only Direct release-plan preflight. It does not "
            "sign, notarize, staple, upload, host, publish, or approve a build."
        ),
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Read-only preflight for the NeAntik Direct Developer ID + notarization release plan.",
    )
    parser.add_argument("--project-root", type=Path, default=PROJECT_ROOT)
    parser.add_argument(
        "--integrated-app",
        type=Path,
        default=PROJECT_ROOT / "dist" / "NeAntik.app",
    )
    parser.add_argument("--runtime-app", type=Path)
    parser.add_argument("--args-gn", type=Path)
    parser.add_argument(
        "--gui-fingerprint-report",
        type=Path,
        default=PROJECT_ROOT / "dist" / "fingerprint-audit.json",
    )
    parser.add_argument(
        "--candidate-manifest",
        type=Path,
        default=PROJECT_ROOT / "dist" / "direct-candidate-manifest.json",
    )
    parser.add_argument(
        "--runtime-lock",
        type=Path,
        default=PROJECT_ROOT / "runtime" / "fingerprint-chromium.lock.json",
    )
    parser.add_argument(
        "--download-url",
        default=os.environ.get("NEXT_PUBLIC_NEANTIK_DOWNLOAD_URL"),
    )
    parser.add_argument(
        "--release-channel",
        choices=("public-alpha", "production"),
        default=os.environ.get("NEANTIK_RELEASE_CHANNEL"),
        help=(
            "Explicit fingerprint qualification required for this Direct "
            "candidate."
        ),
    )
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    integrated_app = args.integrated_app.resolve()
    project_root = args.project_root.resolve()
    notary_transaction_report = NOTARY_INSPECTOR.inspect_dist(
        project_root / "dist",
        expected_archive_name=(
            "NeAntik-"
            + str(
                read_plist(
                    project_root / "Resources" / "Info.plist"
                )["CFBundleShortVersionString"]
            )
            + "-arm64-notarized.zip"
        ),
    )
    results = verify_direct_public_release_plan(
        project_root=project_root,
        integrated_app=integrated_app,
        runtime_app=(args.runtime_app or default_runtime_app(integrated_app)).resolve(),
        args_gn=(args.args_gn or default_args_gn(integrated_app)).resolve(),
        gui_fingerprint_report=args.gui_fingerprint_report.resolve(),
        candidate_manifest=args.candidate_manifest.resolve(),
        runtime_lock=args.runtime_lock.resolve(),
        download_url=args.download_url,
        release_channel=args.release_channel,
        notary_transaction_report=notary_transaction_report,
    )
    if args.json:
        print(
            json.dumps(
                results_to_json(
                    results,
                    download_url=args.download_url,
                    release_channel=args.release_channel,
                    notary_transaction_report=(
                        notary_transaction_report
                    ),
                ),
                indent=2,
                ensure_ascii=False,
            )
        )
    else:
        print(format_report(results))
    return 0 if all(result.passed for result in results) else 2


if __name__ == "__main__":
    sys.exit(main())
