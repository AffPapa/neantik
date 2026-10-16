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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-receipt", type=Path, required=True)
    parser.add_argument("--binary-receipt", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    receipt = json.loads(regular(args.build_receipt))
    if receipt.get("status") != "PASS" or receipt.get("sourceUnchanged") is not True or receipt.get("inputSHA256") != input_digest():
        raise ValueError("Build/source receipt mismatch; do not rebuild blindly")
    binary_root = ROOT / ".build/neantik-local/webkit-isolation/swift/arm64-apple-macosx/debug"
    names = ["IsolationQAController", "IsolationQAHost", "IsolationQADenyProvider"]
    # Hash all input bytes before creating any output. This is assembly, not
    # evidence of a signature, notarization, installed rules or live routing.
    payloads = {name: regular(binary_root / name) for name in names}
    binding = json.loads(regular(args.binary_receipt))
    if (binding.get("buildInputSHA256") != receipt["inputSHA256"]
            or binding.get("binarySHA256") != {name: hashlib.sha256(payloads[name]).hexdigest() for name in names}):
        raise ValueError("Compiled executable binding mismatch")
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
                "CFBundleVersion":"3", "LSMinimumSystemVersion":"14.0", "NeAntikQARunID":run}
        info.update(extra or {})
        validate_usage_description(info)
        infos[identifier] = info
        (contents / "Info.plist").write_bytes(plistlib.dumps(info, sort_keys=True))
        manifest.append({"bundle":str(path.relative_to(destination)),"identifier":identifier,
                         "executableSHA256":hashlib.sha256(payloads[binary]).hexdigest()})

    bundle(root,"IsolationQAController",BASE,"NeAntik Network QA",extra={
        "NSSystemExtensionUsageDescription":USAGE_DESCRIPTION})
    web_extra = {"NSAppTransportSecurity":{"NSAllowsArbitraryLoadsInWebContent":True}}
    bundle(host,"IsolationQAHost",BASE+".profilehost","NeAntik Isolation Host",extra=web_extra)
    bundle(control,"IsolationQAHost",BASE+".control","NeAntik Isolation Control",extra=web_extra)
    bundle(provider,"IsolationQADenyProvider",BASE+".proxy","NeAntik Isolation QA Deny Provider","SYSX",extra={
        "NSSystemExtensionUsageDescription":USAGE_DESCRIPTION,
        "NetworkExtension":{"NEMachServiceName":QA_GROUP+".proxy",
                            "NEProviderClasses":{"com.apple.networkextension.app-proxy":"NeAntikIsolationQADenyProvider"}}})
    entitlement_root = destination / "unsigned-entitlement-templates"
    entitlement_root.mkdir(mode=0o700)
    for name, identifier, extra in [
        ("controller",BASE,{"com.apple.developer.system-extension.install":True,
                            "com.apple.developer.networking.networkextension":["app-proxy-provider-systemextension"]}),
        ("provider",BASE+".proxy",{"com.apple.security.app-sandbox":True,
                                  "com.apple.security.application-groups":[QA_GROUP],
                                  "com.apple.developer.networking.networkextension":["app-proxy-provider-systemextension"]})]:
        value = {"com.apple.application-identifier":TEAM+"."+identifier,
                 "com.apple.developer.team-identifier":TEAM, **extra}
        if name == "provider":
            validate_network_service(infos[identifier], value)
        (entitlement_root/(name+".plist")).write_bytes(plistlib.dumps(value))
    result = {"status":"UNSIGNED;NOT LAUNCHED;NOT INSTALLED", "runID":run,
              "buildInputSHA256":receipt["inputSHA256"],"bundles":manifest,
              "next":"Validate exact DeveloperID provisioning/CMS/certificate;sign with existing certificate;notarize;fresh resource admission and explicit QA-install authorization before launch. No production release.",
              "proof":"Assembly does not prove kernel routing, WebKit attribution or working proxy."}
    (destination/"preparation.json").write_text(json.dumps(result,ensure_ascii=False,indent=2)+"\n")
    print(json.dumps({"status":result["status"],"bundles":len(manifest),"signing":False,"launch":False,"networkSettingsChanged":False}))


if __name__ == "__main__":
    main()
