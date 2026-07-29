#!/usr/bin/env python3
from __future__ import annotations

import argparse
import copy
import hashlib
import importlib.util
import json
import os
import secrets
import stat
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


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


class EvidenceCollectionError(ValueError):
    pass


MAX_REPORT_FUTURE_SKEW_SECONDS = 120


def default_audits_dir() -> Path:
    return (
        Path.home()
        / "Library"
        / "Application Support"
        / "NeAntik"
        / "FingerprintAudits"
    )


def candidate_reports(audits_dir: Path) -> list[Path]:
    if not audits_dir.is_dir():
        return []
    return sorted(
        (
            path
            for path in audits_dir.glob("audit-*.json")
            if path.is_file() and not path.is_symlink()
        ),
        key=lambda path: (path.stat().st_mtime_ns, path.name),
        reverse=True,
    )


def select_source_report(*, source: Path | None, audits_dir: Path) -> Path:
    if source is not None:
        if not source.is_file() or source.is_symlink():
            raise EvidenceCollectionError(f"Source report is not a regular file: {source}")
        return source
    candidates = candidate_reports(audits_dir)
    if not candidates:
        raise EvidenceCollectionError(f"No fingerprint reports found in {audits_dir}")
    return candidates[0]


def sanitized_release_report(report: dict[str, Any]) -> dict[str, Any]:
    sanitized = copy.deepcopy(report)
    sanitized["id"] = "00000000-0000-4000-8000-000000000000"
    public_profiles = {
        "webrtcDirectControl": (
            "00000000-0000-4000-8000-000000000003",
            "Контроль WebRTC",
            0x30000000,
        ),
        "firstInitial": (
            "00000000-0000-4000-8000-000000000001",
            "Профиль A",
            0x10000000,
        ),
        "second": (
            "00000000-0000-4000-8000-000000000002",
            "Профиль B",
            0x20000000,
        ),
        "firstRepeat": (
            "00000000-0000-4000-8000-000000000001",
            "Профиль A",
            0x10000000,
        ),
    }
    for capture_key, (
        public_profile_id,
        public_profile_name,
        synthetic_base,
    ) in public_profiles.items():
        capture = sanitized.get(capture_key)
        if not isinstance(capture, dict):
            continue
        identity_code = capture.get("identityCode")
        if (
            not isinstance(identity_code, str)
            or not identity_code.startswith("NA-")
        ):
            raise EvidenceCollectionError(
                f"Cannot sanitize identity code in {capture_key}."
            )
        try:
            original_seed = int(identity_code[3:], 16)
        except ValueError as error:
            raise EvidenceCollectionError(
                f"Cannot sanitize identity code in {capture_key}."
            ) from error
        tuple_count = len(GUI_VERIFIER.APPLE_DEVICE_TUPLES)
        tuple_index = original_seed % tuple_count
        synthetic_seed = synthetic_base + (
            tuple_index - synthetic_base % tuple_count
        ) % tuple_count
        capture["profileID"] = public_profile_id
        capture["profileName"] = public_profile_name
        capture["identityCode"] = f"NA-{synthetic_seed:08X}"
    return sanitized


def public_attestation(
    report: dict[str, Any],
    summary: dict[str, Any],
    *,
    private_evidence_sha256: str,
) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "kind": "neantik-gui-fingerprint-attestation",
        "createdAt": report.get("createdAt"),
        "managerVersion": report.get("managerVersion"),
        "managerBuild": report.get("managerBuild"),
        "runtimeName": report.get("runtimeName"),
        "runtimeVersion": report.get("runtimeVersion"),
        "runtimeFlavor": report.get("runtimeFlavor"),
        "runtimeCodeSignatureValid": report.get(
            "runtimeCodeSignatureValid"
        ),
        "runtimeExecutableSHA256": report.get(
            "runtimeExecutableSHA256"
        ),
        "runtimeFrameworkSHA256": report.get(
            "runtimeFrameworkSHA256"
        ),
        "privateEvidenceSHA256": private_evidence_sha256,
        "auditSchemaVersion": summary.get("auditSchemaVersion"),
        "identityCatalogVersion": summary.get(
            "identityCatalogVersion"
        ),
        "qualified": summary.get("qualified"),
        "productionQualified": summary.get("productionQualified"),
        "changedCriticalKeys": summary.get("changedCriticalKeys"),
        "unstableRequiredKeys": summary.get("unstableRequiredKeys"),
        "publicAlphaIssues": summary.get("issues"),
        "productionIssues": summary.get("productionIssues"),
    }


