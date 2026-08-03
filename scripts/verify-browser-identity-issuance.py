#!/usr/bin/env python3
from __future__ import annotations

import argparse
import ast
import json
import re
import sys
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
EXPECTED_SELECTION = "system-csprng-uniform-cohort-and-ordinal"
SWIFT_INTEGER = re.compile(
    r"static let (?P<name>[A-Za-z]+)(?:: [A-Za-z0-9]+)? = "
    r"(?P<value>[0-9_]+)"
)
SWIFT_ARRAY = re.compile(
    r"static let (?P<name>commonTupleIDs|commonTupleResidues)"
    r"(?:: \[UInt32\])? = \[(?P<body>.*?)\]",
    re.DOTALL,
)


class IdentityIssuanceError(ValueError):
    pass


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise IdentityIssuanceError(f"duplicate JSON key: {key}")
        value[key] = item
    return value


def load_json(path: Path, *, label: str) -> dict[str, Any]:
    try:
        payload = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_keys,
        )
    except IdentityIssuanceError:
        raise
    except (OSError, json.JSONDecodeError) as error:
        raise IdentityIssuanceError(f"cannot read {label}: {path}") from error
    if not isinstance(payload, dict):
        raise IdentityIssuanceError(f"{label} must be a JSON object")
    return payload


def load_policy(path: Path) -> dict[str, Any]:
    payload = load_json(path, label="browser identity issuance policy")
    expected_keys = {
        "schemaVersion",
        "legacyIssuanceVersion",
        "currentIssuanceVersion",
        "identityCatalogVersion",
        "seedRange",
        "selection",
        "allowedTupleIDs",
        "allowedTupleResidues",
        "membersPerCohort",
        "candidateCount",
        "boundary",
    }
    if set(payload) != expected_keys:
        raise IdentityIssuanceError(
            "issuance policy keys must match the reviewed schema exactly"
        )
    required = {
        "schemaVersion": 1,
        "legacyIssuanceVersion": 1,
        "currentIssuanceVersion": 2,
        "identityCatalogVersion": 1,
        "selection": EXPECTED_SELECTION,
    }
    for key, expected in required.items():
        if type(payload.get(key)) is not type(expected) or payload.get(key) != expected:
            raise IdentityIssuanceError(
                f"issuance policy {key} must be {expected!r}"
            )
    seed_range = payload.get("seedRange")
    if (
        not isinstance(seed_range, dict)
        or set(seed_range) != {"minimum", "maximum"}
        or type(seed_range.get("minimum")) is not int
        or type(seed_range.get("maximum")) is not int
        or seed_range != {"minimum": 1, "maximum": 2_147_483_647}
    ):
        raise IdentityIssuanceError(
            "issuance policy seedRange must match positive signed 32-bit"
        )
    ids = payload.get("allowedTupleIDs")
    residues = payload.get("allowedTupleResidues")
    if (
        not isinstance(ids, list)
        or not isinstance(residues, list)
        or len(ids) != 4
        or len(residues) != 4
        or len(set(ids)) != 4
        or len(set(residues)) != 4
        or not all(isinstance(item, str) for item in ids)
        or not all(type(item) is int for item in residues)
    ):
        raise IdentityIssuanceError(
            "issuance policy must define four unique tuple IDs and residues"
        )
    if (
        type(payload.get("membersPerCohort")) is not int
        or payload.get("membersPerCohort") != 195_225_786
    ):
        raise IdentityIssuanceError(
            "issuance policy membersPerCohort drifted"
        )
    if (
        type(payload.get("candidateCount")) is not int
        or payload.get("candidateCount") != 780_903_144
    ):
        raise IdentityIssuanceError("issuance policy candidateCount drifted")
    if payload["membersPerCohort"] * len(ids) != payload["candidateCount"]:
        raise IdentityIssuanceError("issuance policy candidate count is incoherent")
    boundary = payload.get("boundary")
    if not isinstance(boundary, str) or len(boundary) < 80:
        raise IdentityIssuanceError(
            "issuance policy must preserve its explicit privacy boundary"
        )
    return payload


