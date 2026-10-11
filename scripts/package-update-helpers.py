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


def package(app: Path, binaries: Path, identity: str, run=run_checked, inspect=cdhash) -> dict:
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
    # Admit BOTH inputs before any mutation, including a missing second helper.
    inputs = {role: binary_bytes(binaries / name) for role, name in HELPERS.items()}
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
        for role, name in HELPERS.items():
            destination = helpers / name
            if destination.is_symlink() or (destination.exists() and not destination.is_file()):
                raise ContractError("Existing helper entry refused")
        for name in HELPERS.values(): os.replace(staging / name, helpers / name)
        info[PIN_KEY] = pins
        seal_capability(app, info, original)
    return pins


def main() -> None:
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path); parser.add_argument("binaries", type=Path); parser.add_argument("identity")
    args = parser.parse_args()
    try:
        package(args.app, args.binaries, args.identity)
        print("PASS: fixed update helpers packaged; channel activation unchanged.")
    except (ContractError, OSError, ValueError, subprocess.SubprocessError):
        parser.exit(65, "Update helper packaging refused; candidate is not enrolled.\n")


if __name__ == "__main__": main()
