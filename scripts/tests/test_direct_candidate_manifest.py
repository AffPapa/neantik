import base64
import hashlib
import importlib.util
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "direct-candidate-manifest.py"
SPEC = importlib.util.spec_from_file_location("direct_candidate_manifest", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)

VERIFIER_TESTS = (
    Path(__file__).resolve().parent / "test_verify_gui_fingerprint_report.py"
)
VERIFIER_SPEC = importlib.util.spec_from_file_location(
    "test_verify_gui_fingerprint_report_for_candidate_manifest",
    VERIFIER_TESTS,
)
assert VERIFIER_SPEC and VERIFIER_SPEC.loader
FIXTURES = importlib.util.module_from_spec(VERIFIER_SPEC)
sys.modules[VERIFIER_SPEC.name] = FIXTURES
VERIFIER_SPEC.loader.exec_module(FIXTURES)


def prepared_fixture(root: Path) -> Path:
    app = FIXTURES.write_integrated_app_fixture(root)
    info_path = app / "Contents/Info.plist"
    with info_path.open("rb") as file:
        info = plistlib.load(file)
    info["CFBundleIdentifier"] = "app.neantik.desktop"
    info["CFBundleExecutable"] = "NeAntik"
    with info_path.open("wb") as file:
        plistlib.dump(info, file)
    executable = app / "Contents/MacOS/NeAntik"
    executable.parent.mkdir(parents=True, exist_ok=True)
    executable.write_bytes(b"manager executable")
    return app


def fingerprint_binding() -> dict[str, object]:
    fixture_path = (
        Path(__file__).resolve().parent
        / "fixtures/fingerprint-evidence-schema8-swift.json"
    )
    fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
    manifest = json.loads(
        base64.b64decode(fixture["manifestBase64"]).decode("utf-8")
    )
    return manifest["fingerprintEvidence"]


def write_candidate_manifest(
    root: Path,
    app: Path,
    *,
    binding: dict[str, object] | None = None,
) -> tuple[Path, dict[str, object], bytes]:
    payload = MODULE.manifest_payload(
        app,
        release_channel="public-alpha",
        fingerprint_evidence=(
            binding if binding is not None else fingerprint_binding()
        ),
        prepared_at="2026-07-30T00:00:00Z",
    )
    raw = MODULE.encoded_manifest(payload)
    path = root / "candidate.json"
    path.write_bytes(raw)
    return path, payload, raw


