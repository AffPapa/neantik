import importlib.util
import tempfile
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = PROJECT_ROOT / "scripts" / "verify-chromium-launch-flags.py"
SPEC = importlib.util.spec_from_file_location(
    "verify_chromium_launch_flags",
    SCRIPT,
)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ChromiumLaunchFlagTests(unittest.TestCase):
    def fixture(self, root: Path) -> Path:
        for relative, markers in MODULE.REQUIRED_SOURCE_MARKERS.items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("\n".join(markers) + "\n", encoding="utf-8")
        manager = root / "BrowserProcessManager.swift"
        manager.write_text(
            "\n".join(MODULE.REQUIRED_MANAGER_MARKERS) + "\n",
            encoding="utf-8",
        )
        return manager

    def test_accepts_exact_current_launch_contract(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manager = self.fixture(root)
            MODULE.verify(root, manager)

    def test_rejects_obsolete_dns_prefetch_switch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manager = self.fixture(root)
            manager.write_text(
                manager.read_text(encoding="utf-8")
                + '"--dns-prefetch-disable"\n',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                MODULE.VerificationError,
                "obsolete launch control",
            ):
                MODULE.verify(root, manager)

    def test_rejects_removed_background_mode_switch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manager = self.fixture(root)
            manager.write_text(
                manager.read_text(encoding="utf-8")
                + '"--disable-background-mode"\n',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                MODULE.VerificationError,
                "obsolete launch control",
            ):
                MODULE.verify(root, manager)

    def test_rejects_nonexistent_timezone_switch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manager = self.fixture(root)
            manager.write_text(
                manager.read_text(encoding="utf-8")
                + '"--timezone=Europe/Berlin"\n',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                MODULE.VerificationError,
                "obsolete launch control",
            ):
                MODULE.verify(root, manager)

    def test_rejects_old_doh_feature_name(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manager = self.fixture(root)
            manager.write_text(
                manager.read_text(encoding="utf-8") + '"DnsOverHttps"\n',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                MODULE.VerificationError,
                "obsolete launch control",
            ):
                MODULE.verify(root, manager)

    def test_rejects_chromium_feature_rename(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manager = self.fixture(root)
            path = root / "services/network/public/cpp/features.cc"
            path.write_text(
                "BASE_FEATURE(kSomeFutureReplacement,\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                MODULE.VerificationError,
                "contract changed",
            ):
                MODULE.verify(root, manager)


if __name__ == "__main__":
    unittest.main()
