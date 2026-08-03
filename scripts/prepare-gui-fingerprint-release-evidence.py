#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
COLLECTOR_PATH = PROJECT_ROOT / "scripts" / "collect-gui-fingerprint-evidence.py"
SPEC = importlib.util.spec_from_file_location(
    "collect_gui_fingerprint_evidence",
    COLLECTOR_PATH,
)
assert SPEC and SPEC.loader
COLLECTOR = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = COLLECTOR
SPEC.loader.exec_module(COLLECTOR)


class GuiEvidencePreparationError(ValueError):
    pass


def analyze(
    *,
    source: Path | None,
    audits_dir: Path,
    runtime_lock: Path,
    integrated_app: Path | None = None,
    release_channel: str = "public-alpha",
) -> dict[str, Any]:
    selected = COLLECTOR.select_source_report(source=source, audits_dir=audits_dir)
    report = COLLECTOR.GUI_VERIFIER.load_report(selected)
    if integrated_app is not None:
        expected_runtime = (
            COLLECTOR.GUI_VERIFIER.expected_runtime_evidence_from_app(
                integrated_app
            )
        )
    else:
        expected_runtime = COLLECTOR.GUI_VERIFIER.expected_runtime_evidence(
            COLLECTOR.GUI_VERIFIER.load_runtime_lock(runtime_lock),
            lock_path=runtime_lock,
        )
    summary = COLLECTOR.GUI_VERIFIER.verification_summary(
        report,
        expected_runtime=expected_runtime,
    )
    return {
        "source": str(selected),
        "runtimeLock": str(runtime_lock),
        "runtimeVerificationCreatedAt": expected_runtime.get("runtimeVerificationCreatedAt"),
        "qualified": summary["qualified"],
        "issues": summary["issues"],
        "productionQualified": summary["productionQualified"],
        "productionIssues": summary["productionIssues"],
        "releaseQualification": release_channel,
        "releaseQualified": not COLLECTOR.GUI_VERIFIER.qualification_issues(
            summary,
            require_production=release_channel == "production",
        ),
        "changedCriticalKeys": summary["changedCriticalKeys"],
        "unstableRequiredKeys": summary["unstableRequiredKeys"],
        "executionMode": summary["executionMode"],
        "runtimeName": summary["runtimeName"],
        "runtimeVersion": summary["runtimeVersion"],
        "runtimeFlavor": summary["runtimeFlavor"],
        "createdAt": summary.get("createdAt"),
    }


def prepare(
    *,
    source: Path | None,
    audits_dir: Path,
    output: Path,
    collect: bool,
    runtime_lock: Path,
    integrated_app: Path | None = None,
    candidate_manifest: Path | None = None,
    release_channel: str = "public-alpha",
) -> dict[str, Any]:
    status = analyze(
        source=source,
        audits_dir=audits_dir,
        runtime_lock=runtime_lock,
        integrated_app=integrated_app,
        release_channel=release_channel,
    )
    if collect:
        raise GuiEvidencePreparationError(
            "Raw schema-7 reports are diagnostic only. Direct release "
            "evidence must be produced and signed as schema 8 by the exact "
            "prepared NeAntik.app."
        )
    return status


def format_text(status: dict[str, Any], *, output: Path, collect: bool) -> str:
    lines = [
        "NeAntik GUI fingerprint release evidence",
        f"Source report: {status['source']}",
        f"Runtime lock: {status.get('runtimeLock') or 'unknown'}",
        f"Runtime verification created: {status.get('runtimeVerificationCreatedAt') or 'unknown'}",
        f"Report created: {status.get('createdAt') or 'unknown'}",
        f"Runtime: {status.get('runtimeName') or 'unknown'} {status.get('runtimeVersion') or 'unknown'}",
        f"Execution mode: {status.get('executionMode') or 'unknown'}",
        f"Changed critical keys: {', '.join(status['changedCriticalKeys']) or 'none'}",
    ]
    if status["releaseQualified"]:
        lines.append(
            "Status: qualified "
            f"{status['releaseQualification']} GUI A -> B -> A report"
        )
        if not status["productionQualified"]:
            lines.append(
                "Strict coherent production hardening remains incomplete."
            )
        if collect:
            lines.append(f"Collected release evidence: {status['collectedTo']}")
        else:
            lines.append(
                f"Next: rerun with --collect to copy this report to {output}"
            )
    else:
        lines.append(
            "Status: not qualified for "
            f"{status['releaseQualification']} Direct release"
        )
        lines.append("Issues:")
        issues = (
            status["productionIssues"]
            if status["releaseQualification"] == "production"
            else status["issues"]
        )
        for issue in issues:
            lines.append(f"- {issue}")
        lines.extend(
            [
                "Next:",
                "1. Run the runtime audit kit from Finder in a normal user session.",
                "2. Keep fingerprint-audit.json and fingerprint-audit-terminal.log private; never attach or publish either raw file.",
                "3. Re-run this command with --source /absolute/path/to/fingerprint-audit.json.",
            ]
        )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Inspect and optionally collect NeAntik production GUI fingerprint release evidence.",
    )
    parser.add_argument(
        "--source",
        type=Path,
        help="Specific NeAntik FingerprintAudits/audit-*.json report to inspect.",
    )
    parser.add_argument(
        "--audits-dir",
        type=Path,
        default=COLLECTOR.default_audits_dir(),
        help="Directory to scan when --source is not provided.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=PROJECT_ROOT / "dist" / "fingerprint-audit.json",
        help="Release evidence output path used with --collect.",
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
            "Exact prepared NeAntik.app. Required with --collect for a "
            "Direct candidate."
        ),
    )
    parser.add_argument(
        "--candidate-manifest",
        type=Path,
        default=PROJECT_ROOT / "dist" / "direct-candidate-manifest.json",
        help="Immutable manifest created before this GUI run.",
    )
    parser.add_argument(
        "--release-channel",
        choices=("public-alpha", "production"),
        default="public-alpha",
    )
    parser.add_argument(
        "--collect",
        action="store_true",
        help=(
            "Deprecated fail-closed option. Raw schema-7 reports are "
            "diagnostic only; Direct release evidence is schema 8."
        ),
    )
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    try:
        status = prepare(
            source=args.source,
            audits_dir=args.audits_dir,
            output=args.output,
            collect=args.collect,
            runtime_lock=args.runtime_lock,
            integrated_app=args.integrated_app,
            candidate_manifest=args.candidate_manifest,
            release_channel=args.release_channel,
        )
    except (
        OSError,
        GuiEvidencePreparationError,
        COLLECTOR.GUI_VERIFIER.FingerprintReportError,
        COLLECTOR.EvidenceCollectionError,
    ) as error:
        if args.json:
            print(
                json.dumps(
                    {
                        "qualified": False,
                        "collected": False,
                        "error": str(error),
                    },
                    indent=2,
                    ensure_ascii=False,
                )
            )
        else:
            print(f"GUI fingerprint release evidence is not ready: {error}")
            print("Next: run the runtime audit kit from Finder in a normal user session.")
        return 1

    if args.json:
        print(json.dumps(status, indent=2, ensure_ascii=False))
    else:
        print(format_text(status, output=args.output, collect=args.collect))
    return 0 if status["releaseQualified"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
