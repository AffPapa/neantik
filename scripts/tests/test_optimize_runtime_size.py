import contextlib
import importlib.util
import io
import json
import struct
import sys
import tempfile
import unittest
from pathlib import Path
from subprocess import CompletedProcess
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "optimize-runtime-size.py"
SPEC = importlib.util.spec_from_file_location("optimize_runtime_size", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def macho_fixture(
    *,
    cpu_type: int,
    local_symbols: int,
    string_table_offset: int = 0,
) -> bytes:
    symtab = struct.pack(
        "<IIIIII",
        MODULE.LC_SYMTAB,
        24,
        0,
        0,
        string_table_offset,
        0,
    )
    dysymtab = struct.pack(
        "<IIIIIIIIIIIIIIIIIIII",
        MODULE.LC_DYSYMTAB,
        80,
        0,
        local_symbols,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
    )
    header = MODULE.MH_MAGIC_64 + struct.pack(
        "<iiIIIII",
        cpu_type,
        0,
        2,
        2,
        len(symtab) + len(dysymtab),
        0,
        0,
    )
    return header + symtab + dysymtab + (b"\0" * local_symbols)


def runtime_fixture(root: Path, *, cpu_type: int, local_symbols: int) -> Path:
    app = root / "NeAntik Browser.app"
    contents = app / "Contents"
    executable = contents / "MacOS" / "NeAntik Browser"
    executable.parent.mkdir(parents=True)
    (contents / "Info.plist").write_text("fixture\n", encoding="utf-8")
    executable.write_bytes(
        macho_fixture(cpu_type=cpu_type, local_symbols=local_symbols)
    )
    return app


def strip_fixture(root: Path) -> Path:
    strip_tool = (
        root
        / "Xcode.app"
        / "Contents"
        / "Developer"
        / "Toolchains"
        / "XcodeDefault.xctoolchain"
        / "usr"
        / "bin"
        / "strip"
    )
    strip_tool.parent.mkdir(parents=True)
    strip_tool.write_text("#!/bin/sh\n", encoding="utf-8")
    strip_tool.chmod(0o755)
    return strip_tool


def fake_runner(
    *,
    strip_returncode: int = 0,
    retained_local_symbols: int = 1,
    string_table_offset: int = 0,
    signed: bool = False,
):
    def run(command, **_kwargs):
        if command[0] == "codesign":
            return CompletedProcess(
                command,
                0 if signed else 1,
                "",
                "" if signed else "not signed",
            )
        if Path(command[0]).name == "strip":
            if strip_returncode == 0:
                Path(command[-1]).write_bytes(
                    macho_fixture(
                        cpu_type=MODULE.CPU_TYPE_ARM64,
                        local_symbols=retained_local_symbols,
                        string_table_offset=string_table_offset,
                    )
                )
            return CompletedProcess(
                command,
                strip_returncode,
                "",
                "strip failed" if strip_returncode else "",
            )
        raise AssertionError(f"Unexpected command: {command}")

    return run


class RuntimeSizeOptimizerTests(unittest.TestCase):
    def test_reads_arm64_local_symbol_count(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / "runtime"
            binary.write_bytes(
                macho_fixture(
                    cpu_type=MODULE.CPU_TYPE_ARM64,
                    local_symbols=990_851,
                )
            )
            inspection = MODULE.inspect_macho(binary)

        self.assertEqual(inspection.cpu_type, MODULE.CPU_TYPE_ARM64)
        self.assertEqual(inspection.local_symbol_count, 990_851)

    def test_rejects_misaligned_string_table(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / "runtime"
            binary.write_bytes(
                macho_fixture(
                    cpu_type=MODULE.CPU_TYPE_ARM64,
                    local_symbols=2,
                    string_table_offset=3,
                )
            )
            with self.assertRaisesRegex(
                MODULE.OptimizationError,
                "Misaligned 64-bit Mach-O LINKEDIT string table",
            ):
                MODULE.inspect_macho(binary)

    def test_rejects_fat_macho_in_arm64_release(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / "runtime"
            binary.write_bytes(b"\xca\xfe\xba\xbe" + b"\0" * 64)
            with self.assertRaises(MODULE.OptimizationError):
                MODULE.inspect_macho(binary)

    def test_non_macho_is_ignored(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            resource = Path(temporary) / "resource.pak"
            resource.write_bytes(b"not a Mach-O")
            self.assertIsNone(MODULE.inspect_macho(resource))

    def test_optimizer_success_returns_exact_report(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = runtime_fixture(
                root,
                cpu_type=MODULE.CPU_TYPE_ARM64,
                local_symbols=8,
            )
            strip_tool = strip_fixture(root)
            with mock.patch.object(
                MODULE.subprocess,
                "run",
                side_effect=fake_runner(),
            ):
                report = MODULE.optimize(app, strip_tool)

        self.assertEqual(report["binaryCount"], 1)
        self.assertEqual(report["changedBinaryCount"], 1)
        self.assertEqual(report["beforeLocalSymbols"], 8)
        self.assertEqual(report["afterLocalSymbols"], 1)
        self.assertEqual(report["savedBytes"], 7)
        self.assertEqual(
            report["binaries"][0]["relativePath"],
            "Contents/MacOS/NeAntik Browser",
        )

    def test_main_writes_success_report(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = runtime_fixture(
                root,
                cpu_type=MODULE.CPU_TYPE_ARM64,
                local_symbols=7,
            )
            strip_tool = strip_fixture(root)
            report_path = root / "optimizer-report.json"
            arguments = [
                str(SCRIPT),
                str(app),
                "--strip-tool",
                str(strip_tool),
                "--report",
                str(report_path),
            ]
            with mock.patch.object(sys, "argv", arguments), mock.patch.object(
                MODULE.subprocess,
                "run",
                side_effect=fake_runner(),
            ), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(MODULE.main(), 0)

            report = json.loads(report_path.read_text(encoding="utf-8"))

        self.assertEqual(report["beforeLocalSymbols"], 7)
        self.assertEqual(report["afterLocalSymbols"], 1)

    def test_optimizer_rejects_signed_input(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = runtime_fixture(
                root,
                cpu_type=MODULE.CPU_TYPE_ARM64,
                local_symbols=8,
            )
            strip_tool = strip_fixture(root)
            with mock.patch.object(
                MODULE.subprocess,
                "run",
                side_effect=fake_runner(signed=True),
            ), self.assertRaisesRegex(
                MODULE.OptimizationError,
                "attached signature",
            ):
                MODULE.optimize(app, strip_tool)

    def test_optimizer_rejects_non_arm64_runtime(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = runtime_fixture(root, cpu_type=7, local_symbols=8)
            strip_tool = strip_fixture(root)
            with mock.patch.object(
                MODULE.subprocess,
                "run",
                side_effect=fake_runner(),
            ), self.assertRaisesRegex(
                MODULE.OptimizationError,
                "not ARM64",
            ):
                MODULE.optimize(app, strip_tool)

    def test_optimizer_fails_closed_when_strip_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = runtime_fixture(
                root,
                cpu_type=MODULE.CPU_TYPE_ARM64,
                local_symbols=8,
            )
            strip_tool = strip_fixture(root)
            with mock.patch.object(
                MODULE.subprocess,
                "run",
                side_effect=fake_runner(strip_returncode=1),
            ), self.assertRaisesRegex(
                MODULE.OptimizationError,
                "Apple strip failed",
            ):
                MODULE.optimize(app, strip_tool)

    def test_optimizer_fails_closed_when_local_symbols_remain(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = runtime_fixture(
                root,
                cpu_type=MODULE.CPU_TYPE_ARM64,
                local_symbols=8,
            )
            strip_tool = strip_fixture(root)
            with mock.patch.object(
                MODULE.subprocess,
                "run",
                side_effect=fake_runner(retained_local_symbols=2),
            ), self.assertRaisesRegex(
                MODULE.OptimizationError,
                "left unexpected local symbols",
            ):
                MODULE.optimize(app, strip_tool)

    def test_optimizer_fails_closed_when_strip_misaligns_string_table(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = runtime_fixture(
                root,
                cpu_type=MODULE.CPU_TYPE_ARM64,
                local_symbols=8,
            )
            strip_tool = strip_fixture(root)
            with mock.patch.object(
                MODULE.subprocess,
                "run",
                side_effect=fake_runner(string_table_offset=3),
            ), self.assertRaisesRegex(
                MODULE.OptimizationError,
                "Misaligned 64-bit Mach-O LINKEDIT string table",
            ):
                MODULE.optimize(app, strip_tool)

    def test_optimizer_source_forbids_llvm_strip(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn('strip_tool.name != "strip"', source)
        self.assertIn("never llvm-strip", source)
        self.assertIn('after.local_symbol_count > 1', source)
        self.assertIn("require_unsigned(app)", source)


if __name__ == "__main__":
    unittest.main()
