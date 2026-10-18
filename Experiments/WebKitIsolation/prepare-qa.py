#!/usr/bin/env python3
"""Assemble fresh UNSIGNED QA bundles from the matching build-only receipt.

No build, signing, launch, preference save, App ID registration or installation.
The controller can change QA settings only after a separately authorized,
properly provisioned/signed/notarized native stage. Production is not touched.
"""
import argparse
import hashlib
import json
from pathlib import Path
import os
import plistlib
import stat
import struct
import uuid

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = Path(__file__).resolve().parent
TEAM = "H6VGU2M6JD"
BASE = "app.neantik.desktop.network-qa"
QA_GROUP = TEAM + "." + BASE
USAGE_DESCRIPTION = "Изолированная QA-проверка только собственного WebKit Host; рабочие приложения не перехватываются."


def validate_usage_description(info):
    # sysextd validates this property on the network system extension itself,
    # in addition to the containing application's activation purpose string.
    if info.get("CFBundleIdentifier") in (BASE, BASE + ".proxy"):
        value = info.get("NSSystemExtensionUsageDescription")
        if not isinstance(value, str) or not value.strip() or len(value) > 1024:
            raise ValueError("Both QA container and network extension require a bounded usage description")


def validate_network_service(info, entitlements):
    """Refuse an unscoped Mach service before signing or Apple submission.

    macOS validates the service against an entitled App Group. This QA-only
    group grants no membership in production containers or Keychain groups.
    """
    network = info.get("NetworkExtension")
    if (info.get("CFBundleIdentifier") != BASE + ".proxy"
            or not isinstance(network, dict)
            or network.get("NEMachServiceName") != QA_GROUP + ".proxy"
            or entitlements.get("com.apple.security.application-groups") != [QA_GROUP]
            or "keychain-access-groups" in entitlements):
        raise ValueError("QA provider requires exactly its dedicated App Group and Mach service")


def input_digest():
    digest = hashlib.sha256()
    for path in sorted(PACKAGE.rglob("*.swift")):
        if ".build" not in path.parts:
            digest.update(str(path.relative_to(ROOT)).encode() + b"\0" + path.read_bytes())
    return digest.hexdigest()


def executable_uuid(data):
    """Read one LC_UUID from a bounded thin ARM64 executable, without running it."""
    if len(data) < 32:
        raise ValueError("Truncated Mach-O header")
    magic, cpu, _, kind, count, size, _, _ = struct.unpack_from("<8I", data)
    if (magic != 0xFEEDFACF or cpu != 0x0100000C or kind != 2
            or not 1 <= count <= 4096 or size > len(data) - 32):
        raise ValueError("Expected thin ARM64 Mach-O executable")
    end = 32 + size
    offset = 32
    found = []
    for _ in range(count):
        if offset + 8 > end:
            raise ValueError("Truncated Mach-O load command")
        command, length = struct.unpack_from("<II", data, offset)
        if length < 8 or length % 8 or offset + length > end:
            raise ValueError("Invalid Mach-O load command size")
        if command == 0x1B:
            if length != 24:
                raise ValueError("Invalid LC_UUID size")
            found.append(uuid.UUID(bytes=data[offset + 8:offset + 24]))
        offset += length
    if offset != end or len(found) != 1 or found[0].int == 0:
        raise ValueError("Executable needs exactly one nonzero UUID")
    return str(found[0])


def distinct_host_uuids(host, control):
    identities = (executable_uuid(host), executable_uuid(control))
    if identities[0] == identities[1]:
        raise ValueError("Independent A/B controls must not share an executable UUID")
    return identities


