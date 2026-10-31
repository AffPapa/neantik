#!/usr/bin/env python3
"""Offline Ed25519 release-envelope signing. Never grants install authority."""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile
from datetime import datetime, timezone


class SigningError(ValueError):
    pass


def crypto(command: list[str], *, openssl: Path, data: bytes | None = None,
           descriptors: tuple[int, ...] = ()) -> bytes:
    result = subprocess.run([str(openssl), *command], input=data,
                            capture_output=True, pass_fds=descriptors, timeout=15)
    if result.returncode:
        # Native diagnostics can contain paths and input material.
        raise SigningError("OpenSSL signing operation refused")
    return result.stdout


def private_parent(path: Path) -> None:
    parent = path.parent
    if not path.is_absolute() or parent.resolve(strict=True) != parent:
        raise SigningError("Private key requires an absolute private parent")
    identity = parent.stat()
    if (not stat.S_ISDIR(identity.st_mode) or identity.st_uid != os.getuid()
            or stat.S_IMODE(identity.st_mode) != 0o700):
        raise SigningError("Private key parent must be owned mode0700")


def stable_identity(identity: os.stat_result) -> tuple:
    # Reading may update atime. Custody concerns inode, bytes and permissions.
    return (identity.st_dev, identity.st_ino, identity.st_mode, identity.st_uid,
            identity.st_gid, identity.st_nlink, identity.st_size,
            identity.st_mtime_ns, identity.st_ctime_ns)


def exclusive_write(path: Path, data: bytes) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "wb", closefd=False) as stream:
            stream.write(data); stream.flush(); os.fsync(fd)
    finally:
        os.close(fd)


def generate_key(path: Path, *, openssl: Path) -> None:
    private_parent(path)
    # Secret stdout remains in memory, never in terminal/logs/argv.
    key = crypto(["genpkey", "-algorithm", "ED25519"], openssl=openssl)
    expected_header = b"-----BEGIN " + b"PRIVATE KEY-----\n"
    if not key.startswith(expected_header) or len(key) > 8192:
        raise SigningError("Unexpected key encoding")
    exclusive_write(path, key)


