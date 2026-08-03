#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.util
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = PROJECT_ROOT / "dist" / "GUI-FINGERPRINT-READINESS.json"
DEFAULT_MARKDOWN = PROJECT_ROOT / "dist" / "GUI-FINGERPRINT-READINESS.md"
DEFAULT_REPORT = PROJECT_ROOT / "dist" / "fingerprint-audit.json"
DEFAULT_RUNTIME_LOCK = PROJECT_ROOT / "runtime" / "fingerprint-chromium.lock.json"
RUNBOOK_PATH = PROJECT_ROOT / "scripts" / "export-gui-fingerprint-audit-runbook.py"
OWNER_EVIDENCE_PLACEHOLDERS = [
    "<ABSOLUTE_GUI_FINGERPRINT_AUDIT_JSON>",
    "<ABSOLUTE_GUI_FINGERPRINT_AUDIT_LOG>",
]

SPEC = importlib.util.spec_from_file_location("export_gui_fingerprint_audit_runbook", RUNBOOK_PATH)
assert SPEC and SPEC.loader
RUNBOOK = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = RUNBOOK
SPEC.loader.exec_module(RUNBOOK)


class GuiFingerprintReadinessExportError(RuntimeError):
    pass


def build_owner_evidence_input_template() -> dict[str, Any]:
    return {
        "target": "dist/fingerprint-audit.json",
        "format": "production-gui-evidence-template",
        "placeholdersMustBeReplaced": OWNER_EVIDENCE_PLACEHOLDERS,
        "requiredInputs": [
            {
                "name": "sourceReport",
                "placeholder": "<ABSOLUTE_GUI_FINGERPRINT_AUDIT_JSON>",
                "rule": "Absolute path to fingerprint-audit.json produced by Run-NeAntik-Runtime-Audit.command from Finder in a normal macOS user session.",
            },
            {
                "name": "sourceTerminalLog",
                "placeholder": "<ABSOLUTE_GUI_FINGERPRINT_AUDIT_LOG>",
                "rule": "Absolute path to fingerprint-audit-terminal.log produced in the same extracted audit-kit folder; keep it for review evidence but do not upload it to the public site.",
            },
        ],
        "collectContract": {
            "sourceMustBeQualifiedBeforeCollect": True,
            "releaseOutput": "dist/fingerprint-audit.json",
            "releaseOutputPermissions": "0600",
            "runtimeLock": "runtime/fingerprint-chromium.lock.json",
            "requiredExecutionMode": "browser",
            "requiredProfileSequence": "A -> B -> A",
        },
        "applyThenVerify": [
            "python3 scripts/prepare-gui-fingerprint-release-evidence.py --source <ABSOLUTE_GUI_FINGERPRINT_AUDIT_JSON> --runtime-lock runtime/fingerprint-chromium.lock.json",
            "python3 scripts/prepare-gui-fingerprint-release-evidence.py --source <ABSOLUTE_GUI_FINGERPRINT_AUDIT_JSON> --runtime-lock runtime/fingerprint-chromium.lock.json --collect",
            "python3 scripts/verify-gui-fingerprint-report.py dist/fingerprint-audit.json --runtime-lock runtime/fingerprint-chromium.lock.json",
            "python3 scripts/export-gui-fingerprint-readiness-report.py",
            "python3 scripts/verify-persisted-gui-fingerprint-readiness-report.py",
            "python3 scripts/verify-nevision-release-matrix.py --gui-fingerprint-report dist/fingerprint-audit.json",
        ],
        "safetyBoundary": [
            "Do not edit fingerprint-audit.json by hand.",
            "Do not invent browser-mode, timestamp, runtime hash, WebGL, Canvas, Audio, ClientRects, or profile A/B values.",
            "Do not collect diagnostic/headless reports as production GUI evidence.",
            "Do not publish fingerprint-audit-terminal.log or raw local paths on the public website.",
        ],
    }


def verify_report(
    *,
    project_root: Path,
    report_path: Path,
    runtime_lock: Path,
) -> dict[str, Any]:
    command = [
        sys.executable,
        "scripts/verify-gui-fingerprint-report.py",
        str(report_path),
        "--runtime-lock",
        str(runtime_lock),
    ]
    completed = subprocess.run(
        command,
        cwd=project_root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
        timeout=120,
    )
    return {
        "command": command,
        "passed": completed.returncode == 0,
        "returnCode": completed.returncode,
        "outputPreview": completed.stdout.splitlines()[:40],
    }


