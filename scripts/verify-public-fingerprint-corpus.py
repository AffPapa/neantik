#!/usr/bin/env python3
from __future__ import annotations

import argparse
import copy
import importlib.util
import json
import re
import sys
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CORPUS = (
    PROJECT_ROOT / "Tests/Fixtures/fingerprint-conformance"
)
GUI_VERIFIER_PATH = PROJECT_ROOT / "scripts/verify-gui-fingerprint-report.py"
MAX_JSON_BYTES = 256 * 1024
SYNTHETIC_PROFILE_IDS = {
    "00000000-0000-4000-8000-000000000101",
    "00000000-0000-4000-8000-000000000202",
}
SYNTHETIC_PROFILE_NAMES = {"SYNTHETIC-A", "SYNTHETIC-B"}
SYNTHETIC_IDENTITY_CODES = {"NA-13579BDF", "NA-2468ACE0"}
SYNTHETIC_CONTROL_ID = "00000000-0000-4000-8000-000000000303"
SYNTHETIC_CONTROL_NAME = "SYNTHETIC-CONTROL"
ALLOWED_MUTATION_PATHS = {
    "executionMode",
    "firstInitial.values.worker_platform",
    "firstRepeat.values.worker_platform",
    "firstInitial.values.worker_device_memory",
    "second.values.worker_device_memory",
    "firstRepeat.values.worker_device_memory",
    "firstInitial.values.languages",
    "firstInitial.values.worker_languages",
    "firstInitial.values.primary_locale_core",
    "firstInitial.values.worker_primary_locale_core",
    "firstRepeat.values.languages",
    "firstRepeat.values.worker_languages",
    "firstRepeat.values.primary_locale_core",
    "firstRepeat.values.worker_primary_locale_core",
    "firstRepeat.values.canvas",
    "firstInitial.values.device_memory",
    "second.values.device_memory",
    "firstRepeat.values.device_memory",
    "second.values.network_route",
    "second.values.webrtc_stun_requests",
    "second.values.webrtc_candidate_summary",
}
FORBIDDEN_KEY_MARKERS = {
    "cookie",
    "history",
    "observedip",
    "password",
    "proxy",
    "seed",
    "starturl",
    "username",
}
FORBIDDEN_TEXT_PATTERNS = [
    re.compile(r"/Users/", re.IGNORECASE),
    re.compile(r"/home/", re.IGNORECASE),
    re.compile(r"Library/Application Support", re.IGNORECASE),
    re.compile(r"file://", re.IGNORECASE),
    re.compile(r"BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY", re.IGNORECASE),
]


class PublicFingerprintCorpusError(ValueError):
    pass


