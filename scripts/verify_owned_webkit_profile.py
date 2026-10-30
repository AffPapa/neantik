#!/usr/bin/env python3
"""Verify the persisted, isolated WebKit profile before owned-runtime QA."""
from __future__ import annotations

import argparse
import json
import re
import sys
import uuid
from pathlib import Path
from typing import Any


class ProfileFixtureError(ValueError):
    pass


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ProfileFixtureError("duplicate_json_key")
        result[key] = value
    return result


def inspect_profile_store(path: Path, profile_name: str) -> dict[str, Any]:
    """Require one exact, non-proxy isolatedV1 profile in profiles.json."""
    if path.is_symlink():
        raise ProfileFixtureError("profile_store_symlink_refused")
    profile_file = path / "profiles.json" if path.is_dir() else path
    if profile_file.is_symlink() or not profile_file.is_file():
        raise ProfileFixtureError("profile_store_missing_or_symlink")
    try:
        if profile_file.stat().st_size > 16 * 1024 * 1024:
            raise ProfileFixtureError("profile_store_too_large")
        document = json.loads(
            profile_file.read_text(encoding="utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
        )
    except ProfileFixtureError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ProfileFixtureError("profile_store_unreadable") from error

    if not isinstance(document, dict):
        raise ProfileFixtureError("profile_store_shape_invalid")
    version = document.get("schemaVersion")
    profiles = document.get("profiles")
    if type(version) is not int or version not in {1, 2, 3, 4, 5} or not isinstance(profiles, list):
        raise ProfileFixtureError("profile_store_schema_invalid")

    matches = [
        profile for profile in profiles
        if isinstance(profile, dict) and profile.get("name") == profile_name
    ]
    if len(matches) != 1:
        raise ProfileFixtureError("profile_name_missing_or_ambiguous")
    profile = matches[0]
    if profile.get("engine") != "webkit":
        raise ProfileFixtureError("profile_engine_mismatch")
    if profile.get("webKitRuntimeGeneration") != "isolatedV1":
        raise ProfileFixtureError("profile_runtime_generation_mismatch")
    if version < 5:
        raise ProfileFixtureError("profile_store_schema_invalid")
    if profile.get("startURL") != "about:blank":
        raise ProfileFixtureError("profile_start_url_mismatch")
    if profile.get("proxy") is not None:
        raise ProfileFixtureError("profile_proxy_must_be_absent")
    try:
        profile_id = str(uuid.UUID(str(profile.get("id"))))
    except (ValueError, AttributeError, TypeError) as error:
        raise ProfileFixtureError("profile_id_invalid") from error

    return {
        "status": "PASS",
        "profileID": profile_id,
        "profileName": profile_name,
        "engine": "webkit",
        "webKitRuntimeGeneration": "isolatedV1",
        "startURL": "about:blank",
        "proxyConfigured": False,
        "schemaVersion": version,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile_store", type=Path, help="QA data root or its profiles.json")
    parser.add_argument("--profile-name", required=True, help="Exact synthetic QA profile name")
    args = parser.parse_args(argv)
    try:
        result = inspect_profile_store(args.profile_store, args.profile_name)
        print(json.dumps(result, ensure_ascii=False, sort_keys=True))
        return 0
    except ProfileFixtureError as error:
        print(json.dumps({"status": "FAIL", "reason": str(error)}, sort_keys=True))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