def build_report(
    *,
    project_root: Path = PROJECT_ROOT,
    report_path: Path | None = None,
    runtime_lock: Path | None = None,
    generated_at: str | None = None,
    verifier=verify_report,
) -> dict[str, Any]:
    project_root = project_root.resolve()
    report_path = report_path or Path("dist/fingerprint-audit.json")
    runtime_lock = runtime_lock or Path("runtime/fingerprint-chromium.lock.json")
    report_path = report_path if report_path.is_absolute() else project_root / report_path
    runtime_lock = runtime_lock if runtime_lock.is_absolute() else project_root / runtime_lock
    generated_at = generated_at or datetime.now(timezone.utc).isoformat(timespec="seconds")
    runbook = RUNBOOK.build_runbook(project_root=project_root, generated_at=generated_at)
    report_exists = report_path.is_file()
    verification = None
    if report_exists:
        verification = verifier(
            project_root=project_root,
            report_path=report_path,
            runtime_lock=runtime_lock,
        )
    ready = bool(report_exists and verification and verification.get("passed") is True)
    blocked_gates: list[str] = []
    if not report_exists:
        blocked_gates.append("Production GUI fingerprint report")
    elif not ready:
        blocked_gates.append("Production GUI fingerprint report verifier")
    return {
        "schemaVersion": 1,
        "generatedAt": generated_at,
        "mode": "direct-gui-fingerprint-readiness-snapshot",
        "channel": "Direct",
        "ready": ready,
        "report": {
            "path": str(report_path),
            "exists": report_exists,
            "expectedRelativePath": "dist/fingerprint-audit.json",
        },
        "blockedCount": len(blocked_gates),
        "blockedGates": blocked_gates,
        "verification": verification,
        "runtime": runbook["runtime"],
        "ownerEvidenceInputTemplate": build_owner_evidence_input_template(),
        "releaseBoundary": (
            "This readiness snapshot does not launch Finder, Terminal, Chrome, or NeAntik Browser. "
            "It does not create GUI evidence and does not qualify Direct public release by itself. "
            "Direct release remains blocked until a real user-context browser report is collected "
            "into dist/fingerprint-audit.json and passes scripts/verify-gui-fingerprint-report.py."
        ),
        "operatorRunbook": {
            "purpose": runbook["purpose"],
            "operatorSteps": runbook["operatorSteps"],
            "expectedFiles": runbook["expectedFiles"],
            "qualificationRequirements": runbook["qualificationRequirements"],
            "commands": runbook["commands"],
        },
        "nextOwnerActions": [
            "Run Run-NeAntik-Runtime-Audit.command from Finder in a normal macOS user session.",
            "Keep the produced fingerprint-audit.json and fingerprint-audit-terminal.log.",
            "Run scripts/prepare-gui-fingerprint-release-evidence.py --source /absolute/path/to/fingerprint-audit.json --runtime-lock runtime/fingerprint-chromium.lock.json.",
            "Run the same command with --collect only after inspection passes.",
            "Run scripts/verify-gui-fingerprint-report.py dist/fingerprint-audit.json --runtime-lock runtime/fingerprint-chromium.lock.json.",
            "Re-run scripts/verify-nevision-release-matrix.py --gui-fingerprint-report dist/fingerprint-audit.json.",
        ],
    }