def encoded_private_json(value: dict[str, Any]) -> bytes:
    return (
        json.dumps(
            value,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
        + "\n"
    ).encode("utf-8")


def write_private_bytes(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_CLOEXEC", 0)
    )
    descriptor: int | None = None
    temporary: Path | None = None
    for _ in range(32):
        candidate = path.with_name(
            f".{path.name}.{secrets.token_hex(16)}.tmp"
        )
        try:
            descriptor = os.open(candidate, flags, 0o600)
        except FileExistsError:
            continue
        temporary = candidate
        break
    if descriptor is None or temporary is None:
        raise EvidenceCollectionError(
            f"Cannot allocate a private temporary file for {path.name}."
        )

    replaced = False
    try:
        os.fchmod(descriptor, 0o600)
        view = memoryview(payload)
        offset = 0
        while offset < len(view):
            written = os.write(descriptor, view[offset:])
            if written <= 0:
                raise OSError("Cannot complete private evidence write.")
            offset += written
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = None
        os.replace(temporary, path)
        replaced = True
        directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
        directory_descriptor = os.open(path.parent, directory_flags)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if not replaced:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass


def write_private_json(path: Path, value: dict[str, Any]) -> bytes:
    payload = encoded_private_json(value)
    write_private_bytes(path, payload)
    return payload


def invalidate_stale_attestation(path: Path) -> None:
    try:
        os.lstat(path)
    except FileNotFoundError:
        return
    try:
        os.unlink(path)
    except IsADirectoryError as error:
        raise EvidenceCollectionError(
            f"Public attestation path is not a file: {path}"
        ) from error


def parse_not_before(value: str | None) -> datetime | None:
    if value is None:
        return None
    text = value.strip()
    if not text:
        raise EvidenceCollectionError("--not-before must not be empty.")
    try:
        epoch = float(text)
    except ValueError:
        try:
            parsed = GUI_VERIFIER.parse_iso8601(text, "--not-before")
        except GUI_VERIFIER.FingerprintReportError as error:
            raise EvidenceCollectionError(str(error)) from error
        return parsed.astimezone(timezone.utc)
    try:
        return datetime.fromtimestamp(epoch, tz=timezone.utc)
    except (OverflowError, OSError, ValueError) as error:
        raise EvidenceCollectionError("--not-before epoch is invalid.") from error


def verify_attestation_binding(
    *,
    private_evidence: Path,
    attestation: Path,
) -> str:
    try:
        private_payload = private_evidence.read_bytes()
        public_payload = json.loads(attestation.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise EvidenceCollectionError(
            f"Cannot read evidence/attestation binding inputs: {error}"
        ) from error
    if not isinstance(public_payload, dict):
        raise EvidenceCollectionError("Public attestation must be a JSON object.")
    expected_sha = hashlib.sha256(private_payload).hexdigest()
    if public_payload.get("privateEvidenceSHA256") != expected_sha:
        raise EvidenceCollectionError(
            "Public attestation does not match the exact private evidence bytes."
        )
    try:
        report = json.loads(private_payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise EvidenceCollectionError(
            "Private fingerprint evidence is not valid UTF-8 JSON."
        ) from error
    if not isinstance(report, dict):
        raise EvidenceCollectionError(
            "Private fingerprint evidence must be a JSON object."
        )
    summary = GUI_VERIFIER.verification_summary(
        report,
        expected_runtime=None,
    )
    if not summary.get("qualified"):
        raise EvidenceCollectionError(
            "Private fingerprint evidence is not semantically qualified."
        )
    expected_attestation = public_attestation(
        report,
        summary,
        private_evidence_sha256=expected_sha,
    )
    if public_payload != expected_attestation:
        raise EvidenceCollectionError(
            "Public attestation fields do not match private evidence semantics."
        )
    return expected_sha


def existing_report_ids(audits_dir: Path) -> set[str]:
    report_ids: set[str] = set()
    for path in candidate_reports(audits_dir):
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError):
            continue
        if isinstance(payload, dict) and isinstance(payload.get("id"), str):
            report_ids.add(payload["id"])
    return report_ids


def load_report_id_baseline(path: Path) -> set[str]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise EvidenceCollectionError(
            f"Cannot read report-ID baseline: {error}"
        ) from error
    if (
        not isinstance(payload, dict)
        or set(payload) != {"schemaVersion", "reportIDs"}
        or payload.get("schemaVersion") != 1
        or not isinstance(payload.get("reportIDs"), list)
        or not all(isinstance(item, str) for item in payload["reportIDs"])
    ):
        raise EvidenceCollectionError("Report-ID baseline is invalid.")
    return set(payload["reportIDs"])


def quarantine_regular_file(path: Path, destination: Path) -> None:
    try:
        status = os.lstat(path)
    except FileNotFoundError:
        return
    if not stat.S_ISREG(status.st_mode):
        raise EvidenceCollectionError(
            f"Cannot quarantine unsafe release evidence path: {path}"
        )
    os.replace(path, destination)


def prepare_attempt_state(
    *,
    audits_dir: Path,
    output: Path,
    summary_output: Path | None,
    state_dir: Path,
) -> Path:
    if state_dir.exists() or state_dir.is_symlink():
        raise EvidenceCollectionError(
            f"Attempt state directory already exists or is unsafe: {state_dir}"
        )
    state_dir.mkdir(parents=True, mode=0o700)
    os.chmod(state_dir, 0o700)
    quarantine_regular_file(
        output,
        state_dir / f"previous-{output.name}",
    )
    if summary_output is not None:
        quarantine_regular_file(
            summary_output,
            state_dir / f"previous-{summary_output.name}",
        )
    baseline = state_dir / "report-ids.json"
    write_private_json(
        baseline,
        {
            "schemaVersion": 1,
            "reportIDs": sorted(existing_report_ids(audits_dir)),
        },
    )
    return baseline


def collect_evidence(
    *,
    source: Path | None,
    audits_dir: Path,
    output: Path,
    runtime_lock: Path,
    integrated_app: Path | None = None,
    summary_output: Path | None = None,
    not_before: datetime | None = None,
    baseline_report_ids: set[str] | None = None,
) -> dict[str, Any]:
    if (
        summary_output is not None
        and summary_output.resolve() == output.resolve()
    ):
        raise EvidenceCollectionError(
            "Private evidence and public attestation paths must be distinct."
        )
    source_report = select_source_report(source=source, audits_dir=audits_dir)
    report = GUI_VERIFIER.load_report(source_report)
    report_id = report.get("id")
    if (
        baseline_report_ids is not None
        and isinstance(report_id, str)
        and report_id in baseline_report_ids
    ):
        raise EvidenceCollectionError(
            "Source report ID existed before the current GUI attempt."
        )
    report_created_at = GUI_VERIFIER.parse_iso8601(
        report.get("createdAt"),
        "createdAt",
    )
    if not_before is not None:
        if report_created_at <= not_before.astimezone(timezone.utc):
            raise EvidenceCollectionError(
                "Source report predates the current GUI collection attempt."
            )
    if report_created_at > datetime.now(timezone.utc).replace(
        microsecond=0
    ) + timedelta(seconds=MAX_REPORT_FUTURE_SKEW_SECONDS):
        raise EvidenceCollectionError(
            "Source report timestamp is implausibly far in the future."
        )
    if integrated_app is not None:
        expected_runtime = GUI_VERIFIER.expected_runtime_evidence_from_app(
            integrated_app
        )
    else:
        expected_runtime = GUI_VERIFIER.expected_runtime_evidence(
            GUI_VERIFIER.load_runtime_lock(runtime_lock),
            lock_path=runtime_lock,
        )
    summary = GUI_VERIFIER.verification_summary(
        report,
        expected_runtime=expected_runtime,
    )
    if report.get("auditSchemaVersion") != GUI_VERIFIER.CURRENT_AUDIT_SCHEMA_VERSION:
        raise EvidenceCollectionError(
            "Source report does not use the current fingerprint audit schema."
        )
    if not summary["qualified"]:
        issues = "; ".join(summary["issues"])
        raise EvidenceCollectionError(
            f"Source report is not public-alpha-qualified: {issues}"
        )

    sanitized = sanitized_release_report(report)
    sanitized_summary = GUI_VERIFIER.verification_summary(
        sanitized,
        expected_runtime=expected_runtime,
    )
    if not sanitized_summary["qualified"]:
        raise EvidenceCollectionError(
            "Sanitized release report failed fingerprint verification."
        )
    private_payload = encoded_private_json(sanitized)
    write_private_bytes(output, private_payload)
    private_evidence_sha256 = hashlib.sha256(private_payload).hexdigest()
    if summary_output is not None:
        invalidate_stale_attestation(summary_output)
        write_private_json(
            summary_output,
            public_attestation(
                sanitized,
                sanitized_summary,
                private_evidence_sha256=private_evidence_sha256,
            ),
        )
    return {
        "source": str(source_report),
        "output": str(output),
        "integratedApp": (
            str(integrated_app) if integrated_app is not None else None
        ),
        "summaryOutput": (
            str(summary_output) if summary_output is not None else None
        ),
        "summary": sanitized_summary,
        "privateEvidenceSHA256": private_evidence_sha256,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Collect the latest qualified NeAntik GUI A -> B -> A fingerprint "
            "report into dist/fingerprint-audit.json for Direct release gates."
        ),
    )
    parser.add_argument(
        "--source",
        type=Path,
        help="Specific NeAntik FingerprintAudits/audit-*.json report to collect.",
    )
    parser.add_argument(
        "--audits-dir",
        type=Path,
        default=Path(os.environ.get("NEANTIK_FINGERPRINT_AUDITS_DIR", default_audits_dir())),
        help="Directory to scan when --source is not provided.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=PROJECT_ROOT / "dist" / "fingerprint-audit.json",
        help="Private, verifier-readable release evidence output path.",
    )
    parser.add_argument(
        "--summary-output",
        type=Path,
        default=PROJECT_ROOT
        / "dist"
        / "fingerprint-audit-summary.json",
        help=(
            "Aggregate public-safe attestation path. It contains no captures, "
            "profile identifiers, identity codes or browser-surface values."
        ),
    )
    parser.add_argument(
        "--runtime-lock",
        type=Path,
        default=PROJECT_ROOT / "runtime" / "fingerprint-chromium.lock.json",
        help=(
            "Runtime lock used to bind the GUI report to the pinned runtime "
            "version and executable/framework SHA-256 evidence."
        ),
    )
    parser.add_argument(
        "--integrated-app",
        type=Path,
        help=(
            "Exact distributed NeAntik.app to hash and bind to the report. "
            "Direct release collection must provide this option."
        ),
    )
    parser.add_argument(
        "--not-before",
        help=(
            "Reject reports created before this ISO-8601 timestamp or Unix epoch. "
            "Release automation sets it immediately before opening the GUI."
        ),
    )
    parser.add_argument(
        "--report-id-baseline",
        type=Path,
        help="Reject any report ID recorded before the current GUI attempt.",
    )
    parser.add_argument(
        "--prepare-attempt-state",
        type=Path,
        help=(
            "Quarantine old output/summary and snapshot existing report IDs "
            "into this new private directory, then exit."
        ),
    )
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    try:
        if args.prepare_attempt_state is not None:
            baseline = prepare_attempt_state(
                audits_dir=args.audits_dir,
                output=args.output,
                summary_output=args.summary_output,
                state_dir=args.prepare_attempt_state,
            )
            print(f"Prepared private GUI attempt state: {baseline}")
            return 0
        result = collect_evidence(
            source=args.source,
            audits_dir=args.audits_dir,
            output=args.output,
            runtime_lock=args.runtime_lock,
            integrated_app=args.integrated_app,
            summary_output=args.summary_output,
            not_before=parse_not_before(args.not_before),
            baseline_report_ids=(
                load_report_id_baseline(args.report_id_baseline)
                if args.report_id_baseline is not None
                else None
            ),
        )
    except (OSError, GUI_VERIFIER.FingerprintReportError, EvidenceCollectionError) as error:
        print(f"GUI fingerprint evidence collection failed: {error}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(result, indent=2, ensure_ascii=False))
    else:
        print("PASS: public-alpha GUI fingerprint evidence collected.")
        print(f"Source: {result['source']}")
        print(f"Output: {result['output']}")
        print(f"Public-safe summary: {result['summaryOutput']}")
        print(
            "Changed critical keys: "
            + ", ".join(result["summary"]["changedCriticalKeys"])
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
