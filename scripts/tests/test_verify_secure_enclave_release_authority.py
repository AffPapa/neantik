from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "verify-secure-enclave-release-authority.py"
)
SPEC = importlib.util.spec_from_file_location(
    "verify_secure_enclave_release_authority",
    SCRIPT,
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SecureEnclaveReleaseAuthorityTests(unittest.TestCase):
    def test_production_authority_is_hardware_only(self) -> None:
        message = MODULE.verify()

        self.assertIn("hardware-backed", message)
        self.assertIn("fail-closed", message)

    def test_rejects_software_key_fallback(self) -> None:
        source = MODULE.DEFAULT_SOURCE.read_text(encoding="utf-8")
        with tempfile.TemporaryDirectory() as temporary:
            mutated = Path(temporary) / "Signer.swift"
            mutated.write_text(
                source + "\nlet fallbackKeyService = P256.Signing.PrivateKey()\n",
                encoding="utf-8",
            )

            with self.assertRaises(MODULE.SecureEnclaveAuthorityError):
                MODULE.verify(mutated)

    def test_rejects_missing_hardware_attribute_validation(self) -> None:
        source = MODULE.DEFAULT_SOURCE.read_text(encoding="utf-8")
        with tempfile.TemporaryDirectory() as temporary:
            mutated = Path(temporary) / "Signer.swift"
            mutated.write_text(
                source.replace("SecKeyCopyAttributes", "removedAttributeRead"),
                encoding="utf-8",
            )

            with self.assertRaises(MODULE.SecureEnclaveAuthorityError):
                MODULE.verify(mutated)


if __name__ == "__main__":
    unittest.main()
