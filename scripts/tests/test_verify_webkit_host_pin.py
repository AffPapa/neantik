import importlib.util
import hashlib
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "verify-webkit-host-pin.py"
SPEC = importlib.util.spec_from_file_location("verify_webkit_host_pin", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class VerifyWebKitHostPinTests(unittest.TestCase):
    def make_app(self, root: Path):
        app = root / "NeAntik.app"
        contents = app / "Contents"
        host = contents / "Helpers/webkit-v1/NeAntikWebKitHost.app/Contents"
        (host / "MacOS").mkdir(parents=True)
        manager_id = "app.neantik.desktop.dev"
        host_id = manager_id + ".webkit-host"
        executable = host / "MacOS/NeAntikWebKitHost"
        executable.write_bytes(b"signed-host-binary")
        digest = hashlib.sha256(executable.read_bytes()).hexdigest()
        webkit = host / "Frameworks/WebKit.framework/Versions/A/WebKit"
        webkit.parent.mkdir(parents=True)
        webkit.write_bytes(b"signed-owned-webkit-binary")
        network = (host / "Frameworks/WebKit.framework/Versions/A/XPCServices"
                   / "app.neantik.desktop.webkit.Networking.xpc/Contents")
        (network / "MacOS").mkdir(parents=True)
        network_id = "app.neantik.desktop.webkit.Networking"
        network_executable = "app.neantik.desktop.webkit.Networking.Development"
        (network / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": network_id,
            "CFBundleExecutable": network_executable,
            "CFBundlePackageType": "XPC!",
        }))
        (network / "MacOS" / network_executable).write_bytes(b"signed-network-binary")
        cdhash = "a" * 40
        (host / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": host_id,
            "CFBundleExecutable": "NeAntikWebKitHost",
            "CFBundlePackageType": "APPL",
            "NeAntikWebKitRuntimeV1": {
                "schemaVersion": 2,
                "webKitSHA256": hashlib.sha256(webkit.read_bytes()).hexdigest(),
                "minimumOSVersion": "14.0.0",
            },
        }))
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": manager_id,
            "NeAntikDeveloperTeamIdentifier": "H6VGU2M6JD",
            "NeAntikWebKitHostV1": {
                "schemaVersion": 1, "identifier": host_id,
                "sha256": digest, "cdHash": cdhash,
            },
            "NeAntikWebKitNetworkProcessV1": {
                "schemaVersion": 1, "identifier": network_id,
                "executable": network_executable,
                "sha256": hashlib.sha256((network / "MacOS" / network_executable).read_bytes()).hexdigest(),
                "cdHash": "b" * 40,
            },
        }))
        return app, executable, digest, cdhash

    @staticmethod
    def runner_for(host_id, cdhash):
        def runner(args, **kwargs):
            if args[1] == "-dv":
                assert kwargs.get("capture_output") is True
                assert kwargs.get("text") is True
            is_network = str(args[-1]).endswith("app.neantik.desktop.webkit.Networking.xpc")
            identifier = "app.neantik.desktop.webkit.Networking" if is_network else host_id
            digest = "b" * 40 if is_network else cdhash
            return subprocess.CompletedProcess(args, 0, "", (
                f"Identifier={identifier}\nTeamIdentifier=H6VGU2M6JD\nCDHash={digest}\n"))
        return runner

    def test_codesign_display_captures_metadata_streams(self):
        with tempfile.TemporaryDirectory() as temporary:
            app, executable, _, cdhash = self.make_app(Path(temporary))
            result = MODULE.verify(app, self.runner_for(
                "app.neantik.desktop.dev.webkit-host", cdhash))
            self.assertEqual(result["status"], "PASS")

    def test_accepts_exact_final_host_bytes_and_signature_pin(self):
        with tempfile.TemporaryDirectory() as temporary:
            app, _, _, cdhash = self.make_app(Path(temporary))
            result = MODULE.verify(app, self.runner_for(
                "app.neantik.desktop.dev.webkit-host", cdhash))
            self.assertEqual(result["status"], "PASS")

    def test_rejects_host_resealed_after_manager_pin(self):
        with tempfile.TemporaryDirectory() as temporary:
            app, executable, _, cdhash = self.make_app(Path(temporary))
            executable.write_bytes(b"host changed by a later deep re-sign")
            with self.assertRaisesRegex(MODULE.PinError, "changed after its manager pin"):
                MODULE.verify(app, self.runner_for(
                    "app.neantik.desktop.dev.webkit-host", cdhash))

    def test_rejects_runtime_resealed_after_host_pin_before_packaging(self):
        with tempfile.TemporaryDirectory() as temporary:
            app, _, _, cdhash = self.make_app(Path(temporary))
            webkit = (app / "Contents/Helpers/webkit-v1/NeAntikWebKitHost.app/Contents"
                      / "Frameworks/WebKit.framework/Versions/A/WebKit")
            webkit.write_bytes(b"WebKit changed by a later nested re-sign")
            runner = self.runner_for("app.neantik.desktop.dev.webkit-host", cdhash)
            with self.assertRaisesRegex(MODULE.PinError, "runtime image changed"):
                MODULE.verify(app, runner)
            with self.assertRaisesRegex(MODULE.PinError, "runtime image changed"):
                MODULE.refresh_pin(app, runner)

    def test_rejects_network_process_resealed_after_manager_pin(self):
        with tempfile.TemporaryDirectory() as temporary:
            app, _, _, cdhash = self.make_app(Path(temporary))
            network = (app / "Contents/Helpers/webkit-v1/NeAntikWebKitHost.app/Contents"
                       / "Frameworks/WebKit.framework/Versions/A/XPCServices"
                       / "app.neantik.desktop.webkit.Networking.xpc/Contents/MacOS"
                       / "app.neantik.desktop.webkit.Networking.Development")
            network.write_bytes(b"Networking changed by a later nested re-sign")
            runner = self.runner_for("app.neantik.desktop.dev.webkit-host", cdhash)
            with self.assertRaisesRegex(MODULE.PinError, "Networking changed"):
                MODULE.verify(app, runner)
            MODULE.refresh_pin(app, runner)
            self.assertEqual(MODULE.verify(app, runner)["status"], "PASS")

    def test_rejects_wrong_code_directory_hash(self):
        with tempfile.TemporaryDirectory() as temporary:
            app, _, _, _ = self.make_app(Path(temporary))
            with self.assertRaisesRegex(MODULE.PinError, "signature does not match"):
                MODULE.verify(app, self.runner_for(
                    "app.neantik.desktop.dev.webkit-host", "b" * 40))

    def test_rejects_symlinked_nested_host(self):
        with tempfile.TemporaryDirectory() as temporary:
            app, _, _, _ = self.make_app(Path(temporary))
            host = app / "Contents/Helpers/webkit-v1/NeAntikWebKitHost.app"
            moved = host.with_name("host-real.app")
            host.rename(moved)
            host.symlink_to(moved, target_is_directory=True)
            with self.assertRaisesRegex(MODULE.PinError, "identity is missing or inconsistent"):
                MODULE.verify(app, self.runner_for("app.neantik.desktop.dev.webkit-host", "a" * 40))

    def test_rejects_symlinked_webkit_parent_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            app, _, _, cdhash = self.make_app(Path(temporary))
            contents = app / "Contents"
            helpers = contents / "Helpers"
            moved = contents / "Helpers-real"
            helpers.rename(moved)
            helpers.symlink_to(moved, target_is_directory=True)
            with self.assertRaisesRegex(MODULE.PinError, "host path is missing or unsafe"):
                MODULE.verify(app, self.runner_for("app.neantik.desktop.dev.webkit-host", cdhash))

    def test_rejects_malformed_manager_pin(self):
        with tempfile.TemporaryDirectory() as temporary:
            app, _, _, _ = self.make_app(Path(temporary))
            manager_path = app / "Contents/Info.plist"
            manager = plistlib.loads(manager_path.read_bytes())
            manager["NeAntikWebKitHostV1"]["extra"] = True
            manager_path.write_bytes(plistlib.dumps(manager))
            with self.assertRaisesRegex(MODULE.PinError, "pin is malformed"):
                MODULE.verify(app, self.runner_for("app.neantik.desktop.dev.webkit-host", "a" * 40))

    def test_refreshes_only_parent_pin_after_final_host_signature(self):
        with tempfile.TemporaryDirectory() as temporary:
            app, _, digest, cdhash = self.make_app(Path(temporary))
            runner = self.runner_for("app.neantik.desktop.dev.webkit-host", cdhash)
            MODULE.refresh_pin(app, runner)
            result = MODULE.verify(app, runner)
            self.assertEqual(result["hostSHA256"], digest)

    def test_refresh_refuses_invalid_host_signature(self):
        with tempfile.TemporaryDirectory() as temporary:
            app, _, _, cdhash = self.make_app(Path(temporary))

            def bad_runner(args, **kwargs):
                if args[1] == "--verify":
                    return subprocess.CompletedProcess(args, 1, "", "invalid")
                return self.runner_for("app.neantik.desktop.dev.webkit-host", cdhash)(args, **kwargs)

            with self.assertRaisesRegex(MODULE.PinError, "signature is invalid"):
                MODULE.refresh_pin(app, bad_runner)


if __name__ == "__main__":
    unittest.main()