def key_fd(path: Path) -> int:
    private_parent(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    identity = os.fstat(fd)
    if (not stat.S_ISREG(identity.st_mode) or identity.st_uid != os.getuid()
            or stat.S_IMODE(identity.st_mode) != 0o600 or identity.st_nlink != 1
            or not 1 <= identity.st_size <= 8192):
        os.close(fd)
        raise SigningError("Private key custody refused")
    return fd


def public_key(fd: int, *, openssl: Path) -> bytes:
    os.lseek(fd, 0, os.SEEK_SET)
    der = crypto(["pkey", "-in", f"/dev/fd/{fd}", "-pubout", "-outform", "DER"],
                 openssl=openssl, descriptors=(fd,))
    prefix = bytes.fromhex("302a300506032b6570032100")
    if len(der) != len(prefix) + 32 or not der.startswith(prefix):
        raise SigningError("Key is not Ed25519")
    return der[len(prefix):]


def validate_payload(payload: dict, archive: Path, *, now: datetime) -> None:
    required = {"schemaVersion", "product", "edition", "version", "build", "issuedAt",
                "expiresAt", "archiveName", "downloadURL", "sha256", "minimumOS",
                "architecture", "artifactKind", "publicReleaseState", "chromiumVersion"}
    if not isinstance(payload, dict) or set(payload) != required:
        raise SigningError("Unexpected payload fields")
    version = payload["version"]
    if (not isinstance(version, str) or not re.fullmatch(r"\d+\.\d+\.\d+", version)
            or type(payload["build"]) is not int or payload["build"] <= 0
            or type(payload["schemaVersion"]) is not int or payload["schemaVersion"] != 1
            or payload["product"] != "NeAntik" or payload["edition"] != "Direct"
            or payload["architecture"] != "arm64"
            or payload["artifactKind"] != "public-notarized"
            or payload["publicReleaseState"] != "public-ready"):
        raise SigningError("Release metadata refused")
    name = f"NeAntik-{version}-arm64-notarized.zip"
    if (payload["archiveName"] != name or archive.name != name
            or payload["downloadURL"] != f"https://github.com/AffPapa/neantik/releases/download/v{version}/{name}"):
        raise SigningError("Exact GitHub archive binding refused")
    for field in ("chromiumVersion", "minimumOS"):
        if not isinstance(payload[field], str) or not re.fullmatch(r"\d+(?:\.\d+){1,3}", payload[field]):
            raise SigningError("Version format refused")
    if int(payload["minimumOS"].split(".")[0]) < 14:
        raise SigningError("Unsupported minimum OS")
    baseline = json.loads((Path(__file__).resolve().parents[1] /
                           "runtime/security-baseline.json").read_bytes())
    parts = lambda value: tuple(int(part) for part in value.split("."))
    if parts(payload["chromiumVersion"]) < parts(baseline["minimumPublicChromiumVersion"]):
        raise SigningError("Runtime is below the pinned public security baseline")
    try:
        issued = datetime.fromisoformat(payload["issuedAt"].replace("Z", "+00:00"))
        expires = datetime.fromisoformat(payload["expiresAt"].replace("Z", "+00:00"))
        lifetime = (expires - issued).total_seconds()
        if (issued.utcoffset() is None or expires.utcoffset() is None
                or issued.timestamp() > now.timestamp() + 300
                or expires.timestamp() < now.timestamp() - 300
                or not 0 < lifetime <= 14 * 86400):
            raise SigningError("Manifest lifetime refused")
    except (ValueError, TypeError, AttributeError) as error:
        raise SigningError("Manifest dates refused") from error
    fd = os.open(archive, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode):
            raise SigningError("Archive is not a regular file")
        with os.fdopen(fd, "rb", closefd=False) as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        if stable_identity(before) != stable_identity(os.fstat(fd)) or payload["sha256"] != digest:
            raise SigningError("Archive hash/custody refused")
    finally:
        os.close(fd)


def sign(payload: dict, archive: Path, key: Path, key_id: str, *, openssl: Path,
         now: datetime | None = None) -> tuple[bytes, bytes]:
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", key_id):
        raise SigningError("Key identifier refused")
    validate_payload(payload, archive, now=now or datetime.now(timezone.utc))
    data = json.dumps(payload, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()
    if len(data) > 64 * 1024:
        raise SigningError("Payload is too large")
    fd = key_fd(key)
    try:
        before = os.fstat(fd); public = public_key(fd, openssl=openssl)
        with tempfile.TemporaryDirectory(prefix="neantik-manifest-sign-") as work:
            source = Path(work) / "payload.json"; source.write_bytes(data)
            os.lseek(fd, 0, os.SEEK_SET)
            signature = crypto(["pkeyutl", "-sign", "-rawin", "-inkey", f"/dev/fd/{fd}",
                                "-in", str(source)], openssl=openssl, descriptors=(fd,))
        if len(signature) != 64 or stable_identity(before) != stable_identity(os.fstat(fd)):
            raise SigningError("Key/signature custody refused")
    finally:
        os.close(fd)
    envelope = {"schemaVersion": 1, "algorithm": "Ed25519", "keyID": key_id,
                "payload": base64.b64encode(data).decode(),
                "signature": base64.b64encode(signature).decode()}
    return json.dumps(envelope, sort_keys=True, separators=(",", ":")).encode() + b"\n", public


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--openssl", type=Path, required=True, help="Installed OpenSSL3 executable")
    sub = parser.add_subparsers(dest="command", required=True)
    generate = sub.add_parser("generate-key"); generate.add_argument("--key", type=Path, required=True)
    create = sub.add_parser("sign")
    for name in ("payload", "archive", "key", "output"):
        create.add_argument("--" + name, type=Path, required=True)
    create.add_argument("--key-id", required=True)
    args = parser.parse_args()
    try:
        if args.command == "generate-key":
            generate_key(args.key, openssl=args.openssl)
            print("PASS: private Ed25519 key created; no key material displayed.")
        else:
            if args.payload.stat().st_size > 64 * 1024:
                raise SigningError("Payload is too large")
            envelope, public = sign(json.loads(args.payload.read_bytes()), args.archive,
                                    args.key, args.key_id, openssl=args.openssl)
            exclusive_write(args.output, envelope)
            print(json.dumps({"keyID": args.key_id, "publicKeyBase64": base64.b64encode(public).decode(),
                              "envelopeSHA256": hashlib.sha256(envelope).hexdigest()}))
    except (SigningError, OSError, ValueError, TypeError, subprocess.SubprocessError):
        parser.exit(1, "REFUSED: signing inputs, custody or crypto operation invalid; existing files retained.\n")


if __name__ == "__main__":
    main()
