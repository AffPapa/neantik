#!/usr/bin/env python3
"""Package two fixed update helpers before the outer manager signature.

Does not enable the updater or change Chromium. Only an owned staging app is
mutated. Public SHA-256/CDHash pins are sealed into its Info.plist; keys and
credentials are neither read nor written here.
"""
import hashlib
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import tempfile

from direct_backup_signing import CERTIFICATE, run_checked, seal_capability
from direct_provisioning_contract import ContractError, read_regular

HELPERS = {"owner": "NeAntikUpdateOwner", "assessment": "NeAntikUpdateAssessment"}
PIN_KEY = "NeAntikUpdateHelpers"
MODERN_PIN_KEY = "NeAntikUpdateHelpersV2"


def binary_bytes(path: Path) -> bytes:
    if not path.is_absolute() or any(parent.is_symlink() for parent in path.parents):
        raise ContractError("Helper source must be an absolute non-symlink file")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_uid != os.geteuid() or not 32 <= before.st_size <= 16 * 1024 * 1024:
            raise ContractError("Helper input type, ownership or size refused")
        data = bytearray()
        while len(data) < before.st_size:
            block = os.read(fd, min(1024 * 1024, before.st_size - len(data)))
            if not block: raise ContractError("Helper input truncated")
            data.extend(block)
        after = os.fstat(fd)
        fields = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
        entry = os.stat(path, follow_symlinks=False)
        if fields(before) != fields(after) or fields(before) != fields(entry) or data[:8] != bytes.fromhex("cffaedfe0c000001"):
            raise ContractError("Helper changed or is not thin ARM64")
        return bytes(data)
    finally:
        os.close(fd)


def directory(path: Path) -> None:
    if any(part.is_symlink() for part in (path, *path.parents)):
        raise ContractError("Staging path contains a symlink")
    value = path.stat()
    if not stat.S_ISDIR(value.st_mode) or value.st_uid != os.geteuid() or value.st_mode & 0o7022:
        raise ContractError("Staging directory permissions refused")


def cdhash(path: Path) -> str:
    # Only this public scalar escapes codesign diagnostics; never echo paths.
    result = subprocess.run(["/usr/bin/codesign", "-d", "--verbose=4", str(path)],
                            capture_output=True, check=True, timeout=30)
    match = re.search(rb"^CDHash=([0-9a-f]{40})$", result.stderr, re.MULTILINE)
    if not match: raise ContractError("Helper CodeDirectory hash missing")
    return match[1].decode("ascii")


def legacy_inputs(app: Path, run, inspect) -> tuple[dict, dict]:
    """Hold every selected input identity through native signature checks."""
    held = []
    identity = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns, s.st_nlink, s.st_uid, s.st_mode)
    def retain(path, is_directory=False):
        flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
        if is_directory: flags |= os.O_DIRECTORY
        fd = os.open(path, flags)
        status = os.fstat(fd)
        held.append((fd, path, identity(status)))
        if status.st_uid != os.geteuid() or status.st_mode & 0o7022:
            raise ContractError("Legacy input ownership or permissions refused")
    try:
        directory(app); directory(app / "Contents")
        retain(app, True); retain(app / "Contents", True)
        retain(app / "Contents/Info.plist")
        original = read_regular(app / "Contents/Info.plist")
        info = plistlib.loads(original)
        source = app / "Contents/Helpers"
        directory(source); retain(source, True)
        if MODERN_PIN_KEY in info:
            source = source / "v2"; directory(source); retain(source, True)
        for name in HELPERS.values(): retain(source / name)
        result = _verified_legacy_inputs(app, run, inspect)
        # A file swapped just for codesign must fail even if its bytes were
        # restored afterwards. Retained FDs prevent inode reuse from hiding it.
        for fd, path, expected in held:
            if identity(os.fstat(fd)) != expected or identity(path.stat(follow_symlinks=False)) != expected:
                raise ContractError("Legacy input changed during signature verification")
        if read_regular(app / "Contents/Info.plist") != original:
            raise ContractError("Legacy signed policy changed")
        return result
    finally:
        for fd, _, _ in held: os.close(fd)


def _verified_legacy_inputs(app: Path, run, inspect) -> tuple[dict, dict]:
    """Carry the prior primary, never re-sign or trust an unsigned pin file."""
    directory(app); directory(app / "Contents")
    requirement = 'anchor apple generic and certificate leaf = H"' + CERTIFICATE + '" and identifier "app.neantik.desktop"'
    run(["/usr/bin/codesign", "--verify", "--strict", "--all-architectures", "-R=" + requirement, str(app)])
    info = plistlib.loads(read_regular(app / "Contents/Info.plist"))
    if info.get("CFBundleIdentifier") != "app.neantik.desktop": raise ContractError("Legacy manager identity refused")
    modern = MODERN_PIN_KEY in info
    pins = info.get(MODERN_PIN_KEY if modern else PIN_KEY)
    if not isinstance(pins, dict) or set(pins) != {"schemaVersion", *HELPERS} or type(pins["schemaVersion"]) is not int or pins["schemaVersion"] != (2 if modern else 1):
        raise ContractError("Legacy signed helper policy refused")
    source = app / "Contents/Helpers"
    if modern: source = source / "v2"
    directory(source)
    inputs = {}
    for role, name in HELPERS.items():
        pin = pins[role]
        if not isinstance(pin, dict) or set(pin) != {"sha256", "cdHash"} or not isinstance(pin["sha256"], str) or not isinstance(pin["cdHash"], str) or not re.fullmatch("[0-9a-f]{64}", pin["sha256"]) or not re.fullmatch("[0-9a-f]{40}", pin["cdHash"]):
            raise ContractError("Legacy helper pin refused")
        data = binary_bytes(source / name)
        if hashlib.sha256(data).hexdigest() != pin["sha256"] or inspect(source / name) != pin["cdHash"]:
            raise ContractError("Legacy helper bytes do not match signed policy")
        helper_requirement = 'anchor apple generic and certificate leaf = H"' + CERTIFICATE + '" and identifier "app.neantik.update-' + role + '"'
        run(["/usr/bin/codesign", "--verify", "--strict", "--all-architectures", "-R=" + helper_requirement, str(source / name)])
        inputs[role] = data
    run(["/usr/bin/codesign", "--verify", "--strict", "--all-architectures", "-R=" + requirement, str(app)])
    return inputs, {**pins, "schemaVersion": 1}


