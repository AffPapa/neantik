#!/usr/bin/env python3
"""Create a preseeded, isolatedV1 proxy-A/direct-B QA profile store.

The source profile must be an app-produced, validated system-free isolatedV1
fixture. This avoids opening the app first and accidentally creating a system
WebKit profile. The two profiles deliberately share the same synthetic browser
identity so route is the only A/B variable; their profile IDs and BrowserData
stores remain separate.
"""
from __future__ import annotations

import argparse
import copy
import datetime as dt
import json
import os
from pathlib import Path
import stat
import sys
import uuid
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from verify_owned_webkit_profile import ProfileFixtureError, inspect_profile_store


class ProxyPairFixtureError(ValueError):
    pass


def _object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ProxyPairFixtureError("duplicate_json_key")
        result[key] = value
    return result


def _safe_json(path: Path) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 16 * 1024 * 1024:
        raise ProxyPairFixtureError("template_must_be_bounded_regular_file")
    try:
        value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=_object)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ProxyPairFixtureError("template_unreadable") from error
    if not isinstance(value, dict):
        raise ProxyPairFixtureError("template_shape_invalid")
    return value


def _local_url(port: int, route: str) -> str:
    if type(port) is not int or not 1 <= port <= 65535:
        raise ProxyPairFixtureError("loopback_port_invalid")
    return f"http://127.0.0.1:{port}/{route}"


