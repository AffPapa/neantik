import importlib.util
from pathlib import Path
import tempfile
import subprocess
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'package-webkit-host.py'
SPEC = importlib.util.spec_from_file_location('package_webkit_host_v508_test', SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PrivateV508HostTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / 'NeAntik.app'; self.app.mkdir()
        self.offer = self.root / 'offer'; self.offer.mkdir()
        self.frameworks = self.root / 'frameworks'; self.frameworks.mkdir()
        self.host = self.root / 'host'
        self.evidence = MODULE.PrivateV508Evidence(
            source=self.root / 'source', baseline=self.root / 'baseline',
            modified=self.root / 'modified', binding=self.root / 'binding', receipt=self.root / 'receipt')
        self.dev = {'CFBundleIdentifier': MODULE.DEVELOPMENT_BUNDLE_ID}
        self.production = {'CFBundleIdentifier': MODULE.PRODUCTION_BUNDLE_ID}

    def test_private_mode_rejects_production_or_missing_opt_in_or_wrong_offer(self):
        for info, enabled, diagnostic, offer, digest in (
            (self.production, True, False, self.offer, MODULE.V508_SOURCE_OFFER_SHA256),
            (self.dev, False, False, self.offer, MODULE.V508_SOURCE_OFFER_SHA256),
            (self.dev, True, True, self.offer, MODULE.V508_SOURCE_OFFER_SHA256),
            (self.dev, True, False, None, MODULE.V508_SOURCE_OFFER_SHA256),
            (self.dev, True, False, self.offer, '0' * 64),
        ):
            with self.subTest(info=info, enabled=enabled, diagnostic=diagnostic), \
                 self.assertRaises(MODULE.ContractError):
                MODULE._validate_private_v508(self.evidence, info, enabled, diagnostic, offer, digest)
        with self.assertRaises(MODULE.ContractError):
            MODULE._validate_private_v508({}, self.dev, True, False, self.offer, MODULE.V508_SOURCE_OFFER_SHA256)

    def test_default_path_accepts_no_private_evidence(self):
        MODULE._validate_private_v508(None, self.production, False, False, None, None)

    def test_evidence_action_calls_narrow_validator_with_explicit_paths(self):
        for action in ('preflight', 'install'):
            with patch.object(MODULE, 'private_v446_dev_qa_notices') as notices:
                MODULE._v508_notice_action(action, self.app, self.frameworks, self.offer, self.evidence)
                notices.assert_called_once_with(action, self.app, self.frameworks,
                    source_offer_root=self.offer, source=self.evidence.source, baseline=self.evidence.baseline,
                    modified=self.evidence.modified, binding=self.evidence.binding, v508_receipt=self.evidence.receipt)

    def test_dev_evidence_propagates_to_packaging_and_recipient_mode_is_rejected(self):
        kwargs = dict(allow_development_qa=True, source_offer_root=self.offer,
                      source_offer_manifest_sha256=MODULE.V508_SOURCE_OFFER_SHA256,
                      private_v508_evidence=self.evidence)
        with patch.object(MODULE, 'read_info', return_value=self.dev), \
             patch.object(MODULE, 'host_qa_tls_scope', return_value={}), \
             patch.object(MODULE, 'verify_signing_identity'), \
             patch.object(MODULE, '_package_verified_host', return_value=self.root / 'host.app') as pack:
            MODULE.package(self.app, self.host, self.frameworks, 'identity', **kwargs)
            self.assertIs(pack.call_args.kwargs['private_v508_evidence'], self.evidence)
            with self.assertRaisesRegex(MODULE.ContractError, 'separate from recipient relink'):
                MODULE.package(self.app, self.host, self.frameworks, 'identity', recipient_relink=True, **kwargs)

    def test_private_preflight_is_selected_before_any_copy(self):
        with patch.object(MODULE, 'read_info', return_value=self.dev), \
             patch.object(MODULE, 'host_qa_tls_scope', return_value={}), \
             patch.object(MODULE, 'verify_signing_identity'), \
             patch.object(MODULE, 'verify_host_binary'), \
             patch.object(MODULE, 'verify_development_qa_host_binary'), \
             patch.object(MODULE, 'verify_runtime_webkit_linkage'), \
             patch.object(MODULE, 'verify_runtime_frameworks', return_value=self.frameworks / 'WebKit'), \
             patch.object(MODULE, 'runtime_minimum_os_version', return_value='15.4'), \
             patch.object(MODULE, 'network_process_pin', return_value={}), \
             patch.object(MODULE, 'verify_release_xpc_entitlements'), \
             patch.object(MODULE, 'require_safe_parent_chain'), \
             patch.object(MODULE, 'preflight_owned_webkit_notices') as regular, \
             patch.object(MODULE, '_v508_notice_action', side_effect=MODULE.ContractError('fixture preflight')) as private:
            with self.assertRaisesRegex(MODULE.ContractError, 'fixture preflight'):
                MODULE._package_verified_host(self.app, self.host, self.frameworks, 'identity',
                    allow_development_qa=True, source_offer_root=self.offer,
                    source_offer_manifest_sha256=MODULE.V508_SOURCE_OFFER_SHA256,
                    private_v508_evidence=self.evidence)
            private.assert_called_once_with('preflight', self.app, self.frameworks, self.offer, self.evidence)
            regular.assert_not_called()
            self.assertFalse((self.app / MODULE.HOST_BUNDLE_RELATIVE_PATH).exists())

    def test_private_binding_must_be_the_exact_staged_sidecar_before_copy(self):
        with patch.object(MODULE, 'read_info', return_value=self.dev), \
             patch.object(MODULE, 'host_qa_tls_scope', return_value={}), \
             patch.object(MODULE, 'verify_signing_identity'), \
             patch.object(MODULE, 'verify_host_binary'), \
             patch.object(MODULE, 'verify_development_qa_host_binary'), \
             patch.object(MODULE, 'verify_runtime_webkit_linkage'), \
             patch.object(MODULE, 'verify_runtime_frameworks', return_value=self.frameworks / 'WebKit'), \
             patch.object(MODULE, 'runtime_minimum_os_version', return_value='15.4'), \
             patch.object(MODULE, 'network_process_pin', return_value={}), \
             patch.object(MODULE, 'verify_release_xpc_entitlements'), \
             patch.object(MODULE, 'require_safe_parent_chain'), \
             patch.object(MODULE, '_v508_notice_action'), \
             patch.object(MODULE, 'runtime_image_binding_source', return_value=None):
            with self.assertRaisesRegex(MODULE.ContractError, 'staged binding'):
                MODULE._package_verified_host(self.app, self.host, self.frameworks, 'identity',
                    allow_development_qa=True, source_offer_root=self.offer,
                    source_offer_manifest_sha256=MODULE.V508_SOURCE_OFFER_SHA256,
                    private_v508_evidence=self.evidence)
            self.assertFalse((self.app / MODULE.HOST_BUNDLE_RELATIVE_PATH).exists())

    def test_private_install_uses_copied_runtime_and_retains_exact_binding(self):
        image = self.frameworks / 'WebKit.framework/Versions/A/WebKit'
        image.parent.mkdir(parents=True)
        image.write_bytes(b'private-runtime')
        self.host.write_bytes(b'private-host')
        binding = self.frameworks.parent / (self.frameworks.name + '.NeAntikRuntimeImageBinding.json')
        binding.write_bytes(b'fixture-binding')
        self.evidence.binding.write_bytes(binding.read_bytes())
        actual_digest = MODULE.digest
        def digest(path):
            return MODULE.V508_BINDING_SHA256 if Path(path) in (binding, self.evidence.binding) else actual_digest(path)
        def codesign(args, **kwargs):
            detail = (f'Identifier={MODULE.DEVELOPMENT_BUNDLE_ID}.webkit-host\n'
                      f'TeamIdentifier={MODULE.TEAM_ID}\nCDHash=' + 'a' * 40 + '\n')
            return subprocess.CompletedProcess(args, 0, stdout=b'', stderr=detail)
        with patch.object(MODULE, 'read_info', return_value=self.dev), \
             patch.object(MODULE, 'host_qa_tls_scope', return_value={}), \
             patch.object(MODULE, 'host_ats_policy', return_value={}), \
             patch.object(MODULE, 'verify_signing_identity'), \
             patch.object(MODULE, 'verify_host_binary'), \
             patch.object(MODULE, 'verify_development_qa_host_binary'), \
             patch.object(MODULE, 'verify_runtime_webkit_linkage'), \
             patch.object(MODULE, 'verify_runtime_frameworks', return_value=image), \
             patch.object(MODULE, 'runtime_minimum_os_version', return_value='15.4'), \
             patch.object(MODULE, 'network_process_pin', return_value={}), \
             patch.object(MODULE, 'verify_release_xpc_entitlements'), \
             patch.object(MODULE, 'require_safe_parent_chain'), \
             patch.object(MODULE, 'pinned_info', return_value={}), \
             patch.object(MODULE, 'install_info_atomically'), \
             patch.object(MODULE, 'digest', side_effect=digest), \
             patch.object(MODULE.subprocess, 'run', side_effect=codesign), \
             patch.object(MODULE, '_v508_notice_action') as notices:
            bundle = MODULE._package_verified_host(self.app, self.host, self.frameworks, 'identity',
                allow_development_qa=True, source_offer_root=self.offer,
                source_offer_manifest_sha256=MODULE.V508_SOURCE_OFFER_SHA256,
                private_v508_evidence=self.evidence)
        staged = bundle / 'Contents/Frameworks'
        self.assertEqual([call.args[0] for call in notices.call_args_list], ['preflight', 'install'])
        self.assertEqual(notices.call_args_list[0].args[2], self.frameworks)
        self.assertEqual(notices.call_args_list[1].args[2], staged)
        self.assertEqual((bundle / 'Contents/Resources/NeAntikRuntimeEvidence/NeAntikRuntimeImageBinding.json').read_bytes(), binding.read_bytes())
