#!/usr/bin/env python3
"""Remove build-machine RPATHs from an unsigned WebKit staging tree.

Run after assembling the private Frameworks tree and before Developer ID
signing. The tool never signs, launches, or installs the runtime.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys


MACHO_MAGICS = {
    bytes.fromhex(value) for value in (
        "cffaedfe", "cefaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca"
    )
}
SYSTEM_RPATHS = {"/usr/lib/swift"}


class ContractError(ValueError):
    pass


def run(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, capture_output=True, text=True, check=True)


def require_frameworks_root(path: Path) -> Path:
    if path.is_symlink() or not path.is_dir():
        raise ContractError("Runtime root must be a physical staging directory")
    root = path.resolve(strict=True)
    for entry in path.rglob("*"):
        if entry.is_symlink():
            try:
                entry.resolve(strict=True).relative_to(root)
            except (OSError, ValueError) as error:
                raise ContractError("Runtime tree contains a symlink escaping staging root") from error
    return root


def macho_images(path: Path, root: Path) -> list[Path]:
    images = []
    seen = set()
    for entry in sorted(path.rglob("*")):
        if entry.is_symlink() or not entry.is_file():
            continue
        try:
            with entry.open("rb") as stream:
                magic = stream.read(4)
        except OSError as error:
            raise ContractError("Could not read a runtime image") from error
        if magic not in MACHO_MAGICS:
            continue
        resolved = entry.resolve(strict=True)
        resolved.relative_to(root)
        if resolved not in seen:
            seen.add(resolved)
            images.append(entry)
    if not images:
        raise ContractError("Runtime staging tree contains no Mach-O images")
    return images


def load_rpaths(binary: Path) -> list[str]:
    try:
        output = run(["/usr/bin/otool", "-l", str(binary)]).stdout
    except subprocess.SubprocessError as error:
        raise ContractError("Could not inspect runtime load commands") from error
    rpaths = []
    for command in output.split("cmd LC_RPATH")[1:]:
        match = re.search(r"^\s*path\s+(.+?)\s+\(offset\s+\d+\)", command, re.MULTILINE)
        if not match:
            raise ContractError("Runtime image has a malformed LC_RPATH")
        rpaths.append(match.group(1))
    return rpaths


def rpath_dependencies(binary: Path) -> list[str]:
    try:
        output = run(["/usr/bin/otool", "-L", str(binary)]).stdout
    except subprocess.SubprocessError as error:
        raise ContractError("Could not inspect runtime dependencies") from error
    # otool's first line is the inspected filename; subsequent lines include
    # the image ID and every LC_LOAD_DYLIB dependency.
    return [line.strip().split(" (compatibility")[0]
            for line in output.splitlines()[1:]
            if line.strip().startswith("@rpath/")]


def dependency_resolves_from_runtime_root(binary: Path, root: Path, dependency: str,
                                          rpaths: list[str]) -> bool:
    suffix = dependency.removeprefix("@rpath/")
    for value in rpaths:
        if value in SYSTEM_RPATHS:
            # Swift compatibility shims may be provided from dyld's system
            # shared cache rather than as standalone files on disk.
            if suffix.startswith("libswift"):
                return True
            continue
        if value == "@loader_path":
            base = binary.resolve(strict=True).parent
        elif value.startswith("@loader_path/"):
            base = (binary.resolve(strict=True).parent / value[len("@loader_path/"):]).resolve()
        else:
            continue
        candidate = base / suffix
        try:
            candidate.resolve(strict=False).relative_to(root)
        except ValueError:
            continue
        if candidate.exists():
            return True
    return False


def verify_relative_rpaths(binary: Path, root: Path, rpaths: list[str]) -> None:
    for value in rpaths:
        if value.startswith("/"):
            if value not in SYSTEM_RPATHS:
                continue  # Removed by the staging plan below.
            continue
        if value == "@loader_path":
            candidate = binary.resolve(strict=True).parent
        elif value.startswith("@loader_path/"):
            suffix = value[len("@loader_path/"):]
            candidate = (binary.resolve(strict=True).parent / suffix).resolve(strict=False)
        else:
            raise ContractError("Runtime RPATH must use @loader_path or an allowlisted system path")
        try:
            candidate.relative_to(root)
        except ValueError as error:
            raise ContractError("Relative runtime RPATH escapes staging root") from error


def preflight_signature(binary: Path) -> None:
    result = subprocess.run(
        ["/usr/bin/codesign", "-dv", "--verbose=2", str(binary)],
        capture_output=True, text=True,
    )
    detail = result.stdout + result.stderr
    if result.returncode != 0 and "code object is not signed at all" in detail.lower():
        return
    if "Signature=adhoc" in detail and "TeamIdentifier=not set" in detail:
        return
    raise ContractError("Refusing to mutate a signed or unrecognized runtime image")


def inspect(path: Path) -> tuple[Path, list[dict[str, object]]]:
    root = require_frameworks_root(path)
    plan = []
    for binary in macho_images(path, root):
        resolved = binary.resolve(strict=True)
        rpaths = load_rpaths(binary)
        verify_relative_rpaths(binary, root, rpaths)
        remove = [value for value in rpaths if value.startswith("/") and value not in SYSTEM_RPATHS]
        add = None
        missing_runtime_edge = any(
            not dependency_resolves_from_runtime_root(binary, root, dependency, rpaths)
            for dependency in rpath_dependencies(binary)
        )
        if missing_runtime_edge:
            relative_root = os.path.relpath(root, resolved.parent)
            add = "@loader_path" + ("/" + relative_root if relative_root != "." else "")
            if add in rpaths:
                raise ContractError("Existing runtime RPATH does not resolve a bundled dependency")
            unresolved = [dependency for dependency in rpath_dependencies(binary)
                          if not dependency_resolves_from_runtime_root(
                              binary, root, dependency, [*rpaths, add])]
            if unresolved:
                raise ContractError("Runtime dependency is not present in staging or allowlisted system paths")
        if remove or add:
            plan.append({"image": str(resolved.relative_to(root)), "remove": remove, "add": add})
    return root, plan


def apply(path: Path, plan: list[dict[str, object]], root: Path) -> None:
    images = {str(image.resolve(strict=True).relative_to(root)): image for image in macho_images(path, root)}
    for item in plan:
        binary = images[str(item["image"])]
        preflight_signature(binary)
    for item in plan:
        binary = images[str(item["image"])]
        for rpath in item["remove"]:
            run(["/usr/bin/install_name_tool", "-delete_rpath", str(rpath), str(binary)])
        if item["add"]:
            run(["/usr/bin/install_name_tool", "-add_rpath", str(item["add"]), str(binary)])
    _, remaining = inspect(path)
    if remaining:
        raise ContractError("Runtime still has build-machine RPATHs or missing relative runtime paths")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("frameworks", type=Path, help="private, pre-sign Frameworks staging directory")
    parser.add_argument("--apply", action="store_true", help="mutate this staging tree before code signing")
    args = parser.parse_args()
    try:
        root, plan = inspect(args.frameworks)
        if args.apply and plan:
            apply(args.frameworks, plan, root)
        print(json.dumps({
            "result": "applied" if args.apply else "dry-run",
            "frameworksRoot": str(root),
            "machoImages": len(macho_images(args.frameworks, root)),
            "changedImages": len(plan),
            "changes": plan,
            "signatureAfterApply": "must be Developer ID signed after relocation",
        }, ensure_ascii=False, indent=2))
        return 0
    except (ContractError, OSError, subprocess.SubprocessError) as error:
        print(json.dumps({"result": "refused", "reason": str(error)}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
