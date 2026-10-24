#!/usr/bin/env python3
"""Fail closed when the pinned Direct runtime is behind the security baseline."""

from __future__ import annotations

import argparse
import json
import re
from datetime import date, datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit


PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_LOCK = PROJECT_ROOT / "runtime" / "fingerprint-chromium.lock.json"
DEFAULT_BASELINE = PROJECT_ROOT / "runtime" / "security-baseline.json"


def fail(message: str) -> None:
    raise SystemExit(message)


def version_tuple(raw: object, label: str) -> tuple[int, int, int, int]:
    if not isinstance(raw, str):
        fail(f"{label} must be a four-part version string.")
    parts = raw.split(".")
    if len(parts) != 4 or any(not part.isdigit() for part in parts):
        fail(f"{label} must be a four-part numeric version string.")
    return tuple(int(part) for part in parts)  # type: ignore[return-value]


def load_object(path: Path, label: str) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"Cannot read {label} at {path}: {error}")
    if not isinstance(value, dict):
        fail(f"{label} must contain a JSON object.")
    return value


def verify_security_branch(lock, fingerprint, baseline, runtime, minimum):
    """A higher milestone cannot substitute for a source-bound fix review."""
    if runtime[:3] == minimum[:3]:
        return False
    branch = ".".join(map(str, runtime[:3]))
    prefix = "Public Direct release blocked: security branch " + branch + ": "
    reviews = baseline.get("reviewedSecurityBranches")
    review = reviews.get(branch) if isinstance(reviews, dict) else None
    if not isinstance(review, dict) or review.get("status") != "verified":
        fail(prefix + "a complete source-bound security fix review is required; a higher version is not proof.")
    if review.get("securityReference") != baseline["reference"]:
        fail(prefix + "review refers to a different security batch.")
    commit = fingerprint.get("commit")
    contract = lock.get("sourceContractSHA256")
    if (not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}", commit)
            or not isinstance(contract, str) or not re.fullmatch(r"[0-9a-f]{64}", contract)
            or review.get("sourceCommit") != commit
            or review.get("sourceContractSHA256") != contract):
        fail(prefix + "review does not bind this exact source commit and contract.")
    floor = version_tuple(review.get("minimumVersion"), "Reviewed branch minimum")
    if floor[:3] != runtime[:3] or runtime < floor:
        fail(prefix + "runtime is below or outside the reviewed branch floor.")
    required = baseline.get("requiredSecurityFixes")
    if (not isinstance(required, list)
            or any(not isinstance(item, str) or not re.fullmatch(r"[0-9]{6,12}", item) for item in required)
            or len(set(required)) != len(required)
            or len(required) != baseline["securityFixCount"]):
        fail(prefix + "the complete published security fix set is missing or invalid.")
    fixes = review.get("fixes")
    if not isinstance(fixes, dict) or set(fixes) != set(required):
        fail(prefix + "security fix coverage is incomplete.")
    for issue in required:
        proof = fixes[issue]
        if not isinstance(proof, dict) or proof.get("status") not in ("included", "not-applicable"):
            fail(prefix + "security fix coverage contains an unverified result.")
        reference = proof.get("reference")
        if not isinstance(reference, str):
            fail(prefix + "a security fix has no primary-source evidence.")
        try:
            parsed = urlsplit(reference)
            official = (parsed.hostname == "chromium.googlesource.com" and re.fullmatch(
                r"/(?:codesearch/)?(?:chromium/src(?:\.git)?|v8/v8(?:\.git)?)/\+/[0-9a-f]{40}(?:/.*)?",
                parsed.path) is not None)
            own_pinned = (parsed.hostname == "github.com" and re.match(
                r"^/AffPapa/neantik/blob/[0-9a-f]{40}/", parsed.path) is not None)
            valid = (parsed.scheme == "https" and parsed.username is None
                     and parsed.password is None and parsed.port in (None, 443)
                     and not parsed.query and not parsed.fragment
                     and not any(part in (".", "..") for part in parsed.path.split("/"))
                     and "%" not in parsed.path and "\\" not in parsed.path
                     and (official or own_pinned))
        except ValueError:
            valid = False
        if not valid:
            fail(prefix + "security evidence must use a commit-pinned upstream source or a pinned NeAntik source report.")
        if (proof["status"] == "not-applicable"
                and (not isinstance(proof.get("reason"), str) or not proof["reason"].strip())):
            fail(prefix + "a not-applicable fix requires a specific reason.")
    return True


