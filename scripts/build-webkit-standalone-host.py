#!/usr/bin/env python3
"""Build the independent WebKit host from an explicit, audited source set."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
TARGET = ROOT / "DerivedSources/NeAntikWebKitHost"
SOURCES = (
    "WebKitHostChildRuntime.swift", "WebKitProfileBrowser.swift",
    "WebKitHostChildBootstrap.swift", "WebKitHostCodeIdentity.swift",
    "WebKitHostIPC.swift", "WebKitRuntimeImageAttestation.swift",
    "WebKitHostLeaseReservation.swift", "WebKitHostReadOnlyLease.swift",
    "WebKitHostProfileReader.swift", "WebKitOwnedNetworkProcessPID.swift",
    "WebKitProxyConfigurationFactory.swift",
    "WebKitSessionStore.swift", "WebKitSessionCheckpointer.swift",
    "WebKitDownloads.swift", "WebKitMediaPolicy.swift",
    "ProxyRelayPrivatePipe.swift", "WebKitBrokerPort.swift",
    "AppPaths.swift", "Models.swift", "BrowserStartURL.swift",
    "ManagerLaunchAdmission.swift", "ApplicationUpdateAdmission.swift",
    "ProxyRelaySocketOwnerInspector.swift",
    "DirectUpdateCoreExports.swift",
)
SYSTEM_WEBKIT = "/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit"
OWNED_WEBKIT = "@rpath/WebKit.framework/Versions/A/WebKit"
OWNED_RPATH = "@executable_path/../Frameworks"


def prepare() -> dict[str, str]:
    TARGET.mkdir(parents=True, exist_ok=True)
    expected = {"HostEntry.swift", *SOURCES}
    retired_generated = {"main.swift", "WebKitRelayAuthority.swift",
                         "WebKitProxySession.swift", "WebKitProxyConnectCodec.swift",
                         "WebKitNetworkProcessCodeIdentity.swift", "ApplicationEnvironment.swift"}
    for stale in TARGET.glob("*.swift"):
        if stale.name not in expected:
            if stale.name not in retired_generated:
                raise RuntimeError(f"Unexpected generated host source: {stale.name}")
            stale.unlink()
    shutil.copyfile(ROOT / "Sources/WebKitHostEntry/HostEntry.swift", TARGET / "HostEntry.swift")
    hashes: dict[str, str] = {}
    for name in SOURCES:
        source = ROOT / "Sources/NeAntik" / name
        data = source.read_bytes()
        if b"import SwiftUI" in data or b"@main" in data:
            raise RuntimeError(f"Manager/UI source entered WebKit host: {name}")
        (TARGET / name).write_bytes(data)
        hashes[name] = hashlib.sha256(data).hexdigest()
    hashes["HostEntry.swift"] = hashlib.sha256((TARGET / "HostEntry.swift").read_bytes()).hexdigest()
    return hashes


def stage_owned_host(binary: Path) -> Path:
    """Rebind only a copy; reject every unapproved system or absolute path."""
    linked = subprocess.check_output(["/usr/bin/otool", "-L", str(binary)], text=True)
    if linked.count(SYSTEM_WEBKIT) != 1 or "SwiftUI.framework" in linked or "libswiftWebKit" in linked:
        raise RuntimeError("Standalone host has an unexpected system engine/UI dependency")
    output = binary.with_name("NeAntikWebKitHost-owned")
    shutil.copy2(binary, output)
    commands = subprocess.check_output(["/usr/bin/otool", "-l", str(output)], text=True)
    rpaths = re.findall(r"cmd LC_RPATH\n\s*cmdsize \d+\n\s*path (.+?) \(offset \d+\)", commands)
    for path in rpaths:
        if path not in {"/usr/lib/swift", "@loader_path"}:
            subprocess.run(["/usr/bin/install_name_tool", "-delete_rpath", path, str(output)], check=True)
    subprocess.run(["/usr/bin/install_name_tool", "-change", SYSTEM_WEBKIT, OWNED_WEBKIT,
                    "-add_rpath", OWNED_RPATH, str(output)], check=True)
    linked = subprocess.check_output(["/usr/bin/otool", "-L", str(output)], text=True)
    commands = subprocess.check_output(["/usr/bin/otool", "-l", str(output)], text=True)
    rpaths = re.findall(r"cmd LC_RPATH\n\s*cmdsize \d+\n\s*path (.+?) \(offset \d+\)", commands)
    if linked.count(OWNED_WEBKIT) != 1 or SYSTEM_WEBKIT in linked or "SwiftUI.framework" in linked \
            or "libswiftWebKit" in linked or rpaths.count(OWNED_RPATH) != 1 \
            or any(path not in {"/usr/lib/swift", "@loader_path", OWNED_RPATH} for path in rpaths):
        raise RuntimeError("Owned WebKit host closure refused after rebinding")
    return output


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--configuration", choices=("debug", "release"), default="debug")
    parser.add_argument("--qa-proxy", action="store_true",
                        help="compile the private Dev-only WebKit proxy qualification gate")
    parser.add_argument("--production-proxy", action="store_true",
                        help="compile the production proxy feature gate; does not qualify or package a release")
    args = parser.parse_args()
    if args.qa_proxy and args.production_proxy:
        parser.error("--qa-proxy and --production-proxy are mutually exclusive")
    hashes = prepare()
    print(json.dumps({"target": str(TARGET), "sourceCount": len(hashes), "sourcesSHA256": hashes}, sort_keys=True))
    if args.prepare_only:
        return
    developer_dir = subprocess.check_output(
        [str(ROOT / "scripts/resolve-compatible-developer-dir.sh")], text=True).strip()
    cache = ROOT / ".build/neantik-local"
    module_cache = cache / "clang-module-cache"
    module_cache.mkdir(parents=True, exist_ok=True)
    env = {**os.environ, "DEVELOPER_DIR": developer_dir,
           "CLANG_MODULE_CACHE_PATH": str(module_cache),
           "SWIFTPM_MODULECACHE_OVERRIDE": str(module_cache)}
    env["NEANTIK_WEBKIT_PROXY_BUILD_MODE"] = (
        "qualification" if args.qa_proxy else
        "production" if args.production_proxy else
        "disabled")
    build_args = ["swift", "build", "--disable-sandbox", "--configuration", args.configuration]
    if args.configuration == "release":
        # No dSYM is shipped. Avoid a separate dsymutil child that the managed
        # build sandbox cannot write, while keeping optimized product bytes.
        build_args += ["-debug-info-format", "none"]
    common_args = ["--scratch-path", str(cache / "webkit-standalone-host"),
                   "--cache-path", str(cache / "cache"), "-j", "2"]
    subprocess.run(build_args + common_args + ["--product", "NeAntikWebKitHost"],
                   check=True, cwd=ROOT, env=env)
    # SwiftPM has emitted this target under both out/Products and a target
    # triple directory on this Mac. Ask the same invocation for its actual
    # product directory instead of staging an older file from a guessed path.
    bin_path = subprocess.check_output(build_args + common_args + ["--show-bin-path"],
                                       cwd=ROOT, env=env, text=True).strip()
    binary = Path(bin_path) / "NeAntikWebKitHost"
    if not binary.is_file() or binary.is_symlink() or not binary.resolve().is_relative_to(
            (cache / "webkit-standalone-host").resolve()):
        raise RuntimeError("SwiftPM did not return this build's host product")
    binary_hash = hashlib.sha256(binary.read_bytes()).hexdigest()
    owned = stage_owned_host(binary)
    status = ("built-private-qa" if args.qa_proxy else
              "built-production-mode-unqualified" if args.production_proxy else
              "built-unqualified")
    print(json.dumps({"status": status,
                      "qaProxy": args.qa_proxy,
                      "productionProxy": args.production_proxy, "binary": str(binary),
                      "binarySHA256": binary_hash,
                      "ownedBinary": str(owned),
                      "ownedSHA256": hashlib.sha256(owned.read_bytes()).hexdigest()}, sort_keys=True))


if __name__ == "__main__":
    main()
