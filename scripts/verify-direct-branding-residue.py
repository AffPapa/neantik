#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import plistlib
import sys
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
LEGACY_NAME = "NeVision"
EXPECTED_MANAGER_VALUES = {
    "CFBundleDisplayName": "NeAntik",
    "CFBundleExecutable": "NeAntik",
    "CFBundleIdentifier": "app.neantik.desktop",
    "CFBundleName": "NeAntik",
    "CFBundleSignature": "NANT",
}


class BrandingVerificationError(ValueError):
    pass


def load_plist(path: Path) -> dict[str, Any]:
    if not path.is_file() or path.is_symlink():
        raise BrandingVerificationError(f"Missing regular plist: {path}")
    with path.open("rb") as file:
        value = plistlib.load(file)
    if not isinstance(value, dict):
        raise BrandingVerificationError(f"Plist is not an object: {path}")
    return value


def inspect_app(app: Path) -> dict[str, Any]:
    if app.name != "NeAntik.app" or not app.is_dir() or app.is_symlink():
        raise BrandingVerificationError(
            "Direct bundle must be a regular directory named NeAntik.app"
        )

    contents = app / "Contents"
    manager_info = load_plist(contents / "Info.plist")
    public_issues: list[str] = []
    for key, expected in EXPECTED_MANAGER_VALUES.items():
        actual = manager_info.get(key)
        if actual != expected:
            public_issues.append(
                f"{key} is {actual!r}; expected {expected!r}"
            )

    pkg_info = contents / "PkgInfo"
    if not pkg_info.is_file() or pkg_info.read_bytes() != b"APPLNANT":
        public_issues.append("PkgInfo must be APPLNANT")

    manager_executable = contents / "MacOS" / "NeAntik"
    if not manager_executable.is_file():
        public_issues.append("Manager executable is missing")
    elif LEGACY_NAME.encode() in manager_executable.read_bytes():
        public_issues.append(
            "Manager executable contains user-facing legacy NeVision casing"
        )

    for path in (
        contents / "Info.plist",
        contents / "Resources" / "PrivacyInfo.xcprivacy",
    ):
        if path.is_file() and LEGACY_NAME.encode() in path.read_bytes():
            public_issues.append(
                f"Public manager metadata contains {LEGACY_NAME}: {path.name}"
            )

    runtime = contents / "Resources" / "NeAntik Browser.app"
    if not runtime.is_dir():
        public_issues.append("Embedded NeAntik Browser.app is missing")
        legacy_runtime_paths: list[str] = []
    else:
        legacy_runtime_paths = sorted(
            str(path.relative_to(runtime))
            for path in runtime.rglob("*")
            if LEGACY_NAME in path.name
        )

    return {
        "app": str(app),
        "publicManagerQualified": not public_issues,
        "publicManagerIssues": public_issues,
        "legacyRuntimeBrandingCount": len(legacy_runtime_paths),
        "legacyRuntimeBrandingExamples": legacy_runtime_paths[:20],
        "strictRuntimeBrandingQualified": not legacy_runtime_paths,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Reject public NeVision residue while explicitly separating "
            "legacy compiled Chromium branding that requires a full rebuild."
        )
    )
    parser.add_argument(
        "--app",
        type=Path,
        default=PROJECT_ROOT / "dist" / "NeAntik.app",
    )
    parser.add_argument(
        "--allow-legacy-runtime-branding",
        action="store_true",
        help=(
            "Allow known compiled runtime path residue for a documented "
            "public-alpha release. Strict mode remains fail-closed."
        ),
    )
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    try:
        result = inspect_app(args.app)
    except (OSError, BrandingVerificationError, plistlib.InvalidFileException) as error:
        print(f"Direct branding verification failed: {error}", file=sys.stderr)
        return 1

    qualified = result["publicManagerQualified"] and (
        result["strictRuntimeBrandingQualified"]
        or args.allow_legacy_runtime_branding
    )
    result["qualified"] = qualified
    result["releaseMode"] = (
        "public-alpha-with-documented-runtime-residue"
        if qualified and not result["strictRuntimeBrandingQualified"]
        else "strict"
    )

    if args.json:
        print(json.dumps(result, indent=2, ensure_ascii=False))
    else:
        if not result["publicManagerQualified"]:
            for issue in result["publicManagerIssues"]:
                print(f"FAIL: {issue}", file=sys.stderr)
        if result["legacyRuntimeBrandingCount"]:
            prefix = (
                "WATCH"
                if args.allow_legacy_runtime_branding
                and result["publicManagerQualified"]
                else "FAIL"
            )
            print(
                f"{prefix}: {result['legacyRuntimeBrandingCount']} compiled "
                "Chromium paths retain NeVision branding; a full runtime "
                "rebuild is required for strict branding."
            )
        if qualified:
            print("PASS: public NeAntik manager branding is clean.")
    return 0 if qualified else 1


if __name__ == "__main__":
    sys.exit(main())