def verify(
    lock_path: Path,
    baseline_path: Path,
    today: date,
    *,
    allow_public_alpha_tuples: bool = False,
    allow_unqualified_bundle: bool = False,
) -> str:
    lock = load_object(lock_path, "runtime source lock")
    baseline = load_object(baseline_path, "runtime security baseline")

    if baseline.get("schemaVersion") != 1:
        fail("Unexpected runtime security baseline schema.")

    fingerprint = lock.get("fingerprintChromium")
    if not isinstance(fingerprint, dict):
        fail("Runtime source lock has no fingerprintChromium object.")

    runtime_raw = fingerprint.get("chromiumVersion")
    minimum_raw = baseline.get("minimumPublicChromiumVersion")
    runtime = version_tuple(runtime_raw, "Pinned Chromium version")
    minimum = version_tuple(minimum_raw, "Minimum public Chromium version")

    checked_raw = baseline.get("checkedAt")
    published_raw = baseline.get("publishedAt")
    maximum_age = baseline.get("maximumAgeDays")
    reference = baseline.get("reference")
    reference_title = baseline.get("referenceTitle")
    source_label = baseline.get("sourceLabel")
    release_boundary = baseline.get("releaseBoundary")
    if not isinstance(checked_raw, str):
        fail("Runtime security baseline has no checkedAt date.")
    if not isinstance(published_raw, str):
        fail("Runtime security baseline has no publishedAt date.")
    if not isinstance(maximum_age, int) or isinstance(maximum_age, bool):
        fail("Runtime security baseline maximumAgeDays must be an integer.")
    if maximum_age < 0 or maximum_age > 31:
        fail("Runtime security baseline maximumAgeDays must be between 0 and 31.")
    if not isinstance(reference, str) or not reference.startswith("https://"):
        fail("Runtime security baseline must include an HTTPS primary-source reference.")
    if reference_title != "Stable Channel Update for Desktop":
        fail("Runtime security baseline must declare the Desktop Stable reference title.")
    if source_label != "Chrome Releases":
        fail("Runtime security baseline must declare Chrome Releases as sourceLabel.")
    if not isinstance(release_boundary, str) or "not a live updater" not in release_boundary:
        fail("Runtime security baseline must declare the pinned manual refresh boundary.")
    if baseline.get("channel") != "Desktop Stable":
        fail("Runtime security baseline channel must be Desktop Stable.")
    platforms = baseline.get("platforms")
    if not isinstance(platforms, list) or "macOS" not in platforms:
        fail("Runtime security baseline platforms must include macOS.")
    security_fix_count = baseline.get("securityFixCount")
    if not isinstance(security_fix_count, int) or isinstance(security_fix_count, bool):
        fail("Runtime security baseline securityFixCount must be an integer.")
    if security_fix_count < 0:
        fail(
            "Runtime security baseline securityFixCount must be non-negative."
        )
    observed = baseline.get("alsoObservedPublicChromiumVersions")
    if not isinstance(observed, list) or not all(isinstance(item, str) for item in observed):
        fail("Runtime security baseline alsoObservedPublicChromiumVersions must be a string list.")
    for observed_raw in observed:
        version_tuple(observed_raw, "Observed public Chromium version")

    try:
        checked = date.fromisoformat(checked_raw)
    except ValueError:
        fail("Runtime security baseline checkedAt must use YYYY-MM-DD.")
    try:
        published = date.fromisoformat(published_raw)
    except ValueError:
        fail("Runtime security baseline publishedAt must use YYYY-MM-DD.")
    if published > checked:
        fail("Runtime security baseline publishedAt must not be after checkedAt.")
    age = (today - checked).days
    if age < 0:
        fail("Runtime security baseline checkedAt is in the future.")
    if age > maximum_age:
        fail(
            "Runtime security baseline is stale "
            f"({age} days old; maximum {maximum_age}). Refresh it from {reference}"
        )
    if runtime < minimum:
        fail(
            "Public Direct release blocked: pinned Chromium "
            f"{runtime_raw} is below the security baseline {minimum_raw}. "
            "Rebase the owned fingerprint runtime and reproduce all runtime gates first."
        )

    reviewed_branch = verify_security_branch(lock, fingerprint, baseline, runtime, minimum)

    security_summary = (
        f"security fixes {security_fix_count}"
        if security_fix_count > 0
        else "security fixes not enumerated by the official post"
    )

    if reviewed_branch:
        security_summary += "; cross-branch source-bound security fix review verified"

    verification = lock.get("verification")
    if not isinstance(verification, dict):
        if allow_unqualified_bundle and lock.get("status") == "source-qualified":
            return (
                f"Pre-qualification bundle only: Chromium {runtime_raw} >= "
                f"{minimum_raw}; baseline age {age} day(s); source {source_label}; "
                f"{security_summary}; runtime tuple evidence is still required "
                "before a public Direct release."
            )
        if allow_public_alpha_tuples and lock.get("status") == "source-qualified":
            return (
                f"Runtime security baseline verified for public alpha: Chromium {runtime_raw} >= "
                f"{minimum_raw}; baseline age {age} day(s); source {source_label}; "
                f"{security_summary}; source-only runtime lock has no "
                "coherent Apple device tuple verification object; GUI fingerprint evidence "
                "must remain bound by the Direct release gate."
            )
        fail("Runtime source lock has no verification object.")
    tuple_status = verification.get("coherentAppleDeviceTuples")
    if tuple_status != "verified":
        if not allow_public_alpha_tuples:
            fail(
                "Public Direct release blocked: coherent Apple device tuples are "
                f"not verified (status: {tuple_status!r}). GPU, hardware concurrency, "
                "memory, screen, scale and platform values must come from one "
                "reviewed tuple catalog and pass browser evidence."
            )
        return (
            f"Runtime security baseline verified for public alpha: Chromium {runtime_raw} >= "
            f"{minimum_raw}; baseline age {age} day(s); source {source_label}; "
            f"{security_summary}; coherent Apple device tuple hardening "
            f"not complete (status: {tuple_status!r})."
        )

    return (
        f"Runtime security baseline verified: Chromium {runtime_raw} >= "
        f"{minimum_raw}; baseline age {age} day(s); source {source_label}; "
        f"{security_summary}; coherent Apple device tuples verified."
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lock", type=Path, default=DEFAULT_LOCK)
    parser.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE)
    # Source receipts and CI use UTC. A host timezone must not make the same
    # review appear future-dated on one machine and current on another.
    parser.add_argument("--today", type=date.fromisoformat,
                        default=datetime.now(timezone.utc).date())
    parser.add_argument(
        "--allow-public-alpha-tuples",
        action="store_true",
        help=(
            "Allow notarized public-alpha builds when GUI A -> B -> A evidence "
            "is verified but strict coherent Apple tuple hardening is incomplete."
        ),
    )
    parser.add_argument(
        "--allow-unqualified-bundle",
        action="store_true",
        help=(
            "Permit only a private bundle-only preparation from source-qualified "
            "runtime evidence; this never qualifies a public release."
        ),
    )
    args = parser.parse_args()
    print(
        verify(
            args.lock,
            args.baseline,
            args.today,
            allow_public_alpha_tuples=args.allow_public_alpha_tuples,
            allow_unqualified_bundle=args.allow_unqualified_bundle,
        )
    )


if __name__ == "__main__":
    main()
