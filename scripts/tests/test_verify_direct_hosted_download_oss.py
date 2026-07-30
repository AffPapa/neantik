import hashlib
import importlib.util
import plistlib
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


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
    def make_fixture(
        self,
        root: Path,
        *,
        version: str = "0.3.12",
    ) -> Path:
        (root / "Resources").mkdir()
        (root / "dist").mkdir()
        with (root / "Resources" / "Info.plist").open("wb") as file:
            plistlib.dump({"CFBundleShortVersionString": version}, file)
        archive = (
            root
            / "dist"
            / f"NeAntik-{version}-arm64-notarized.zip"
        )
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

            legacy_pair = (
                archive.name,
                hashlib.sha256(archive.read_bytes()).hexdigest(),
            )
            with mock.patch.object(
                MODULE,
                "LEGACY_ARCHIVE_ALLOWLIST",
                {legacy_pair},
            ):
                result = MODULE.verify_hosted_download(
                    project_root=root,
                    archive=archive,
                    download_url=(
                        "https://github.com/AffPapa/neantik/releases/download/v0.3.12/"
                        "NeAntik-0.3.12-arm64-notarized.zip"
                    ),
                    downloader=downloader,
                    archive_verifier=verifier,
                    legacy_archive_only=True,
                )

        self.assertEqual(
            result["status"],
            "legacy-hosted-zip-byte-identical-and-gatekeeper-verified",
        )
        self.assertEqual(len(verified), 2)
        self.assertNotEqual(verified[0], archive.resolve())
        self.assertIn("neantik-hosted-input-set-", str(verified[0]))
        self.assertNotEqual(verified[0].parent, verified[1].parent)
        self.assertIn("pinned", verified[1].parts)

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

            legacy_pair = (
                archive.name,
                hashlib.sha256(archive.read_bytes()).hexdigest(),
            )
            with mock.patch.object(
                MODULE,
                "LEGACY_ARCHIVE_ALLOWLIST",
                {legacy_pair},
            ):
                with self.assertRaisesRegex(
                    MODULE.HostedDownloadError,
                    "downloaded SHA-256 differs",
                ):
                    MODULE.verify_hosted_download(
                        project_root=root,
                        archive=archive,
                        download_url=(
                            "https://downloads.example/"
                            "NeAntik-0.3.12-arm64-notarized.zip"
                        ),
                        downloader=changed_download,
                        archive_verifier=lambda candidate: verified.append(candidate),
                        legacy_archive_only=True,
                    )

        self.assertEqual(len(verified), 1)
        self.assertNotEqual(verified[0], archive.resolve())
        self.assertIn("neantik-hosted-input-set-", str(verified[0]))

    def test_new_release_reverifies_local_and_downloaded_exact_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = self.make_fixture(root, version="1.2.3")
            manifest = root / "dist" / "direct-candidate-manifest.json"
            manifest.write_text("{}\n", encoding="utf-8")
            evidence = root / "dist" / "fingerprint-audit.json"
            evidence.write_text("{}\n", encoding="utf-8")
            attestation = root / "dist" / "fingerprint-audit-summary.json"
            attestation.write_text("{}\n", encoding="utf-8")
            candidate_checks: list[tuple[Path, Path, str]] = []
            evidence_checks: list[tuple[Path, Path, Path, str]] = []

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
                fingerprint_evidence=evidence,
                fingerprint_attestation=attestation,
                candidate_verifier=lambda candidate, bound_manifest, channel:
                    candidate_checks.append(
                        (candidate, bound_manifest, channel)
                    ),
                release_evidence_verifier=lambda bound_manifest, private, public, channel:
                    evidence_checks.append(
                        (bound_manifest, private, public, channel)
                    ),
            )

        self.assertEqual(
            result["status"],
            "hosted-zip-byte-identical-gatekeeper-candidate-and-evidence-verified",
        )
        self.assertEqual(len(candidate_checks), 2)
        self.assertEqual(len(evidence_checks), 1)
        self.assertNotEqual(candidate_checks[0][0], archive.resolve())
        self.assertIn(
            "neantik-hosted-input-set-",
            str(candidate_checks[0][0]),
        )
        self.assertNotEqual(
            candidate_checks[0][0].parent,
            candidate_checks[1][0].parent,
        )
        self.assertEqual(
            candidate_checks[0][1],
            candidate_checks[1][1],
        )
        self.assertEqual(candidate_checks[0][1], evidence_checks[0][0])
        self.assertTrue(
            all(check[2] == "public-alpha" for check in candidate_checks)
        )

    def test_manifest_swap_after_evidence_check_fails_on_source_drift(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = self.make_fixture(root, version="1.2.3")
            archive_bytes = archive.read_bytes()
            manifest = root / "dist" / "direct-candidate-manifest.json"
            manifest.write_text('{"candidate":"A"}\n', encoding="utf-8")
            evidence = root / "dist" / "fingerprint-audit.json"
            evidence.write_text("{}\n", encoding="utf-8")
            attestation = root / "dist" / "fingerprint-audit-summary.json"
            attestation.write_text("{}\n", encoding="utf-8")
            observed_manifest_bytes: list[bytes] = []

            def verify_evidence(
                bound_manifest: Path,
                _private: Path,
                _public: Path,
                _channel: str,
            ) -> None:
                observed_manifest_bytes.append(bound_manifest.read_bytes())
                manifest.write_text(
                    '{"candidate":"B"}\n',
                    encoding="utf-8",
                )

            with self.assertRaisesRegex(
                MODULE.HostedDownloadError,
                "release input changed",
            ):
                MODULE.verify_hosted_download(
                    project_root=root,
                    archive=archive,
                    download_url=(
                        "https://downloads.example/"
                        "NeAntik-1.2.3-arm64-notarized.zip"
                    ),
                    downloader=lambda _url, destination, _size:
                        destination.write_bytes(archive_bytes),
                    archive_verifier=lambda _candidate: None,
                    candidate_manifest=manifest,
                    release_channel="public-alpha",
                    fingerprint_evidence=evidence,
                    fingerprint_attestation=attestation,
                    candidate_verifier=lambda candidate, bound_manifest, channel:
                        observed_manifest_bytes.append(
                            bound_manifest.read_bytes()
                        ),
                    release_evidence_verifier=verify_evidence,
                )

            self.assertGreaterEqual(len(observed_manifest_bytes), 2)
            self.assertTrue(
                all(
                    value == b'{"candidate":"A"}\n'
                    for value in observed_manifest_bytes
                )
            )

    def test_pinned_manifest_mutate_verify_restore_cannot_receive_pass(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = self.make_fixture(root, version="1.2.3")
            archive_bytes = archive.read_bytes()
            manifest = root / "dist" / "direct-candidate-manifest.json"
            original = b'{"candidate":"A"}\n'
            manifest.write_bytes(original)
            evidence = root / "dist" / "fingerprint-audit.json"
            evidence.write_text("{}\n", encoding="utf-8")
            attestation = root / "dist" / "fingerprint-audit-summary.json"
            attestation.write_text("{}\n", encoding="utf-8")
            pinned_manifest: Path | None = None

            def verify_evidence(
                bound_manifest: Path,
                _private: Path,
                _public: Path,
                _channel: str,
            ) -> None:
                nonlocal pinned_manifest
                pinned_manifest = bound_manifest
                bound_manifest.write_bytes(b'{"candidate":"B"}\n')

            def verify_candidate(
                _candidate: Path,
                bound_manifest: Path,
                _channel: str,
            ) -> None:
                if bound_manifest.read_bytes() != original:
                    bound_manifest.write_bytes(original)

            with self.assertRaisesRegex(
                MODULE.HostedDownloadError,
                "release input changed",
            ):
                MODULE.verify_hosted_download(
                    project_root=root,
                    archive=archive,
                    download_url=(
                        "https://downloads.example/"
                        "NeAntik-1.2.3-arm64-notarized.zip"
                    ),
                    downloader=lambda _url, destination, _size:
                        destination.write_bytes(archive_bytes),
                    archive_verifier=lambda _candidate: None,
                    candidate_manifest=manifest,
                    release_channel="public-alpha",
                    fingerprint_evidence=evidence,
                    fingerprint_attestation=attestation,
                    candidate_verifier=verify_candidate,
                    release_evidence_verifier=verify_evidence,
                )

            self.assertIsNotNone(pinned_manifest)

    def test_local_archive_replacement_after_snapshot_cannot_receive_pass(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = self.make_fixture(root)
            archive_bytes = archive.read_bytes()
            verifier_calls = 0

            def verifier(_candidate: Path) -> None:
                nonlocal verifier_calls
                verifier_calls += 1
                if verifier_calls == 1:
                    archive.write_bytes(b"replacement with another payload")

            legacy_pair = (
                archive.name,
                hashlib.sha256(archive_bytes).hexdigest(),
            )
            with mock.patch.object(
                MODULE,
                "LEGACY_ARCHIVE_ALLOWLIST",
                {legacy_pair},
            ):
                with self.assertRaisesRegex(
                    MODULE.HostedDownloadError,
                    "release input changed",
                ):
                    MODULE.verify_hosted_download(
                        project_root=root,
                        archive=archive,
                        download_url=(
                            "https://downloads.example/"
                            "NeAntik-0.3.12-arm64-notarized.zip"
                        ),
                        downloader=lambda _url, destination, _size:
                            destination.write_bytes(archive_bytes),
                        archive_verifier=verifier,
                        legacy_archive_only=True,
                    )

            self.assertEqual(verifier_calls, 2)

    def test_verifier_cannot_mutate_pinned_archive_and_receive_pass(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = self.make_fixture(root)
            archive_bytes = archive.read_bytes()
            verifier_calls = 0

            def verifier(candidate: Path) -> None:
                nonlocal verifier_calls
                verifier_calls += 1
                candidate.write_bytes(b"mutated pinned payload")

            legacy_pair = (
                archive.name,
                hashlib.sha256(archive_bytes).hexdigest(),
            )
            with mock.patch.object(
                MODULE,
                "LEGACY_ARCHIVE_ALLOWLIST",
                {legacy_pair},
            ):
                with self.assertRaisesRegex(
                    MODULE.HostedDownloadError,
                    "pinned release input changed|"
                    "downloaded release changed",
                ):
                    MODULE.verify_hosted_download(
                        project_root=root,
                        archive=archive,
                        download_url=(
                            "https://downloads.example/"
                            "NeAntik-0.3.12-arm64-notarized.zip"
                        ),
                        downloader=lambda _url, destination, _size:
                            destination.write_bytes(archive_bytes),
                        archive_verifier=verifier,
                        legacy_archive_only=True,
                    )

            self.assertGreaterEqual(verifier_calls, 1)

    def test_candidate_manifest_and_channel_are_an_atomic_opt_in(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = self.make_fixture(root)
            with self.assertRaisesRegex(
                MODULE.HostedDownloadError,
                "new releases require",
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

    def test_new_release_cannot_use_legacy_archive_only_bypass(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = self.make_fixture(root, version="1.2.3")

            with self.assertRaisesRegex(
                MODULE.HostedDownloadError,
                "allowlisted historical",
            ):
                MODULE.verify_hosted_download(
                    project_root=root,
                    archive=archive,
                    download_url=(
                        "https://downloads.example/"
                        "NeAntik-1.2.3-arm64-notarized.zip"
                    ),
                    downloader=lambda _url, _destination, _size: None,
                    archive_verifier=lambda _candidate: None,
                    legacy_archive_only=True,
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
        self.assertIn("verify-public-artifact-privacy.py", text)
        self.assertIn("--legacy-archive-only", text)
        self.assertIn('["ditto", "-x", "-k"', text)


if __name__ == "__main__":
    unittest.main()
