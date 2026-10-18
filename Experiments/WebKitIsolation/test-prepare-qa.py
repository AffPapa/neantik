#!/usr/bin/env python3
"""Pure packaging controls; never sign, launch or access an App Group."""
import copy
import importlib.util
from pathlib import Path
import unittest
import struct
import uuid
import os
import stat
import tempfile

SPEC = importlib.util.spec_from_file_location("qa_preparation", Path(__file__).with_name("prepare-qa.py"))
QA = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(QA)


class ReplacementBuildTests(unittest.TestCase):
    def test_reviewed_builds_and_transitions(self):
        for build, previous, enabled in [("4", None, False), ("5", None, True),
                                         ("5", "3", True), ("6", "5", True), ("7", "6", True)]:
            QA.validate_replacement_build(build, previous, enabled)

    def test_same_downgrade_unknown_or_wrong_surface_refuse(self):
        for build, previous, enabled in [("5", "5", True), ("5", "6", True),
                                         ("6", "3", True), ("7", "5", True), ("8", "6", True), ("6", "7", True),
                                         ("6", "5", False), ("4", None, True),
                                         ("06", "5", True)]:
            with self.subTest(build=build, previous=previous), self.assertRaises(ValueError):
                QA.validate_replacement_build(build, previous, enabled)


class MachServiceContractTests(unittest.TestCase):
    def setUp(self):
        self.info = {"CFBundleIdentifier": QA.BASE + ".proxy",
                     "NetworkExtension": {"NEMachServiceName": QA.QA_GROUP + ".proxy"}}
        self.claims = {"com.apple.security.application-groups": [QA.QA_GROUP]}

    def test_exact_group_accepts(self):
        QA.validate_network_service(self.info, self.claims)

    def test_previous_missing_group_refuses(self):
        with self.assertRaises(ValueError):
            QA.validate_network_service(self.info, {})

    def test_wrong_or_broader_group_refuses(self):
        for groups in ([], ["other"], [QA.QA_GROUP, "production"], QA.QA_GROUP):
            with self.subTest(groups=groups), self.assertRaises(ValueError):
                QA.validate_network_service(self.info, {"com.apple.security.application-groups": groups})

    def test_service_mismatch_refuses(self):
        for name in (None, "", QA.QA_GROUP + ".proxy.other", "other." + QA.QA_GROUP + ".proxy"):
            info = copy.deepcopy(self.info)
            info["NetworkExtension"]["NEMachServiceName"] = name
            with self.subTest(name=name), self.assertRaises(ValueError):
                QA.validate_network_service(info, self.claims)

    def test_keychain_claim_refuses(self):
        with self.assertRaises(ValueError):
            QA.validate_network_service(self.info, {**self.claims, "keychain-access-groups": []})


class ExecutableIdentityTests(unittest.TestCase):
    def image(self, identifier, command=0x1B, length=24, count=1):
        body = struct.pack("<II", command, length) + uuid.UUID(identifier).bytes
        return struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2, count, len(body), 0, 0) + body

    def test_distinct_pair_accepts(self):
        a = self.image("00000000-0000-4000-8000-000000000001")
        b = self.image("00000000-0000-4000-8000-000000000002")
        self.assertNotEqual(*QA.distinct_host_uuids(a, b))

    def test_former_copied_executable_refuses(self):
        a = self.image("00000000-0000-4000-8000-000000000001")
        with self.assertRaises(ValueError):
            QA.distinct_host_uuids(a, bytes(a))

    def test_truncated_or_unknown_header_refuses(self):
        good = self.image("00000000-0000-4000-8000-000000000001")
        for data in (b"", good[:31], good[:-1], bytes(32), b"\xca\xfe\xba\xbe" + good[4:]):
            with self.subTest(size=len(data)), self.assertRaises(ValueError):
                QA.executable_uuid(data)

    def test_missing_or_zero_uuid_refuses(self):
        for data in (self.image("00000000-0000-0000-0000-000000000000"),
                     self.image("00000000-0000-4000-8000-000000000001", command=1)):
            with self.assertRaises(ValueError):
                QA.executable_uuid(data)

    def test_command_bounds_and_duplicate_uuid_refuse(self):
        good = self.image("00000000-0000-4000-8000-000000000001")
        duplicate = struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2, 2, 48, 0, 0) + good[32:] * 2
        for data in (self.image("00000000-0000-4000-8000-000000000001", length=0),
                     self.image("00000000-0000-4000-8000-000000000001", length=25), duplicate):
            with self.assertRaises(ValueError):
                QA.executable_uuid(data)


class BundleModeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.parent = Path(self.temp.name)
        self.root = self.parent / 'Own.app'
        self.exe = self.root / 'Contents/MacOS/Own'
        self.exe.parent.mkdir(parents=True, mode=0o700)
        self.exe.write_bytes(b'own synthetic executable bytes')
        self.exe.chmod(0o700)
        self.resource = self.root / 'Contents/Info.plist'
        self.resource.write_bytes(b'own resource')
        self.names = ['Contents/MacOS/Own']

    def test_old_private_executable_modes_refuse(self):
        with self.assertRaises(ValueError):
            QA.qa_bundle_modes(self.root, self.names)

    def test_normalized_bundle_preserves_bytes_and_private_parent(self):
        before = self.exe.read_bytes(), self.resource.read_bytes()
        parent_mode = stat.S_IMODE(self.parent.stat().st_mode)
        QA.qa_bundle_modes(self.root, self.names, normalize=True)
        QA.qa_bundle_modes(self.root, self.names)
        self.assertEqual(before, (self.exe.read_bytes(), self.resource.read_bytes()))
        self.assertEqual(stat.S_IMODE(self.exe.stat().st_mode), 0o755)
        self.assertEqual(stat.S_IMODE(self.resource.stat().st_mode), 0o644)
        self.assertEqual(stat.S_IMODE(self.parent.stat().st_mode), parent_mode)

    def test_symlink_refuses_before_any_mode_change(self):
        outside = self.parent / 'outside'
        outside.write_bytes(b'do not alter')
        outside.chmod(0o600)
        (self.root / 'link').symlink_to(outside)
        with self.assertRaises(ValueError):
            QA.qa_bundle_modes(self.root, self.names, normalize=True)
        self.assertEqual(stat.S_IMODE(outside.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.exe.stat().st_mode), 0o700)

    def test_hardlink_refuses_before_any_mode_change(self):
        os.link(self.resource, self.root / 'alias')
        with self.assertRaises(ValueError):
            QA.qa_bundle_modes(self.root, self.names, normalize=True)
        self.assertEqual(stat.S_IMODE(self.exe.stat().st_mode), 0o700)

    def test_missing_or_directory_executable_refuses(self):
        for names in ([], ['missing'], ['Contents/MacOS']):
            with self.subTest(names=names), self.assertRaises(ValueError):
                QA.qa_bundle_modes(self.root, names, normalize=True)


if __name__ == "__main__":
    unittest.main()
