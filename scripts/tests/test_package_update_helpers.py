import importlib.util
import hashlib
import os
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location("package_update_helpers", SCRIPTS / "package-update-helpers.py")
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)


class PackageUpdateHelpersTests(unittest.TestCase):
    def fixture(self, root):
        app = root / "Owned.app"; (app / "Contents").mkdir(parents=True)
        info = {"CFBundleIdentifier": "app.neantik.desktop", "NeAntikUpdateChannelEnabled": False}
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        binaries = root / "binaries"; binaries.mkdir()
        for name in module.HELPERS.values():
            (binaries / name).write_bytes(bytes.fromhex("cffaedfe0c000001") + bytes(40))
        return app, binaries

    def test_fixed_roles_empty_entitlements_pins_and_outer_signing_order(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as tmp:
            app, binaries = self.fixture(Path(tmp)); calls = []
            pins = module.package(app, binaries, module.CERTIFICATE, run=calls.append, inspect=lambda path: "b" * 40)
            info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            self.assertEqual(info[module.PIN_KEY], pins)
            self.assertFalse(info["NeAntikUpdateChannelEnabled"])
            signatures = [call for call in calls if "--sign" in call]
            self.assertEqual(len(signatures), 2)
            for call, role in zip(signatures, module.HELPERS):
                self.assertIn("app.neantik.update-" + role, call)
                self.assertEqual(call[call.index("--sign") + 1], module.CERTIFICATE)
                self.assertIn("--timestamp", call); self.assertNotIn("--entitlements", call)
            for script in ("package-app.sh", "prepare-direct-manager-update.sh"):
                source = (SCRIPTS / script).read_text()
                self.assertLess(source.index("package-update-helpers.py"), source.index("direct_backup_signing.py\" sign"))
            self.assertNotIn("codesign --force --deep --sign -", (SCRIPTS / "package-app.sh").read_text())

    def test_input_failure_does_not_mutate_staging_metadata_or_helpers(self):
        for control in ("missing", "symlink", "foreign-header", "oversize", "certificate"):
            with self.subTest(control=control), tempfile.TemporaryDirectory(dir="/private/tmp") as tmp:
                app, binaries = self.fixture(Path(tmp)); before = (app / "Contents/Info.plist").read_bytes()
                second = binaries / module.HELPERS["assessment"]
                identity = module.CERTIFICATE
                if control == "missing": second.unlink()
                if control == "symlink": second.unlink(); second.symlink_to(binaries / module.HELPERS["owner"])
                if control == "foreign-header": second.write_bytes(bytes(40))
                if control == "oversize":
                    with second.open("wb") as stream: stream.truncate(16 * 1024 * 1024 + 1)
                if control == "certificate": identity = "0" * 40
                with self.assertRaises((module.ContractError, OSError)):
                    module.package(app, binaries, identity, run=lambda _: None, inspect=lambda _: "b" * 40)
                self.assertEqual((app / "Contents/Info.plist").read_bytes(), before)
                self.assertFalse((app / "Contents/Helpers").exists())

    def test_second_signing_failure_does_not_publish_any_helper_or_pin(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as tmp:
            app, binaries = self.fixture(Path(tmp)); before = (app / "Contents/Info.plist").read_bytes()
            def run(call):
                if "--sign" in call and "app.neantik.update-assessment" in call: raise module.ContractError("synthetic signing refusal")
            with self.assertRaises(module.ContractError): module.package(app, binaries, module.CERTIFICATE, run=run, inspect=lambda _: "b" * 40)
            self.assertEqual((app / "Contents/Info.plist").read_bytes(), before)
            self.assertEqual(list((app / "Contents/Helpers").iterdir()), [])

    def test_ad_hoc_cannot_activate_channel(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as tmp:
            app, binaries = self.fixture(Path(tmp)); path = app / "Contents/Info.plist"
            info = plistlib.loads(path.read_bytes()); info["NeAntikUpdateChannelEnabled"] = True
            path.write_bytes(plistlib.dumps(info))
            with self.assertRaises(module.ContractError): module.package(app, binaries, "-", run=lambda _: None)

    def test_release_continuity_cannot_be_accidentally_omitted(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as tmp:
            app, binaries = self.fixture(Path(tmp)); path = app / "Contents/Info.plist"
            info = plistlib.loads(path.read_bytes()); info["NeAntikUpdateOwnerContinuityRequired"] = True
            path.write_bytes(plistlib.dumps(info))
            with self.assertRaises(module.ContractError):
                module.package(app, binaries, module.CERTIFICATE, run=lambda _: None, inspect=lambda _: "b" * 40)
            self.assertFalse((app / "Contents/Helpers").exists())

    def legacy(self, root, modern=False):
        app = root / "Legacy.app"; (app / "Contents/Helpers").mkdir(parents=True)
        source = app / "Contents/Helpers"
        if modern: source = source / "v2"; source.mkdir()
        pins = {"schemaVersion": 2 if modern else 1}
        for role, name in module.HELPERS.items():
            data = bytes.fromhex("cffaedfe0c000001") + role.encode().ljust(40, b"\0")
            (source / name).write_bytes(data)
            pins[role] = {"sha256": hashlib.sha256(data).hexdigest(), "cdHash": "c" * 40}
        info = {"CFBundleIdentifier": "app.neantik.desktop", module.MODERN_PIN_KEY if modern else module.PIN_KEY: pins}
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        return app, source

    def test_carries_prior_primary_without_resigning_and_selects_fixed_modern_paths(self):
        for modern in (False, True):
            with self.subTest(modern=modern), tempfile.TemporaryDirectory(dir="/private/tmp") as tmp:
                root = Path(tmp); app, binaries = self.fixture(root); old, source = self.legacy(root, modern)
                calls = []
                inspect = lambda path: "c" * 40 if path.is_relative_to(old) else "b" * 40
                module.package(app, binaries, module.CERTIFICATE, run=calls.append, inspect=inspect, legacy_app=old)
                info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
                self.assertEqual(info[module.PIN_KEY]["schemaVersion"], 1)
                self.assertEqual(info[module.MODERN_PIN_KEY]["schemaVersion"], 2)
                for role, name in module.HELPERS.items():
                    self.assertEqual((app / "Contents/Helpers" / name).read_bytes(), (source / name).read_bytes())
                    self.assertEqual(info[module.PIN_KEY][role]["cdHash"], "c" * 40)
                    self.assertEqual(info[module.MODERN_PIN_KEY][role]["cdHash"], "b" * 40)
                    self.assertEqual((app / "Contents/Helpers/v2" / name).read_bytes(), (binaries / name).read_bytes())
                self.assertEqual(len([c for c in calls if "--sign" in c]), 2)
                self.assertEqual(len([c for c in calls if any(arg.startswith("-R=") for arg in c)]), 4)

    def test_invalid_legacy_or_modern_pins_refuse_before_staging_mutation(self):
        for control in ("tampered", "cdhash", "bad-modern", "symlink", "signature"):
            with self.subTest(control=control), tempfile.TemporaryDirectory(dir="/private/tmp") as tmp:
                root = Path(tmp); app, binaries = self.fixture(root); old, source = self.legacy(root)
                before = (app / "Contents/Info.plist").read_bytes()
                file = source / module.HELPERS["owner"]
                if control == "tampered": file.write_bytes(file.read_bytes() + b"wrong")
                if control == "symlink": file.unlink(); file.symlink_to(source / module.HELPERS["assessment"])
                if control == "bad-modern":
                    info = plistlib.loads((old / "Contents/Info.plist").read_bytes()); info[module.MODERN_PIN_KEY] = False
                    (old / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
                def run(call):
                    if control == "signature" and any(arg.startswith("-R=") for arg in call): raise module.ContractError("synthetic signature refusal")
                inspect = lambda _: "d" * 40 if control == "cdhash" else "c" * 40
                with self.assertRaises((module.ContractError, OSError)):
                    module.package(app, binaries, module.CERTIFICATE, run=run, inspect=inspect, legacy_app=old)
                self.assertEqual((app / "Contents/Info.plist").read_bytes(), before)
                self.assertFalse((app / "Contents/Helpers").exists())

    def test_temporary_policy_swap_during_signature_command_is_refused(self):
        for control in ("rename", "in-place"):
            with self.subTest(control=control), tempfile.TemporaryDirectory(dir="/private/tmp") as tmp:
                root = Path(tmp); app, binaries = self.fixture(root); old, _ = self.legacy(root)
                policy = old / "Contents/Info.plist"; original = policy.read_bytes(); backup = old / "Contents/held-original"
                calls = 0
                def run(command):
                    nonlocal calls
                    if command[-1] != str(old): return
                    calls += 1
                    if calls == 1:
                        if control == "rename": policy.rename(backup); policy.write_bytes(original)
                        else: policy.write_bytes(original + b"\n"); policy.write_bytes(original)
                    elif calls == 2 and control == "rename":
                        policy.unlink(); backup.rename(policy)
                with self.assertRaises(module.ContractError):
                    module.package(app, binaries, module.CERTIFICATE, run=run,
                                   inspect=lambda _: "c" * 40, legacy_app=old)
                self.assertFalse((app / "Contents/Helpers").exists())


if __name__ == "__main__": unittest.main()
