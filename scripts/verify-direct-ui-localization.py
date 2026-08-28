#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import plistlib
import re
import sys
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SOURCES_DIR = PROJECT_ROOT / "Sources" / "NeAntik"
DEFAULT_INFO_PLIST = PROJECT_ROOT / "Resources" / "Info.plist"
REQUIRED_RUSSIAN_BUNDLE_STRINGS = (
    "More",
    "Hide Sidebar",
    "About %@",
    "Quit %@",
)
VISIBLE_CALL = re.compile(
    r"\b(?:Text|Button|Label|GroupBox|Picker|LabeledContent|Section|Toggle|"
    r"Menu|SecureField|TextField|ContentUnavailableView|DisclosureGroup|"
    r"accessibilityLabel|accessibilityHint|help|navigationTitle|alert|"
    r"confirmationDialog)"
    r"\s*\(\s*\"((?:\\.|[^\"\\])*)\"",
    re.DOTALL,
)
FORBIDDEN_ENGLISH = re.compile(
    r"\b(?:Fingerprint|Runtime|Keychain|Unknown|Error|Launch|Stop|"
    r"Delete|Edit|Data|Settings|Profile|Proxy|Start|Cancel|More|Show|Hide|"
    r"Close|Copy|Import|Export|Rename|Folder|Tag|Search|Clear|Done|Save|"
    r"Open)\b",
    re.IGNORECASE,
)
REQUIRED_ACTIONS = (
    "Запустить",
    "Изменить",
    "Показать папку данных в Finder",
    "Технические сведения",
    "Удалить профиль",
)


class LocalizationVerificationError(ValueError):
    pass


def inspect_sources(
    sources_dir: Path,
    info_plist_path: Path = DEFAULT_INFO_PLIST,
) -> dict[str, Any]:
    visible_strings: list[dict[str, str]] = []
    issues: list[str] = []
    combined = ""
    source_paths = sorted(sources_dir.rglob("*.swift"))
    if not source_paths:
        raise LocalizationVerificationError(
            f"No shipped Swift sources found in: {sources_dir}"
        )
    for path in source_paths:
        filename = path.relative_to(sources_dir).as_posix()
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

    if not info_plist_path.is_file() or info_plist_path.is_symlink():
        raise LocalizationVerificationError(
            f"Missing regular application Info.plist: {info_plist_path}"
        )
    with info_plist_path.open("rb") as stream:
        info = plistlib.load(stream)
    development_region = info.get("CFBundleDevelopmentRegion")
    if development_region != "ru":
        issues.append(
            "Resources/Info.plist must set CFBundleDevelopmentRegion to 'ru' "
            f"(found {development_region!r})"
        )
    bundle_localizations = info.get("CFBundleLocalizations")
    if not isinstance(bundle_localizations, list) or "ru" not in (
        bundle_localizations
    ):
        issues.append(
            "Resources/Info.plist must declare Russian in "
            "CFBundleLocalizations"
        )

    russian_resources = info_plist_path.parent / "ru.lproj"
    if not russian_resources.is_dir() or russian_resources.is_symlink():
        issues.append("Resources/ru.lproj must be a regular directory")
    else:
        info_strings = russian_resources / "InfoPlist.strings"
        localizable_strings = russian_resources / "Localizable.strings"
        for resource in (info_strings, localizable_strings):
            if not resource.is_file() or resource.is_symlink():
                issues.append(
                    f"Missing regular Russian bundle resource: {resource.name}"
                )
        if localizable_strings.is_file() and not localizable_strings.is_symlink():
            localized_text = localizable_strings.read_text(encoding="utf-8")
            for key in REQUIRED_RUSSIAN_BUNDLE_STRINGS:
                if f'"{key}"' not in localized_text:
                    issues.append(
                        f"Russian Localizable.strings is missing native key: {key}"
                    )

    return {
        "qualified": not issues,
        "files": [
            path.relative_to(sources_dir).as_posix()
            for path in source_paths
        ],
        "bundleDevelopmentRegion": development_region,
        "bundleLocalizations": bundle_localizations,
        "visibleStringCount": len(visible_strings),
        "issues": issues,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Check every shipped SwiftUI source and its accessibility/help "
            "copy for known English residue, required Russian actions, and "
            "a Russian bundle locale."
        )
    )
    parser.add_argument(
        "--sources-dir",
        type=Path,
        default=DEFAULT_SOURCES_DIR,
    )
    parser.add_argument(
        "--info-plist",
        type=Path,
        default=DEFAULT_INFO_PLIST,
    )
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    try:
        result = inspect_sources(args.sources_dir, args.info_plist)
    except (
        OSError,
        UnicodeError,
        plistlib.InvalidFileException,
        LocalizationVerificationError,
    ) as error:
        print(f"Direct UI localization verification failed: {error}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(result, indent=2, ensure_ascii=False))
    elif result["qualified"]:
        print(
            "PASS: shipped SwiftUI actions, visible labels and bundle locale "
            "are Russian "
            f"({len(result['files'])} files, "
            f"{result['visibleStringCount']} strings checked)."
        )
    else:
        for issue in result["issues"]:
            print(f"FAIL: {issue}", file=sys.stderr)
    return 0 if result["qualified"] else 1


if __name__ == "__main__":
    sys.exit(main())
