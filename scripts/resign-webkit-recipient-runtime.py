#!/usr/bin/env python3
"""Re-sign a copied WebKit Frameworks tree for an existing recipient app.

This is a packaging helper, not a build or license tool. It never edits the
source tree or manager app. The output is committed only after the existing
WebKit host verifier accepts every image, XPC entitlement, team, timestamp,
and relocatable runtime path.
"""
from __future__ import annotations

import argparse
import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

SCRIPT_DIR = Path(__file__).resolve().parent
PACKAGER_PATH = SCRIPT_DIR / "package-webkit-host.py"
SPEC = importlib.util.spec_from_file_location("neantik_package_webkit_host", PACKAGER_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("WebKit host packager is unavailable")
PACKAGER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = PACKAGER
SPEC.loader.exec_module(PACKAGER)
RELOCATOR_PATH = SCRIPT_DIR / "relocate-webkit-runtime-rpaths.py"
RELOCATOR_SPEC = importlib.util.spec_from_file_location("neantik_relocate_webkit_runtime_rpaths", RELOCATOR_PATH)
if RELOCATOR_SPEC is None or RELOCATOR_SPEC.loader is None:
    raise RuntimeError("WebKit runtime RPATH relocator is unavailable")
RELOCATOR = importlib.util.module_from_spec(RELOCATOR_SPEC)
sys.modules[RELOCATOR_SPEC.name] = RELOCATOR
RELOCATOR_SPEC.loader.exec_module(RELOCATOR)


class ResignError(ValueError):
    pass


def _inside(path: Path, root: Path) -> bool:
    try:
        path.resolve(strict=True).relative_to(root)
        return True
    except (OSError, ValueError):
        return False


def _validate_tree(root: Path) -> Path:
    if root.is_symlink() or not root.is_dir():
        raise ResignError("Frameworks input must be an existing physical directory")
    resolved = root.resolve(strict=True)
    for entry in root.rglob("*"):
        if entry.is_symlink() and not _inside(entry, resolved):
            raise ResignError("Frameworks input contains a symlink outside its root")
    if not (root / "WebKit.framework/Versions/A/WebKit").is_file():
        raise ResignError("Frameworks input is missing the owned WebKit image")
    return resolved


def _manager_team(app: Path, development_qa: bool = False) -> str:
    app_info = PACKAGER.read_info(app, allow_development_qa=development_qa)
    if development_qa and app_info["CFBundleIdentifier"] != PACKAGER.DEVELOPMENT_BUNDLE_ID:
        raise ResignError("Development QA requires the separate Dev manager bundle")
    return PACKAGER.manager_signing_team(app, app_info["CFBundleIdentifier"])


def _macho_files(root: Path) -> list[Path]:
    images = []
    for entry in root.rglob("*"):
        if entry.is_symlink() or not entry.is_file():
            continue
        try:
            with entry.open("rb") as stream:
                magic = stream.read(4)
        except OSError as error:
            raise ResignError("Cannot read a runtime file") from error
        if magic in PACKAGER.MACHO_MAGICS:
            images.append(entry)
    if not images:
        raise ResignError("Frameworks input contains no Mach-O images")
    return images


def _xpc_entitlements(bundle: Path) -> dict[str, object]:
    info_path = bundle / "Contents/Info.plist"
    if info_path.is_symlink() or not info_path.is_file():
        raise ResignError("Runtime XPC Info.plist is missing or unsafe")
    try:
        info = plistlib.loads(info_path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        raise ResignError("Runtime XPC Info.plist is unreadable") from error
    identifier = info.get("CFBundleIdentifier") if isinstance(info, dict) else None
    expected = PACKAGER.RELEASE_XPC_ENTITLEMENTS.get(identifier)
    if expected is None:
        raise ResignError("Runtime contains an unrecognized WebKit XPC service")
    return expected


def _sign(identity: str, path: Path, entitlements: dict[str, object] | None = None) -> None:
    arguments = ["/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp"]
    if entitlements is not None:
        with tempfile.NamedTemporaryFile(prefix="neantik-webkit-xpc-entitlements-", suffix=".plist") as handle:
            handle.write(plistlib.dumps(entitlements, fmt=plistlib.FMT_XML, sort_keys=True))
            handle.flush()
            subprocess.run(arguments + ["--entitlements", handle.name, "--sign", identity, str(path)],
                           check=True, capture_output=True)
    else:
        subprocess.run(arguments + ["--sign", identity, str(path)], check=True, capture_output=True)


def resign_runtime(manager_app: Path, source_frameworks: Path, output_frameworks: Path,
                   identity: str, development_qa: bool = False) -> Path:
    """Copy, recipient-sign, validate, and atomically publish a Frameworks tree."""
    source = _validate_tree(source_frameworks)
    if manager_app.is_symlink() or not manager_app.is_dir():
        raise ResignError("Recipient manager app must be a physical app bundle")
    app = manager_app.resolve(strict=True)
    requested_output = output_frameworks.absolute()
    parent = requested_output.parent
    if not parent.is_dir():
        raise ResignError("Output parent must be an existing physical directory")
    # macOS exposes /var and /tmp as symlinks to /private/var and /private/tmp.
    # Canonicalize the parent so the final atomic rename has one physical path.
    parent = parent.resolve(strict=True)
    output = parent / requested_output.name
    if output.exists() or output.is_symlink():
        raise ResignError("Output already exists; refusing to replace recipient data")
    if output == source or source in output.parents or output in source.parents:
        raise ResignError("Source and output trees must be separate")
    if app == output or app in output.parents or output in app.parents:
        raise ResignError("Output must remain separate from the manager app")

    expected_team = _manager_team(app, development_qa)
    PACKAGER.verify_signing_identity(identity, expected_team)

    temporary_parent = Path(tempfile.mkdtemp(prefix=".neantik-webkit-resign-", dir=parent))
    staged = temporary_parent / "Frameworks"
    try:
        shutil.copytree(source_frameworks, staged, symlinks=True)
        staged_root = staged.resolve(strict=True)
        relocation_root, relocation_plan = RELOCATOR.inspect(staged)
        if relocation_plan:
            RELOCATOR.apply(staged, relocation_plan, relocation_root)
        images = _macho_files(staged)
        for image in images:
            _sign(identity, image)

        xpc_root = staged / "WebKit.framework/Versions/A/XPCServices"
        xpcs = sorted(xpc_root.glob("*.xpc")) if xpc_root.is_dir() and not xpc_root.is_symlink() else []
        seen = set()
        for bundle in xpcs:
            if bundle.is_symlink() or not bundle.is_dir():
                raise ResignError("Runtime XPC bundle must be a physical directory")
            info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
            identifier = info.get("CFBundleIdentifier") if isinstance(info, dict) else None
            if identifier in seen:
                raise ResignError("Duplicate runtime XPC identity")
            seen.add(identifier)
            _sign(identity, bundle, _xpc_entitlements(bundle))
        if seen != set(PACKAGER.RELEASE_XPC_ENTITLEMENTS):
            raise ResignError("Runtime XPC service set is incomplete")

        bundles = [entry for entry in staged.rglob("*")
                   if not entry.is_symlink() and entry.is_dir()
                   and entry.suffix in {".framework", ".xpc", ".bundle"}]
        for bundle in sorted(bundles, key=lambda item: len(item.parts), reverse=True):
            if bundle.suffix != ".xpc":
                _sign(identity, bundle)

        PACKAGER.verify_runtime_frameworks(staged, expected_team)
        PACKAGER.verify_release_xpc_entitlements(staged)
        if staged.resolve(strict=True) != staged_root:
            raise ResignError("Staged runtime root changed during signing")
        os.replace(staged, output)
        return output
    except (OSError, subprocess.SubprocessError, plistlib.InvalidFileException) as error:
        raise ResignError("Recipient runtime signing or validation failed") from error
    finally:
        shutil.rmtree(temporary_parent, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manager-app", type=Path, required=True,
                        help="Existing signed recipient app; its Developer ID team is authoritative")
    parser.add_argument("--source-frameworks", type=Path, required=True,
                        help="Disposable copy of the built WebKit Frameworks tree")
    parser.add_argument("--output-frameworks", type=Path, required=True,
                        help="New output path; existing data is never replaced")
    parser.add_argument("--identity", required=True,
                        help="Existing Developer ID Application identity for the manager team")
    parser.add_argument("--development-qa", action="store_true",
                        help="Allow only a separately signed app.neantik.desktop.dev recipient")
    args = parser.parse_args()
    try:
        result = resign_runtime(args.manager_app, args.source_frameworks,
                                args.output_frameworks, args.identity, args.development_qa)
    except ResignError as error:
        parser.exit(1, f"Recipient WebKit re-sign refused: {error}\n")
    except PACKAGER.ContractError as error:
        parser.exit(1, f"Recipient WebKit re-sign refused: {error}\n")
    except RELOCATOR.ContractError as error:
        parser.exit(1, f"Recipient WebKit re-sign refused: {error}\n")
    print(f"Recipient-signed Frameworks tree: {result}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
