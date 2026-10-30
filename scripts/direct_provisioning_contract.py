"""Exact Direct claims, separate from decoding and from notarization.

The Security helper authenticates CMS and actual signed code. Python checks the
grants and byte binding. A permissive Keychain group never authorizes a different
App ID. Profile data and signing certificates are not printed or published.
"""
from __future__ import annotations

import datetime as dt
import hashlib
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess

TEAM = "H6VGU2M6JD"
PRODUCTION = "app.neantik.desktop"
QA = PRODUCTION + ".backup-qa"
LIMIT = 2 * 1024 * 1024


class ContractError(ValueError):
    pass


def media_claims(info: dict) -> dict:
    keys = ("NSCameraUsageDescription", "NSMicrophoneUsageDescription")
    flag = info.get("NeAntikWebKitMediaPolicyEnabled")
    if "NeAntikWebKitMediaPolicyEnabled" in info and type(flag) is not bool:
        raise ContractError("Media capability flag must be a boolean")
    if flag is True and not all(key in info for key in keys):
        raise ContractError("Enabled media requires both purpose strings")
    if flag is False and any(key in info for key in keys):
        raise ContractError("Disabled media must not request device capabilities")
    if not any(key in info for key in keys):
        return {}
    if not all(isinstance(info.get(key), str) and info[key].strip() for key in keys):
        raise ContractError("Both camera and microphone purpose strings required")
    return {"com.apple.security.device.camera": True,
            "com.apple.security.device.audio-input": True}


def exact_claims(bundle: str) -> dict:
    if bundle not in (PRODUCTION, QA):
        raise ContractError("Unsupported Direct identity")
    app_id = TEAM + "." + bundle
    return {"com.apple.application-identifier": app_id,
            "com.apple.developer.team-identifier": TEAM,
            "keychain-access-groups": [app_id]}


def grant_allows(grant: object, claim: str) -> bool:
    if not isinstance(grant, str):
        return False
    if "*" not in grant:
        return grant == claim
    # Apple grants may end in '.*', never a caller supplied glob expression.
    return grant.count("*") == 1 and grant.endswith(".*") and claim.startswith(grant[:-1])


def validate_profile(profile: object, bundle: str, certificate_sha1: str,
                     now: dt.datetime | None = None) -> dict:
    claims = exact_claims(bundle)
    now = now or dt.datetime.now(dt.timezone.utc)
    if not isinstance(profile, dict) or profile.get("Platform") != ["OSX"]:
        raise ContractError("Developer ID macOS profile required")
    if profile.get("ProvisionsAllDevices") is not True or "ProvisionedDevices" in profile or profile.get("LocalProvision") is True:
        raise ContractError("All-devices Developer ID distribution required")
    if profile.get("TeamIdentifier") != [TEAM] or profile.get("ApplicationIdentifierPrefix") != [TEAM]:
        raise ContractError("Provisioning team or prefix differs")
    dates = [profile.get("CreationDate"), profile.get("ExpirationDate")]
    if any(not isinstance(value, dt.datetime) for value in dates):
        raise ContractError("Provisioning validity dates required")
    created, expires = [value.replace(tzinfo=dt.timezone.utc) if value.tzinfo is None else value for value in dates]
    if not created <= now < expires:
        raise ContractError("Provisioning profile is expired or not yet valid")
    grants = profile.get("Entitlements")
    if not isinstance(grants, dict) or grants.get("com.apple.developer.team-identifier") != TEAM:
        raise ContractError("Provisioning entitlement team differs")
    if not grant_allows(grants.get("com.apple.application-identifier"), claims["com.apple.application-identifier"]):
        raise ContractError("Provisioning App ID does not authorize this app")
    groups = grants.get("keychain-access-groups")
    if not isinstance(groups, list) or not any(grant_allows(value, claims["keychain-access-groups"][0]) for value in groups):
        raise ContractError("Provisioning profile does not authorize the exact Keychain group")
    if any(key in grants and grants[key] is not False for key in ("get-task-allow", "com.apple.security.get-task-allow")):
        raise ContractError("Development debugging entitlement refused")
    if not re.fullmatch(r"[0-9a-fA-F]{40}", certificate_sha1):
        raise ContractError("Exact signing certificate SHA1 required")
    certificates = profile.get("DeveloperCertificates")
    if not isinstance(certificates, list) or not 1 <= len(certificates) <= 16 or any(not isinstance(value, bytes) or not 1 <= len(value) <= 32768 for value in certificates):
        raise ContractError("Provisioning signing certificates invalid")
    if not any(hashlib.sha1(value).hexdigest() == certificate_sha1.lower() for value in certificates):
        raise ContractError("Provisioning signing certificate differs")
    return claims