def load_catalog(path: Path) -> list[str]:
    payload = load_json(path, label="Apple device tuple catalog")
    tuples = payload.get("tuples")
    if payload.get("schemaVersion") != 1 or not isinstance(tuples, list):
        raise IdentityIssuanceError("Apple device tuple catalog schema is invalid")
    ids: list[str] = []
    for index, item in enumerate(tuples):
        if not isinstance(item, dict) or not isinstance(item.get("id"), str):
            raise IdentityIssuanceError(
                f"Apple device tuple catalog item {index} is invalid"
            )
        ids.append(item["id"])
    if len(ids) != len(set(ids)):
        raise IdentityIssuanceError("Apple device tuple catalog has duplicate IDs")
    return ids


def parse_swift_policy(path: Path) -> dict[str, Any]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise IdentityIssuanceError(
            f"cannot read Swift browser identity source: {path}"
        ) from error
    marker = "enum BrowserIdentityIssuancePolicy"
    start = text.find(marker)
    end = text.find("\nstruct BrowserIdentity:", start)
    if start < 0 or end < 0:
        raise IdentityIssuanceError(
            "Swift BrowserIdentityIssuancePolicy is missing"
        )
    body = re.sub(r"/\*.*?\*/", "", text[start:end], flags=re.DOTALL)
    body = re.sub(r"//[^\n]*", "", body)
    integer_matches = list(SWIFT_INTEGER.finditer(body))
    integer_names = [match.group("name") for match in integer_matches]
    if len(integer_names) != len(set(integer_names)):
        raise IdentityIssuanceError(
            "Swift issuance policy contains duplicate constants"
        )
    integers = {
        match.group("name"): int(match.group("value").replace("_", ""))
        for match in integer_matches
    }
    arrays: dict[str, list[Any]] = {}
    for match in SWIFT_ARRAY.finditer(body):
        name = match.group("name")
        if name in arrays:
            raise IdentityIssuanceError(
                "Swift issuance policy contains duplicate arrays"
            )
        raw = match.group("body")
        if name == "commonTupleIDs":
            arrays[name] = re.findall(r'"([^"]+)"', raw)
        else:
            arrays[name] = [
                int(value.replace("_", ""))
                for value in re.findall(r"\b[0-9_]+\b", raw)
            ]
    required_integers = {
        "legacyVersion",
        "currentVersion",
        "membersPerCohort",
        "candidateCount",
    }
    if not required_integers.issubset(integers):
        raise IdentityIssuanceError(
            "Swift issuance policy constants are incomplete"
        )
    if set(arrays) != {"commonTupleIDs", "commonTupleResidues"}:
        raise IdentityIssuanceError(
            "Swift issuance policy arrays are incomplete"
        )
    return {**integers, **arrays}


def parse_repair_policy(path: Path) -> dict[str, Any]:
    try:
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    except (OSError, SyntaxError) as error:
        raise IdentityIssuanceError(
            f"cannot read profile repair policy: {path}"
        ) from error
    expected = {
        "MAXIMUM_RUNTIME_SEED",
        "IDENTITY_CATALOG_SIZE",
        "LEGACY_ISSUANCE_VERSION",
        "CURRENT_ISSUANCE_VERSION",
        "CURRENT_ISSUANCE_RESIDUES",
    }
    values: dict[str, Any] = {}
    for node in tree.body:
        if (
            not isinstance(node, ast.Assign)
            or len(node.targets) != 1
            or not isinstance(node.targets[0], ast.Name)
            or node.targets[0].id not in expected
        ):
            continue
        name = node.targets[0].id
        if name in values:
            raise IdentityIssuanceError(
                f"profile repair policy duplicates {name}"
            )
        try:
            values[name] = ast.literal_eval(node.value)
        except (ValueError, TypeError) as error:
            raise IdentityIssuanceError(
                f"profile repair policy {name} is not a literal"
            ) from error
    if set(values) != expected:
        raise IdentityIssuanceError(
            "profile repair issuance policy constants are incomplete"
        )
    return values


