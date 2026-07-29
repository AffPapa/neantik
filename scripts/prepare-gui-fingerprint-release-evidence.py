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
) -> dict[str, Any]:
    selected = COLLECTOR.select_source_report(source=source, audits_dir=audits_dir)
    report = COLLECTOR.GUI_VERIFIER.load_report(selected)
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
) -> dict[str, Any]:
    status = analyze(source=source, audits_dir=audits_dir, runtime_lock=runtime_lock)
    if collect:
        result = COLLECTOR.collect_evidence(
            source=Path(status["source"]),
            audits_dir=audits_dir,
            output=output,
            runtime_lock=runtime_lock,
        )
        status["collectedTo"] = result["output"]
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
    if status["qualified"]:
        lines.append("Status: qualified production GUI A -> B -> A report")
        if collect:
            lines.append(f"Collected release evidence: {status['collectedTo']}")
        else:
            lines.append(
                f"Next: rerun with --collect to copy this report to {output}"
            )
    else:
        lines.append("Status: not qualified for Direct release")
        lines.append("Issues:")
        for issue in status["issues"]:
            lines.append(f"- {issue}")
        lines.extend(
            [
                "Next:",
                "1. Run the runtime audit kit from Finder in a normal user session.",
                "2. Keep fingerprint-audit.json and fingerprint-audit-terminal.log.",
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
        "--collect",
        action="store_true",
        help="Copy the qualified report into the release evidence output path.",
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
        )
    except (
        OSError,
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
    return 0 if status["qualified"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
