import base64
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("direct_update_signing", SCRIPTS / "direct-update-signing.py")
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
OPENSSL = Path("/opt/homebrew/opt/openssl@3/bin/openssl")


@unittest.skipUnless(OPENSSL.is_file(), "Installed OpenSSL3 required for actual Ed25519 controls")
class DirectUpdateSigningTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(dir="/private/tmp", prefix="neantik-signing-test-")
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name); self.root.chmod(0o700)
        self.key = self.root / "owned.pem"
        module.generate_key(self.key, openssl=OPENSSL)
        self.archive = self.root / "NeAntik-0.7.36-arm64-notarized.zip"
        self.archive.write_bytes(b"synthetic archive bytes; not a notarized release")
        self.now = datetime.now(timezone.utc).replace(microsecond=0)
        self.payload = dict(schemaVersion=1, product="NeAntik", edition="Direct", version="0.7.36",
                            build=99, issuedAt=self.now.isoformat(), expiresAt=(self.now + timedelta(days=7)).isoformat(),
                            archiveName=self.archive.name,
                            downloadURL="https://github.com/AffPapa/neantik/releases/download/v0.7.36/" + self.archive.name,
                            sha256=hashlib.sha256(self.archive.read_bytes()).hexdigest(), minimumOS="14.0",
                            architecture="arm64", artifactKind="public-notarized", publicReleaseState="public-ready",
                            chromiumVersion="156.0.8078.80")

    def sign(self):
        return module.sign(self.payload, self.archive, self.key, "qa-owned-v1", openssl=OPENSSL, now=self.now)

    def test_actual_signature_independent_verification_and_tamper_control(self):
        envelope, public = self.sign(); decoded = json.loads(envelope)
        self.assertEqual(len(public), 32); self.assertEqual(decoded["algorithm"], "Ed25519")
        message = self.root / "message"; message.write_bytes(base64.b64decode(decoded["payload"]))
        signature = self.root / "signature"; signature.write_bytes(base64.b64decode(decoded["signature"]))
        key = self.root / "public.der"; key.write_bytes(bytes.fromhex("302a300506032b6570032100") + public)
        def verify():
            return subprocess.run([str(OPENSSL), "pkeyutl", "-verify", "-rawin", "-pubin", "-keyform", "DER",
                                   "-inkey", str(key), "-in", str(message), "-sigfile", str(signature)], capture_output=True).returncode
        self.assertEqual(verify(), 0)
        message.write_bytes(message.read_bytes().replace(b'"build":99', b'"build":98'))
        self.assertNotEqual(verify(), 0)
        # Reads must not make an unchanged key fail custody because atime changed.
        self.assertEqual(self.sign(), (envelope, public))
        self.assertEqual(os.stat(self.key).st_mode & 0o777, 0o600)

    def test_generate_and_envelope_output_never_overwrite(self):
        before = self.key.read_bytes()
        with self.assertRaises(FileExistsError): module.generate_key(self.key, openssl=OPENSSL)
        self.assertEqual(self.key.read_bytes(), before)
        output = self.root / "envelope"; module.exclusive_write(output, b"first")
        with self.assertRaises(FileExistsError): module.exclusive_write(output, b"second")
        self.assertEqual(output.read_bytes(), b"first")

    def test_key_symlink_fifo_hardlink_and_permissions_refused(self):
        for control in ("symlink", "fifo", "hardlink", "permissions"):
            with self.subTest(control=control):
                candidate = self.root / control
                if control == "symlink": candidate.symlink_to(self.key)
                if control == "fifo": os.mkfifo(candidate, 0o600)
                if control == "hardlink": os.link(self.key, candidate)
                if control == "permissions": candidate.write_bytes(self.key.read_bytes()); candidate.chmod(0o644)
                try:
                    with self.assertRaises((module.SigningError, OSError)):
                        module.sign(self.payload, self.archive, candidate, "qa", openssl=OPENSSL, now=self.now)
                finally: candidate.unlink()

    def test_private_directory_modes_and_symlink_ancestor_refused(self):
        self.root.chmod(0o755)
        with self.assertRaises(module.SigningError): self.sign()
        self.root.chmod(0o700)
        alias = self.root / "alias"; alias.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(module.SigningError):
            module.sign(self.payload, self.archive, alias / self.key.name, "qa", openssl=OPENSSL, now=self.now)

    def test_archive_tamper_symlink_fifo_and_wrong_name_refused(self):
        self.archive.write_bytes(b"tampered")
        with self.assertRaises(module.SigningError): self.sign()
        self.archive.unlink(); self.archive.symlink_to(self.key)
        with self.assertRaises(OSError): self.sign()
        self.archive.unlink(); os.mkfifo(self.archive, 0o600)
        with self.assertRaises(module.SigningError): self.sign()

    def test_schema_contract_dates_url_runtime_and_key_identifier_controls(self):
        controls = {"schemaVersion": True, "build": True, "edition": "Store", "architecture": "x86_64",
                    "version": "0.7.36-rc", "archiveName": "../archive.zip", "minimumOS": "13.0",
                    "chromiumVersion": "154.0.8037.98", "issuedAt": "2026-01-01", "expiresAt": "nonsense",
                    "publicReleaseState": "development", "artifactKind": "local",
                    "downloadURL": self.payload["downloadURL"] + "?token=synthetic"}
        for field, value in controls.items():
            with self.subTest(field=field):
                prior = self.payload[field]; self.payload[field] = value
                with self.assertRaises(module.SigningError): self.sign()
                self.payload[field] = prior
        for expiry in (self.now - timedelta(minutes=6), self.now + timedelta(days=15)):
            self.payload["expiresAt"] = expiry.isoformat()
            with self.assertRaises(module.SigningError): self.sign()
        self.payload["expiresAt"] = (self.now + timedelta(days=7)).isoformat()
        for key_id in ("", "../key", "a" * 65):
            with self.assertRaises(module.SigningError):
                module.sign(self.payload, self.archive, self.key, key_id, openssl=OPENSSL, now=self.now)
        with self.assertRaises(module.SigningError): module.validate_payload([], self.archive, now=self.now)

    def test_other_crypto_algorithm_refused(self):
        self.key.unlink()
        self.key.write_bytes(module.crypto(["genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256"], openssl=OPENSSL))
        self.key.chmod(0o600)
        with self.assertRaises(module.SigningError): self.sign()

    def test_cli_redacted_refusal_and_public_only_success(self):
        payload = self.root / "payload.json"; payload.write_text(json.dumps(self.payload))
        output = self.root / "release.json"
        command = ["python3", "-B", str(SCRIPTS / "direct-update-signing.py"), "--openssl", str(OPENSSL),
                   "sign", "--payload", str(payload), "--archive", str(self.archive), "--key", str(self.key),
                   "--key-id", "qa", "--output", str(output)]
        success = subprocess.run(command, capture_output=True)
        self.assertEqual(success.returncode, 0, success.stderr)
        self.assertEqual(set(json.loads(success.stdout)), {"keyID", "publicKeyBase64", "envelopeSHA256"})
        refusal = subprocess.run(command, capture_output=True)
        self.assertNotEqual(refusal.returncode, 0)
        self.assertNotIn(str(self.root).encode(), refusal.stderr)
        self.assertNotIn(b"PRIVATE KEY", success.stdout + refusal.stdout + refusal.stderr)


if __name__ == "__main__": unittest.main()