def read_regular(path: Path) -> bytes:
    if not path.is_absolute() or any(parent.is_symlink() for parent in path.parents):
        raise ContractError("Absolute non-symlink input required")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or not 0 < before.st_size <= LIMIT:
            raise ContractError("Single-link bounded regular input required")
        with os.fdopen(fd, "rb", closefd=False) as stream:
            data = stream.read(LIMIT + 1)
        after = os.fstat(fd)
        visible = path.stat(follow_symlinks=False)
        identity = lambda item: (item.st_dev, item.st_ino, item.st_size, item.st_mtime_ns, item.st_ctime_ns, item.st_nlink)
        if len(data) != before.st_size or identity(before) != identity(after) or identity(after) != identity(visible):
            raise ContractError("Input changed while being read")
        return data
    finally:
        os.close(fd)


def security_result(helper: Path, arguments: list[str], data: bytes | None = None) -> dict:
    # Only stdout is a machine-readable plist. CLI diagnostics are discarded so
    # private profile/path data never reaches logs through a failed subprocess.
    try:
        result = subprocess.run([str(helper), *arguments], input=data, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, timeout=60, check=True)
        if not 0 < len(result.stdout) <= LIMIT:
            raise ContractError("Security verifier output exceeds limit")
        decoded = plistlib.loads(result.stdout)
        if not isinstance(decoded, dict):
            raise ContractError("Security verifier output invalid")
        return decoded
    except (subprocess.SubprocessError, plistlib.InvalidFileException, OSError) as error:
        raise ContractError("Provisioning or signed-code trust refused") from error


def authenticated_profile(helper: Path, data: bytes, bundle: str, certificate_sha1: str) -> dict:
    profile = security_result(helper, ["profile"], data)
    validate_profile(profile, bundle, certificate_sha1)
    return profile


def verify_app(helper: Path, app: Path, bundle: str, certificate_sha1: str,
               expected_profile: bytes | None = None) -> str:
    claims = exact_claims(bundle)
    if app.is_symlink() or any(parent.is_symlink() for parent in app.parents) or not app.is_absolute():
        raise ContractError("Absolute non-symlink app required")
    embedded = app / "Contents/embedded.provisionprofile"
    # Never fall back from an invalid provisioned app into legacy acceptance.
    provisioned = embedded.exists() or embedded.is_symlink()
    data = read_regular(embedded) if provisioned else None
    if expected_profile is not None and data != expected_profile:
        raise ContractError("Embedded profile missing or byte binding differs")
    profile = authenticated_profile(helper, data, bundle, certificate_sha1) if data is not None else None
    signed = security_result(helper, ["app", str(app), bundle])
    info = plistlib.loads(read_regular(app / "Contents/Info.plist"))
    if info.get("CFBundleIdentifier") != bundle:
        raise ContractError("Signed bundle identity differs")
    if (embedded.exists() or embedded.is_symlink()) != provisioned or (provisioned and read_regular(embedded) != data):
        raise ContractError("Embedded profile changed during signed-code verification")
    leaf = signed.get("certificate")
    if not isinstance(leaf, bytes) or hashlib.sha1(leaf).hexdigest() != certificate_sha1.lower() or signed.get("hardenedRuntime") is not True:
        raise ContractError("Actual signed certificate or hardened runtime differs")
    claims.update(media_claims(info))
    if profile is not None:
        if leaf not in profile["DeveloperCertificates"] or signed.get("entitlements") != claims:
            raise ContractError("Actual signed claims or certificate not authorized")
        return "provisioned"
    if bundle != PRODUCTION or signed.get("entitlements") != {"com.apple.application-identifier": TEAM + "." + PRODUCTION, **media_claims(info)}:
        raise ContractError("Legacy Direct claim contract differs")
    return "legacy"
