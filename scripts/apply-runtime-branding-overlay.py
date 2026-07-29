#!/usr/bin/env python3

"""Apply NeAntik's exact-preimage Chromium branding overlay."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import re
import sys


BRANDING_PATH = Path("chrome/app/theme/chromium/BRANDING")
APP_PLIST_PATH = Path("chrome/app/app-Info.plist")
APP_ICON_PATH = Path("chrome/app/theme/chromium/mac/app.icns")
CHROMIUM_STRINGS_PATH = Path("chrome/app/chromium_strings.grd")

BRANDING_BEFORE = (
    "15ac20cb8744ebac0815961059231baefa"
    "71fd4ed3023cb2094aaf8a34ae423b"
)
BRANDING_AFTER = (
    "c49446ab785ce478cef03fa7a393f65d"
    "ee45e7e1479a85aadeb96acfd3df1d09"
)
APP_PLIST_BEFORE = (
    "c307bd327bf0e9102027b6adec2156336"
    "80f8e7f6c7cd6ab86b73961e32348d0"
)
APP_PLIST_AFTER = (
    "f9653170f8f5dcc0b71e202afb6ea716"
    "258a7a6c698b8d684da9ddead4e9bf5f"
)
APP_ICON_BEFORE = (
    "a1c2b17191234ee4ab1259d4fb5056ef"
    "340cc64345c1a7d2b504c632812ff062"
)
APP_ICON_AFTER = (
    "421defe904b8cc761d9cac3ed226e8d86"
    "4cc7ecb0ab281a76bde5e67b61f317a"
)
CHROMIUM_STRINGS_BEFORE = (
    "59666f75079fea7c27c25bde4076d4406"
    "8cb60429ff5932e0d907f74151a4379"
)
CHROMIUM_STRINGS_AFTER = (
    "0b382334bd23b84ef98c8263a8513050"
    "5d360c3c5b68f26afee344e8dcb8208c"
)

BRANDING_CONTENT = """\
COMPANY_FULLNAME=NeAntik
COMPANY_SHORTNAME=NeAntik
PRODUCT_FULLNAME=NeAntik Browser
PRODUCT_SHORTNAME=NeAntik
PRODUCT_INSTALLER_FULLNAME=NeAntik Browser Installer
PRODUCT_INSTALLER_SHORTNAME=NeAntik Installer
COPYRIGHT=Copyright @LASTCHANGE_YEAR@ The Chromium Authors and NeAntik contributors.
MAC_BUNDLE_ID=app.neantik.runtime
MAC_CREATOR_CODE=NVsn
MAC_TEAM_ID=
"""

ICON_NAME_ENTRY = """\
\t<key>CFBundleIconName</key>
\t<string>AppIcon</string>
"""
NAME_ENTRY = """\
\t<key>CFBundleName</key>
\t<string>${CHROMIUM_SHORT_NAME}</string>
"""
NEANTIK_ENTRIES = """\
\t<key>LSApplicationCategoryType</key>
\t<string>public.app-category.utilities</string>
\t<key>NeAntikRuntimeFlavor</key>
\t<string>fingerprint-chromium</string>
\t<key>NeAntikRuntimeBuildMode</key>
\t<string>source-build</string>
"""


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def replace_atomically(path: Path, data: bytes) -> None:
    temporary = path.with_name(f".{path.name}.nevision-branding")
    temporary.write_bytes(data)
    os.chmod(temporary, path.stat().st_mode)
    os.replace(temporary, path)


def transform_plist(data: bytes) -> bytes:
    text = data.decode("utf-8")
    if text.count(ICON_NAME_ENTRY) != 1:
        raise ValueError("expected one CFBundleIconName entry")
    if text.count(NAME_ENTRY) != 1:
        raise ValueError("expected one CFBundleName entry")
    if "NeAntikRuntimeFlavor" in text:
        raise ValueError("NeAntik metadata is already present in preimage")
    text = text.replace(ICON_NAME_ENTRY, "", 1)
    text = text.replace(
        NAME_ENTRY,
        NAME_ENTRY + NEANTIK_ENTRIES,
        1,
    )
    return text.encode("utf-8")


def transform_strings(data: bytes) -> bytes:
    text = data.decode("utf-8")
    parts = re.split(r"(<[^>]*>)", text)
    replacements = 0
    for index in range(0, len(parts), 2):
        visible = parts[index]
        protected = visible.replace(
            "The Chromium Authors",
            "__NEANTIK_CHROMIUM_AUTHORS__",
        ).replace(
            "ChromiumOS",
            "__NEANTIK_CHROMIUM_OS__",
        )
        replacements += protected.count("Chromium")
        protected = protected.replace("Chromium", "NeAntik")
        parts[index] = protected.replace(
            "__NEANTIK_CHROMIUM_AUTHORS__",
            "The Chromium Authors",
        ).replace(
            "__NEANTIK_CHROMIUM_OS__",
            "ChromiumOS",
        )
    if replacements != 476:
        raise ValueError(
            f"expected 476 visible Chromium strings, found {replacements}"
        )
    return "".join(parts).encode("utf-8")


def verify_or_apply(
    path: Path,
    before: str,
    after: str,
    replacement: bytes,
    check: bool,
) -> bool:
    if not path.is_file():
        print(f"Missing Chromium source file: {path}", file=sys.stderr)
        return False
    current = path.read_bytes()
    current_digest = digest(current)
    if current_digest == after:
        print(f"OK   {path}")
        return True
    if current_digest != before:
        print(
            f"Unexpected preimage for {path}: {current_digest}",
            file=sys.stderr,
        )
        return False
    if check:
        print(f"Branding overlay is not applied: {path}", file=sys.stderr)
        return False
    if digest(replacement) != after:
        print(
            f"Unexpected calculated postimage for {path}: "
            f"{digest(replacement)}",
            file=sys.stderr,
        )
        return False
    replace_atomically(path, replacement)
    print(f"APPLY {path}")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source_root", type=Path)
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()
    root = arguments.source_root.resolve()
    project_root = Path(__file__).resolve().parent.parent
    project_icon = project_root / "Resources/NeAntik.icns"

    if not project_icon.is_file():
        print(f"Missing NeAntik icon: {project_icon}", file=sys.stderr)
        return 66
    icon = project_icon.read_bytes()
    if digest(icon) != APP_ICON_AFTER:
        print(
            f"Unexpected NeAntik icon digest: {digest(icon)}",
            file=sys.stderr,
        )
        return 65

    plist_path = root / APP_PLIST_PATH
    if not plist_path.is_file():
        print(f"Missing Chromium source file: {plist_path}", file=sys.stderr)
        return 66
    plist = plist_path.read_bytes()
    if digest(plist) == APP_PLIST_AFTER:
        branded_plist = plist
    elif digest(plist) == APP_PLIST_BEFORE:
        try:
            branded_plist = transform_plist(plist)
        except ValueError as error:
            print(f"Cannot transform {plist_path}: {error}", file=sys.stderr)
            return 65
    else:
        branded_plist = b""

    strings_path = root / CHROMIUM_STRINGS_PATH
    if not strings_path.is_file():
        print(f"Missing Chromium source file: {strings_path}", file=sys.stderr)
        return 66
    strings = strings_path.read_bytes()
    if digest(strings) == CHROMIUM_STRINGS_AFTER:
        branded_strings = strings
    elif digest(strings) == CHROMIUM_STRINGS_BEFORE:
        try:
            branded_strings = transform_strings(strings)
        except ValueError as error:
            print(f"Cannot transform {strings_path}: {error}", file=sys.stderr)
            return 65
    else:
        branded_strings = b""

    checks = [
        verify_or_apply(
            root / BRANDING_PATH,
            BRANDING_BEFORE,
            BRANDING_AFTER,
            BRANDING_CONTENT.encode("utf-8"),
            arguments.check,
        ),
        verify_or_apply(
            plist_path,
            APP_PLIST_BEFORE,
            APP_PLIST_AFTER,
            branded_plist,
            arguments.check,
        ),
        verify_or_apply(
            root / APP_ICON_PATH,
            APP_ICON_BEFORE,
            APP_ICON_AFTER,
            icon,
            arguments.check,
        ),
        verify_or_apply(
            strings_path,
            CHROMIUM_STRINGS_BEFORE,
            CHROMIUM_STRINGS_AFTER,
            branded_strings,
            arguments.check,
        ),
    ]
    if not all(checks):
        return 65

    print(
        "NeAntik source branding verified: app, executable, Framework, "
        "Helpers, bundle identifiers, runtime metadata, icon, and visible "
        "browser strings."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
