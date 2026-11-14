import importlib.util
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "package-webkit-host.py"
SPEC = importlib.util.spec_from_file_location("package_webkit_host_successor", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PrivateSuccessorHostTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.app = self.root / "NeAntik.app"
        self.app.mkdir()
        self.frameworks = self.root / "Frameworks"
        self.frameworks.mkdir()
        self.host = self.root / "host"
        self.manifest = self.root / "manifest.json"
        self.manifest_hash = "a" * 64
        self.successor = (self.manifest, self.manifest_hash)
        self.dev = {"CFBundleIdentifier": MODULE.DEVELOPMENT_BUNDLE_ID}

    def test_refuses_production_diagnostics_recipient_relink_and_conflicting_pins(self):
        production = {"CFBundleIdentifier": MODULE.PRODUCTION_BUNDLE_ID}
        for info, options in (
            (production, {}),
            (self.dev, {"allow_production_diagnostic": True}),
            (self.dev, {"recipient_relink": True}),
            (self.dev, {"network_sandbox_sha256": "b" * 64}),
            (self.dev, {"source_offer_root": self.root}),
            ({**self.dev, "NeAntikPrivateQARuntimeVariant": "V508"}, {}),
        ):
            with self.subTest(info=info, options=options), \
                    patch.object(MODULE, "read_info", return_value=info), \
                    patch.object(MODULE, "verify_signing_identity") as signing:
                with self.assertRaisesRegex(MODULE.ContractError, "private successor"):
                    MODULE.package(self.app, self.host, self.frameworks, "identity",
                                   allow_development_qa=True, private_successor=self.successor, **options)
                signing.assert_not_called()

    def test_rtc_relay_requires_private_successor_and_synthetic_tls_before_signing(self):
        with patch.object(MODULE, "read_info", return_value=self.dev), \
                patch.object(MODULE, "verify_signing_identity") as signing:
            with self.assertRaisesRegex(MODULE.ContractError, "private successor evidence"):
                MODULE.package(self.app, self.host, self.frameworks, "identity",
                               allow_development_qa=True, qualify_rtc_relay=True)
            with self.assertRaisesRegex(MODULE.ContractError, "synthetic TLS scope"):
                MODULE.package(self.app, self.host, self.frameworks, "identity",
                               allow_development_qa=True, private_successor=self.successor,
                               qualify_rtc_relay=True)
            signing.assert_not_called()

    def test_detached_session_requires_private_successor_and_synthetic_tls_before_signing(self):
        with patch.object(MODULE, "read_info", return_value=self.dev), \
                patch.object(MODULE, "verify_signing_identity") as signing:
            with self.assertRaisesRegex(MODULE.ContractError, "private successor evidence"):
                MODULE.package(self.app, self.host, self.frameworks, "identity",
                               allow_development_qa=True, detached_session_qa=True)
            with self.assertRaisesRegex(MODULE.ContractError, "synthetic TLS scope"):
                MODULE.package(self.app, self.host, self.frameworks, "identity",
                               allow_development_qa=True, private_successor=self.successor,
                               detached_session_qa=True)
            signing.assert_not_called()

    def test_metal_frames_require_private_detached_successor_before_packaging(self):
        with patch.object(MODULE, "verify_signing_identity") as signing:
            with self.assertRaisesRegex(MODULE.ContractError, "private detached successor"):
                MODULE.package(self.app, self.host, self.frameworks, "identity",
                               allow_development_qa=True, private_successor=self.successor,
                               metal_frame_qa=True)
            signing.assert_not_called()

    def test_manifest_verification_runs_before_copy_and_keeps_historical_notice_path_separate(self):
        evidence_module = types.ModuleType("owned_webkit_successor_evidence")
        with patch.dict(sys.modules, {evidence_module.__name__: evidence_module}), \
                patch.object(evidence_module, "verify", create=True,
                             side_effect=ValueError("fixture manifest refused")) as verify, \
                patch.object(MODULE, "read_info", return_value=self.dev), \
                patch.object(MODULE, "verify_signing_identity"), \
                patch.object(MODULE, "verify_host_binary"), \
                patch.object(MODULE, "verify_development_qa_host_binary"), \
                patch.object(MODULE, "verify_runtime_webkit_linkage"), \
                patch.object(MODULE, "verify_runtime_frameworks"), \
                patch.object(MODULE, "runtime_minimum_os_version"), \
                patch.object(MODULE, "network_process_pin"), \
                patch.object(MODULE, "verify_release_xpc_entitlements"), \
                patch.object(MODULE, "preflight_owned_webkit_notices") as historical:
            with self.assertRaisesRegex(ValueError, "fixture manifest refused"):
                MODULE.package(self.app, self.host, self.frameworks, "identity",
                               allow_development_qa=True, private_successor=self.successor)
            verify.assert_called_once_with(self.manifest, self.manifest_hash, self.frameworks)
            historical.assert_not_called()
            self.assertFalse((self.app / MODULE.HOST_BUNDLE_RELATIVE_PATH).exists())
