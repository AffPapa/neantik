#!/usr/bin/env python3
"""Repair legacy NeAntik profile metadata without touching browser data."""

from __future__ import annotations

import argparse
import json
import shutil
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


MAXIMUM_RUNTIME_SEED = 2_147_483_647
IDENTITY_CATALOG_SIZE = 11
LEGACY_ISSUANCE_VERSION = 1
CURRENT_ISSUANCE_VERSION = 2
CURRENT_ISSUANCE_RESIDUES = {0, 2, 5, 8}


def runtime_seed(value: int) -> int:
    folded = value & MAXIMUM_RUNTIME_SEED
    return folded or 1


def next_available(seed: int, used: set[int]) -> int:
    residue = seed % IDENTITY_CATALOG_SIZE
    first = IDENTITY_CATALOG_SIZE if residue == 0 else residue
    candidate = (
        seed + IDENTITY_CATALOG_SIZE
        if seed <= MAXIMUM_RUNTIME_SEED - IDENTITY_CATALOG_SIZE
        else first
    )
    while candidate != seed:
        if candidate not in used:
            return candidate
        candidate = (
            candidate + IDENTITY_CATALOG_SIZE
            if candidate <= MAXIMUM_RUNTIME_SEED - IDENTITY_CATALOG_SIZE
            else first
        )
    raise ValueError("browser identity seed space is exhausted")


def load_profiles(path: Path) -> list[dict[str, Any]]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise SystemExit(f"profiles.json not found: {path}")
    except json.JSONDecodeError as error:
        raise SystemExit(f"profiles.json is not valid JSON: {error}")
    if not isinstance(value, list):
        raise SystemExit("profiles.json must contain a JSON array")
    for index, profile in enumerate(value):
        if not isinstance(profile, dict):
            raise SystemExit(f"profile at index {index} is not an object")
    return value


def repair_profiles(profiles: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], list[str]]:
    repaired = json.loads(json.dumps(profiles))
    used: set[int] = set()
    changes: list[str] = []
    for index, profile in enumerate(repaired):
        identity = profile.get("identity")
        if not isinstance(identity, dict):
            identity = {}
            profile["identity"] = identity
        original_seed = identity.get("seed")
        seed_is_integer = type(original_seed) is int
        raw_seed = original_seed if seed_is_integer else 1
        requested = runtime_seed(raw_seed)
        issuance_version = identity.get(
            "issuanceVersion",
            LEGACY_ISSUANCE_VERSION,
        )
        if type(issuance_version) is not int:
            raise ValueError(
                f"profile at index {index} has invalid issuanceVersion"
            )
        if issuance_version not in {
            LEGACY_ISSUANCE_VERSION,
            CURRENT_ISSUANCE_VERSION,
        }:
            raise ValueError(
                f"profile at index {index} has unsupported issuanceVersion"
            )
        if (
            issuance_version == CURRENT_ISSUANCE_VERSION
            and (
                raw_seed != requested
                or requested % IDENTITY_CATALOG_SIZE
                not in CURRENT_ISSUANCE_RESIDUES
            )
        ):
            raise ValueError(
                f"profile at index {index} has a seed outside issuance policy"
            )
        replacement = next_available(requested, used) if requested in used else requested
        used.add(replacement)
        if replacement != raw_seed or not seed_is_integer:
            identity["seed"] = replacement
            name = profile.get("name") if isinstance(profile.get("name"), str) else f"#{index}"
            changes.append(f"{name}: seed {original_seed!r} -> {replacement}")
    return repaired, changes


def apply_repairs(path: Path, repaired: list[dict[str, Any]]) -> Path:
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = path.with_name(f"{path.name}.backup-{timestamp}")
    shutil.copy2(path, backup)
    encoded = json.dumps(repaired, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    path.write_text(encoded, encoding="utf-8")
    path.chmod(0o600)
    return backup


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "profiles",
        type=Path,
        nargs="?",
        default=Path.home() / "Library/Application Support/NeAntik/profiles.json",
    )
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()

    path = args.profiles.expanduser()
    profiles = load_profiles(path)
    repaired, changes = repair_profiles(profiles)
    if not changes:
        print("No profile metadata repairs needed.")
        return
    print("Profile metadata repairs:")
    for change in changes:
        print(f"- {change}")
    if not args.apply:
        print("Dry run only. Re-run with --apply to write a backup and repair profiles.json.")
        return

    backup = apply_repairs(path, repaired)
    print(f"Backup: {backup}")
    print(f"Repaired: {path}")


if __name__ == "__main__":
    main()