def create_pair(
    template: Path,
    output_root: Path,
    *,
    profile_name_prefix: str,
    proxy_port: int,
    origin_port: int,
    now: dt.datetime | None = None,
) -> dict[str, Any]:
    """Write one safe synthetic profile store; refuses overwrite and links."""
    try:
        inspect_profile_store(template, profile_name="QA isolated WebKit blank 20261021")
    except ProfileFixtureError as error:
        raise ProxyPairFixtureError("isolated_template_rejected") from error
    if output_root.is_symlink() or not output_root.is_dir():
        raise ProxyPairFixtureError("output_root_must_be_existing_directory")
    root_stat = output_root.stat(follow_symlinks=False)
    if root_stat.st_uid != os.getuid() or stat.S_IMODE(root_stat.st_mode) != 0o700:
        raise ProxyPairFixtureError("output_root_must_be_owned_mode_0700")
    output = output_root / "profiles.json"
    if output.is_symlink() or output.exists():
        raise ProxyPairFixtureError("refusing_existing_profile_store")

    document = _safe_json(template if template.is_file() else template / "profiles.json")
    if document.get("schemaVersion") != 5 or not isinstance(document.get("profiles"), list):
        raise ProxyPairFixtureError("template_schema_invalid")
    profiles = [profile for profile in document["profiles"]
                if isinstance(profile, dict) and profile.get("name") == "QA isolated WebKit blank 20261021"]
    if len(profiles) != 1:
        raise ProxyPairFixtureError("template_profile_ambiguous")
    template_profile = profiles[0]
    if not isinstance(template_profile.get("identity"), dict):
        raise ProxyPairFixtureError("template_identity_missing")

    stamp = (now or dt.datetime.now(dt.timezone.utc)).astimezone(dt.timezone.utc)
    timestamp = stamp.isoformat(timespec="seconds").replace("+00:00", "Z")
    proxy_profile = copy.deepcopy(template_profile)
    direct_profile = copy.deepcopy(template_profile)
    proxy_profile.update({
        "id": str(uuid.uuid4()).upper(),
        "name": profile_name_prefix + " A proxy",
        "startURL": _local_url(origin_port, "proxy-a"),
        "proxy": {"kind": "http", "host": "127.0.0.1", "port": proxy_port, "username": ""},
        "createdAt": timestamp,
        "updatedAt": timestamp,
        "revision": 1,
        "lastLaunchedAt": None,
    })
    direct_profile.update({
        "id": str(uuid.uuid4()).upper(),
        "name": profile_name_prefix + " B direct",
        "startURL": _local_url(origin_port, "direct-b"),
        "proxy": None,
        "createdAt": timestamp,
        "updatedAt": timestamp,
        "revision": 1,
        "lastLaunchedAt": None,
    })
    payload = json.dumps({"schemaVersion": 5, "profiles": [proxy_profile, direct_profile]},
                         ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8") + b"\n"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(output, flags, 0o600)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
    except BaseException:
        output.unlink(missing_ok=True)
        raise
    return verify_pair(output, profile_name_prefix=profile_name_prefix,
                       proxy_port=proxy_port, origin_port=origin_port)


def verify_pair(
    path: Path,
    *,
    profile_name_prefix: str,
    proxy_port: int,
    origin_port: int,
) -> dict[str, Any]:
    document = _safe_json(path)
    profiles = document.get("profiles")
    if document.get("schemaVersion") != 5 or not isinstance(profiles, list) or len(profiles) != 2:
        raise ProxyPairFixtureError("expected_exactly_two_v5_profiles")
    by_name = {profile.get("name"): profile for profile in profiles if isinstance(profile, dict)}
    if len(by_name) != 2:
        raise ProxyPairFixtureError("profile_names_ambiguous")
    a = by_name.get(profile_name_prefix + " A proxy")
    b = by_name.get(profile_name_prefix + " B direct")
    if a is None or b is None:
        raise ProxyPairFixtureError("expected_proxy_a_and_direct_b")
    for profile, route in ((a, "proxy-a"), (b, "direct-b")):
        try:
            identifier = uuid.UUID(str(profile.get("id")))
        except (ValueError, TypeError, AttributeError) as error:
            raise ProxyPairFixtureError("profile_id_invalid") from error
        if profile.get("engine") != "webkit" or profile.get("webKitRuntimeGeneration") != "isolatedV1":
            raise ProxyPairFixtureError("owned_runtime_profile_required")
        if profile.get("startURL") != _local_url(origin_port, route):
            raise ProxyPairFixtureError("unexpected_start_url")
        if any(isinstance(value, dict) and "password" in value for value in profile.values()):
            raise ProxyPairFixtureError("credential_material_refused")
    if a["id"] == b["id"] or a.get("identity") != b.get("identity"):
        raise ProxyPairFixtureError("A_B_must_share_identity_but_not_profile_id")
    if a.get("proxy") != {"kind": "http", "host": "127.0.0.1", "port": proxy_port, "username": ""}:
        raise ProxyPairFixtureError("proxy_A_must_match_exact_loopback_fixture")
    if b.get("proxy") is not None:
        raise ProxyPairFixtureError("direct_B_must_have_no_proxy")
    return {
        "status": "PASS",
        "schemaVersion": 5,
        "profileCount": 2,
        "engine": "webkit",
        "runtimeGeneration": "isolatedV1",
        "proxyA": f"127.0.0.1:{proxy_port}",
        "directB": True,
        "credentials": False,
        "sharedSyntheticIdentityForA_B": True,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("template", type=Path, help="Validated app-produced isolatedV1 profiles.json")
    parser.add_argument("output_root", type=Path, help="Existing empty QA directory owned by this user with mode 0700")
    parser.add_argument("--name-prefix", required=True)
    parser.add_argument("--proxy-port", type=int, default=45101)
    parser.add_argument("--origin-port", type=int, default=45102)
    parser.add_argument("--verify", action="store_true", help="Verify an existing exact pair without modifying it")
    args = parser.parse_args()
    try:
        if args.verify:
            result = verify_pair(args.output_root / "profiles.json", profile_name_prefix=args.name_prefix,
                                 proxy_port=args.proxy_port, origin_port=args.origin_port)
        else:
            result = create_pair(args.template, args.output_root, profile_name_prefix=args.name_prefix,
                                 proxy_port=args.proxy_port, origin_port=args.origin_port)
        print(json.dumps(result, ensure_ascii=False, sort_keys=True))
        return 0
    except (ProxyPairFixtureError, OSError, ValueError) as error:
        print(json.dumps({"status": "FAIL", "reason": str(error)}, sort_keys=True))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