def load_gui_verifier() -> Any:
    spec = importlib.util.spec_from_file_location(
        "verify_gui_fingerprint_report_for_public_corpus",
        GUI_VERIFIER_PATH,
    )
    if spec is None or spec.loader is None:
        raise PublicFingerprintCorpusError(
            "Cannot load the GUI fingerprint verifier."
        )
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def load_json_object(path: Path) -> dict[str, Any]:
    try:
        if path.stat().st_size > MAX_JSON_BYTES:
            raise PublicFingerprintCorpusError(
                f"Corpus JSON exceeds {MAX_JSON_BYTES} bytes: {path}"
            )
        value = json.loads(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise PublicFingerprintCorpusError(
            f"Cannot read corpus JSON {path}: {error}"
        ) from error
    except json.JSONDecodeError as error:
        raise PublicFingerprintCorpusError(
            f"Invalid corpus JSON {path}: {error}"
        ) from error
    if not isinstance(value, dict):
        raise PublicFingerprintCorpusError(
            f"Corpus JSON must be an object: {path}"
        )
    return value


def verify_privacy_boundary(report: dict[str, Any]) -> None:
    captures = [
        report.get("firstInitial"),
        report.get("second"),
        report.get("firstRepeat"),
    ]
    if not all(isinstance(capture, dict) for capture in captures):
        raise PublicFingerprintCorpusError(
            "Synthetic corpus must contain three capture objects."
        )
    profile_ids = {
        str(capture.get("profileID")) for capture in captures
    }
    profile_names = {
        str(capture.get("profileName")) for capture in captures
    }
    identity_codes = {
        str(capture.get("identityCode")) for capture in captures
    }
    if profile_ids != SYNTHETIC_PROFILE_IDS:
        raise PublicFingerprintCorpusError(
            "Corpus contains a non-synthetic profile identifier."
        )
    if profile_names != SYNTHETIC_PROFILE_NAMES:
        raise PublicFingerprintCorpusError(
            "Corpus contains a non-synthetic profile name."
        )
    if identity_codes != SYNTHETIC_IDENTITY_CODES:
        raise PublicFingerprintCorpusError(
            "Corpus contains an unexpected identity code."
        )
    direct_control = report.get("webrtcDirectControl")
    if not isinstance(direct_control, dict) or (
        direct_control.get("profileID") != SYNTHETIC_CONTROL_ID
        or direct_control.get("profileName") != SYNTHETIC_CONTROL_NAME
        or direct_control.get("identityCode") != "NA-13579BDF"
    ):
        raise PublicFingerprintCorpusError(
            "Corpus contains a non-synthetic WebRTC direct control."
        )
    if report.get("runtimeExecutableSHA256") != "a" * 64 or (
        report.get("runtimeFrameworkSHA256") != "b" * 64
    ):
        raise PublicFingerprintCorpusError(
            "Corpus runtime hashes must use documented synthetic sentinels."
        )

    def walk(value: Any) -> None:
        if isinstance(value, dict):
            for key, child in value.items():
                normalized = re.sub(r"[^a-z0-9]", "", str(key).lower())
                if any(marker in normalized for marker in FORBIDDEN_KEY_MARKERS):
                    raise PublicFingerprintCorpusError(
                        f"Forbidden sensitive field in public corpus: {key}"
                    )
                walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)
        elif isinstance(value, str):
            for pattern in FORBIDDEN_TEXT_PATTERNS:
                if pattern.search(value):
                    raise PublicFingerprintCorpusError(
                        "Public corpus contains a local path or secret marker."
                    )

    walk(report)


def apply_mutation(
    report: dict[str, Any],
    mutation: dict[str, Any],
) -> None:
    path = mutation.get("path")
    operation = mutation.get("operation", "set")
    if path not in ALLOWED_MUTATION_PATHS:
        raise PublicFingerprintCorpusError(
            f"Mutation path is not allowlisted: {path!r}"
        )
    if operation not in {"set", "delete"}:
        raise PublicFingerprintCorpusError(
            f"Unsupported mutation operation: {operation!r}"
        )
    parts = str(path).split(".")
    target: Any = report
    for part in parts[:-1]:
        if not isinstance(target, dict) or part not in target:
            raise PublicFingerprintCorpusError(
                f"Mutation path does not exist: {path}"
            )
        target = target[part]
    if not isinstance(target, dict):
        raise PublicFingerprintCorpusError(
            f"Mutation parent is not an object: {path}"
        )
    leaf = parts[-1]
    if operation == "delete":
        if leaf not in target:
            raise PublicFingerprintCorpusError(
                f"Mutation target does not exist: {path}"
            )
        del target[leaf]
    else:
        if "value" not in mutation:
            raise PublicFingerprintCorpusError(
                f"Set mutation has no value: {path}"
            )
        target[leaf] = mutation["value"]


