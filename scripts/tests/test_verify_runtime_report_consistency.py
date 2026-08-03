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
            "schemaVersion": 3,
            "chromiumVersion": "150.0.7871.186",
            "architecture": "arm64",
            "gpuMode": "metal",
            "sourceLockSHA256": "a" * 64,
            "candidateLockSHA256": "a" * 64,
            "sourceContractSHA256": "7" * 64,
            "sourceProvenanceSHA256": "8" * 64,
            "neantikPatchManifestSHA256": "d" * 64,
            "appleDeviceTuplesManifestSHA256": "e" * 64,
            "securityBaselineSHA256": "f" * 64,
            "machoCount": 13,
            "codeSignature": "verified",
            "codeSignatureKind": "developer-id",
            "fingerprintProtocolStrings": "verified",
            "executable": {
                "path": "Contents/MacOS/NeAntik Browser",
                "sha256": "3" * 64,
            },
            "framework": {
                "path": (
                    "Contents/Frameworks/NeVision Browser Framework.framework/"
                    "Versions/150.0.7871.186/NeVision Browser Framework"
                ),
                "sha256": "4" * 64,
            },
            "buildArguments": {"sha256": "5" * 64},
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

    def test_ignores_timestamps(self) -> None:
        packaged = self.report()
        fresh = self.report()
        fresh["createdAt"] = "different"
        self.verify(packaged, fresh)

    def test_rejects_changed_runtime_path(self) -> None:
        packaged = self.report()
        fresh = self.report()
        fresh["executable"] = {
            "path": "Contents/MacOS/Redirected Browser",
            "sha256": "3" * 64,
        }
        with self.assertRaisesRegex(SystemExit, "executable.path"):
            self.verify(packaged, fresh)

    def test_rejects_absolute_runtime_path(self) -> None:
        packaged = self.report()
        fresh = self.report()
        packaged["framework"] = {
            "path": "/private/tmp/redirected-framework",
            "sha256": "4" * 64,
        }
        with self.assertRaisesRegex(SystemExit, "bundle-relative"):
            self.verify(packaged, fresh)

    def test_rejects_build_arguments_path(self) -> None:
        packaged = self.report()
        fresh = self.report()
        packaged["buildArguments"] = {
            "path": "/private/tmp/args.gn",
            "sha256": "5" * 64,
        }
        with self.assertRaisesRegex(SystemExit, "only sha256"):
            self.verify(packaged, fresh)

    def test_rejects_changed_runtime_hash(self) -> None:
        packaged = self.report()
        fresh = self.report()
        fresh["framework"] = {
            "path": (
                "Contents/Frameworks/NeVision Browser Framework.framework/"
                "Versions/150.0.7871.186/NeVision Browser Framework"
            ),
            "sha256": "6" * 64,
        }
        with self.assertRaisesRegex(SystemExit, "framework.sha256"):
            self.verify(packaged, fresh)

    def test_rejects_changed_candidate_lock_hash(self) -> None:
        packaged = self.report()
        fresh = self.report()
        fresh["candidateLockSHA256"] = "9" * 64
        with self.assertRaisesRegex(SystemExit, "candidateLockSHA256"):
            self.verify(packaged, fresh)

    def test_rejects_changed_patch_manifest_hash(self) -> None:
        packaged = self.report()
        fresh = self.report()
        fresh["neantikPatchManifestSHA256"] = "6" * 64
        with self.assertRaisesRegex(SystemExit, "neantikPatchManifestSHA256"):
            self.verify(packaged, fresh)

    def test_rejects_changed_source_provenance_hash(self) -> None:
        packaged = self.report()
        fresh = self.report()
        fresh["sourceProvenanceSHA256"] = "9" * 64
        with self.assertRaisesRegex(
            SystemExit,
            "sourceProvenanceSHA256",
        ):
            self.verify(packaged, fresh)

    def test_rejects_changed_source_contract_hash(self) -> None:
        packaged = self.report()
        fresh = self.report()
        fresh["sourceContractSHA256"] = "6" * 64
        with self.assertRaisesRegex(
            SystemExit,
            "sourceContractSHA256",
        ):
            self.verify(packaged, fresh)

    def test_rejects_missing_immutable_field(self) -> None:
        packaged = self.report()
        fresh = self.report()
        del fresh["buildArguments"]
        with self.assertRaisesRegex(SystemExit, "missing immutable field"):
            self.verify(packaged, fresh)

    def test_rejects_schema_one_even_when_both_reports_match(self) -> None:
        packaged = self.report()
        fresh = self.report()
        packaged["schemaVersion"] = 1
        fresh["schemaVersion"] = 1
        with self.assertRaisesRegex(SystemExit, "schema 3"):
            self.verify(packaged, fresh)


if __name__ == "__main__":
    unittest.main()
