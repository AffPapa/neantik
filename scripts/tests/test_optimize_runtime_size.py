import importlib.util
import struct
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "optimize-runtime-size.py"
SPEC = importlib.util.spec_from_file_location("optimize_runtime_size", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def macho_fixture(*, cpu_type: int, local_symbols: int) -> bytes:
    command = struct.pack(
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
        1,
        len(command),
        0,
        0,
    )
    return header + command


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

    def test_optimizer_source_forbids_llvm_strip(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn('strip_tool.name != "strip"', source)
        self.assertIn("never llvm-strip", source)
        self.assertIn('after.local_symbol_count > 1', source)
        self.assertIn("require_unsigned(app)", source)


if __name__ == "__main__":
    unittest.main()
