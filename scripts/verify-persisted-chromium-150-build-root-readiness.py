#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from copy import deepcopy
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
EXPORTER_PATH = PROJECT_ROOT / "scripts" / "export-chromium-150-build-root-readiness.py"
SPEC = importlib.util.spec_from_file_location(
    "export_chromium_150_build_root_readiness",
    EXPORTER_PATH,
)
assert SPEC and SPEC.loader
EXPORTER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = EXPORTER
SPEC.loader.exec_module(EXPORTER)


class PersistedBuildRootReadinessError(RuntimeError):
    pass


def normalized_report(report: dict[str, Any]) -> dict[str, Any]:
    normalized = deepcopy(report)
    normalized.pop("generatedAt", None)
    return normalized


def verify_persisted_readiness(*, project_root: Path = PROJECT_ROOT) -> str:
    project_root = project_root.resolve()
    json_path = project_root / "dist" / "NeAntik-Chromium-150-build-root-readiness.json"
    markdown_path = project_root / "dist" / "NeAntik-Chromium-150-build-root-readiness.md"
    if not json_path.is_file():
        raise PersistedBuildRootReadinessError(
            f"persisted Chromium 150 build-root readiness JSON is missing: {json_path}"
        )
    if not markdown_path.is_file():
        raise PersistedBuildRootReadinessError(
            f"persisted Chromium 150 build-root readiness markdown is missing: {markdown_path}"
        )

    persisted = json.loads(json_path.read_text(encoding="utf-8"))
    if not isinstance(persisted, dict):
        raise PersistedBuildRootReadinessError(
            "persisted Chromium 150 build-root readiness JSON must be an object"
        )
    current = EXPORTER.build_readiness(
        project_root=project_root,
        generated_at=str(persisted.get("generatedAt") or ""),
    )
    if normalized_report(persisted) != normalized_report(current):
        raise PersistedBuildRootReadinessError(
            "persisted Chromium 150 build-root readiness is stale; regenerate it with "
            "`scripts/export-chromium-150-build-root-readiness.py`"
        )

    summary = persisted.get("summary")
    if not isinstance(summary, dict):
        raise PersistedBuildRootReadinessError("build-root readiness summary must be an object")
    candidates = persisted.get("candidates")
    if not isinstance(candidates, list):
        raise PersistedBuildRootReadinessError("build-root readiness candidates must be a list")
    if summary.get("candidateCount") != len(candidates):
        raise PersistedBuildRootReadinessError("build-root readiness candidateCount mismatch")
    ready_count = sum(
        1 for candidate in candidates if isinstance(candidate, dict) and candidate.get("ready") is True
    )
    if summary.get("readyCount") != ready_count:
        raise PersistedBuildRootReadinessError("build-root readiness readyCount mismatch")
    contract = persisted.get("ownerDecisionContract")
    if not isinstance(contract, dict):
        raise PersistedBuildRootReadinessError("build-root readiness is missing ownerDecisionContract")
    if contract.get("status") != "owner-storage-decision-required":
        raise PersistedBuildRootReadinessError("ownerDecisionContract status mismatch")
    if contract.get("requiredFreeGiB") != persisted.get("minimumPrepareFreeGiB"):
        raise PersistedBuildRootReadinessError("ownerDecisionContract requiredFreeGiB mismatch")
    for key in (
        "recommendedExternalVolume",
        "recommendedExternalBuildRoot",
        "preservedEvidenceBuildRoot",
        "releaseBoundary",
    ):
        value = contract.get(key)
        if not isinstance(value, str) or not value:
            raise PersistedBuildRootReadinessError(f"ownerDecisionContract is missing {key}")
    if not str(contract["recommendedExternalBuildRoot"]).startswith("/Volumes/"):
        raise PersistedBuildRootReadinessError("ownerDecisionContract must prefer an external /Volumes build root")
    if contract["preservedEvidenceBuildRoot"] == contract["recommendedExternalBuildRoot"]:
        raise PersistedBuildRootReadinessError("ownerDecisionContract must not reuse preserved evidence root")
    for key in ("acceptedChoices", "commands", "prohibitedActions"):
        values = contract.get(key)
        if not isinstance(values, list) or not values or not all(isinstance(item, str) and item for item in values):
            raise PersistedBuildRootReadinessError(f"ownerDecisionContract {key} must be non-empty strings")
    prohibited_text = "\n".join(contract["prohibitedActions"]).lower()
    if "do not delete" not in prohibited_text or "preserved chromium 144" not in prohibited_text:
        raise PersistedBuildRootReadinessError("ownerDecisionContract must protect the Chromium 144 evidence root")
    boundary = str(contract["releaseBoundary"]).lower()
    for marker in ("does not mount", "delete files", "clone chromium", "publish"):
        if marker not in boundary:
            raise PersistedBuildRootReadinessError(
                f"ownerDecisionContract releaseBoundary is missing: {marker}"
            )
    template = persisted.get("ownerBuildRootInputTemplate")
    if not isinstance(template, dict):
        raise PersistedBuildRootReadinessError("build-root readiness is missing ownerBuildRootInputTemplate")
    if template.get("target") != "owner-shell-environment" or template.get("format") != "shell-env-template":
        raise PersistedBuildRootReadinessError("ownerBuildRootInputTemplate target/format mismatch")
    if template.get("placeholdersMustBeReplaced") != EXPORTER.OWNER_BUILD_ROOT_PLACEHOLDERS:
        raise PersistedBuildRootReadinessError("ownerBuildRootInputTemplate placeholders mismatch")
    required_env = "\n".join(str(item) for item in template.get("requiredEnvironment", []))
    if "NEANTIK_CHROMIUM_150_BUILD_ROOT" not in required_env or "<ABSOLUTE_CHROMIUM_150_BUILD_ROOT>" not in required_env:
        raise PersistedBuildRootReadinessError("ownerBuildRootInputTemplate requiredEnvironment is incomplete")
    if template.get("defaultRecommendedValue") != contract.get("recommendedExternalBuildRoot"):
        raise PersistedBuildRootReadinessError("ownerBuildRootInputTemplate defaultRecommendedValue mismatch")
    validation_rules = "\n".join(str(item) for item in template.get("validationRules", []))
    for phrase in (
        "absolute path",
        str(contract["preservedEvidenceBuildRoot"]),
        f"{persisted.get('minimumPrepareFreeGiB')} GiB free",
        "/Volumes/NeAntikBuild",
        "Run preflight",
    ):
        if phrase not in validation_rules:
            raise PersistedBuildRootReadinessError("ownerBuildRootInputTemplate validationRules are incomplete")
    apply_then_verify = "\n".join(str(item) for item in template.get("applyThenVerify", []))
    for command in (
        "export-chromium-150-build-root-readiness.py",
        "preflight-runtime-rebase-150.py",
        "generate-runtime-rebase-150-bootstrap.py",
        "NeAntik-Chromium-150-bootstrap.sh",
        "--source-root",
    ):
        if command not in apply_then_verify:
            raise PersistedBuildRootReadinessError(f"ownerBuildRootInputTemplate applyThenVerify is missing {command}")
    safety_boundary = "\n".join(str(item) for item in template.get("safetyBoundary", []))
    for phrase in (
        "preserved Chromium 144 evidence root",
        "Do not delete",
        "unresolved variables",
        "passes preflight",
        "Do not mark Chromium 150 patches ported",
    ):
        if phrase not in safety_boundary:
            raise PersistedBuildRootReadinessError("ownerBuildRootInputTemplate safetyBoundary is incomplete")
    expected_markdown = EXPORTER.format_markdown(persisted)
    actual_markdown = markdown_path.read_text(encoding="utf-8")
    if actual_markdown != expected_markdown:
        raise PersistedBuildRootReadinessError(
            "persisted Chromium 150 build-root readiness markdown is stale; regenerate it with "
            "`scripts/export-chromium-150-build-root-readiness.py`"
        )
    return (
        "Persisted Chromium 150 build-root readiness verified: "
        f"{ready_count}/{len(candidates)} ready candidate(s), "
        "owner storage decision contract present."
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify persisted NeAntik Chromium 150 build-root readiness artifacts.",
    )
    parser.add_argument("--project-root", type=Path, default=PROJECT_ROOT)
    args = parser.parse_args()
    try:
        print(verify_persisted_readiness(project_root=args.project_root))
    except (OSError, json.JSONDecodeError, PersistedBuildRootReadinessError) as error:
        print(f"Persisted Chromium 150 build-root readiness verification failed: {error}", file=sys.stderr)
        return 65
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
