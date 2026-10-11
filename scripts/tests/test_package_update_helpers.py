import importlib.util
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


if __name__ == "__main__": unittest.main()
