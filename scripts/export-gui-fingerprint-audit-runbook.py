#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]


class GuiAuditRunbookError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_runtime_version(project_root: Path) -> str:
    lock = json.loads((project_root / "runtime" / "fingerprint-chromium.lock.json").read_text(encoding="utf-8"))
    try:
        return str(lock["fingerprintChromium"]["chromiumVersion"])
    except KeyError as error:
        raise GuiAuditRunbookError("runtime lock is missing fingerprintChromium.chromiumVersion") from error


def build_runbook(
    *,
    project_root: Path = PROJECT_ROOT,
    generated_at: str | None = None,
) -> dict[str, Any]:
    runtime_version = load_runtime_version(project_root)
    archive = project_root / "dist" / f"NeAntik-{runtime_version}-source-branded-runtime-audit-kit.zip"
    if not archive.is_file():
        raise GuiAuditRunbookError(f"runtime audit kit archive is missing: {archive}")
    generated_at = generated_at or datetime.now(timezone.utc).isoformat(timespec="seconds")
    archive_rel = str(archive.relative_to(project_root))
    return {
        "schemaVersion": 1,
        "generatedAt": generated_at,
        "channel": "Direct",
        "purpose": "production-gui-fingerprint-evidence",
        "releaseBoundary": (
            "This runbook describes how to capture production GUI A->B->A "
            "fingerprint evidence. It is not evidence by itself. Direct release "
            "remains blocked until a real browser-mode report passes the "
            "independent verifier and is collected into dist/fingerprint-audit.json."
        ),
        "runtime": {
            "name": "NeAntik Browser",
            "chromiumVersion": runtime_version,
            "archive": archive_rel,
            "archiveSHA256": sha256_file(archive),
        },
        "operatorSteps": [
            "Extract the runtime audit kit ZIP in Finder.",
            "Open Run-NeAntik-Runtime-Audit.command from Finder in a normal macOS user session.",
            "Allow Terminal/local audit tool prompts if macOS asks.",
            "Wait for three browser launches: profile A, profile B, profile A.",
            "Keep fingerprint-audit.json and fingerprint-audit-terminal.log from the extracted folder.",
            "From the main NeAntik project, run prepare-gui-fingerprint-release-evidence.py with --source.",
            "Run the same command with --collect only after the report is qualified.",
        ],
        "expectedFiles": [
            "fingerprint-audit.json",
            "fingerprint-audit-terminal.log",
        ],
        "qualificationRequirements": [
            "executionMode is browser, not diagnostic/headless",
            "report createdAt and capture timestamps are valid ISO-8601 values",
            "capture timestamps are ordered as profile A, profile B, profile A",
            "report createdAt is not older than the pinned runtime verification report",
            "runtimeFlavor is fingerprintChromium",
            "runtime executable and framework SHA-256 values are recorded",
            "runtime executable/framework SHA-256 values match the pinned runtime verification report",
            "runtime code signature is valid",
            "profile sequence is A -> B -> A with stable A identity",
            "Canvas, Audio, ClientRects, and WebGL pixels are available",
            "at least two critical surfaces differ between A and B",
            "WebGL pixels differ between A and B",
            "all required browser context surfaces are stable for A repeat",
        ],
        "commands": {
            "inspectSpecificReport": (
                "scripts/prepare-gui-fingerprint-release-evidence.py "
                "--source /absolute/path/to/fingerprint-audit.json "
                "--runtime-lock runtime/fingerprint-chromium.lock.json"
            ),
            "collectSpecificReport": (
                "scripts/prepare-gui-fingerprint-release-evidence.py "
                "--source /absolute/path/to/fingerprint-audit.json "
                "--runtime-lock runtime/fingerprint-chromium.lock.json --collect"
            ),
            "inspectNewestReport": (
                "scripts/prepare-gui-fingerprint-release-evidence.py "
                "--runtime-lock runtime/fingerprint-chromium.lock.json"
            ),
            "collectNewestReport": (
                "scripts/prepare-gui-fingerprint-release-evidence.py "
                "--runtime-lock runtime/fingerprint-chromium.lock.json --collect"
            ),
            "verifyCollectedReport": (
                "scripts/verify-gui-fingerprint-report.py "
                "dist/fingerprint-audit.json "
                "--runtime-lock runtime/fingerprint-chromium.lock.json"
            ),
        },
        "blockedUntil": [
            "A real user-context GUI report exists",
            "The report passes verify-gui-fingerprint-report.py",
            "The report is collected to dist/fingerprint-audit.json with 0600 permissions",
            "Chromium security baseline and owned Chromium 150 patchset gates pass",
        ],
    }


def format_markdown(runbook: dict[str, Any]) -> str:
    lines = [
        "# NeAntik GUI fingerprint audit runbook",
        "",
        f"- Generated: `{runbook['generatedAt']}`",
        f"- Runtime: `{runbook['runtime']['name']} {runbook['runtime']['chromiumVersion']}`",
        f"- Audit kit: `{runbook['runtime']['archive']}`",
        f"- Audit kit SHA-256: `{runbook['runtime']['archiveSHA256']}`",
        "",
        runbook["releaseBoundary"],
        "",
        "## Operator steps",
        "",
    ]
    for index, step in enumerate(runbook["operatorSteps"], start=1):
        lines.append(f"{index}. {step}")
    lines.extend(["", "## Expected files", ""])
    for item in runbook["expectedFiles"]:
        lines.append(f"- `{item}`")
    lines.extend(["", "## Qualification requirements", ""])
    for item in runbook["qualificationRequirements"]:
        lines.append(f"- {item}")
    lines.extend(["", "## Commands", ""])
    for label, command in runbook["commands"].items():
        lines.extend([f"### {label}", "", "```bash", command, "```", ""])
    lines.extend(["## Still blocked until", ""])
    for item in runbook["blockedUntil"]:
        lines.append(f"- {item}")
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Export the owner-facing NeAntik GUI fingerprint audit runbook.",
    )
    parser.add_argument("--project-root", type=Path, default=PROJECT_ROOT)
    parser.add_argument("--format", choices=("json", "markdown"), default="markdown")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        runbook = build_runbook(project_root=args.project_root.resolve())
        text = (
            json.dumps(runbook, indent=2, ensure_ascii=False) + "\n"
            if args.format == "json"
            else format_markdown(runbook)
        )
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(text, encoding="utf-8")
        else:
            print(text, end="")
    except (OSError, json.JSONDecodeError, GuiAuditRunbookError) as error:
        print(f"GUI fingerprint audit runbook export failed: {error}")
        return 65
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
