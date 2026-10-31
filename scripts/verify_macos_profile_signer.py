#!/usr/bin/env python3
"""Fail closed unless an embedded macOS provisioning profile authorizes its app signer."""
from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import re
import subprocess
import tempfile
from pathlib import Path
from typing import Any


class ProfileVerificationError(RuntimeError):
    pass


def profile_allows_value(allowed: Any, requested: Any) -> bool:
    """Match exact profile values and Apple's trailing wildcard form."""
    if isinstance(allowed, str) and isinstance(requested, str):
        return allowed == requested or (allowed.endswith(".*") and requested.startswith(allowed[:-1]))
    if isinstance(allowed, list):
        return any(profile_allows_value(item, requested) for item in allowed)
    return False


def validate_profile_contract(
    *,
    bundle_id: str,
    signing_identifier: str,
    signing_team: str,
    signing_certificate_sha256: str,
    signing_entitlements: dict[str, Any],
    profile: dict[str, Any],
) -> dict[str, Any]:
    """Check bundle, team, restricted entitlements, and exact leaf certificate membership."""
    profile_entitlements = profile.get("Entitlements")
    if not isinstance(profile_entitlements, dict):
        raise ProfileVerificationError("profile_entitlements_missing")

    expected_identifier = f"{signing_team}.{bundle_id}"
    # The CodeDirectory Identifier is the bundle ID. Some valid Developer ID
    # apps have no explicit entitlement blob; in that case the profile still
    # binds the app ID and the actual signing certificate. If Apple embedded
    # an explicit application identifier/team claim, require it to agree.
    if signing_identifier != bundle_id:
        raise ProfileVerificationError("signed_identifier_mismatch")
    signed_app_identifier = signing_entitlements.get("com.apple.application-identifier")
    if signed_app_identifier is not None and signed_app_identifier != expected_identifier:
        raise ProfileVerificationError("signed_application_identifier_mismatch")
    app_identifier = profile_entitlements.get("com.apple.application-identifier")
    if not profile_allows_value(app_identifier, expected_identifier):
        raise ProfileVerificationError("profile_application_identifier_mismatch")

    profile_teams = profile.get("TeamIdentifier")
    profile_entitlement_team = profile_entitlements.get("com.apple.developer.team-identifier")
    if signing_team not in (profile_teams or []) or profile_entitlement_team != signing_team:
        raise ProfileVerificationError("profile_team_mismatch")
    signed_team = signing_entitlements.get("com.apple.developer.team-identifier")
    if signed_team is not None and signed_team != signing_team:
        raise ProfileVerificationError("signed_team_mismatch")

    allowed_certificates = {
        hashlib.sha256(bytes(certificate)).hexdigest().upper()
        for certificate in profile.get("DeveloperCertificates", [])
    }
    signer_sha256 = signing_certificate_sha256.replace(":", "").upper()
    if not re.fullmatch(r"[0-9A-F]{64}", signer_sha256):
        raise ProfileVerificationError("signing_certificate_digest_invalid")
    if signer_sha256 not in allowed_certificates:
        raise ProfileVerificationError("signing_certificate_not_in_profile")

    for entitlement in ("keychain-access-groups", "com.apple.security.application-groups"):
        for value in signing_entitlements.get(entitlement, []):
            if not profile_allows_value(profile_entitlements.get(entitlement), value):
                raise ProfileVerificationError(f"profile_{entitlement.replace('-', '_')}_mismatch")

    return {
        "status": "PASS",
        "bundleIdentifier": bundle_id,
        "teamIdentifier": signing_team,
        "applicationIdentifier": expected_identifier,
        "signingCertificateSHA256": signer_sha256,
        "profileUUID": profile.get("UUID"),
        "profileName": profile.get("Name"),
        "profileIncludesSigningCertificate": True,
    }


def run_checked(args: list[str]) -> bytes:
    try:
        return subprocess.run(args, check=True, capture_output=True, timeout=15).stdout
    except (OSError, subprocess.SubprocessError) as error:
        raise ProfileVerificationError("required_macos_verifier_failed") from error


def extract_signed_entitlements(app: Path) -> dict[str, Any]:
    """Read the signature's XML entitlement payload; an absent payload is valid."""
    try:
        result = subprocess.run(
            ["/usr/bin/codesign", "--display", "--entitlements", "-", "--xml", str(app)],
            check=True, capture_output=True, timeout=15,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise ProfileVerificationError("required_macos_verifier_failed") from error
    if not result.stdout:
        return {}
    try:
        value = plistlib.loads(result.stdout)
    except plistlib.InvalidFileException as error:
        raise ProfileVerificationError("signed_entitlements_decode_failed") from error
    if not isinstance(value, dict):
        raise ProfileVerificationError("signed_entitlements_decode_failed")
    return value


def inspect_app(app: Path) -> dict[str, Any]:
    if app.is_symlink() or not app.is_dir():
        raise ProfileVerificationError("app_path_invalid")
    profile_path = app / "Contents" / "embedded.provisionprofile"
    info_path = app / "Contents" / "Info.plist"
    if profile_path.is_symlink() or not profile_path.is_file() or info_path.is_symlink() or not info_path.is_file():
        raise ProfileVerificationError("embedded_profile_or_info_missing")
    try:
        profile = plistlib.loads(run_checked(["/usr/bin/security", "cms", "-D", "-i", str(profile_path)]))
        info = plistlib.loads(info_path.read_bytes())
    except (plistlib.InvalidFileException, OSError) as error:
        raise ProfileVerificationError("profile_or_info_decode_failed") from error

    with tempfile.TemporaryDirectory(prefix="neantik-profile-certs-") as temporary:
        prefix = str(Path(temporary) / "signer-")
        run_checked(["/usr/bin/codesign", "--display", f"--extract-certificates={prefix}", str(app)])
        leaf_path = Path(prefix + "0")
        if not leaf_path.is_file():
            raise ProfileVerificationError("signing_certificate_missing")
        signer_sha256 = hashlib.sha256(leaf_path.read_bytes()).hexdigest().upper()

    details = run_checked(["/usr/bin/codesign", "--display", "--verbose=4", str(app)]).decode("utf-8", "replace")
    # codesign writes display details to stderr on supported macOS versions.
    if not details:
        result = subprocess.run(["/usr/bin/codesign", "--display", "--verbose=4", str(app)], capture_output=True, timeout=15)
        details = (result.stderr or result.stdout).decode("utf-8", "replace")
    identifier = re.search(r"^Identifier=(.+)$", details, re.MULTILINE)
    team = re.search(r"^TeamIdentifier=(.+)$", details, re.MULTILINE)
    signed_entitlements = extract_signed_entitlements(app)

    bundle_id = info.get("CFBundleIdentifier")
    if not bundle_id or not identifier or not team:
        raise ProfileVerificationError("signed_identity_metadata_missing")
    return validate_profile_contract(
        bundle_id=bundle_id,
        signing_identifier=identifier.group(1).strip(),
        signing_team=team.group(1).strip(),
        signing_certificate_sha256=signer_sha256,
        signing_entitlements=signed_entitlements,
        profile=profile,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="Signed macOS .app bundle")
    args = parser.parse_args()
    try:
        print(json.dumps(inspect_app(args.app), ensure_ascii=False, sort_keys=True))
        return 0
    except ProfileVerificationError as error:
        print(json.dumps({"status": "FAIL", "reason": str(error)}, sort_keys=True))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