def format_markdown(report: dict[str, Any]) -> str:
    lines = [
        "# NeAntik GUI fingerprint readiness snapshot",
        "",
        f"- Generated: `{report['generatedAt']}`",
        f"- Ready: `{str(report['ready']).lower()}`",
        f"- Report: `{report['report']['path']}`",
        f"- Report exists: `{str(report['report']['exists']).lower()}`",
        f"- Blocked: `{report['blockedCount']}`",
        "",
        report["releaseBoundary"],
        "",
        "## Blocked gates",
        "",
    ]
    blockers = report.get("blockedGates") or []
    if blockers:
        for blocker in blockers:
            lines.append(f"- {blocker}")
    else:
        lines.append("- None.")

    verification = report.get("verification")
    if verification:
        lines.extend(["", "## Verification", ""])
        marker = "PASS" if verification.get("passed") else "BLOCKED"
        lines.append(f"- Status: `{marker}`")
        lines.append(f"- Return code: `{verification.get('returnCode')}`")
        lines.extend(["", "```text"])
        lines.extend(str(line) for line in verification.get("outputPreview", []))
        lines.append("```")

    template = report["ownerEvidenceInputTemplate"]
    lines.extend(
        [
            "",
            "## Owner evidence input template",
            "",
            f"- Target: `{template['target']}`",
            f"- Format: `{template['format']}`",
            "",
            "### Required inputs",
            "",
        ]
    )
    for item in template["requiredInputs"]:
        lines.extend(
            [
                f"- `{item['name']}`: `{item['placeholder']}`",
                f"  - {item['rule']}",
            ]
        )
    contract = template["collectContract"]
    lines.extend(
        [
            "",
            "### Collect contract",
            "",
            f"- Source must be qualified before collect: `{str(contract['sourceMustBeQualifiedBeforeCollect']).lower()}`",
            f"- Release output: `{contract['releaseOutput']}`",
            f"- Release output permissions: `{contract['releaseOutputPermissions']}`",
            f"- Runtime lock: `{contract['runtimeLock']}`",
            f"- Required execution mode: `{contract['requiredExecutionMode']}`",
            f"- Required profile sequence: `{contract['requiredProfileSequence']}`",
            "",
            "### Apply, then verify",
            "",
            "```bash",
        ]
    )
    lines.extend(template["applyThenVerify"])
    lines.extend(["```", "", "### Safety boundary", ""])
    for item in template["safetyBoundary"]:
        lines.append(f"- {item}")

    lines.extend(["", "## Operator steps", ""])
    for index, step in enumerate(report["operatorRunbook"]["operatorSteps"], start=1):
        lines.append(f"{index}. {step}")

    lines.extend(["", "## Qualification requirements", ""])
    for item in report["operatorRunbook"]["qualificationRequirements"]:
        lines.append(f"- {item}")

    lines.extend(["", "## Commands", ""])
    for label, command in report["operatorRunbook"]["commands"].items():
        lines.extend([f"### {label}", "", "```bash", command, "```", ""])

    lines.extend(["## Next owner actions", ""])
    for action in report["nextOwnerActions"]:
        lines.append(f"- {action}")
    return "\n".join(lines).rstrip() + "\n"


def write_outputs(report: dict[str, Any], *, output: Path, markdown: Path | None) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    if markdown is not None:
        markdown.parent.mkdir(parents=True, exist_ok=True)
        markdown.write_text(format_markdown(report), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Export a persisted NeAntik Direct GUI fingerprint readiness snapshot.",
    )
    parser.add_argument("--project-root", type=Path, default=PROJECT_ROOT)
    parser.add_argument("--report", type=Path, default=Path("dist/fingerprint-audit.json"))
    parser.add_argument(
        "--runtime-lock",
        type=Path,
        default=Path("runtime/fingerprint-chromium.lock.json"),
    )
    parser.add_argument("--output", type=Path, default=Path("dist/GUI-FINGERPRINT-READINESS.json"))
    parser.add_argument(
        "--markdown",
        type=Path,
        default=Path("dist/GUI-FINGERPRINT-READINESS.md"),
    )
    args = parser.parse_args()
    project_root = args.project_root.resolve()
    output = args.output if args.output.is_absolute() else project_root / args.output
    markdown = args.markdown if args.markdown.is_absolute() else project_root / args.markdown
    try:
        report = build_report(
            project_root=project_root,
            report_path=args.report,
            runtime_lock=args.runtime_lock,
        )
        write_outputs(report, output=output, markdown=markdown)
    except (OSError, json.JSONDecodeError, GuiFingerprintReadinessExportError) as error:
        print(f"GUI fingerprint readiness export failed: {error}", file=sys.stderr)
        return 65
    print(output)
    print(
        "GUI fingerprint readiness snapshot: "
        f"ready={str(report['ready']).lower()}, blocked={report['blockedCount']}"
    )
    return 0 if report["ready"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
