import importlib.util
import subprocess
import sys
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

    def modern_fixture(self, root: Path) -> Path:
        self.fixture(root)
        (root / MODULE.SWITCH_IMPLEMENTATION).unlink()
        header = root / MODULE.SWITCH_INLINE_HEADER
        header.write_text("\n".join(MODULE.INLINE_SWITCH_MARKERS) + "\n")
        return header

    def test_accepts_inline_header_switch_definition(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.modern_fixture(root)
            MODULE.verify(root)

    def test_modern_header_comment_or_literal_definition_is_refused(self) -> None:
        for mode in ("comment", "raw_literal"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                header = self.modern_fixture(root)
                original = header.read_text()
                header.write_text('/*\n' + original + '*/\n' if mode == 'comment'
                    else 'const char* unused = R"qa(' + original + ')qa";\n')
                with self.assertRaisesRegex(MODULE.VerificationError, "contract changed"):
                    MODULE.verify(root)

    def test_present_invalid_legacy_file_does_not_fall_back_to_header(self) -> None:
        for mode in ("empty", "directory", "broken_link"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                self.modern_fixture(root)
                legacy = root / MODULE.SWITCH_IMPLEMENTATION
                if mode == "empty":
                    legacy.write_text("")
                elif mode == "directory":
                    legacy.mkdir()
                else:
                    legacy.symlink_to(root / 'absent.cc')
                with self.assertRaises(MODULE.VerificationError):
                    MODULE.verify(root)

    def test_modern_header_symlink_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            header = self.modern_fixture(root)
            original = root / 'untrusted-header.h'
            header.rename(original)
            header.symlink_to(original)
            with self.assertRaisesRegex(MODULE.VerificationError, "missing"):
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

    def test_rejects_comment_only_policy_markers(self) -> None:
        for kind in ("block", "line", "spliced-line"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                self.fixture(root)
                for relative, markers in MODULE.REQUIRED_SOURCE_MARKERS.items():
                    if kind == "block":
                        text = "/*\n" + "\n".join(markers) + "\n*/\n"
                    elif kind == "line":
                        text = "\n".join("// " + m for m in markers)
                    else:
                        text = "\n".join("// hidden \\\n" + m for m in markers)
                    (root / relative).write_text(text)
                with self.assertRaisesRegex(MODULE.VerificationError, "contract changed"):
                    MODULE.verify(root)

    def test_rejects_raw_literal_policy_markers(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root)
            for relative, markers in MODULE.REQUIRED_SOURCE_MARKERS.items():
                (root / relative).write_text('const char* unused = R"qa(' + "\n".join(markers) + ')qa";\n')
            with self.assertRaisesRegex(MODULE.VerificationError, "contract changed"):
                MODULE.verify(root)

    def test_rejects_renderer_markers_inside_ordinary_string_literals(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root)
            relative = "chrome/browser/renderer_preferences_util.cc"
            (root / relative).write_text("\n".join('const char* unused = "' + marker + '";'
                for marker in MODULE.REQUIRED_SOURCE_MARKERS[relative]))
            with self.assertRaisesRegex(MODULE.VerificationError, "contract changed"):
                MODULE.verify(root)

    def test_comments_in_literals_do_not_hide_real_following_code(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root)
            for relative in MODULE.REQUIRED_SOURCE_MARKERS:
                path = root / relative
                path.write_text('const char* url = "https://example.test/*literal*/";\n'
                    'const char* raw = R"qa(// literal /* also literal */)qa";\n'
                    "constexpr auto number = 1'000;\n"
                    "constexpr auto hex = 0xAB'CD;\n"
                    "constexpr auto wide = L'A';\n"
                    "constexpr auto utf = u'B';\n" + path.read_text())
            MODULE.verify(root)

    def test_malformed_literals_and_comments_refuse_instead_of_passing(self) -> None:
        for prefix in ('/*', '"', 'R"qa('):
            with self.subTest(prefix=prefix):
                with self.assertRaises(MODULE.VerificationError):
                    MODULE.source_view(prefix + "\nrequired marker")

    def test_commented_marker_before_real_marker_does_not_mask_positive(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root)
            for relative in MODULE.REQUIRED_SOURCE_MARKERS:
                path = root / relative
                original = path.read_text()
                path.write_text('/*\n' + original + '*/\n' + original)
            MODULE.verify(root)

    def test_cli_states_that_source_markers_do_not_prove_runtime_policy(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.fixture(root)
            result = subprocess.run([sys.executable, "-B", str(SCRIPT), str(root)],
                capture_output=True, text=True, check=True)
            self.assertIn("Preprocessing, compilation and effective runtime policy are not proved", result.stdout)
            self.assertNotIn(str(root), result.stdout)


if __name__ == "__main__":
    unittest.main()
