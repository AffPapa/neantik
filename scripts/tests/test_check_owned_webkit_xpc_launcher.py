import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import subprocess


SCRIPT = Path(__file__).resolve().parents[1] / "check-owned-webkit-xpc-launcher.py"
SPEC = importlib.util.spec_from_file_location("owned_xpc_launcher", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class CompiledLauncherNameTests(unittest.TestCase):
    def test_rejects_stale_system_networking_service_in_webkit_image(self):
        with tempfile.TemporaryDirectory() as temporary:
            image = Path(temporary) / "WebKit"
            image.write_bytes(b"\xcf\xfa\xed\xfeapp.neantik.desktop.webkit.Networking\0"
                              b"com.apple.WebKit.Networking\0")
            with self.assertRaisesRegex(ValueError, "system Networking XPC"):
                MODULE.check_compiled_network_launcher(image)
            image.write_bytes(b"\xcf\xfa\xed\xfeapp.neantik.desktop.webkit.Networking\0")
            MODULE.check_compiled_network_launcher(image)

    def test_mach_feature_requires_source_probe_and_compiled_handler(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            header = root / "Source/WTF/wtf/PlatformHave.h"
            header.parent.mkdir(parents=True)
            image = root / "Frameworks/JavaScriptCore.framework/Versions/A/JavaScriptCore"
            image.parent.mkdir(parents=True)
            image.write_bytes(b"test image")
            header.write_text("#if __has_include(<mach/mach_exc.defs>)\n")
            with self.assertRaisesRegex(ValueError, "SDK 27 Mach-exception probe"):
                MODULE.check_mach_exception_feature(root, root / "Frameworks")
            header.write_text("#if __has_include(<Kernel/mach/mach_exc.defs>)\n")
            with patch.object(MODULE.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")):
                with self.assertRaisesRegex(ValueError, "lacks Mach exception handling"):
                    MODULE.check_mach_exception_feature(root, root / "Frameworks")
            with patch.object(MODULE.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "handleSignalsWithMach", "")):
                MODULE.check_mach_exception_feature(root, root / "Frameworks")


if __name__ == "__main__":
    unittest.main()
