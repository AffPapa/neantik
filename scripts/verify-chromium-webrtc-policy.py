#!/usr/bin/env python3
"""Verify the shipping Chromium WebRTC policy command-line path.

Chromium exposes two similarly named switches. Chrome consumes
`--webrtc-ip-handling-policy` through ChromeCommandLinePrefStore, while
`--force-webrtc-ip-handling-policy` is used by content shell/headless paths.
NeAntik must bind its launch contract to the shipping Chrome path.
This is a source-marker check, not preprocessing, compilation, or proof of the
effective runtime policy. Native positive and negative controls remain required.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import re


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


def source_view(text: str) -> tuple[str, list[bool]]:
    """Hide comments and identify literal spans without treating them as code.

    Line splicing precedes C++ comment recognition. Marker values may include
    string literals, but a marker must begin in code, never inside a literal.
    This deliberately does not evaluate preprocessor conditionals.
    """
    text = re.sub(r"\\\r?\n", "", text)
    visible = list(text)
    code = [True] * len(text)
    i = 0
    while i < len(text):
        end = None
        comment = False
        if text.startswith("//", i):
            end = text.find("\n", i + 2)
            if end < 0:
                end = len(text)
            comment = True
        elif text.startswith("/*", i):
            closing = text.find("*/", i + 2)
            if closing < 0:
                raise VerificationError("Unterminated source comment")
            end = closing + 2
            comment = True
        elif text.startswith('R"', i):
            raw = re.match(r'R"([^ ()\\\t\v\f\r\n]{0,16})\(', text[i:])
            if raw is None:
                raise VerificationError("Invalid source raw literal")
            terminator = ")" + raw.group(1) + '"'
            closing = text.find(terminator, i + raw.end())
            if closing < 0:
                raise VerificationError("Unterminated source raw literal")
            end = closing + len(terminator)
        elif text[i] in ('"', "'"):
            # C++ numeric separators are not character-literal delimiters.
            if text[i] == "'" and i + 1 < len(text) and text[i + 1].isalnum():
                start = i - 1
                while start >= 0 and (text[start].isalnum() or text[start] in "_'."):
                    start -= 1
                prefix = text[start + 1:i]
                if prefix and prefix[0].isdigit():
                    i += 1
                    continue
            quote = text[i]
            j = i + 1
            while j < len(text):
                if text[j] == "\\":
                    j += 2
                elif text[j] == quote:
                    end = j + 1
                    break
                elif text[j] in "\r\n":
                    break
                else:
                    j += 1
            if end is None:
                raise VerificationError("Unterminated source literal")
        if end is not None:
            code[i:end] = [False] * (end - i)
            if comment:
                visible[i:end] = ["\n" if c == "\n" else " " for c in text[i:end]]
            i = end
        else:
            i += 1
    return "".join(visible), code


def contains_code_marker(text: str, code: list[bool], marker: str) -> bool:
    start = text.find(marker)
    while start >= 0:
        if code[start]:
            return True
        start = text.find(marker, start + 1)
    return False


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
        text, code = source_view(path.read_text(encoding="utf-8"))
        for marker in markers:
            if not contains_code_marker(text, code, marker):
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
        "PASS: required shipping WebRTC source markers are outside comments "
        "and literal starts. Preprocessing, compilation and effective runtime "
        "policy are not proved by this check."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