class DirectCandidateManifestTests(unittest.TestCase):
    def test_schema3_manifest_preserves_binding_and_exact_compact_bytes(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = prepared_fixture(root)
            binding = fingerprint_binding()
            manifest = root / "candidate.json"
            payload = MODULE.manifest_payload(
                app,
                release_channel="public-alpha",
                fingerprint_evidence=binding,
                prepared_at="2026-07-30T00:00:00Z",
            )
            digest = MODULE.write_manifest(manifest, payload)
            raw = manifest.read_bytes()

            self.assertEqual(payload["schemaVersion"], 3)
            self.assertEqual(payload["fingerprintEvidence"], binding)
            self.assertEqual(
                raw,
                MODULE.EVIDENCE_SCHEMA.canonical_json_bytes(payload),
            )
            self.assertFalse(raw.endswith(b"\n"))
            self.assertEqual(digest, hashlib.sha256(raw).hexdigest())
            self.assertEqual(
                MODULE.verify_manifest(
                    app,
                    manifest,
                    release_channel="public-alpha",
                ),
                hashlib.sha256(raw).hexdigest(),
            )

    def test_rejects_schema2_unknown_and_missing_root_fields(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = prepared_fixture(root)
            _, payload, _ = write_candidate_manifest(root, app)
            variants: list[dict[str, object]] = []
            schema2 = dict(payload)
            schema2["schemaVersion"] = 2
            variants.append(schema2)
            unknown = dict(payload)
            unknown["unknown"] = True
            variants.append(unknown)
            missing = dict(payload)
            missing.pop("fingerprintEvidence")
            variants.append(missing)

            for index, variant in enumerate(variants):
                path = root / f"variant-{index}.json"
                path.write_bytes(MODULE.encoded_manifest(variant))
                with self.subTest(index=index):
                    with self.assertRaises(MODULE.CandidateManifestError):
                        MODULE.load_manifest(path)

    def test_rejects_duplicate_noncanonical_and_nonfinite_json(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = prepared_fixture(root)
            _, payload, raw = write_candidate_manifest(root, app)
            variants = [
                raw.replace(
                    b"{",
                    b'{"schemaVersion":3,',
                    1,
                ),
                raw + b"\n",
                json.dumps(payload, indent=2, sort_keys=True).encode("utf-8"),
                raw.replace(b'"schemaVersion":3', b'"schemaVersion":NaN'),
            ]
            for index, variant in enumerate(variants):
                path = root / f"noncanonical-{index}.json"
                path.write_bytes(variant)
                with self.subTest(index=index):
                    with self.assertRaises(MODULE.CandidateManifestError):
                        MODULE.load_manifest(path)

    def test_rejects_symlink_oversized_fifo_and_hardlink_manifest(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = prepared_fixture(root)
            valid, _, _ = write_candidate_manifest(root, app)
            symlink = root / "symlink.json"
            symlink.symlink_to(valid)
            oversized = root / "oversized.json"
            with oversized.open("wb") as handle:
                handle.truncate(MODULE.MAXIMUM_MANIFEST_BYTES + 1)
            fifo = root / "fifo"
            os.mkfifo(fifo)
            hardlink = root / "hardlink.json"
            os.link(valid, hardlink)
            for path in (symlink, oversized, fifo, hardlink):
                with self.subTest(path=path.name):
                    with self.assertRaises(MODULE.CandidateManifestError):
                        MODULE.load_manifest(path)

    def test_rejects_malformed_or_incoherent_fingerprint_binding(
        self,
    ) -> None:
        valid = fingerprint_binding()
        public_key = base64.b64decode(
            str(valid["publicKeyX963"]),
            validate=True,
        )
        off_curve = b"\x04" + (b"\x00" * 64)
        variants: list[dict[str, object]] = []
        for changes in (
            {"schemaVersion": True},
            {"authorityKeyID": hashlib.sha256(public_key).hexdigest().upper()},
            {"authorityKeyID": "0" * 64},
            {"sessionID": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"},
            {"sessionID": "not-a-uuid"},
            {"challenge": base64.b64encode(b"a" * 31).decode("ascii")},
            {"challenge": base64.b64encode(b"a" * 33).decode("ascii")},
            {"challenge": "%%%"},
            {"publicKeyX963": str(valid["publicKeyX963"]).rstrip("=")},
            {
                "publicKeyX963": base64.b64encode(off_curve).decode("ascii"),
                "authorityKeyID": hashlib.sha256(off_curve).hexdigest(),
            },
        ):
            candidate = dict(valid)
            candidate.update(changes)
            variants.append(candidate)

        for index, candidate in enumerate(variants):
            with self.subTest(index=index):
                with self.assertRaises(MODULE.CandidateManifestError):
                    MODULE.validated_fingerprint_evidence_binding(candidate)

    def test_cli_create_requires_safe_enrollment_binding(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = prepared_fixture(root)
            manifest = root / "candidate.json"
            common = [
                sys.executable,
                str(SCRIPT),
                "create",
                "--app",
                str(app),
                "--manifest",
                str(manifest),
                "--release-channel",
                "public-alpha",
            ]
            missing = subprocess.run(
                common,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(missing.returncode, 0)
            self.assertFalse(manifest.exists())
            self.assertIn("--fingerprint-enrollment", missing.stderr)

            target = root / "enrollment.json"
            target.write_bytes(
                MODULE.EVIDENCE_SCHEMA.canonical_json_bytes(
                    fingerprint_binding()
                )
            )
            symlink = root / "enrollment-link.json"
            symlink.symlink_to(target)
            unsafe = subprocess.run(
                common
                + [
                    "--fingerprint-enrollment",
                    str(symlink),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(unsafe.returncode, 0)
            self.assertFalse(manifest.exists())

    def test_round_trip_binds_code_critical_candidate_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = prepared_fixture(root)
            manifest = root / "candidate.json"
            created_sha = MODULE.write_manifest(
                manifest,
                MODULE.manifest_payload(
                    app,
                    release_channel="public-alpha",
                    fingerprint_evidence=fingerprint_binding(),
                ),
            )
            verified_sha = MODULE.verify_manifest(
                app,
                manifest,
                release_channel="public-alpha",
            )
            self.assertEqual(created_sha, verified_sha)
            self.assertNotIn(str(root), manifest.read_text(encoding="utf-8"))

    def test_rejects_manager_executable_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = prepared_fixture(root)
            manifest = root / "candidate.json"
            MODULE.write_manifest(
                manifest,
                MODULE.manifest_payload(
                    app,
                    release_channel="public-alpha",
                    fingerprint_evidence=fingerprint_binding(),
                ),
            )
            (app / "Contents/MacOS/NeAntik").write_bytes(b"changed")
            with self.assertRaisesRegex(MODULE.CandidateManifestError, "changed after"):
                MODULE.verify_manifest(
                    app,
                    manifest,
                    release_channel="public-alpha",
                )

    def test_rejects_unlisted_helper_or_signature_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = prepared_fixture(root)
            helper = (
                app
                / "Contents/Resources/NeAntik Browser.app/Contents/Frameworks"
                / "NeAntik Helper.app/Contents/MacOS/NeAntik Helper"
            )
            helper.parent.mkdir(parents=True)
            helper.write_bytes(b"helper executable")
            manifest = root / "candidate.json"
            MODULE.write_manifest(
                manifest,
                MODULE.manifest_payload(
                    app,
                    release_channel="public-alpha",
                    fingerprint_evidence=fingerprint_binding(),
                ),
            )
            helper.write_bytes(b"changed helper executable")
            with self.assertRaisesRegex(MODULE.CandidateManifestError, "changed after"):
                MODULE.verify_manifest(
                    app,
                    manifest,
                    release_channel="public-alpha",
                )

    def test_allows_only_documented_stapler_ticket_path_to_change(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = prepared_fixture(root)
            ticket = app / "Contents/CodeResources"
            ticket.write_bytes(b"before staple")
            manifest = root / "candidate.json"
            MODULE.write_manifest(
                manifest,
                MODULE.manifest_payload(
                    app,
                    release_channel="public-alpha",
                    fingerprint_evidence=fingerprint_binding(),
                ),
            )
            ticket.write_bytes(b"after staple")
            MODULE.verify_manifest(
                app,
                manifest,
                release_channel="public-alpha",
            )

    def test_rejects_release_channel_substitution(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = prepared_fixture(root)
            manifest = root / "candidate.json"
            MODULE.write_manifest(
                manifest,
                MODULE.manifest_payload(
                    app,
                    release_channel="public-alpha",
                    fingerprint_evidence=fingerprint_binding(),
                ),
            )
            with self.assertRaisesRegex(
                MODULE.CandidateManifestError,
                "release channel",
            ):
                MODULE.verify_manifest(
                    app,
                    manifest,
                    release_channel="production",
                )

    def test_rejects_gui_evidence_created_before_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = prepared_fixture(root)
            manifest = root / "candidate.json"
            MODULE.write_manifest(
                manifest,
                MODULE.manifest_payload(
                    app,
                    release_channel="public-alpha",
                    fingerprint_evidence=fingerprint_binding(),
                    prepared_at="2026-07-25T09:00:00Z",
                ),
            )
            evidence = root / "fingerprint-audit.json"
            evidence.write_text(
                json.dumps(FIXTURES.production_report()),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(MODULE.CandidateManifestError, "predates"):
                MODULE.verify_evidence_follows_manifest(manifest, evidence)


if __name__ == "__main__":
    unittest.main()
