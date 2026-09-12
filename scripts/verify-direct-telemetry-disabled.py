#!/usr/bin/env python3
from __future__ import annotations

import plistlib
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
TELEMETRY_ENDPOINT_KEY = "NeAntikTelemetryEndpoint"
FORBIDDEN_INFO_KEYS = (
    "NeAntikPublicStatsURL",
)
FORBIDDEN_SOURCE_MARKERS = (
    "TelemetryController",
    "TelemetryNetworkClient",
    "TelemetryConfiguration",
    "NeAntikPublicStatsURL",
)


class DirectTelemetryError(ValueError):
    pass


def verify(
    project_root: Path = PROJECT_ROOT,
    *,
    info_plist: Path | None = None,
) -> None:
    resolved_info_plist = info_plist or (
        project_root / "Resources/Info.plist"
    )
    with resolved_info_plist.open("rb") as file:
        info = plistlib.load(file)
    present_keys = [key for key in FORBIDDEN_INFO_KEYS if key in info]
    if present_keys:
        raise DirectTelemetryError(
            "Direct build must not contain telemetry configuration keys: "
            + ", ".join(present_keys)
        )
    endpoint = info.get(TELEMETRY_ENDPOINT_KEY)
    if not isinstance(endpoint, str) or not endpoint.startswith("https://"):
        raise DirectTelemetryError("Direct telemetry endpoint is missing or insecure")

    with (project_root / "Resources/PrivacyInfo.xcprivacy").open("rb") as file:
        privacy = plistlib.load(file)
    if privacy.get("NSPrivacyTracking") is not False:
        raise DirectTelemetryError("Direct privacy manifest must disable tracking")
    if not isinstance(privacy.get("NSPrivacyCollectedDataTypes"), list):
        raise DirectTelemetryError(
            "Direct privacy manifest must declare collected data explicitly"
        )

    source_root = project_root / "Sources/NeAntik"
    if not source_root.is_dir():
        raise DirectTelemetryError(
            f"Direct source directory is missing: {source_root}"
        )
    telemetry_source = source_root / "Telemetry.swift"
    if not telemetry_source.exists():
        raise DirectTelemetryError("Direct build is missing telemetry implementation")
    for source_path in source_root.glob("*.swift"):
        source = source_path.read_text(encoding="utf-8")
        for marker in FORBIDDEN_SOURCE_MARKERS:
            if marker not in source:
                continue
            raise DirectTelemetryError(
                "Direct source contains dormant telemetry marker "
                f"{marker}: {source_path.name}"
            )


def main() -> int:
    info_plist = None
    if len(sys.argv) == 3 and sys.argv[1] == "--info-plist":
        info_plist = Path(sys.argv[2]).resolve()
    elif len(sys.argv) != 1:
        print(
            "usage: verify-direct-telemetry-disabled.py "
            "[--info-plist /absolute/path/to/Info.plist]",
            file=sys.stderr,
        )
        return 64
    try:
        verify(info_plist=info_plist)
    except (OSError, plistlib.InvalidFileException, DirectTelemetryError) as error:
        print(f"Direct telemetry verification failed: {error}", file=sys.stderr)
        return 1
    print("PASS: Direct build contains the privacy-bounded telemetry contract.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
