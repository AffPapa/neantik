import importlib.util
import tempfile
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = PROJECT_ROOT / "scripts" / "verify-chromium-webrtc-policy.py"
SPEC = importlib.util.spec_from_file_location(
    "verify_chromium_webrtc_policy",
    SCRIPT,
)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ChromiumWebRTCPolicyTests(unittest.TestCase):
    def fixture(self, root: Path) -> None:
        for relative, markers in MODULE.REQUIRED_SOURCE_MARKERS.items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("\n".join(markers) + "\n", encoding="utf-8")

    def test_accepts_exact_shipping_policy_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root)
            MODULE.verify(root)

    def test_rejects_content_shell_force_switch_substitution(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root)
            path = root / "chrome/common/chrome_switches.cc"
            path.write_text(
                'const char kWebRtcIPHandlingPolicy[] = '
                '"force-webrtc-ip-handling-policy";\n',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                MODULE.VerificationError,
                "contract changed",
            ):
                MODULE.verify(root)


if __name__ == "__main__":
    unittest.main()
