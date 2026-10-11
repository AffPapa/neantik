#!/usr/bin/env python3
"""Opt-in Direct provisioning preparation/postcheck; legacy signing unchanged.

The helper is compiled into a disposable build directory using the project
developer-dir resolver. Private Apple policy is used only by this build tool;
absence of that policy is a hard refusal. This is not a notarization gate.
"""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

from direct_provisioning_contract import (
    ContractError, PRODUCTION, QA, authenticated_profile, exact_claims,
    read_regular, verify_app,
)


def prepare_outputs(app: Path, output: Path, profile: bytes, bundle: str) -> None:
    embedded = app / "Contents/embedded.provisionprofile"
    info = plistlib.loads(read_regular(app / "Contents/Info.plist"))
    if info.get("CFBundleIdentifier") != bundle:
        raise ContractError("Bundle identity differs before signing")
    destinations = [(output, plistlib.dumps(exact_claims(bundle))), (embedded, profile)]
    for path, _ in destinations:
        if not path.is_absolute() or path.exists() or path.is_symlink() or any(parent.is_symlink() for parent in path.parents):
            raise ContractError("New non-symlink signing outputs required")
    created = []
    try:
        for path, data in destinations:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            created.append(path)
            with os.fdopen(fd, "wb") as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
    except BaseException:
        for path in created:
            path.unlink(missing_ok=True)
        raise


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", type=Path)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--bundle", choices=(PRODUCTION, QA), required=True)
    parser.add_argument("--certificate-sha1", required=True)
    parser.add_argument("--output-entitlements", type=Path,
                        help="Prepare new entitlement and embedded profile files before signing")
    args = parser.parse_args()
    if args.profile is None and args.app is None:
        parser.error("Provide a profile or signed app")
    if args.output_entitlements is not None and (args.profile is None or args.app is None):
        parser.error("Preparation requires profile and unsigned app")
    repo = Path(__file__).resolve().parents[1]
    env = os.environ.copy()
    env["DEVELOPER_DIR"] = subprocess.run(
        [str(repo / "scripts/resolve-compatible-developer-dir.sh")], check=True,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
    ).stdout.strip()
    with tempfile.TemporaryDirectory(prefix="neantik-provisioning-validator-", dir="/private/tmp") as directory:
        helper = Path(directory) / "verify-security"
        try:
            subprocess.run(["/usr/bin/xcrun", "clang", "-O2", "-Werror", "-Wno-deprecated-declarations",
                            "-mmacosx-version-min=14.0", "-framework", "Security", "-framework", "CoreFoundation",
                            str(repo / "scripts/direct-provisioning-security.c"), "-o", str(helper)],
                           check=True, timeout=60, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except subprocess.SubprocessError as error:
            raise ContractError("macOS Security validator could not be built") from error
        data = read_regular(args.profile) if args.profile is not None else None
        if data is not None:
            authenticated_profile(helper, data, args.bundle, args.certificate_sha1)
        if args.output_entitlements is not None:
            prepare_outputs(args.app, args.output_entitlements, data, args.bundle)
            print("PASS: exact scoped claims and authenticated profile prepared; signed app postcheck still required.")
        elif args.app is not None:
            mode = verify_app(helper, args.app, args.bundle, args.certificate_sha1, data)
            print(f"PASS: {mode} Direct signed claims/certificate/profile contract; notarization remains a separate gate.")
        else:
            print("PASS: authenticated macOS Developer ID profile grants exact claims and certificate; no app or Keychain access tested.")


if __name__ == "__main__":
    try:
        main()
    except (ContractError, OSError, ValueError, subprocess.SubprocessError) as error:
        # Never echo a subprocess, profile contents or private input path.
        print("FAIL: Direct provisioning contract refused. " + (str(error) if isinstance(error, ContractError) else "Invalid or inaccessible signing input."))
        raise SystemExit(65)