def verify(
    *,
    policy_path: Path,
    catalog_path: Path,
    swift_path: Path,
    repair_path: Path = PROJECT_ROOT / "scripts" / "repair-profile-metadata.py",
) -> dict[str, Any]:
    policy = load_policy(policy_path)
    catalog_ids = load_catalog(catalog_path)
    swift = parse_swift_policy(swift_path)
    repair = parse_repair_policy(repair_path)
    issues: list[str] = []
    expected_swift = {
        "legacyVersion": policy["legacyIssuanceVersion"],
        "currentVersion": policy["currentIssuanceVersion"],
        "membersPerCohort": policy["membersPerCohort"],
        "candidateCount": policy["candidateCount"],
        "commonTupleIDs": policy["allowedTupleIDs"],
        "commonTupleResidues": policy["allowedTupleResidues"],
    }
    for key, expected in expected_swift.items():
        if swift.get(key) != expected:
            issues.append(
                f"Swift {key} drifted: {swift.get(key)!r} != {expected!r}"
            )
    expected_repair = {
        "MAXIMUM_RUNTIME_SEED": policy["seedRange"]["maximum"],
        "IDENTITY_CATALOG_SIZE": len(catalog_ids),
        "LEGACY_ISSUANCE_VERSION": policy["legacyIssuanceVersion"],
        "CURRENT_ISSUANCE_VERSION": policy["currentIssuanceVersion"],
        "CURRENT_ISSUANCE_RESIDUES": set(policy["allowedTupleResidues"]),
    }
    for key, expected in expected_repair.items():
        if repair.get(key) != expected:
            issues.append(
                f"profile repair {key} drifted: "
                f"{repair.get(key)!r} != {expected!r}"
            )
    for tuple_id, residue in zip(
        policy["allowedTupleIDs"],
        policy["allowedTupleResidues"],
        strict=True,
    ):
        if residue >= len(catalog_ids) or catalog_ids[residue] != tuple_id:
            issues.append(
                f"tuple residue {residue} does not resolve to {tuple_id}"
            )
    maximum = policy["seedRange"]["maximum"]
    tuple_count = len(catalog_ids)
    counts = []
    for residue in policy["allowedTupleResidues"]:
        count = (
            maximum // tuple_count
            if residue == 0
            else (maximum - residue) // tuple_count + 1
        )
        counts.append(count)
    if counts != [policy["membersPerCohort"]] * 4:
        issues.append(
            f"candidate distribution drifted: {counts!r}"
        )
    return {
        "schemaVersion": 1,
        "policyVersion": policy["currentIssuanceVersion"],
        "candidateCount": policy["candidateCount"],
        "membersPerCohort": policy["membersPerCohort"],
        "allowedTupleIDs": policy["allowedTupleIDs"],
        "consistent": not issues,
        "issues": issues,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify the new-profile browser identity issuance contract.",
    )
    parser.add_argument(
        "--policy",
        type=Path,
        default=PROJECT_ROOT / "runtime" / "browser-identity-issuance.json",
    )
    parser.add_argument(
        "--catalog",
        type=Path,
        default=PROJECT_ROOT / "runtime" / "apple-device-tuples.json",
    )
    parser.add_argument(
        "--swift",
        type=Path,
        default=PROJECT_ROOT / "Sources" / "NeAntik" / "Models.swift",
    )
    parser.add_argument(
        "--repair",
        type=Path,
        default=PROJECT_ROOT / "scripts" / "repair-profile-metadata.py",
    )
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    try:
        report = verify(
            policy_path=args.policy,
            catalog_path=args.catalog,
            swift_path=args.swift,
            repair_path=args.repair,
        )
    except IdentityIssuanceError as error:
        print(f"Browser identity issuance verification failed: {error}", file=sys.stderr)
        return 65
    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    elif report["consistent"]:
        print(
            "Browser identity issuance verified: "
            f"{report['candidateCount']} candidates across "
            f"{len(report['allowedTupleIDs'])} cohorts."
        )
    else:
        print("Browser identity issuance contract drift detected.", file=sys.stderr)
        for issue in report["issues"]:
            print(f"- {issue}", file=sys.stderr)
    return 0 if report["consistent"] else 65


if __name__ == "__main__":
    sys.exit(main())
