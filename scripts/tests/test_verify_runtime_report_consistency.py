import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "verify-runtime-report-consistency.py"
)
SPEC = importlib.util.spec_from_file_location("runtime_report_consistency", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class RuntimeReportConsistencyTests(unittest.TestCase):
    def report(self) -> dict[str, object]:
        return {
            "schemaVersion": 2,
            "chromiumVersion": "150.0.7871.186",
            "architecture": "arm64",
            "gpuMode": "metal",
            "sourceLockSHA256": "a" * 64,
            "fingerprintChromiumPatchSeriesSHA256": "b" * 64,
            "macPackagingPatchSeriesSHA256": "c" * 64,
            "neantikPatchManifestSHA256": "d" * 64,
            "appleDeviceTuplesManifestSHA256": "e" * 64,
            "securityBaselineSHA256": "f" * 64,
            "nevisionOverlaySHA256": "1" * 64,
            "nevisionDeviceTupleOverlaySHA256": "2" * 64,
            "machoCount": 13,
            "codeSignature": "verified",
            "codeSignatureKind": "developer-id",
            "fingerprintProtocolStrings": "verified",
            "executable": {"path": "/first", "sha256": "3" * 64},
            "framework": {"path": "/second", "sha256": "4" * 64},
            "buildArguments": {"path": "/args", "sha256": "5" * 64},
            "createdAt": "ignored",
        }

    def verify(
        self,
        packaged: dict[str, object],
        fresh: dict[str, object],
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            packaged_path = root / "packaged.json"
            fresh_path = root / "fresh.json"
            packaged_path.write_text(json.dumps(packaged), encoding="utf-8")
            fresh_path.write_text(json.dumps(fresh), encoding="utf-8")
            MODULE.verify(packaged_path, fresh_path)

    def test_ignores_paths_and_timestamps(self) -> None:
        packaged = self.report()
        fresh = self.report()
        fresh["createdAt"] = "different"
        fresh["executable"] = {
            "path": "/roundtrip/runtime",
            "sha256": "3" * 64,
        }
        self.verify(packaged, fresh)

    def test_rejects_changed_runtime_hash(self) -> None:
        packaged = self.report()
        fresh = self.report()
        fresh["framework"] = {"path": "/second", "sha256": "6" * 64}
        with self.assertRaisesRegex(SystemExit, "framework.sha256"):
            self.verify(packaged, fresh)

    def test_rejects_changed_patch_manifest_hash(self) -> None:
        packaged = self.report()
        fresh = self.report()
        fresh["neantikPatchManifestSHA256"] = "6" * 64
        with self.assertRaisesRegex(SystemExit, "neantikPatchManifestSHA256"):
            self.verify(packaged, fresh)

    def test_rejects_changed_device_tuple_overlay_hash(self) -> None:
        packaged = self.report()
        fresh = self.report()
        fresh["nevisionDeviceTupleOverlaySHA256"] = "6" * 64
        with self.assertRaisesRegex(
            SystemExit,
            "nevisionDeviceTupleOverlaySHA256",
        ):
            self.verify(packaged, fresh)

    def test_rejects_missing_immutable_field(self) -> None:
        packaged = self.report()
        fresh = self.report()
        del fresh["buildArguments"]
        with self.assertRaisesRegex(SystemExit, "missing immutable field"):
            self.verify(packaged, fresh)


if __name__ == "__main__":
    unittest.main()
