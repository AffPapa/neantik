from __future__ import annotations
import hashlib
import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "webkit_rpath_audit", ROOT / "scripts/audit-webkit-rpath-closure.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class WebKitRPathClosureAuditTests(unittest.TestCase):
    def test_internal_edge_resolves_to_hash_bound_image(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "Frameworks"
            (root / "A.framework/Versions/A").mkdir(parents=True)
            (root / "B.framework/Versions/A").mkdir(parents=True)
            loader = root / "A.framework/Versions/A/A"
            target = root / "B.framework/Versions/A/B"
            loader.write_bytes(b"loader")
            target.write_bytes(b"target")
            swift_root = Path(tmp) / "system-swift"
            swift_root.mkdir()
            result = MODULE.resolve_rpath_edge(
                loader, "@rpath/B.framework/Versions/A/B",
                ["@loader_path/../../.."], root, swift_root)
            self.assertEqual(result["state"], "payload-file")
            self.assertEqual(result["sha256"], hashlib.sha256(b"target").hexdigest())

    def test_system_compatibility_alias_is_not_misreported_as_payload_or_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            payload = base / "Frameworks"
            loader = payload / "WebGPU.framework/Versions/A/WebGPU"
            loader.parent.mkdir(parents=True)
            loader.write_bytes(b"webgpu")
            swift = base / "usr/lib/swift"
            swift.mkdir(parents=True)
            (swift / "libswiftCompatibilitySpan.dylib").symlink_to("libswiftCore.dylib")
            result = MODULE.resolve_rpath_edge(
                loader, "@rpath/libswiftCompatibilitySpan.dylib",
                [str(swift)], payload, swift)
            self.assertEqual(result["state"], "system-alias-needs-dyld-verification")
            self.assertFalse(result["canonicalFilePresent"])

    def test_changed_input_image_hash_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            image = root / "A"
            image.write_bytes(b"actual")
            receipt = {"images": [{"path": "A", "sha256": "0" * 64,
                                   "dependencies": [], "rpaths": []}]}
            with self.assertRaisesRegex(MODULE.AuditError, "hash differs"):
                MODULE.audit(receipt, root)


if __name__ == "__main__":
    unittest.main()
