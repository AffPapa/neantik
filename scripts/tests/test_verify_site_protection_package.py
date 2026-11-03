from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "verify_site_protection_package", ROOT / "scripts/verify_site_protection_package.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class VerifySiteProtectionPackageTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="neantik-site-package-")
        self.root = Path(self.temporary.name)
        self.source = self.root / "Resources/SiteProtection"
        self.packaged = self.root / "Candidate.app/Contents/Resources/SiteProtection"
        self.swift = self.root / "Sources/NeAntik/SiteProtectionBundle.swift"
        self.source.mkdir(parents=True)
        self.packaged.mkdir(parents=True)
        self.swift.parent.mkdir(parents=True)
        payload = b"synthetic sealed policy\n"
        (self.source / "policy.mjs").write_bytes(payload)
        seal = {"schemaVersion": 1, "extensionID": "a" * 32, "baselineRuleCount": 1,
                "files": {"policy.mjs": hashlib.sha256(payload).hexdigest()}}
        seal_bytes = (json.dumps(seal, sort_keys=True) + "\n").encode()
        (self.source / "seal.json").write_bytes(seal_bytes)
        pin = hashlib.sha256(seal_bytes).hexdigest()
        self.swift.write_text(f'static let sealSHA256 = "{pin}"\n', encoding="utf-8")
        for path in self.source.iterdir():
            (self.packaged / path.name).write_bytes(path.read_bytes())
        self.app = self.root / "Candidate.app"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_exact_package_and_manager_pin_pass(self) -> None:
        result = MODULE.verify(self.root, self.app)
        self.assertEqual(result["status"], "PASS")
        self.assertEqual(result["payloadFiles"], 1)

    def test_old_or_tampered_packaged_resource_fails(self) -> None:
        (self.packaged / "policy.mjs").write_text("old policy\n", encoding="utf-8")
        with self.assertRaisesRegex(MODULE.VerificationError, "packaged payload differs"):
            MODULE.verify(self.root, self.app)

    def test_wrong_manager_pin_fails(self) -> None:
        self.swift.write_text('static let sealSHA256 = "' + "0" * 64 + '"\n', encoding="utf-8")
        with self.assertRaisesRegex(MODULE.VerificationError, "manager pin"):
            MODULE.verify(self.root, self.app)

    def test_unexpected_packaged_file_fails(self) -> None:
        (self.packaged / "stale.json").write_text("{}", encoding="utf-8")
        with self.assertRaisesRegex(MODULE.VerificationError, "inventory differs"):
            MODULE.verify(self.root, self.app)

    def test_symlinked_resource_fails(self) -> None:
        (self.packaged / "policy.mjs").unlink()
        (self.packaged / "policy.mjs").symlink_to(self.source / "policy.mjs")
        with self.assertRaisesRegex(MODULE.VerificationError, "unsupported resource entry"):
            MODULE.verify(self.root, self.app)


if __name__ == "__main__":
    unittest.main()
