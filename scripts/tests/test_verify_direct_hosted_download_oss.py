import hashlib
import importlib.util
import plistlib
import shutil
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "verify-direct-hosted-download.py"
SPEC = importlib.util.spec_from_file_location(
    "verify_direct_hosted_download_oss",
    SCRIPT,
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class DirectHostedDownloadOSSTests(unittest.TestCase):
    def make_fixture(self, root: Path) -> Path:
        (root / "Resources").mkdir()
        (root / "dist").mkdir()
        with (root / "Resources" / "Info.plist").open("wb") as file:
            plistlib.dump({"CFBundleShortVersionString": "1.2.3"}, file)
        archive = root / "dist" / "NeAntik-1.2.3-arm64-notarized.zip"
        archive.write_bytes(b"notarized NeAntik fixture")
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        archive.with_suffix(".zip.sha256").write_text(
            f"{digest}  {archive.name}\n",
            encoding="utf-8",
        )
        return archive

    def test_download_is_byte_identical_and_reverified_from_fresh_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = self.make_fixture(root)
            verified: list[Path] = []

            def downloader(
                _url: str,
                destination: Path,
                _expected_size: int,
            ) -> None:
                shutil.copyfile(archive, destination)

            def verifier(candidate: Path) -> None:
                self.assertTrue(candidate.is_file())
                self.assertTrue(
                    candidate.with_suffix(candidate.suffix + ".sha256").is_file()
                )
                verified.append(candidate)

            result = MODULE.verify_hosted_download(
                project_root=root,
                archive=archive,
                download_url=(
                    "https://github.com/AffPapa/neantik/releases/download/v1.2.3/"
                    "NeAntik-1.2.3-arm64-notarized.zip"
                ),
                downloader=downloader,
                archive_verifier=verifier,
            )

        self.assertEqual(result["status"], "hosted-zip-byte-identical-and-gatekeeper-verified")
        self.assertEqual(len(verified), 2)
        self.assertEqual(verified[0], archive.resolve())
        self.assertNotEqual(verified[0].parent, verified[1].parent)

    def test_changed_download_fails_before_second_archive_verification(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = self.make_fixture(root)
            verified: list[Path] = []

            def changed_download(
                _url: str,
                destination: Path,
                _expected_size: int,
            ) -> None:
                destination.write_bytes(b"changed hosted bytes")

            with self.assertRaisesRegex(
                MODULE.HostedDownloadError,
                "downloaded SHA-256 differs",
            ):
                MODULE.verify_hosted_download(
                    project_root=root,
                    archive=archive,
                    download_url=(
                        "https://downloads.example/NeAntik-1.2.3-arm64-notarized.zip"
                    ),
                    downloader=changed_download,
                    archive_verifier=lambda candidate: verified.append(candidate),
                )

        self.assertEqual(verified, [archive.resolve()])

    def test_new_release_reverifies_local_and_downloaded_exact_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = self.make_fixture(root)
            manifest = root / "dist" / "direct-candidate-manifest.json"
            manifest.write_text("{}\n", encoding="utf-8")
            candidate_checks: list[tuple[Path, Path, str]] = []

            def downloader(
                _url: str,
                destination: Path,
                _expected_size: int,
            ) -> None:
                shutil.copyfile(archive, destination)

            result = MODULE.verify_hosted_download(
                project_root=root,
                archive=archive,
                download_url=(
                    "https://github.com/AffPapa/neantik/releases/download/v1.2.3/"
                    "NeAntik-1.2.3-arm64-notarized.zip"
                ),
                downloader=downloader,
                archive_verifier=lambda _candidate: None,
                candidate_manifest=manifest,
                release_channel="public-alpha",
                candidate_verifier=lambda candidate, bound_manifest, channel:
                    candidate_checks.append(
                        (candidate, bound_manifest, channel)
                    ),
            )

        self.assertEqual(
            result["status"],
            "hosted-zip-byte-identical-gatekeeper-and-candidate-verified",
        )
        self.assertEqual(len(candidate_checks), 2)
        self.assertEqual(candidate_checks[0][0], archive.resolve())
        self.assertNotEqual(
            candidate_checks[0][0].parent,
            candidate_checks[1][0].parent,
        )
        self.assertTrue(
            all(check[2] == "public-alpha" for check in candidate_checks)
        )

    def test_candidate_manifest_and_channel_are_an_atomic_opt_in(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = self.make_fixture(root)
            with self.assertRaisesRegex(
                MODULE.HostedDownloadError,
                "provided together",
            ):
                MODULE.verify_hosted_download(
                    project_root=root,
                    archive=archive,
                    download_url=(
                        "https://downloads.example/"
                        "NeAntik-1.2.3-arm64-notarized.zip"
                    ),
                    candidate_manifest=root / "candidate.json",
                    downloader=lambda _url, _destination, _size: None,
                    archive_verifier=lambda _candidate: None,
                )

    def test_url_contract_rejects_credentials_query_fragment_and_wrong_name(self) -> None:
        invalid = (
            "http://example.com/NeAntik-1.2.3-arm64-notarized.zip",
            "https://user:secret@example.com/NeAntik-1.2.3-arm64-notarized.zip",
            "https://example.com/NeAntik-1.2.3-arm64-notarized.zip?token=secret",
            "https://example.com/NeAntik-1.2.3-arm64-notarized.zip#fragment",
            "https://example.com/other.zip",
        )
        for url in invalid:
            with self.subTest(url=url):
                with self.assertRaises(MODULE.HostedDownloadError):
                    MODULE.validate_download_url(
                        url,
                        archive_name="NeAntik-1.2.3-arm64-notarized.zip",
                    )

    def test_local_final_archive_must_not_be_a_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = self.make_fixture(root)
            real_archive = root / "real.zip"
            archive.replace(real_archive)
            archive.symlink_to(real_archive)

            with self.assertRaisesRegex(
                MODULE.HostedDownloadError,
                "must not be a symlink",
            ):
                MODULE.verify_hosted_download(
                    project_root=root,
                    archive=archive,
                    download_url=(
                        "https://downloads.example/"
                        "NeAntik-1.2.3-arm64-notarized.zip"
                    ),
                    downloader=lambda _url, _destination, _expected_size: None,
                    archive_verifier=lambda _candidate: None,
                )

    def test_implementation_has_no_private_site_dependency(self) -> None:
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertIn('"--proto",\n            "=https"', text)
        self.assertIn('"--tlsv1.2"', text)
        self.assertIn('"--max-filesize"', text)
        self.assertNotIn("TelemetryDashboard", text)
        self.assertNotIn("verify-site-release-manifest", text)
        self.assertNotIn("cpa.tg", text)
        self.assertIn("direct-candidate-manifest.py", text)
        self.assertIn('["ditto", "-x", "-k"', text)


if __name__ == "__main__":
    unittest.main()
