"""Synthetic, no-codesign tests for recipient WebKit runtime staging."""
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

SCRIPT_PATH = Path(__file__).resolve().parents[1] / "resign-webkit-recipient-runtime.py"
SPEC = importlib.util.spec_from_file_location("resign_webkit_recipient_runtime", SCRIPT_PATH)
RESIGN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RESIGN)


def make_tree(root: Path, *, unexpected_xpc: bool = False) -> Path:
    frameworks = root / "Frameworks"
    webkit = frameworks / "WebKit.framework/Versions/A/WebKit"
    webkit.parent.mkdir(parents=True)
    webkit.write_bytes(bytes.fromhex("cffaedfe") + b"fake WebKit Mach-O")
    xpc_root = frameworks / "WebKit.framework/Versions/A/XPCServices"
    identifiers = list(RESIGN.PACKAGER.RELEASE_XPC_ENTITLEMENTS)
    if unexpected_xpc:
        identifiers[0] = "app.neantik.unknown"
    for identifier in identifiers:
        bundle = xpc_root / f"{identifier}.xpc"
        executable = bundle / "Contents/MacOS/service"
        executable.parent.mkdir(parents=True)
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": identifier,
            "CFBundleExecutable": "service",
            "CFBundlePackageType": "XPC!",
        }))
        executable.write_bytes(bytes.fromhex("cffaedfe") + identifier.encode())
    return frameworks


class RecipientRuntimeResignTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.app = self.root / "NeAntik.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": RESIGN.PACKAGER.PRODUCTION_BUNDLE_ID,
            "CFBundleExecutable": "NeAntik",
        }))
        (self.app / "Contents/MacOS/NeAntik").write_bytes(b"synthetic manager")
        self.source = make_tree(self.root)
        self.output = self.root / "recipient-output/Frameworks"
        self.output.parent.mkdir()

    def tearDown(self):
        self.temporary.cleanup()

    def test_dev_recipient_requires_explicit_qa_scope(self):
        with patch.object(RESIGN.PACKAGER, "read_info", return_value={
            "CFBundleIdentifier": RESIGN.PACKAGER.DEVELOPMENT_BUNDLE_ID,
        }) as read_info, patch.object(RESIGN.PACKAGER, "manager_signing_team",
                               return_value=RESIGN.PACKAGER.TEAM_ID) as signed_team:
            self.assertEqual(RESIGN._manager_team(self.app, development_qa=True),
                             RESIGN.PACKAGER.TEAM_ID)
        read_info.assert_called_once_with(self.app, allow_development_qa=True)
        signed_team.assert_called_once_with(self.app, RESIGN.PACKAGER.DEVELOPMENT_BUNDLE_ID)

    def test_dev_qa_scope_refuses_production_recipient(self):
        with patch.object(RESIGN.PACKAGER, "read_info", return_value={
            "CFBundleIdentifier": RESIGN.PACKAGER.PRODUCTION_BUNDLE_ID,
        }), self.assertRaisesRegex(RESIGN.ResignError, "separate Dev manager"):
            RESIGN._manager_team(self.app, development_qa=True)

    def _mocks(self, sign_calls):
        return (
            patch.object(RESIGN, "_manager_team", return_value="B1C2D3E4F5"),
            patch.object(RESIGN.PACKAGER, "verify_signing_identity"),
            patch.object(RESIGN, "_sign", side_effect=sign_calls),
            patch.object(RESIGN.RELOCATOR, "inspect", side_effect=lambda path: (path.resolve(), [])),
            patch.object(RESIGN.RELOCATOR, "apply"),
            patch.object(RESIGN.PACKAGER, "verify_runtime_frameworks", return_value=self.source / "WebKit.framework/Versions/A/WebKit"),
            patch.object(RESIGN.PACKAGER, "verify_release_xpc_entitlements"),
        )

    def test_copies_signs_and_validates_before_atomic_output(self):
        calls = []
        def signer(identity, path, entitlements=None):
            calls.append((identity, path, entitlements))
        mocks = self._mocks(signer)
        with mocks[0], mocks[1] as verify_identity, mocks[2], mocks[3], mocks[4], mocks[5] as verify_frameworks, mocks[6] as verify_xpc:
            result = RESIGN.resign_runtime(self.app, self.source, self.output, "Developer ID Recipient")
        self.assertEqual(result, self.output.parent.resolve() / self.output.name)
        self.assertTrue((self.output / "WebKit.framework/Versions/A/WebKit").is_file())
        self.assertEqual((self.source / "WebKit.framework/Versions/A/WebKit").read_bytes(),
                         bytes.fromhex("cffaedfe") + b"fake WebKit Mach-O")
        binding = json.loads((self.output.parent /
                              f"{self.output.name}.{RESIGN.IMAGE_BINDING_NAME}").read_text())
        webkit_path = "WebKit.framework/Versions/A/WebKit"
        webkit_row = next(row for row in binding["images"] if row["path"] == webkit_path)
        self.assertEqual(binding["status"], "recipient-signed-runtime-image-binding")
        self.assertEqual(binding["imageCount"], len(binding["images"]))
        self.assertEqual(webkit_row["sourceInputSHA256"],
                         RESIGN._sha256(self.source / webkit_path))
        self.assertEqual(webkit_row["recipientSignedSHA256"],
                         RESIGN._sha256(self.output / webkit_path))
        verify_identity.assert_called_once_with("Developer ID Recipient", "B1C2D3E4F5")
        verify_frameworks.assert_called_once()
        verify_xpc.assert_called_once()
        self.assertTrue(all(identity == "Developer ID Recipient" for identity, _, _ in calls))
        xpc_calls = [call for call in calls if call[2] is not None]
        self.assertEqual(len(xpc_calls), 5)
        self.assertEqual({json.dumps(call[2], sort_keys=True) for call in xpc_calls},
                         {json.dumps(value, sort_keys=True)
                          for value in RESIGN.PACKAGER.RELEASE_XPC_ENTITLEMENTS.values()})

    def test_nested_xpcs_are_signed_before_parent_webkit_framework(self):
        calls = []
        with patch.object(RESIGN, "_manager_team", return_value="B1C2D3E4F5"), \
             patch.object(RESIGN.PACKAGER, "verify_signing_identity"), \
             patch.object(RESIGN, "_sign", side_effect=lambda identity, path, entitlements=None: calls.append(path)), \
             patch.object(RESIGN.RELOCATOR, "inspect", side_effect=lambda path: (path.resolve(), [])), \
             patch.object(RESIGN.PACKAGER, "verify_runtime_frameworks"), \
             patch.object(RESIGN.PACKAGER, "verify_release_xpc_entitlements"):
            RESIGN.resign_runtime(self.app, self.source, self.output, "Recipient")
        framework = next(path for path in calls if path.name == "WebKit.framework")
        framework_index = calls.index(framework)
        self.assertTrue(all(calls.index(xpc) < framework_index for xpc in calls if xpc.suffix == ".xpc"))

    def test_unrecognized_xpc_refuses_without_publishing_output(self):
        self.source = make_tree(self.root / "bad", unexpected_xpc=True)
        self.output = self.root / "recipient-output/bad-frameworks"
        with patch.object(RESIGN, "_manager_team", return_value="B1C2D3E4F5"), \
             patch.object(RESIGN.PACKAGER, "verify_signing_identity"), \
             patch.object(RESIGN, "_sign"), \
             patch.object(RESIGN.RELOCATOR, "inspect", side_effect=lambda path: (path.resolve(), [])), \
             self.assertRaisesRegex(RESIGN.ResignError, "unrecognized WebKit XPC"):
            RESIGN.resign_runtime(self.app, self.source, self.output, "Recipient")
        self.assertFalse(self.output.exists())

    def test_existing_output_is_never_replaced(self):
        self.output.mkdir()
        sentinel = self.output / "keep.txt"
        sentinel.write_text("preserve")
        with self.assertRaisesRegex(RESIGN.ResignError, "refusing to replace"):
            RESIGN.resign_runtime(self.app, self.source, self.output, "Recipient")
        self.assertEqual(sentinel.read_text(), "preserve")

    def test_external_symlink_refuses_before_signing(self):
        outside = self.root / "outside"
        outside.write_text("outside")
        (self.source / "escape").symlink_to(outside)
        with patch.object(RESIGN, "_manager_team", return_value="B1C2D3E4F5"), \
             patch.object(RESIGN.PACKAGER, "verify_signing_identity"), \
             patch.object(RESIGN, "_sign") as sign, \
             self.assertRaisesRegex(RESIGN.ResignError, "symlink outside"):
            RESIGN.resign_runtime(self.app, self.source, self.output, "Recipient")
        sign.assert_not_called()
        self.assertFalse(self.output.exists())

    def test_signing_error_cleans_staging_and_keeps_source(self):
        original = (self.source / "WebKit.framework/Versions/A/WebKit").read_bytes()
        with patch.object(RESIGN, "_manager_team", return_value="B1C2D3E4F5"), \
             patch.object(RESIGN.PACKAGER, "verify_signing_identity"), \
             patch.object(RESIGN, "_sign", side_effect=OSError("synthetic signer failure")), \
             patch.object(RESIGN.RELOCATOR, "inspect", side_effect=lambda path: (path.resolve(), [])), \
             self.assertRaisesRegex(RESIGN.ResignError, "signing or validation failed"):
            RESIGN.resign_runtime(self.app, self.source, self.output, "Recipient")
        self.assertEqual((self.source / "WebKit.framework/Versions/A/WebKit").read_bytes(), original)
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.output.parent.glob(".neantik-webkit-resign-*")), [])

    def test_relative_relocation_runs_before_any_signature(self):
        events = []
        plan = [{"image": "WebCore.framework/Versions/A/WebCore", "remove": ["/build"], "add": "@loader_path/../../.."}]
        def inspect(root):
            events.append("inspect")
            return root.resolve(), plan
        def apply(root, received_plan, resolved_root):
            self.assertIs(received_plan, plan)
            self.assertEqual(resolved_root, root.resolve())
            events.append("relocate")
        def sign(identity, path, entitlements=None):
            events.append("sign")
        with patch.object(RESIGN, "_manager_team", return_value="B1C2D3E4F5"), \
             patch.object(RESIGN.PACKAGER, "verify_signing_identity"), \
             patch.object(RESIGN.RELOCATOR, "inspect", side_effect=inspect), \
             patch.object(RESIGN.RELOCATOR, "apply", side_effect=apply), \
             patch.object(RESIGN, "_sign", side_effect=sign), \
             patch.object(RESIGN.PACKAGER, "verify_runtime_frameworks"), \
             patch.object(RESIGN.PACKAGER, "verify_release_xpc_entitlements"):
            RESIGN.resign_runtime(self.app, self.source, self.output, "Recipient")
        self.assertEqual(events[0:2], ["inspect", "relocate"])
        self.assertEqual(events[2], "sign")

    def test_relocation_refusal_never_signs_or_publishes_output(self):
        plan = [{"image": "WebCore.framework/Versions/A/WebCore", "remove": ["/build"], "add": "@loader_path/../../.."}]
        with patch.object(RESIGN, "_manager_team", return_value="B1C2D3E4F5"), \
             patch.object(RESIGN.PACKAGER, "verify_signing_identity"), \
             patch.object(RESIGN.RELOCATOR, "inspect", side_effect=lambda path: (path.resolve(), plan)), \
             patch.object(RESIGN.RELOCATOR, "apply", side_effect=RESIGN.RELOCATOR.ContractError("signed input")), \
             patch.object(RESIGN, "_sign") as sign, \
             self.assertRaisesRegex(RESIGN.RELOCATOR.ContractError, "signed input"):
            RESIGN.resign_runtime(self.app, self.source, self.output, "Recipient")
        sign.assert_not_called()
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.output.parent.glob(".neantik-webkit-resign-*")), [])


if __name__ == "__main__":
    unittest.main()
