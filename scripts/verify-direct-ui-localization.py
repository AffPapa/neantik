#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
UI_FILES = (
    "ContentView.swift",
    "ProfileEditorView.swift",
    "FingerprintAuditView.swift",
)
VISIBLE_CALL = re.compile(
    r"\b(?:Text|Button|Label|GroupBox|Picker|LabeledContent)"
    r"\s*\(\s*\"((?:\\.|[^\"\\])*)\"",
    re.DOTALL,
)
FORBIDDEN_ENGLISH = re.compile(
    r"\b(?:Fingerprint|Runtime|Keychain|Unknown|Error|Launch|Stop|"
    r"Delete|Edit|Data|Settings|Profile|Proxy|Start|Cancel)\b",
    re.IGNORECASE,
)
REQUIRED_ACTIONS = (
    "Запустить",
    "Изменить",
    "Данные",
    "Отпечаток",
    "Удалить",
)


class LocalizationVerificationError(ValueError):
    pass


def inspect_sources(sources_dir: Path) -> dict[str, Any]:
    visible_strings: list[dict[str, str]] = []
    issues: list[str] = []
    combined = ""
    for filename in UI_FILES:
        path = sources_dir / filename
        if not path.is_file() or path.is_symlink():
            raise LocalizationVerificationError(
                f"Missing regular SwiftUI source: {path}"
            )
        text = path.read_text(encoding="utf-8")
        combined += "\n" + text
        for match in VISIBLE_CALL.finditer(text):
            value = match.group(1)
            visible_strings.append({"file": filename, "value": value})
            visible_literal = re.sub(r"\\\([^)]*\)", "", value)
            forbidden = FORBIDDEN_ENGLISH.search(visible_literal)
            if forbidden:
                issues.append(
                    f"{filename}: visible string contains "
                    f"unlocalized {forbidden.group(0)!r}: {value!r}"
                )

    missing_actions = [
        action for action in REQUIRED_ACTIONS if action not in combined
    ]
    issues.extend(
        f"Required Russian action is missing: {action}"
        for action in missing_actions
    )
    return {
        "qualified": not issues,
        "files": list(UI_FILES),
        "visibleStringCount": len(visible_strings),
        "issues": issues,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Check the primary SwiftUI surfaces for known English residue "
            "and required Russian actions."
        )
    )
    parser.add_argument(
        "--sources-dir",
        type=Path,
        default=PROJECT_ROOT / "Sources" / "NeAntik",
    )
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    try:
        result = inspect_sources(args.sources_dir)
    except (OSError, UnicodeError, LocalizationVerificationError) as error:
        print(f"Direct UI localization verification failed: {error}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(result, indent=2, ensure_ascii=False))
    elif result["qualified"]:
        print(
            "PASS: primary SwiftUI actions and visible labels are Russian "
            f"({result['visibleStringCount']} checked)."
        )
    else:
        for issue in result["issues"]:
            print(f"FAIL: {issue}", file=sys.stderr)
    return 0 if result["qualified"] else 1


if __name__ == "__main__":
    sys.exit(main())