def package(app: Path, binaries: Path, identity: str, run=run_checked, inspect=cdhash, legacy_app: Path | None = None) -> dict:
    if identity not in ("-", CERTIFICATE):
        raise ContractError("Update helpers must reuse the pinned Developer ID certificate")
    contents = app / "Contents"
    directory(app); directory(contents)
    original = read_regular(contents / "Info.plist")
    info = plistlib.loads(original)
    if info.get("CFBundleIdentifier") != "app.neantik.desktop":
        raise ContractError("Release manager staging identity required")
    if identity == "-" and info.get("NeAntikUpdateChannelEnabled") is not False:
        raise ContractError("Ad-hoc helpers cannot enable the update channel")
    continuity = info.get("NeAntikUpdateOwnerContinuityRequired", False)
    if type(continuity) is not bool or (continuity and identity == CERTIFICATE and legacy_app is None):
        raise ContractError("Signed updater continuity requires a verified prior app")
    # Admit BOTH inputs before any mutation, including a missing second helper.
    inputs = {role: binary_bytes(binaries / name) for role, name in HELPERS.items()}
    legacy = None
    if legacy_app is not None:
        if identity != CERTIFICATE or legacy_app == app: raise ContractError("Legacy continuity requires the pinned Developer ID and a separate signed app")
        legacy = legacy_inputs(legacy_app, run, inspect)
    helpers = contents / "Helpers"
    if helpers.exists() or helpers.is_symlink(): directory(helpers)
    else: helpers.mkdir(mode=0o755)
    pins = {"schemaVersion": 1}
    scripts = Path(__file__).resolve().parent
    with tempfile.TemporaryDirectory(prefix=".update-helpers-", dir=contents) as temporary:
        staging = Path(temporary)
        for role, name in HELPERS.items():
            target = staging / name
            target.write_bytes(inputs[role]); target.chmod(0o755)
            run(["python3", str(scripts / "sanitize-manager-rpaths.py"), str(target)])
            run(["xcrun", "strip", "-S", str(target)])
            signing = ["/usr/bin/codesign", "--force", "--options", "runtime", "--identifier", "app.neantik.update-" + role,
                       "--sign", identity]
            if identity != "-": signing.append("--timestamp")
            run(signing + [str(target)])  # no entitlements / provisioning grants
            run(["/usr/bin/codesign", "--verify", "--strict", "--all-architectures", str(target)])
            pins[role] = {"sha256": hashlib.sha256(binary_bytes(target)).hexdigest(), "cdHash": inspect(target)}
            if not re.fullmatch("[0-9a-f]{40}", pins[role]["cdHash"]): raise ContractError("Invalid helper pin")
        # No shell follows an existing helper link; replace only fixed entries in
        # this caller-owned staging tree. A failure never enrolls the candidate.
        directory(contents); directory(helpers)
        current_directory = helpers / "v2" if legacy else helpers
        if current_directory.exists() or current_directory.is_symlink(): directory(current_directory)
        destinations = [current_directory / name for name in HELPERS.values()]
        if legacy: destinations += [helpers / name for name in HELPERS.values()]
        for destination in destinations:
            if destination.is_symlink() or (destination.exists() and not destination.is_file()):
                raise ContractError("Existing helper entry refused")
        if legacy:
            if not current_directory.exists(): current_directory.mkdir(mode=0o755)
            for role, name in HELPERS.items():
                carried = staging / ("legacy-" + name)
                carried.write_bytes(legacy[0][role]); carried.chmod(0o755)
                os.replace(carried, helpers / name)
            info[PIN_KEY] = legacy[1]
            info[MODERN_PIN_KEY] = {**pins, "schemaVersion": 2}
        else:
            info[PIN_KEY] = pins
            info.pop(MODERN_PIN_KEY, None)
        for name in HELPERS.values(): os.replace(staging / name, current_directory / name)
        seal_capability(app, info, original)
    return pins


def main() -> None:
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path); parser.add_argument("binaries", type=Path); parser.add_argument("identity")
    args = parser.parse_args()
    try:
        legacy = os.environ.get("NEANTIK_UPDATE_LEGACY_APP")
        package(args.app, args.binaries, args.identity, legacy_app=Path(legacy) if legacy else None)
        print("PASS: fixed update helpers packaged; channel activation unchanged.")
    except (ContractError, OSError, ValueError, subprocess.SubprocessError):
        parser.exit(65, "Update helper packaging refused; candidate is not enrolled.\n")


if __name__ == "__main__": main()
