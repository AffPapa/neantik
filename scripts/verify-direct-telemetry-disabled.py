#!/usr/bin/env python3
from __future__ import annotations

import plistlib
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
FORBIDDEN_SOURCE_FIELDS = (
    "installationHash",
    "profileName",
    "profileID",
    "proxyHost",
    "proxyPort",
    "proxyPassword",
    "fingerprintSeed",
    "visitedURL",
)


class DirectTelemetryError(ValueError):
    pass


def verify(project_root: Path = PROJECT_ROOT) -> None:
    with (project_root / "Resources/Info.plist").open("rb") as file:
        info = plistlib.load(file)
    if str(info.get("NeAntikTelemetryEndpoint", "")).strip():
        raise DirectTelemetryError(
            "Direct telemetry endpoint must stay empty until the privacy-safe "
            "server and policy are released"
        )

    with (project_root / "Resources/PrivacyInfo.xcprivacy").open("rb") as file:
        privacy = plistlib.load(file)
    if privacy.get("NSPrivacyTracking") is not False:
        raise DirectTelemetryError("Direct privacy manifest must disable tracking")
    if privacy.get("NSPrivacyCollectedDataTypes") != []:
        raise DirectTelemetryError(
            "Direct privacy manifest must declare no collected data while "
            "telemetry is disabled"
        )

    source = (
        project_root / "Sources/NeAntik/Telemetry.swift"
    ).read_text(encoding="utf-8")
    for field in FORBIDDEN_SOURCE_FIELDS:
        if field in source:
            raise DirectTelemetryError(
                f"Direct telemetry source contains forbidden field: {field}"
            )


def main() -> int:
    try:
        verify()
    except (OSError, plistlib.InvalidFileException, DirectTelemetryError) as error:
        print(f"Direct telemetry verification failed: {error}", file=sys.stderr)
        return 1
    print("PASS: Direct telemetry is disabled and declares no collected data.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
