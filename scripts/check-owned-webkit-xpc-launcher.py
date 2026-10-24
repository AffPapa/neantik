#!/usr/bin/env python3
"""Fail before a WebKit build if its macOS XPC launcher still names Apple services."""
from __future__ import annotations

import argparse
from pathlib import Path
import plistlib
import re
import subprocess


OWNED = "app.neantik.desktop.webkit"
SERVICES = {
    "WebContent": "WebContent",
    "Networking": "Networking",
    "GPU": "GPU",
}


def check_compiled_network_launcher(image: Path) -> None:
    """Catch a stale WebKit image even when its source and XPC plists are fixed."""
    if image.is_symlink() or not image.is_file():
        raise ValueError("owned WebKit image is missing or unsafe")
    contents = image.read_bytes()
    if (b"app.neantik.desktop.webkit.Networking\x00" not in contents
            or b"com.apple.WebKit.Networking\x00" in contents):
        raise ValueError("compiled WebKit still selects the system Networking XPC")


def check_mach_exception_feature(source_root: Path, frameworks: Path) -> None:
    """SDK 27 moved mach_exc.defs; losing the probe crashes sandboxed WebContent."""
    header = (source_root / "Source/WTF/wtf/PlatformHave.h").read_text()
    if "__has_include(<Kernel/mach/mach_exc.defs>)" not in header:
        raise ValueError("WebKit source lacks the SDK 27 Mach-exception probe")
    image = frameworks / "JavaScriptCore.framework/Versions/A/JavaScriptCore"
    if image.is_symlink() or not image.is_file():
        raise ValueError("compiled JavaScriptCore image is missing or unsafe")
    symbols = subprocess.run(["nm", "-n", str(image)], capture_output=True, text=True,
                             check=False)
    if symbols.returncode != 0 or "handleSignalsWithMach" not in symbols.stdout:
        raise ValueError("compiled JavaScriptCore lacks Mach exception handling")


def check(source_root: Path, frameworks: Path | None = None) -> None:
    launcher = (source_root / "Source/WebKit/UIProcess/Launcher/cocoa/ProcessLauncherCocoa.mm").read_text()
    names = (source_root / "Source/WebKit/Shared/WebKitServiceNames.h").read_text()
    start = launcher.index("static ASCIILiteral serviceName(")
    end = launcher.index("#endif // !USE(EXTENSIONKIT) || !PLATFORM(IOS)", start)
    xpc_branch = launcher[start:end]
    required = (
        '#import "WebKitServiceNames.h"',
        'return selectedWebContentServiceName(launchOptions, client);',
        'return networkingServiceName;',
        'return gpuServiceName;',
    )
    if any(item not in launcher if item.startswith("#import") else item not in xpc_branch
           for item in required):
        raise ValueError("XPC launcher does not use the owned service-name contract")
    mac_start = names.index("#if PLATFORM(MAC)")
    mac_end = names.index("#else", mac_start)
    mac_names = names[mac_start:mac_end]
    for identifier in SERVICES.values():
        if f'"{OWNED}.{identifier}"_s' not in mac_names:
            raise ValueError(f"Missing owned {identifier} service name")
    web_start = launcher.index("static ASCIILiteral selectedWebContentServiceName(")
    web_end = launcher.index("static ASCIILiteral serviceName(", web_start)
    web_branch = launcher[web_start:web_end]
    if not re.search(r"#if PLATFORM\(MAC\).*?return webContentServiceName;.*?#else", web_branch, re.S):
        raise ValueError("WebContent launcher does not select its owned macOS service")
    for suffix in ("CaptivePortal", "EnhancedSecurity"):
        if f'"{OWNED}.WebContent.{suffix}"_s' not in web_branch:
            raise ValueError(f"Missing owned WebContent {suffix} service")
    if frameworks is not None:
        check_compiled_network_launcher(
            frameworks / "WebKit.framework/Versions/A/WebKit")
        check_mach_exception_feature(source_root, frameworks)
        xpc_root = frameworks / "WebKit.framework/Versions/A/XPCServices"
        expected = {f"{OWNED}.{name}" for name in
                    ("Networking", "GPU", "WebContent", "WebContent.CaptivePortal", "WebContent.EnhancedSecurity")}
        observed: set[str] = set()
        for xpc in xpc_root.glob("*.xpc"):
            if xpc.is_symlink() or not xpc.is_dir():
                raise ValueError("XPC bundle path is unsafe")
            info = plistlib.loads((xpc / "Contents/Info.plist").read_bytes())
            identifier = info.get("CFBundleIdentifier")
            if identifier != xpc.stem or identifier in observed:
                raise ValueError("XPC bundle identifier differs from its path")
            observed.add(identifier)
        if observed != expected:
            raise ValueError("XPC service set differs from owned launcher names")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--frameworks", type=Path)
    args = parser.parse_args()
    check(args.source_root, args.frameworks)
    print("PASS owned WebKit XPC launcher/source/package identity")


if __name__ == "__main__":
    main()
