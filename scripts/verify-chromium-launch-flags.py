#!/usr/bin/env python3
"""Bind NeAntik's protected launch flags to Chromium's current source.

Command-line switches and feature names can disappear or be renamed between
Chromium releases. A flag that is merely present in Swift but absent from the
exact browser source is not a security control, so release builds fail closed
when this small contract drifts.
"""

from __future__ import annotations

import argparse
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
MANAGER_SOURCE = PROJECT_ROOT / "Sources/NeAntik/BrowserProcessManager.swift"
POLICY_SOURCE = PROJECT_ROOT / "Sources/NeAntik/BrowserLaunchPolicy.swift"


class VerificationError(ValueError):
    pass


REQUIRED_SOURCE_MARKERS = {
    "chrome/common/chrome_switches.cc": (
        'const char kNoProxyServer[] = "no-proxy-server";',
        'const char kProxyBypassList[] = "proxy-bypass-list";',
    ),
    "components/network_session_configurator/common/network_switch_list.h": (
        'NETWORK_SWITCH(kDisableQuic, "disable-quic")',
    ),
    "services/network/public/cpp/network_switches.cc": (
        'const char kHostResolverRules[] = "host-resolver-rules";',
    ),
    "net/base/features.cc": (
        "BASE_FEATURE(kAsyncDns,",
    ),
    "services/network/public/cpp/features.cc": (
        "BASE_FEATURE(kDnsOverHttpsUpgrade,",
    ),
    "gpu/config/gpu_finch_features.cc": (
        "BASE_FEATURE(kWebGPUService, WEBGPU_ENABLED);",
    ),
}

REQUIRED_MANAGER_MARKERS = (
    '"--no-proxy-server"',
    '"--disable-quic"',
    '"--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE \\(proxy.host)"',
    '"DnsOverHttpsUpgrade"',
    '"AsyncDns"',
    '"WebGPUService"',
)

FORBIDDEN_MANAGER_MARKERS = (
    '"--disable-background-mode"',
    '"--dns-prefetch-disable"',
    '"--timezone=',
    '"DnsOverHttps"',
)


def verify(source_root: Path, manager_source: Path | None = None) -> None:
    source_root = source_root.resolve()
    if not source_root.is_dir():
        raise VerificationError("Chromium source root is missing")
    for relative, markers in REQUIRED_SOURCE_MARKERS.items():
        path = source_root / relative
        if not path.is_file() or path.is_symlink():
            raise VerificationError(
                f"Required Chromium launch source is missing: {relative}"
            )
        text = path.read_text(encoding="utf-8")
        for marker in markers:
            if marker not in text:
                raise VerificationError(
                    f"Chromium launch flag contract changed: {relative}"
                )

    manager_sources = (
        [manager_source]
        if manager_source is not None
        else [MANAGER_SOURCE, POLICY_SOURCE]
    )
    for source in manager_sources:
        if not source.is_file() or source.is_symlink():
            raise VerificationError(
                f"NeAntik browser launch source is missing: {source.name}"
            )
    manager_text = "\n".join(
        source.read_text(encoding="utf-8") for source in manager_sources
    )
    for marker in REQUIRED_MANAGER_MARKERS:
        if marker not in manager_text:
            raise VerificationError(
                f"NeAntik no longer applies required launch control: {marker}"
            )
    for marker in FORBIDDEN_MANAGER_MARKERS:
        if marker in manager_text:
            raise VerificationError(
                f"NeAntik still declares obsolete launch control: {marker}"
            )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source_root", type=Path)
    arguments = parser.parse_args()
    try:
        verify(arguments.source_root)
    except (OSError, UnicodeError, VerificationError) as error:
        parser.error(str(error))
    print(
        "PASS: protected proxy, DNS, QUIC and WebGPU launch controls "
        "match the exact Chromium source."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
