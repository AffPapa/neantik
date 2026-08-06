#!/usr/bin/env python3
"""Verify the shipping Chromium WebRTC policy command-line path.

Chromium exposes two similarly named switches. Chrome consumes
`--webrtc-ip-handling-policy` through ChromeCommandLinePrefStore, while
`--force-webrtc-ip-handling-policy` is used by content shell/headless paths.
NeAntik must bind its launch contract to the shipping Chrome path.
"""

from __future__ import annotations

import argparse
from pathlib import Path


class VerificationError(ValueError):
    pass


REQUIRED_SOURCE_MARKERS = {
    "chrome/common/chrome_switches.cc": (
        'const char kWebRtcIPHandlingPolicy[] = "webrtc-ip-handling-policy";',
    ),
    "chrome/browser/prefs/chrome_command_line_pref_store.cc": (
        "{switches::kWebRtcIPHandlingPolicy, prefs::kWebRTCIPHandlingPolicy}",
    ),
    "chrome/browser/renderer_preferences_util.cc": (
        "prefs->webrtc_ip_handling_policy = blink::ToWebRTCIPHandlingPolicy(",
        "pref_service->GetString(prefs::kWebRTCIPHandlingPolicy)",
    ),
    "third_party/blink/common/peerconnection/webrtc_ip_handling_policy.cc": (
        'kWebRTCIPHandlingDisableNonProxiedUdp[] = "disable_non_proxied_udp"',
        "kDisableNonProxiedUdp",
    ),
}


def verify(source_root: Path) -> None:
    source_root = source_root.resolve()
    if not source_root.is_dir():
        raise VerificationError("Chromium source root is missing")
    for relative, markers in REQUIRED_SOURCE_MARKERS.items():
        path = source_root / relative
        if not path.is_file() or path.is_symlink():
            raise VerificationError(
                f"Required Chromium WebRTC source is missing: {relative}"
            )
        text = path.read_text(encoding="utf-8")
        for marker in markers:
            if marker not in text:
                raise VerificationError(
                    f"Chromium WebRTC policy contract changed: {relative}"
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
        "PASS: shipping Chromium maps --webrtc-ip-handling-policy "
        "to the renderer WebRTC preference."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
