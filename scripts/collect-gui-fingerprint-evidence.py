#!/usr/bin/env python3
from __future__ import annotations

import argparse
import copy
import importlib.util
import json
import os
import sys
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
    public_profile_ids = {
        "webrtcDirectControl": "00000000-0000-4000-8000-000000000003",
        "firstInitial": "00000000-0000-4000-8000-000000000001",
        "second": "00000000-0000-4000-8000-000000000002",
        "firstRepeat": "00000000-0000-4000-8000-000000000001",
    }
    for capture_key, public_profile_id in public_profile_ids.items():
        capture = sanitized.get(capture_key)
        if not isinstance(capture, dict):
            continue
        capture["profileID"] = public_profile_id
        capture["profileName"] = str(capture.get("identityCode", "NeAntik profile"))
    return sanitized


def collect_evidence(
    *,
    source: Path | None,
    audits_dir: Path,
    output: Path,
    runtime_lock: Path,
    integrated_app: Path | None = None,
) -> dict[str, Any]:
    source_report = select_source_report(source=source, audits_dir=audits_dir)
    report = GUI_VERIFIER.load_report(source_report)
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

    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(f".{output.name}.tmp")
    sanitized = sanitized_release_report(report)
    sanitized_summary = GUI_VERIFIER.verification_summary(
        sanitized,
        expected_runtime=expected_runtime,
    )
    if not sanitized_summary["qualified"]:
        raise EvidenceCollectionError(
            "Sanitized release report failed fingerprint verification."
        )
    temporary.write_text(
        json.dumps(
            sanitized,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    os.chmod(temporary, 0o600)
    os.replace(temporary, output)
    os.chmod(output, 0o600)
    return {
        "source": str(source_report),
        "output": str(output),
        "integratedApp": (
            str(integrated_app) if integrated_app is not None else None
        ),
        "summary": sanitized_summary,
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
        help="Release evidence output path.",
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
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    try:
        result = collect_evidence(
            source=args.source,
            audits_dir=args.audits_dir,
            output=args.output,
            runtime_lock=args.runtime_lock,
            integrated_app=args.integrated_app,
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
        print(
            "Changed critical keys: "
            + ", ".join(result["summary"]["changedCriticalKeys"])
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
