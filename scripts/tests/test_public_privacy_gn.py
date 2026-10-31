"""GN remains fully scanned UTF-8 source; it is not a binary exemption."""
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'verify-public-artifact-privacy.py'
SPEC = importlib.util.spec_from_file_location('gn_privacy_verifier', SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class GNPrivacyTests(unittest.TestCase):
    def verify(self, payload):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / 'BUILD.gn'
            source.write_bytes(payload)
            return MODULE.verify_public_artifact_privacy(artifact=source)

    def test_own_plaintext_build_input_is_scanned(self):
        self.verify(b'executable("owned") { sources = ["own.mm"] }\n')

    def test_runtime_negative_credential_fixture_is_rejected(self):
        # Assemble synthetic negative data without embedding a full credential
        # URL in the public test source; the verifier still receives its bytes.
        payload = b'http://' + b'fixture-user:fixture-password' + b'@proxy.invalid\n'
        with self.assertRaises(MODULE.PublicArtifactPrivacyError):
            self.verify(payload)

    def test_gn_cannot_hide_non_utf8_binary_bytes(self):
        with self.assertRaises(MODULE.PublicArtifactPrivacyError):
            self.verify(b'\xff\xfeopaque-input')


if __name__ == '__main__':
    unittest.main()