def verify_public_corpus(corpus_dir: Path = DEFAULT_CORPUS) -> str:
    manifest = load_json_object(corpus_dir / "manifest.json")
    if manifest.get("schemaVersion") != 1:
        raise PublicFingerprintCorpusError(
            "Public corpus schemaVersion must be 1."
        )
    if manifest.get("privacyBoundary") != "synthetic-only":
        raise PublicFingerprintCorpusError(
            "Public corpus must declare privacyBoundary synthetic-only."
        )
    base_name = manifest.get("baseReport")
    if base_name != "base-production-qualified.json":
        raise PublicFingerprintCorpusError(
            "Public corpus base report path is not canonical."
        )
    base_report = load_json_object(corpus_dir / base_name)
    verify_privacy_boundary(base_report)

    cases = manifest.get("cases")
    if not isinstance(cases, list) or len(cases) < 5:
        raise PublicFingerprintCorpusError(
            "Public corpus must contain at least five cases."
        )
    verifier = load_gui_verifier()
    seen_ids: set[str] = set()
    observed_outcomes: set[tuple[bool, bool]] = set()
    for case in cases:
        if not isinstance(case, dict):
            raise PublicFingerprintCorpusError(
                "Every corpus case must be an object."
            )
        case_id = case.get("id")
        if not isinstance(case_id, str) or not re.fullmatch(
            r"[a-z0-9-]{3,64}", case_id
        ):
            raise PublicFingerprintCorpusError(
                f"Invalid corpus case id: {case_id!r}"
            )
        if case_id in seen_ids:
            raise PublicFingerprintCorpusError(
                f"Duplicate corpus case id: {case_id}"
            )
        seen_ids.add(case_id)
        report = copy.deepcopy(base_report)
        mutations = case.get("mutations")
        if not isinstance(mutations, list):
            raise PublicFingerprintCorpusError(
                f"Corpus case {case_id} mutations must be a list."
            )
        for mutation in mutations:
            if not isinstance(mutation, dict):
                raise PublicFingerprintCorpusError(
                    f"Corpus case {case_id} has a non-object mutation."
                )
            apply_mutation(report, mutation)
        verify_privacy_boundary(report)
        summary = verifier.verification_summary(report)
        expected_public = case.get("publicAlphaQualified")
        expected_production = case.get("productionQualified")
        if not isinstance(expected_public, bool) or not isinstance(
            expected_production, bool
        ):
            raise PublicFingerprintCorpusError(
                f"Corpus case {case_id} must declare boolean outcomes."
            )
        actual = (
            bool(summary["qualified"]),
            bool(summary["productionQualified"]),
        )
        expected = (expected_public, expected_production)
        if actual != expected:
            raise PublicFingerprintCorpusError(
                f"Corpus case {case_id} expected {expected}, got {actual}."
            )
        observed_outcomes.add(actual)
        issue_contains = case.get("issueContains", [])
        if not isinstance(issue_contains, list) or not all(
            isinstance(value, str) and value for value in issue_contains
        ):
            raise PublicFingerprintCorpusError(
                f"Corpus case {case_id} issueContains must be strings."
            )
        all_issues = summary["issues"] + summary["productionIssues"]
        for required in issue_contains:
            if not any(required in issue for issue in all_issues):
                raise PublicFingerprintCorpusError(
                    f"Corpus case {case_id} is missing issue: {required}"
                )

    required_outcomes = {(True, True), (True, False), (False, False)}
    if not required_outcomes.issubset(observed_outcomes):
        raise PublicFingerprintCorpusError(
            "Corpus does not cover PASS, public-alpha-only and FAIL outcomes."
        )
    return (
        "Public fingerprint conformance corpus verified: "
        f"{len(cases)} synthetic cases; no profile, proxy or secret data."
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Verify the synthetic public NeAntik fingerprint conformance corpus."
        )
    )
    parser.add_argument(
        "--corpus",
        type=Path,
        default=DEFAULT_CORPUS,
    )
    args = parser.parse_args()
    try:
        print(verify_public_corpus(args.corpus.resolve()))
    except (PublicFingerprintCorpusError, ValueError, KeyError) as error:
        print(
            f"Public fingerprint corpus verification failed: {error}",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
