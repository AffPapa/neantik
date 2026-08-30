#!/usr/bin/env python3
"""Remove local symbols from an unsigned Apple Silicon Chromium staging app.

Chromium's bundled llvm-strip 22 can corrupt Mach-O string-table alignment on
macOS 27. This release step deliberately uses Xcode's Apple `strip` tool on a
temporary, unsigned copy and verifies every Mach-O before signing.
"""

from __future__ import annotations

import argparse
import json
import os
import struct
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


MH_MAGIC_64 = b"\xcf\xfa\xed\xfe"
FAT_MAGICS = {
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf",
    b"\xbf\xba\xfe\xca",
}
CPU_TYPE_ARM64 = 0x0100000C
LC_DYSYMTAB = 0x0B


class OptimizationError(RuntimeError):
    pass


@dataclass(frozen=True)
class MachOInspection:
    cpu_type: int
    local_symbol_count: int


def inspect_macho(path: Path) -> MachOInspection | None:
    with path.open("rb") as handle:
        magic = handle.read(4)
        if magic in FAT_MAGICS:
            raise OptimizationError(
                f"Universal Mach-O is not allowed in the ARM64 runtime: {path}"
            )
        if magic != MH_MAGIC_64:
            return None
        header_tail = handle.read(28)
        if len(header_tail) != 28:
            raise OptimizationError(f"Truncated Mach-O header: {path}")
        (
            cpu_type,
            _cpu_subtype,
            _file_type,
            command_count,
            command_bytes,
            _flags,
            _reserved,
        ) = struct.unpack("<iiIIIII", header_tail)
        commands = handle.read(command_bytes)
        if len(commands) != command_bytes:
            raise OptimizationError(f"Truncated Mach-O commands: {path}")

    offset = 0
    local_symbol_count: int | None = None
    for _ in range(command_count):
        if offset + 8 > len(commands):
            raise OptimizationError(f"Invalid Mach-O command table: {path}")
        command, command_size = struct.unpack_from("<II", commands, offset)
        if command_size < 8 or offset + command_size > len(commands):
            raise OptimizationError(f"Invalid Mach-O load command: {path}")
        if command == LC_DYSYMTAB:
            if command_size < 16:
                raise OptimizationError(f"Invalid LC_DYSYMTAB command: {path}")
            local_symbol_count = struct.unpack_from(
                "<I", commands, offset + 12
            )[0]
        offset += command_size

    if offset != len(commands):
        raise OptimizationError(f"Unexpected Mach-O command padding: {path}")
    if local_symbol_count is None:
        raise OptimizationError(f"Mach-O has no LC_DYSYMTAB command: {path}")
    return MachOInspection(
        cpu_type=cpu_type,
        local_symbol_count=local_symbol_count,
    )


def iter_macho_files(contents: Path) -> list[Path]:
    result: list[Path] = []
    for root, directories, files in os.walk(contents, followlinks=False):
        root_path = Path(root)
        directories[:] = [
            name for name in directories if not (root_path / name).is_symlink()
        ]
        for name in files:
            candidate = root_path / name
            if candidate.is_symlink() or not candidate.is_file():
                continue
            if inspect_macho(candidate) is not None:
                result.append(candidate)
    return sorted(result)


