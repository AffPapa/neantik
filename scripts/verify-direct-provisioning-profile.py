#!/usr/bin/env python3

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import os
import plistlib
import re
import stat
import subprocess
import tempfile
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_INFO_PLIST = PROJECT_ROOT / "Resources" / "Info.plist"
DEFAULT_ENTITLEMENTS = PROJECT_ROOT / "Resources" / "NeAntik.entitlements"
MAXIMUM_PROFILE_BYTES = 4 * 1024 * 1024
APPLE_PROVISIONING_ROOT_SHA256 = {
    "B0B1730ECBC7FF4505142C49F1295E6EDA6BCAED7E2C68C5BE91B5A11001F024",
}


class ProvisioningProfileError(RuntimeError):
    pass


def _required_string(mapping: dict[str, Any], key: str) -> str:
    value = mapping.get(key)
    if not isinstance(value, str) or not value:
        raise ProvisioningProfileError(f"missing or invalid {key}")
    return value


def _read_plist(path: Path, label: str) -> dict[str, Any]:
    try:
        payload = plistlib.loads(path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        raise ProvisioningProfileError(f"cannot read {label}") from error
    if not isinstance(payload, dict):
        raise ProvisioningProfileError(f"{label} must be a plist dictionary")
    return payload


def _read_regular_profile(path: Path) -> bytes:
    if not path.is_absolute():
        raise ProvisioningProfileError("profile path must be absolute")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise ProvisioningProfileError("cannot open provisioning profile") from error
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise ProvisioningProfileError("provisioning profile is not regular")
        if before.st_uid != os.geteuid() or before.st_nlink != 1:
            raise ProvisioningProfileError(
                "provisioning profile owner or link count is unsafe"
            )
        if before.st_size <= 0 or before.st_size > MAXIMUM_PROFILE_BYTES:
            raise ProvisioningProfileError("provisioning profile size is unsafe")
        chunks: list[bytes] = []
        remaining = before.st_size
        while remaining:
            chunk = os.read(descriptor, min(remaining, 1024 * 1024))
            if not chunk:
                raise ProvisioningProfileError("provisioning profile was truncated")
            chunks.append(chunk)
            remaining -= len(chunk)
        after = os.fstat(descriptor)
        if (
            before.st_dev,
            before.st_ino,
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
        ) != (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
        ):
            raise ProvisioningProfileError(
                "provisioning profile changed while it was read"
            )
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def _decode_profile(profile_bytes: bytes) -> dict[str, Any]:
    with tempfile.TemporaryDirectory(prefix="neantik-profile-") as directory:
        temporary = Path(directory)
        profile_path = temporary / "profile.provisionprofile"
        profile_path.write_bytes(profile_bytes)
        profile_path.chmod(0o600)
        completed = subprocess.run(
            ["/usr/bin/security", "cms", "-D", "-i", str(profile_path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=30,
        )
        if completed.returncode == 0:
            decoded = completed.stdout
        else:
            decoded = _decode_profile_with_openssl(profile_path, temporary)
    try:
        payload = plistlib.loads(decoded)
    except plistlib.InvalidFileException as error:
        raise ProvisioningProfileError(
            "decoded provisioning profile is not a plist"
        ) from error
    if not isinstance(payload, dict):
        raise ProvisioningProfileError(
            "decoded provisioning profile must be a dictionary"
        )
    return payload


def _certificate_der(pem_path: Path) -> bytes:
    completed = subprocess.run(
        [
            "/usr/bin/openssl",
            "x509",
            "-in",
            str(pem_path),
            "-outform",
            "DER",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=30,
    )
    if completed.returncode != 0 or not completed.stdout:
        raise ProvisioningProfileError("CMS signer certificate is invalid")
    return completed.stdout


def _certificate_identity(pem_path: Path) -> str:
    completed = subprocess.run(
        [
            "/usr/bin/openssl",
            "x509",
            "-in",
            str(pem_path),
            "-noout",
            "-subject",
            "-issuer",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=30,
    )
    if completed.returncode != 0:
        raise ProvisioningProfileError("CMS signer identity is invalid")
    return completed.stdout.decode("utf-8", errors="replace")


def _decode_profile_with_openssl(profile_path: Path, temporary: Path) -> bytes:
    payload_path = temporary / "payload.plist"
    signer_path = temporary / "signer.pem"
    certificates_path = temporary / "certificates.pem"
    completed = subprocess.run(
        [
            "/usr/bin/openssl",
            "cms",
            "-verify",
            "-inform",
            "DER",
            "-in",
            str(profile_path),
            "-noverify",
            "-out",
            str(payload_path),
            "-signer",
            str(signer_path),
            "-certsout",
            str(certificates_path),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=30,
    )
    if completed.returncode != 0:
        raise ProvisioningProfileError(
            "Apple provisioning profile CMS signature could not be decoded"
        )
    signer_identity = _certificate_identity(signer_path)
    if (
        "Provisioning Profile Signing" not in signer_identity
        or "O=Apple Inc." not in signer_identity
    ):
        raise ProvisioningProfileError(
            "CMS signer is not an Apple provisioning profile authority"
        )

    try:
        certificates_pem = certificates_path.read_bytes()
    except OSError as error:
        raise ProvisioningProfileError("CMS certificate chain is missing") from error
    blocks = re.findall(
        rb"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----\s*",
        certificates_pem,
        flags=re.DOTALL,
    )
    if len(blocks) < 2 or len(blocks) > 8:
        raise ProvisioningProfileError("CMS certificate chain is invalid")

    signer_fingerprint = hashlib.sha256(_certificate_der(signer_path)).hexdigest()
    root_path: Path | None = None
    intermediate_blocks: list[bytes] = []
    for index, block in enumerate(blocks):
        certificate_path = temporary / f"certificate-{index}.pem"
        certificate_path.write_bytes(block)
        certificate_path.chmod(0o600)
        fingerprint = hashlib.sha256(_certificate_der(certificate_path)).hexdigest()
        identity = _certificate_identity(certificate_path)
        subject, _, issuer = identity.partition("\n")
        if (
            fingerprint.upper() in APPLE_PROVISIONING_ROOT_SHA256
            and subject.removeprefix("subject=").strip()
            == issuer.removeprefix("issuer=").strip()
        ):
            root_path = certificate_path
        elif fingerprint != signer_fingerprint:
            intermediate_blocks.append(block)
    if root_path is None or not intermediate_blocks:
        raise ProvisioningProfileError(
            "CMS chain does not terminate at the reviewed Apple root"
        )
    intermediates_path = temporary / "intermediates.pem"
    intermediates_path.write_bytes(b"".join(intermediate_blocks))
    intermediates_path.chmod(0o600)
    verified = subprocess.run(
        [
            "/usr/bin/openssl",
            "verify",
            "-CAfile",
            str(root_path),
            "-untrusted",
            str(intermediates_path),
            str(signer_path),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=30,
    )
    if verified.returncode != 0:
        raise ProvisioningProfileError(
            "Apple provisioning profile signer chain is invalid"
        )
    try:
        return payload_path.read_bytes()
    except OSError as error:
        raise ProvisioningProfileError(
            "decoded provisioning profile payload is missing"
        ) from error


def expected_release_identity(
    info_plist: dict[str, Any],
) -> tuple[str, str, str]:
    bundle_id = _required_string(info_plist, "CFBundleIdentifier")
    team_id = _required_string(info_plist, "NeAntikDeveloperTeamIdentifier")
    return bundle_id, team_id, f"{team_id}.{bundle_id}"


def validate_source_entitlements(
    entitlements: dict[str, Any],
    *,
    bundle_id: str,
    team_id: str,
    application_id: str,
) -> None:
    expected = {
        "com.apple.application-identifier": application_id,
        "com.apple.developer.team-identifier": team_id,
        "keychain-access-groups": [application_id],
    }
    if entitlements != expected:
        raise ProvisioningProfileError(
            "release entitlements do not match the exact NeAntik identity"
        )
    if bundle_id != application_id.removeprefix(f"{team_id}."):
        raise ProvisioningProfileError("release application identifier is invalid")


def profile_developer_certificate_sha256s(
    profile: dict[str, Any],
) -> frozenset[str]:
    certificates = profile.get("DeveloperCertificates")
    if not isinstance(certificates, list) or not certificates:
        raise ProvisioningProfileError(
            "profile has no authorized Developer ID signing certificate"
        )
    fingerprints: set[str] = set()
    for certificate in certificates:
        if not isinstance(certificate, bytes) or not certificate:
            raise ProvisioningProfileError(
                "profile DeveloperCertificates entry is invalid"
            )
        fingerprints.add(
            hashlib.sha256(certificate).hexdigest().upper()
        )
    return frozenset(fingerprints)


def installed_signing_identities() -> tuple[tuple[str, str], ...]:
    completed = subprocess.run(
        ["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=30,
    )
    if completed.returncode != 0:
        raise ProvisioningProfileError(
            "installed code-signing identities could not be inspected"
        )
    text = (completed.stdout + b"\n" + completed.stderr).decode(
        "utf-8", errors="replace"
    )
    available: list[tuple[str, str]] = []
    for line in text.splitlines():
        match = re.match(
            r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"([^"]+)"',
            line,
        )
        if match:
            available.append((match.group(1).upper(), match.group(2)))
    return tuple(available)


def installed_certificate_sha256s_by_sha1() -> dict[str, frozenset[str]]:
    completed = subprocess.run(
        ["/usr/bin/security", "find-certificate", "-a", "-Z"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=30,
    )
    if completed.returncode != 0:
        raise ProvisioningProfileError(
            "installed signing certificates could not be inspected"
        )
    text = (completed.stdout + b"\n" + completed.stderr).decode(
        "utf-8", errors="replace"
    )
    pairs = re.findall(
        r"SHA-256 hash:\s*([0-9A-Fa-f]{64})\s*"
        r"SHA-1 hash:\s*([0-9A-Fa-f]{40})",
        text,
    )
    fingerprints: dict[str, set[str]] = {}
    for sha256, sha1 in pairs:
        fingerprints.setdefault(sha1.upper(), set()).add(sha256.upper())
    return {
        sha1: frozenset(sha256s)
        for sha1, sha256s in fingerprints.items()
    }


def installed_identity_certificate_sha256(
    identity_sha1: str,
    certificate_map: dict[str, frozenset[str]],
) -> str:
    matches = certificate_map.get(identity_sha1, frozenset())
    if len(matches) != 1:
        raise ProvisioningProfileError(
            "installed Developer ID identity could not be bound to one certificate"
        )
    return next(iter(matches))


def resolve_signing_identity_sha1(identity: str) -> str:
    identity = identity.strip()
    if not identity:
        raise ProvisioningProfileError("signing identity is empty")
    available = installed_signing_identities()
    requested_sha1 = (
        identity.upper()
        if re.fullmatch(r"[0-9A-Fa-f]{40}", identity)
        else None
    )
    matches = {
        fingerprint
        for fingerprint, common_name in available
        if fingerprint == requested_sha1 or common_name == identity
    }
    if not matches:
        raise ProvisioningProfileError(
            "declared Developer ID signing identity is not installed"
        )
    if len(matches) != 1:
        raise ProvisioningProfileError(
            "declared Developer ID signing identity is ambiguous; use its SHA-1"
        )
    return next(iter(matches))


def select_profile_authorized_signing_identity(
    profile: dict[str, Any],
) -> str:
    authorized = profile_developer_certificate_sha256s(profile)
    certificate_map = installed_certificate_sha256s_by_sha1()
    matches: set[str] = set()
    for fingerprint, common_name in installed_signing_identities():
        if not common_name.startswith("Developer ID Application:"):
            continue
        certificate_sha256 = installed_identity_certificate_sha256(
            fingerprint,
            certificate_map,
        )
        if certificate_sha256 in authorized:
            matches.add(fingerprint)
    if not matches:
        raise ProvisioningProfileError(
            "no installed Developer ID Application identity is authorized by profile"
        )
    if len(matches) != 1:
        raise ProvisioningProfileError(
            "multiple installed Developer ID identities are authorized; declare one explicitly"
        )
    return next(iter(matches))


def validate_declared_signing_identity(
    profile: dict[str, Any],
    identity: str,
) -> None:
    signing_sha1 = resolve_signing_identity_sha1(identity)
    certificate_sha256 = installed_identity_certificate_sha256(
        signing_sha1,
        installed_certificate_sha256s_by_sha1(),
    )
    if certificate_sha256 not in profile_developer_certificate_sha256s(profile):
        raise ProvisioningProfileError(
            "profile does not authorize the declared Developer ID signing certificate"
        )


def validate_signed_app_certificate(
    app_path: Path,
    profile: dict[str, Any],
) -> None:
    authorized = profile_developer_certificate_sha256s(profile)
    with tempfile.TemporaryDirectory(prefix="neantik-signed-certificate-") as directory:
        certificate_prefix = Path(directory) / "certificate"
        extracted = subprocess.run(
            [
                "/usr/bin/codesign",
                "--display",
                "--extract-certificates",
                str(certificate_prefix),
                str(app_path),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=30,
        )
        leaf_path = Path(f"{certificate_prefix}0")
        if extracted.returncode != 0:
            raise ProvisioningProfileError(
                "signed app certificate could not be extracted"
            )
        try:
            status = leaf_path.lstat()
            certificate = leaf_path.read_bytes()
        except OSError as error:
            raise ProvisioningProfileError(
                "signed app leaf certificate is unavailable"
            ) from error
        if (
            not stat.S_ISREG(status.st_mode)
            or status.st_uid != os.geteuid()
            or status.st_nlink != 1
            or not certificate
            or len(certificate) > 1024 * 1024
        ):
            raise ProvisioningProfileError(
                "signed app leaf certificate is unsafe"
            )
        fingerprint = hashlib.sha256(certificate).hexdigest().upper()
        if fingerprint not in authorized:
            raise ProvisioningProfileError(
                "signed app certificate is not authorized by its provisioning profile"
            )


def _normalized_utc(value: dt.datetime) -> dt.datetime:
    if value.tzinfo is None:
        return value.replace(tzinfo=dt.timezone.utc)
    return value.astimezone(dt.timezone.utc)


def validate_profile_payload(
    profile: dict[str, Any],
    *,
    bundle_id: str,
    team_id: str,
    application_id: str,
    now: dt.datetime | None = None,
) -> dt.datetime:
    _required_string(profile, "UUID")
    _required_string(profile, "Name")
    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, dt.datetime):
        raise ProvisioningProfileError("profile expiration is missing")
    expiration_utc = _normalized_utc(expiration)
    current = _normalized_utc(now or dt.datetime.now(dt.timezone.utc))
    if expiration_utc <= current:
        raise ProvisioningProfileError("provisioning profile is expired")

    teams = profile.get("TeamIdentifier")
    if not isinstance(teams, list) or teams != [team_id]:
        raise ProvisioningProfileError("profile team does not match NeAntik")
    platforms = profile.get("Platform")
    if not isinstance(platforms, list) or not any(
        platform in {"OSX", "macOS"} for platform in platforms
    ):
        raise ProvisioningProfileError("profile is not authorized for macOS")
    if profile.get("ProvisionsAllDevices") is not True:
        raise ProvisioningProfileError(
            "profile is not a Developer ID distribution profile"
        )
    if profile.get("ProvisionedDevices"):
        raise ProvisioningProfileError(
            "device-limited development or ad hoc profile is forbidden"
        )
    profile_developer_certificate_sha256s(profile)

    entitlements = profile.get("Entitlements")
    if not isinstance(entitlements, dict):
        raise ProvisioningProfileError("profile entitlements are missing")
    if entitlements.get("com.apple.application-identifier") != application_id:
        raise ProvisioningProfileError(
            "profile does not authorize the exact NeAntik application identifier"
        )
    if entitlements.get("com.apple.developer.team-identifier") != team_id:
        raise ProvisioningProfileError(
            "profile does not authorize the NeAntik developer team"
        )
    groups = entitlements.get("keychain-access-groups")
    authorized_groups = {application_id, f"{team_id}.*"}
    if not isinstance(groups, list) or not any(
        isinstance(group, str) and group in authorized_groups for group in groups
    ):
        raise ProvisioningProfileError(
            "profile does not authorize the NeAntik Keychain access group"
        )
    debugging = entitlements.get("get-task-allow")
    if debugging is not None and debugging is not False:
        raise ProvisioningProfileError("development debugging entitlement is forbidden")
    sandbox = entitlements.get("com.apple.security.app-sandbox")
    if sandbox is not None and sandbox is not False:
        raise ProvisioningProfileError("Mac App Store sandbox profile is forbidden")
    if bundle_id != application_id.removeprefix(f"{team_id}."):
        raise ProvisioningProfileError("profile application identifier is invalid")
    return expiration_utc


def _extract_plist(output: bytes, label: str) -> dict[str, Any]:
    start = output.find(b"<?xml")
    end_marker = b"</plist>"
    end = output.find(end_marker, start)
    if start < 0 or end < 0:
        raise ProvisioningProfileError(f"{label} plist was not emitted")
    try:
        payload = plistlib.loads(output[start : end + len(end_marker)])
    except plistlib.InvalidFileException as error:
        raise ProvisioningProfileError(f"{label} plist is invalid") from error
    if not isinstance(payload, dict):
        raise ProvisioningProfileError(f"{label} must be a dictionary")
    return payload


def validate_signed_app(
    app_path: Path,
    *,
    profile_bytes: bytes,
    profile: dict[str, Any],
    source_entitlements: dict[str, Any],
    bundle_id: str,
    team_id: str,
    application_id: str,
) -> None:
    if not app_path.is_absolute() or not app_path.is_dir() or app_path.is_symlink():
        raise ProvisioningProfileError("signed app path is unsafe")
    embedded_path = app_path / "Contents" / "embedded.provisionprofile"
    embedded_bytes = _read_regular_profile(embedded_path)
    if embedded_bytes != profile_bytes:
        raise ProvisioningProfileError(
            "embedded provisioning profile differs from the verified profile"
        )
    app_info = _read_plist(app_path / "Contents" / "Info.plist", "app Info.plist")
    if app_info.get("CFBundleIdentifier") != bundle_id:
        raise ProvisioningProfileError("signed app bundle identifier changed")

    verified = subprocess.run(
        ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app_path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=60,
    )
    if verified.returncode != 0:
        raise ProvisioningProfileError("signed app failed codesign verification")
    validate_signed_app_certificate(app_path, profile)
    displayed = subprocess.run(
        ["/usr/bin/codesign", "-d", "--entitlements", ":-", str(app_path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=30,
    )
    signed_entitlements = _extract_plist(
        displayed.stdout + b"\n" + displayed.stderr,
        "signed app entitlements",
    )
    if signed_entitlements != source_entitlements:
        raise ProvisioningProfileError(
            "signed app entitlements differ from reviewed release entitlements"
        )
    validate_source_entitlements(
        signed_entitlements,
        bundle_id=bundle_id,
        team_id=team_id,
        application_id=application_id,
    )

    details = subprocess.run(
        ["/usr/bin/codesign", "-dvvv", str(app_path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=30,
    )
    signature_text = (details.stdout + b"\n" + details.stderr).decode(
        "utf-8", errors="replace"
    )
    for marker in (
        f"Identifier={bundle_id}",
        f"TeamIdentifier={team_id}",
        "Authority=Developer ID Application:",
        "Timestamp=",
    ):
        if marker not in signature_text:
            raise ProvisioningProfileError(
                "signed app is missing required Developer ID identity metadata"
            )


def _copy_profile(profile_bytes: bytes, destination: Path) -> None:
    if not destination.is_absolute():
        raise ProvisioningProfileError("embedded profile destination must be absolute")
    parent = destination.parent
    if not parent.is_dir() or parent.is_symlink():
        raise ProvisioningProfileError("embedded profile destination is unsafe")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0)
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(destination, flags, 0o600)
    except OSError as error:
        raise ProvisioningProfileError(
            "embedded provisioning profile already exists or is unsafe"
        ) from error
    try:
        view = memoryview(profile_bytes)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise ProvisioningProfileError(
                    "could not write embedded provisioning profile"
                )
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Validate the external Developer ID distribution profile used by "
            "NeAntik Secure Enclave release enrollment."
        )
    )
    parser.add_argument("--profile", required=True, type=Path)
    parser.add_argument("--info-plist", type=Path, default=DEFAULT_INFO_PLIST)
    parser.add_argument("--entitlements", type=Path, default=DEFAULT_ENTITLEMENTS)
    parser.add_argument("--signing-identity")
    parser.add_argument("--print-signing-identity", action="store_true")
    parser.add_argument("--copy-to", type=Path)
    parser.add_argument("--app", type=Path)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    try:
        info_plist = _read_plist(args.info_plist, "source Info.plist")
        entitlements = _read_plist(args.entitlements, "source entitlements")
        bundle_id, team_id, application_id = expected_release_identity(info_plist)
        validate_source_entitlements(
            entitlements,
            bundle_id=bundle_id,
            team_id=team_id,
            application_id=application_id,
        )
        profile_bytes = _read_regular_profile(args.profile)
        profile = _decode_profile(profile_bytes)
        expiration = validate_profile_payload(
            profile,
            bundle_id=bundle_id,
            team_id=team_id,
            application_id=application_id,
        )
        if args.signing_identity is not None:
            validate_declared_signing_identity(profile, args.signing_identity)
        selected_identity: str | None = None
        if args.print_signing_identity:
            if args.signing_identity is not None:
                raise ProvisioningProfileError(
                    "choose either --signing-identity or --print-signing-identity"
                )
            selected_identity = select_profile_authorized_signing_identity(profile)
        if args.copy_to is not None:
            _copy_profile(profile_bytes, args.copy_to)
        if args.app is not None:
            validate_signed_app(
                args.app,
                profile_bytes=profile_bytes,
                profile=profile,
                source_entitlements=entitlements,
                bundle_id=bundle_id,
                team_id=team_id,
                application_id=application_id,
            )
    except ProvisioningProfileError as error:
        raise SystemExit(f"Direct provisioning profile verification failed: {error}")
    if selected_identity is not None:
        print(selected_identity)
        return
    print(
        "PASS: Developer ID distribution profile authorizes "
        f"{application_id} and expires {expiration.date().isoformat()}."
    )


if __name__ == "__main__":
    main()