def regular(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_uid != os.getuid() or before.st_size > 128 * 1024 * 1024:
            raise ValueError("Input must be a bounded single-link owned regular file")
        data = bytearray()
        while len(data) <= before.st_size:
            block = os.read(fd, min(1024 * 1024, before.st_size - len(data) + 1))
            if not block: break
            data.extend(block)
        after, named = os.fstat(fd), path.lstat()
        identity = lambda x: (x.st_dev, x.st_ino, x.st_size, x.st_mtime_ns, x.st_ctime_ns, x.st_nlink)
        if identity(before) != identity(after) or identity(after) != identity(named) or len(data) != before.st_size:
            raise ValueError("Input changed while reading")
        return bytes(data)
    finally:
        os.close(fd)


def qa_bundle_modes(root, executables, *, normalize=False):
    """Make assembled public QA code readable after root-owned OS staging.

    Use only on a fresh owned assembly before signing. The private output
    parent and entitlement templates remain private. Never repair /Library
    staging, frozen signed bundles or a caller-supplied symlink in place.
    """
    paths = [root, *root.rglob("*")]
    executable_paths = {root / name for name in executables}
    if not executable_paths or not executable_paths <= set(paths):
        raise ValueError("Missing declared QA executable")
    planned = []
    # Validate the complete owned tree before changing any mode.
    for path in paths:
        info = path.lstat()
        if info.st_uid != os.getuid() or (not stat.S_ISDIR(info.st_mode)
                and (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1)):
            raise ValueError("QA assembly must contain only owned directories and single-link files")
        mode = 0o755 if stat.S_ISDIR(info.st_mode) or path in executable_paths else 0o644
        planned.append((path, mode, info))
    if any(not stat.S_ISREG(path.lstat().st_mode) for path in executable_paths):
        raise ValueError("Declared QA executable is not a regular file")
    for path, mode, info in planned:
        if normalize:
            path.chmod(mode, follow_symlinks=False)
        elif stat.S_IMODE(info.st_mode) != mode:
            raise ValueError("QA bundle modes must survive root-owned staging: directories/executables755,resources644")


def validate_replacement_build(build, previous, include_filter):
    if build not in ("4", "5", "6") or (build != "4") != include_filter:
        raise ValueError("Explicit QA build must match the opted-in filter surface")
    if previous is not None and (previous, build) not in (("3", "5"), ("5", "6")):
        raise ValueError("Only reviewed inactive QA3->5 or QA5->6 may be prepared")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-receipt", type=Path, required=True)
    parser.add_argument("--binary-receipt", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--include-owned-loopback-filter", action="store_true",
                        help="Prepare an uninstalled QA-only filter; new signed grants/OS consent remain separate")
    parser.add_argument("--qa-build", choices=["4", "5", "6"])
    parser.add_argument("--replace-inactive-qa-build", choices=["3", "5"])
    parser.add_argument("--previous-provider-cdhash")
    args = parser.parse_args()
    build = args.qa_build or ("5" if args.include_owned_loopback_filter else "4")
    validate_replacement_build(build, args.replace_inactive_qa_build, args.include_owned_loopback_filter)
    if args.replace_inactive_qa_build or args.previous_provider_cdhash:
        if (not args.include_owned_loopback_filter or args.replace_inactive_qa_build is None
                or not isinstance(args.previous_provider_cdhash, str)
                or len(args.previous_provider_cdhash) != 40
                or any(char not in "0123456789abcdef" for char in args.previous_provider_cdhash)):
            parser.error("Replacement needs explicit filter opt-in, reviewed inactive QA build and its exact lowercase CDHash")
    receipt = json.loads(regular(args.build_receipt))
    if receipt.get("status") != "PASS" or receipt.get("sourceUnchanged") is not True or receipt.get("inputSHA256") != input_digest():
        raise ValueError("Build/source receipt mismatch; do not rebuild blindly")
    binary_root = ROOT / ".build/neantik-local/webkit-isolation/swift/arm64-apple-macosx/debug"
    names = ["IsolationQAController", "IsolationQAHost", "IsolationQAControl", "IsolationQADenyProvider"]
    # Hash all input bytes before creating any output. This is assembly, not
    # evidence of a signature, notarization, installed rules or live routing.
    payloads = {name: regular(binary_root / name) for name in names}
    binding = json.loads(regular(args.binary_receipt))
    if (binding.get("buildInputSHA256") != receipt["inputSHA256"]
            or binding.get("binarySHA256") != {name: hashlib.sha256(payloads[name]).hexdigest() for name in names}):
        raise ValueError("Compiled executable binding mismatch")
    distinct_host_uuids(payloads["IsolationQAHost"], payloads["IsolationQAControl"])
    destination = args.output.absolute()
    if destination.exists() or destination.is_symlink():
        raise ValueError("Use a fresh QA output directory; never replace a bundle")
    destination.mkdir(mode=0o700, parents=False)
    run = str(uuid.uuid4())
    root = destination / "NeAntik Network QA.app"
    provider = root / "Contents/Library/SystemExtensions" / (BASE + ".proxy.systemextension")
    host = root / "Contents/Helpers/NeAntik Isolation Host.app"
    control = root / "Contents/Helpers/NeAntik Isolation Control.app"
    manifest = []
    infos = {}

    def bundle(path, binary, identifier, title, package_type="APPL", extra=None):
        contents = path / "Contents"
        executable = contents / "MacOS" / binary
        executable.parent.mkdir(parents=True, mode=0o700)
        executable.write_bytes(payloads[binary]); executable.chmod(0o700)
        info = {"CFBundleExecutable":binary, "CFBundleIdentifier":identifier,
                "CFBundleName":title, "CFBundleDisplayName":title,
                "CFBundlePackageType":package_type, "CFBundleShortVersionString":"0.0.0",
                "CFBundleVersion":build, "LSMinimumSystemVersion":"14.0", "NeAntikQARunID":run}
        info.update(extra or {})
        validate_usage_description(info)
        infos[identifier] = info
        (contents / "Info.plist").write_bytes(plistlib.dumps(info, sort_keys=True))
        manifest.append({"bundle":str(path.relative_to(destination)),"identifier":identifier,
                         "executableUUID":executable_uuid(payloads[binary]),
                         "executableSHA256":hashlib.sha256(payloads[binary]).hexdigest()})

    controller_extra = {
        "NSSystemExtensionUsageDescription":USAGE_DESCRIPTION,
        "NeAntikQALoopbackFilterIncluded":args.include_owned_loopback_filter}
    if args.replace_inactive_qa_build:
        controller_extra.update(NeAntikQAReplacementFromBuild=args.replace_inactive_qa_build,
                                NeAntikQAPreviousProviderCDHash=args.previous_provider_cdhash)
    bundle(root,"IsolationQAController",BASE,"NeAntik Network QA",extra=controller_extra)
    web_extra = {"NSAppTransportSecurity":{"NSAllowsArbitraryLoadsInWebContent":True}}
    bundle(host,"IsolationQAHost",BASE+".profilehost","NeAntik Isolation Host",extra=web_extra)
    bundle(control,"IsolationQAControl",BASE+".control","NeAntik Isolation Control",extra=web_extra)
    classes = {"com.apple.networkextension.app-proxy":"NeAntikIsolationQADenyProvider"}
    if args.include_owned_loopback_filter:
        classes["com.apple.networkextension.filter-data"] = "NeAntikIsolationQALoopbackFilter"
    network_grants = ["app-proxy-provider-systemextension"]
    if args.include_owned_loopback_filter:
        network_grants.append("content-filter-provider-systemextension")
    bundle(provider,"IsolationQADenyProvider",BASE+".proxy","NeAntik Isolation QA Deny Provider","SYSX",extra={
        "NSSystemExtensionUsageDescription":USAGE_DESCRIPTION,
        "NetworkExtension":{"NEMachServiceName":QA_GROUP+".proxy",
                            "NEProviderClasses":classes}})
    executable_paths = [str((destination / item["bundle"] / "Contents/MacOS" /
                            infos[item["identifier"]]["CFBundleExecutable"]).relative_to(root))
                        for item in manifest]
    qa_bundle_modes(root, executable_paths, normalize=True)
    qa_bundle_modes(root, executable_paths)
    entitlement_root = destination / "unsigned-entitlement-templates"
    entitlement_root.mkdir(mode=0o700)
    for name, identifier, extra in [
        ("controller",BASE,{"com.apple.developer.system-extension.install":True,
                            "com.apple.developer.networking.networkextension":network_grants}),
        ("provider",BASE+".proxy",{"com.apple.security.app-sandbox":True,
                                  "com.apple.security.application-groups":[QA_GROUP],
                                  "com.apple.developer.networking.networkextension":network_grants})]:
        value = {"com.apple.application-identifier":TEAM+"."+identifier,
                 "com.apple.developer.team-identifier":TEAM, **extra}
        if name == "provider":
            validate_network_service(infos[identifier], value)
        (entitlement_root/(name+".plist")).write_bytes(plistlib.dumps(value))
    result = {"status":"UNSIGNED;NOT LAUNCHED;NOT INSTALLED", "runID":run, "internalQABuild":build,
              "ownedLoopbackFilterIncluded":args.include_owned_loopback_filter,
              "inactiveQAReplacementFromBuild":args.replace_inactive_qa_build,
              "buildInputSHA256":receipt["inputSHA256"],"bundles":manifest,
              "bundleModes":"directories/executables755;resources644;private output/templates unchanged",
              "next":"Validate exact DeveloperID provisioning/CMS/certificate;sign with existing certificate;notarize;fresh resource admission and explicit QA-install authorization before launch. No production release.",
              "proof":"Assembly does not prove kernel routing, WebKit attribution or working proxy."}
    (destination/"preparation.json").write_text(json.dumps(result,ensure_ascii=False,indent=2)+"\n")
    print(json.dumps({"status":result["status"],"bundles":len(manifest),"signing":False,"launch":False,"networkSettingsChanged":False}))


if __name__ == "__main__":
    main()