def require_unsigned(app: Path) -> None:
    signature_directories = [
        path
        for path in app.rglob("_CodeSignature")
        if path.is_dir() and not path.is_symlink()
    ]
    if signature_directories:
        raise OptimizationError(
            "Runtime optimization requires a staging copy without "
            "_CodeSignature directories."
        )
    completed = subprocess.run(
        ["codesign", "--display", str(app)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if completed.returncode == 0:
        raise OptimizationError(
            "Runtime optimization refuses an app with an attached signature."
        )


def optimize(app: Path, strip_tool: Path) -> dict[str, object]:
    if not app.is_absolute() or not app.is_dir() or app.is_symlink():
        raise OptimizationError(
            "Runtime app must be an existing absolute non-symlink directory."
        )
    contents = app / "Contents"
    if not contents.is_dir() or contents.is_symlink():
        raise OptimizationError("Runtime Contents directory is unsafe.")
    info_plist = contents / "Info.plist"
    main_executable = contents / "MacOS" / "NeAntik Browser"
    if not info_plist.is_file() or not main_executable.is_file():
        raise OptimizationError("Runtime bundle is incomplete.")
    if (
        not strip_tool.is_absolute()
        or not strip_tool.is_file()
        or not os.access(strip_tool, os.X_OK)
        or strip_tool.name != "strip"
        or "Xcode" not in str(strip_tool)
        or "/Toolchains/XcodeDefault.xctoolchain/usr/bin/strip" not in str(
            strip_tool
        )
    ):
        raise OptimizationError(
            "Use XcodeDefault.xctoolchain/usr/bin/strip, never llvm-strip."
        )

    require_unsigned(app)
    binaries = iter_macho_files(contents)
    if not binaries or main_executable not in binaries:
        raise OptimizationError("Runtime Mach-O inventory is incomplete.")

    before_bytes = 0
    after_bytes = 0
    before_locals = 0
    after_locals = 0
    changed = 0
    details: list[dict[str, object]] = []
    for binary in binaries:
        before = inspect_macho(binary)
        if before is None or before.cpu_type != CPU_TYPE_ARM64:
            raise OptimizationError(f"Runtime binary is not ARM64: {binary}")
        initial_size = binary.stat().st_size
        if before.local_symbol_count > 1:
            completed = subprocess.run(
                [str(strip_tool), "-x", "-S", str(binary)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
            if completed.returncode != 0:
                detail = (completed.stderr or completed.stdout).strip()
                raise OptimizationError(
                    f"Apple strip failed for {binary}: {detail}"
                )
        after = inspect_macho(binary)
        if after is None or after.cpu_type != before.cpu_type:
            raise OptimizationError(f"Apple strip damaged Mach-O: {binary}")
        final_size = binary.stat().st_size
        if before.local_symbol_count > 1 and final_size > initial_size:
            raise OptimizationError(f"Apple strip increased binary size: {binary}")
        if after.local_symbol_count > 1:
            raise OptimizationError(
                "Apple strip left unexpected local symbols in "
                f"{binary}: {after.local_symbol_count}"
            )
        if final_size < initial_size:
            changed += 1
        before_bytes += initial_size
        after_bytes += final_size
        before_locals += before.local_symbol_count
        after_locals += after.local_symbol_count
        details.append(
            {
                "relativePath": str(binary.relative_to(app)),
                "beforeBytes": initial_size,
                "afterBytes": final_size,
                "beforeLocalSymbols": before.local_symbol_count,
                "afterLocalSymbols": after.local_symbol_count,
            }
        )

    if before_locals > len(binaries) and changed == 0:
        raise OptimizationError("Runtime local symbols were not removed.")
    require_unsigned(app)
    return {
        "schemaVersion": 1,
        "stripTool": str(strip_tool),
        "binaryCount": len(binaries),
        "changedBinaryCount": changed,
        "beforeBytes": before_bytes,
        "afterBytes": after_bytes,
        "savedBytes": before_bytes - after_bytes,
        "beforeLocalSymbols": before_locals,
        "afterLocalSymbols": after_locals,
        "binaries": details,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--strip-tool", required=True, type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    try:
        report = optimize(args.app, args.strip_tool)
        serialized = json.dumps(report, ensure_ascii=False, sort_keys=True)
        if args.report is not None:
            if not args.report.is_absolute() or args.report.exists():
                raise OptimizationError(
                    "Report path must be absolute and must not already exist."
                )
            args.report.write_text(serialized + "\n", encoding="utf-8")
        print(serialized)
        return 0
    except (OSError, OptimizationError) as error:
        print(f"Runtime size optimization failed: {error}", file=sys.stderr)
        return 65


if __name__ == "__main__":
    raise SystemExit(main())
