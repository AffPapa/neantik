"""Manager-only signing selection; never changes runtime or source artifacts.

Opt-in capability is sealed in Info.plist only after Apple CMS authentication.
The caller supplies an owned staging app. All signature/profile checks finish
before candidate enrollment. This does not replace notarization/Gatekeeper.
"""
import os
from pathlib import Path
import plistlib
import subprocess
import stat
import tempfile
import uuid

from direct_provisioning_contract import ContractError, PRODUCTION, read_regular

CAPABILITY = "NeAntikBrowserDataBackupEnabled"
CERTIFICATE = "474F7C78F33EE324C24F6F5AE0443EB713E85E60"


def capability_state(app: Path) -> bool:
    info = plistlib.loads(read_regular(app / "Contents/Info.plist"))
    if info.get("CFBundleIdentifier") != PRODUCTION:
        raise ContractError("Production manager identity required")
    value = info.get(CAPABILITY, False)
    if type(value) is not bool:
        raise ContractError("Backup capability must be a boolean")
    if any(key in info for key in ("NeAntikBackupQualificationRunID", "NeAntikBackupQualificationRoot",
                                  "NeAntikBrowserDataBackupDevelopmentEnabled")):
        raise ContractError("QA/development metadata refused in release manager")
    embedded = app / "Contents/embedded.provisionprofile"
    mobile = app / "Contents/embedded.mobileprovision"
    if mobile.exists() or mobile.is_symlink():
        raise ContractError("Mobile provisioning profile refused in macOS release")
    present = embedded.exists() or embedded.is_symlink()
    if present != value:
        raise ContractError("Backup capability and embedded profile must agree")
    if present:
        read_regular(embedded)
    return value


def validate_selection(enabled: str, profile: str | None, identity: str) -> bool:
    if enabled not in ("0", "1"):
        raise ContractError("Explicit backup opt-in must be 0 or 1")
    if (enabled == "1") != bool(profile):
        raise ContractError("Backup opt-in requires an explicit provisioning profile")
    if enabled == "1" and identity.upper() != CERTIFICATE:
        raise ContractError("Backup signing must reuse the pinned Developer ID certificate")
    return enabled == "1"


def run_checked(arguments: list[str]) -> None:
    # No raw paths/profile content or diagnostics from signing reach reports.
    subprocess.run(arguments, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=180)


def seal_capability(app: Path, info: dict, original: bytes) -> None:
    contents = app / "Contents"
    # Atomic replacement never truncates a file an intervening process linked
    # elsewhere. Refuse a replaced/symlink/multi-link original before rename.
    if read_regular(contents / "Info.plist") != original:
        raise ContractError("Staged metadata changed before capability sealing")
    directory = os.open(contents, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    temporary = ".backup-capability-" + uuid.uuid4().hex
    created = False
    try:
        original_stat = os.stat("Info.plist", dir_fd=directory, follow_symlinks=False)
        if not stat.S_ISREG(original_stat.st_mode) or original_stat.st_nlink != 1:
            raise ContractError("Staged metadata is not a single-link regular file")
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     stat.S_IMODE(original_stat.st_mode), dir_fd=directory)
        created = True
        os.fchmod(fd, stat.S_IMODE(original_stat.st_mode))
        with os.fdopen(fd, "wb") as stream:
            stream.write(plistlib.dumps(info)); stream.flush(); os.fsync(stream.fileno())
        current = os.stat("Info.plist", dir_fd=directory, follow_symlinks=False)
        identity = lambda value: (value.st_dev, value.st_ino, value.st_nlink, value.st_size,
                                  value.st_mtime_ns, value.st_ctime_ns)
        if identity(current) != identity(original_stat):
            raise ContractError("Staged metadata changed during capability sealing")
        os.rename(temporary, "Info.plist", src_dir_fd=directory, dst_dir_fd=directory)
        created = False
        os.fsync(directory)
    finally:
        if created: os.unlink(temporary, dir_fd=directory)
        os.close(directory)


def sign_manager(app: Path, identity: str, environment: dict[str, str], run=run_checked) -> None:
    scripts = Path(__file__).resolve().parent
    profile = environment.get("NEANTIK_DIRECT_PROVISIONING_PROFILE")
    enabled = validate_selection(environment.get("NEANTIK_BROWSER_DATA_BACKUP_ENABLED", "0"), profile, identity)
    info_path = app / "Contents/Info.plist"
    original_info = read_regular(info_path)
    info = plistlib.loads(original_info)
    if info.get("CFBundleIdentifier") != PRODUCTION or any(key in info for key in (
            "NeAntikBackupQualificationRunID", "NeAntikBackupQualificationRoot",
            "NeAntikBrowserDataBackupDevelopmentEnabled")):
        raise ContractError("Release identity/metadata refused")
    validator = ["python3", str(scripts / "verify-direct-provisioning-contract.py"),
                 "--bundle", PRODUCTION, "--certificate-sha1", CERTIFICATE]
    embedded = app / "Contents/embedded.provisionprofile"
    if not enabled:
        if capability_state(app):
            raise ContractError("Provisioned source requires explicit provisioning; no silent downgrade")
        entitlements = scripts.parent / "runtime/neantik-direct-entitlements.plist"
        if identity == "-":
            run(["/usr/bin/codesign", "--force", "--options", "runtime", "--sign", "-",
                 "--entitlements", str(entitlements), str(app)])
        else:
            run(["/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp",
                 "--entitlements", str(entitlements), "--sign", identity, str(app)])
        return

    # Authenticate the source profile before any staging mutation. Profile is
    # embedded byte-for-byte; the postcheck compares it with this same input.
    run(validator + ["--profile", profile])
    if embedded.exists() or embedded.is_symlink():
        read_regular(embedded)  # refuses links, oversized and multi-link files
        embedded.unlink()      # only this owned candidate, never source app
    with tempfile.TemporaryDirectory(prefix="neantik-manager-claims-", dir="/private/tmp") as directory:
        claims = Path(directory) / "claims.plist"
        run(validator + ["--profile", profile, "--app", str(app), "--output-entitlements", str(claims)])
        info[CAPABILITY] = True
        seal_capability(app, info, original_info)
        run(["/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp",
             "--entitlements", str(claims), "--sign", CERTIFICATE, str(app)])
        run(validator + ["--profile", profile, "--app", str(app)])
        if not capability_state(app):
            raise ContractError("Signed backup capability missing")


def main() -> None:
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("sign", "state"))
    parser.add_argument("app", type=Path)
    parser.add_argument("identity", nargs="?")
    args = parser.parse_args()
    try:
        if args.operation == "state":
            print("enabled" if capability_state(args.app) else "legacy")
        else:
            if args.identity is None:
                raise ContractError("Signing identity required")
            sign_manager(args.app, args.identity, dict(os.environ))
            print("PASS: manager signed; opt-in provisioning postcheck completed when enabled.")
    except (ContractError, OSError, ValueError, subprocess.SubprocessError):
        parser.exit(65, "Direct manager signing/capability contract refused; candidate is not enrolled.\n")


if __name__ == "__main__":
    main()
