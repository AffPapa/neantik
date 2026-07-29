#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
PREFLIGHT_PATH = PROJECT_ROOT / "scripts" / "preflight-runtime-rebase-150.py"
SPEC = importlib.util.spec_from_file_location("preflight_runtime_rebase_150", PREFLIGHT_PATH)
assert SPEC and SPEC.loader
PREFLIGHT = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = PREFLIGHT
SPEC.loader.exec_module(PREFLIGHT)


DEFAULT_CANDIDATE_ROOTS = (
    Path("/private/tmp/nevision-chromium-150"),
    Path("/Volumes/NeAntikBuild/nevision-chromium-150"),
)
DEFAULT_DISK_CLEANUP_PLAN = PROJECT_ROOT / "dist" / "NeAntik-disk-cleanup-plan-latest.json"
OWNER_BUILD_ROOT_PLACEHOLDERS = [
    "<ABSOLUTE_CHROMIUM_150_BUILD_ROOT>",
]


def build_owner_build_root_input_template(
    *,
    required_free_gib: int,
    preserved_evidence_build_root: Path,
    recommended_external_build_root: Path,
) -> dict[str, Any]:
    return {
        "target": "owner-shell-environment",
        "format": "shell-env-template",
        "placeholdersMustBeReplaced": OWNER_BUILD_ROOT_PLACEHOLDERS,
        "requiredEnvironment": [
            'export NEANTIK_CHROMIUM_150_BUILD_ROOT="<ABSOLUTE_CHROMIUM_150_BUILD_ROOT>"',
        ],
        "defaultRecommendedValue": str(recommended_external_build_root),
        "validationRules": [
            "Value must be an absolute path.",
            f"Path must not equal preserved evidence build root {preserved_evidence_build_root}.",
            f"Path must have at least {required_free_gib} GiB free before bootstrap.",
            "Prefer a dedicated external APFS volume such as /Volumes/NeAntikBuild.",
            "Run preflight before bootstrap and after source extraction.",
        ],
        "applyThenVerify": [
            'python3 scripts/export-chromium-150-build-root-readiness.py --candidate-root "$NEANTIK_CHROMIUM_150_BUILD_ROOT"',
            'python3 scripts/preflight-runtime-rebase-150.py "$NEANTIK_CHROMIUM_150_BUILD_ROOT"',
            'python3 scripts/preflight-runtime-rebase-150.py --json "$NEANTIK_CHROMIUM_150_BUILD_ROOT"',
            'python3 scripts/generate-runtime-rebase-150-bootstrap.py "$NEANTIK_CHROMIUM_150_BUILD_ROOT" --output dist/NeAntik-Chromium-150-bootstrap.sh',
            "bash dist/NeAntik-Chromium-150-bootstrap.sh",
            'python3 scripts/preflight-runtime-rebase-150.py "$NEANTIK_CHROMIUM_150_BUILD_ROOT" --source-root "$NEANTIK_CHROMIUM_150_BUILD_ROOT/build/src"',
        ],
        "safetyBoundary": [
            "Do not set NEANTIK_CHROMIUM_150_BUILD_ROOT to the preserved Chromium 144 evidence root.",
            "Do not delete or mutate preserved evidence to create free space.",
            "Do not use shell globs, unresolved variables, or broad directories as build roots.",
            "Do not run bootstrap until the selected build root passes preflight.",
            "Do not mark Chromium 150 patches ported from this template alone.",
        ],
    }


def build_owner_decision_contract(
    *,
    required_free_gib: int,
    preserved_evidence_build_root: Path,
    external_build_root: Path,
) -> dict[str, Any]:
    volume_root = Path("/", *external_build_root.parts[1:3]) if len(external_build_root.parts) >= 3 else external_build_root.parent
    return {
        "status": "owner-storage-decision-required",
        "requiredFreeGiB": required_free_gib,
        "recommendedExternalVolume": str(volume_root),
        "recommendedExternalBuildRoot": str(external_build_root),
        "preservedEvidenceBuildRoot": str(preserved_evidence_build_root),
        "acceptedChoices": [
            "Mount an external APFS volume at /Volumes/NeAntikBuild with at least 55 GiB free.",
            "Provide another explicit absolute build root and run this exporter with --candidate-root.",
            "Make an explicit owner cleanup/storage decision that produces at least 55 GiB free without deleting protected evidence.",
        ],
        "commands": [
            f"mkdir -p {external_build_root}",
            f"scripts/preflight-runtime-rebase-150.py {external_build_root}",
            f"scripts/preflight-runtime-rebase-150.py --json {external_build_root}",
            (
                "scripts/generate-runtime-rebase-150-bootstrap.py "
                f"{external_build_root} --output dist/NeAntik-Chromium-150-bootstrap.sh"
            ),
            "bash dist/NeAntik-Chromium-150-bootstrap.sh",
        ],
        "prohibitedActions": [
            f"Do not delete or mutate {preserved_evidence_build_root} automatically.",
            "Do not reuse the preserved Chromium 144 evidence root as the Chromium 150 build root.",
            "Do not mark any patch group ported until the real Chromium 150 source root exists and git apply --check passes.",
            "Do not publish Direct runtime artifacts from a build root that has not passed preflight.",
        ],
        "releaseBoundary": (
            "This contract records the owner storage decision needed before Chromium 150 work can start. "
            "It does not mount disks, delete files, clone Chromium, apply patches, build, sign, notarize, or publish."
        ),
    }


def load_cleanup_projection(
    *,
    project_root: Path,
    disk_cleanup_plan: Path | None,
    required_free_gib: int,
) -> dict[str, Any] | None:
    if disk_cleanup_plan is None:
        return None
    path = disk_cleanup_plan if disk_cleanup_plan.is_absolute() else project_root / disk_cleanup_plan
    if not path.is_file():
        return {
            "source": str(path),
            "available": False,
            "safeDisposableCleanupCanSatisfyLocalBuildRoot": False,
            "error": "disk cleanup plan is missing",
        }
    try:
        plan = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return {
            "source": str(path),
            "available": False,
            "safeDisposableCleanupCanSatisfyLocalBuildRoot": False,
            "error": f"cannot read disk cleanup plan: {error}",
        }
    readiness = plan.get("rebaseReadiness")
    roots = readiness.get("roots") if isinstance(readiness, dict) else None
    private_tmp = roots.get("/private/tmp") if isinstance(roots, dict) else None
    approval = plan.get("approval") if isinstance(plan.get("approval"), dict) else {}
    if not isinstance(private_tmp, dict):
        return {
            "source": str(path),
            "available": False,
            "safeDisposableCleanupCanSatisfyLocalBuildRoot": False,
            "error": "disk cleanup plan is missing /private/tmp rebaseReadiness",
        }

    current = int(private_tmp.get("currentFreeGiB", 0))
    after_safe = int(private_tmp.get("afterSafeDisposableGiB", current))
    deficit = max(0, required_free_gib - after_safe)
    passes = bool(private_tmp.get("passesAfterSafeDisposable")) and after_safe >= required_free_gib
    return {
        "source": str(path.relative_to(project_root) if path.is_relative_to(project_root) else path),
        "available": True,
        "requiredFreeGiB": required_free_gib,
        "currentFreeGiB": current,
        "safeDisposableReclaimGiB": int(readiness.get("safeDisposableReclaimGiB", max(0, after_safe - current)))
        if isinstance(readiness, dict)
        else max(0, after_safe - current),
        "afterSafeDisposableGiB": after_safe,
        "deficitAfterSafeDisposableGiB": deficit,
        "safeDisposableCleanupCanSatisfyLocalBuildRoot": passes,
        "approvalRequired": bool(approval.get("required", True)),
        "approvalCommand": approval.get("executeCommand"),
    }


def build_candidate(
    *,
    project_root: Path,
    build_root: Path,
    free_gib: int | None = None,
) -> dict[str, Any]:
    plan_path = project_root / "runtime" / "chromium-150-rebase-plan.json"
    baseline_path = project_root / "runtime" / "security-baseline.json"
    parts = build_root.parts
    if len(parts) >= 3 and parts[1] == "Volumes":
        volume_root = Path("/", parts[1], parts[2])
        if not volume_root.is_dir():
            return {
                "buildRoot": str(build_root),
                "ready": False,
                "status": "not-mounted",
                "error": f"External volume is not mounted: {volume_root}",
                "preflightCommand": f"scripts/preflight-runtime-rebase-150.py {build_root}",
                "jsonPreflightCommand": f"scripts/preflight-runtime-rebase-150.py --json {build_root}",
                "bootstrapCommand": (
                    "scripts/generate-runtime-rebase-150-bootstrap.py "
                    f"{build_root} --output dist/NeAntik-Chromium-150-bootstrap.sh"
                ),
            }
    try:
        report = PREFLIGHT.verify_report(
            plan_path=plan_path,
            baseline_path=baseline_path,
            build_root=build_root,
            free_gib=free_gib,
        )
    except PREFLIGHT.RebasePreflightError as error:
        return {
            "buildRoot": str(build_root),
            "ready": False,
            "status": "blocked",
            "error": str(error),
            "preflightCommand": f"scripts/preflight-runtime-rebase-150.py {build_root}",
            "jsonPreflightCommand": f"scripts/preflight-runtime-rebase-150.py --json {build_root}",
            "bootstrapCommand": (
                "scripts/generate-runtime-rebase-150-bootstrap.py "
                f"{build_root} --output dist/NeAntik-Chromium-150-bootstrap.sh"
            ),
        }

    return {
        "buildRoot": str(build_root),
        "ready": True,
        "status": "ready-for-source-pair-bootstrap",
        "preflight": report,
        "preflightCommand": f"scripts/preflight-runtime-rebase-150.py {build_root}",
        "jsonPreflightCommand": f"scripts/preflight-runtime-rebase-150.py --json {build_root}",
        "bootstrapCommand": (
            "scripts/generate-runtime-rebase-150-bootstrap.py "
            f"{build_root} --output dist/NeAntik-Chromium-150-bootstrap.sh"
        ),
    }


def build_readiness(
    *,
    project_root: Path = PROJECT_ROOT,
    candidate_roots: list[Path] | None = None,
    generated_at: str | None = None,
    free_gib: int | None = None,
    disk_cleanup_plan: Path | None = DEFAULT_DISK_CLEANUP_PLAN,
) -> dict[str, Any]:
    candidate_roots = candidate_roots or list(DEFAULT_CANDIDATE_ROOTS)
    generated_at = generated_at or datetime.now(timezone.utc).isoformat(timespec="seconds")
    plan = PREFLIGHT.parse_plan(project_root / "runtime" / "chromium-150-rebase-plan.json")
    candidates = [
        build_candidate(project_root=project_root, build_root=root, free_gib=free_gib)
        for root in candidate_roots
    ]
    ready = [candidate for candidate in candidates if candidate["ready"]]
    external_candidates = [
        candidate
        for candidate in candidates
        if str(candidate["buildRoot"]).startswith("/Volumes/")
    ]
    preferred_external = (
        Path(str(external_candidates[0]["buildRoot"]))
        if external_candidates
        else Path("/Volumes/NeAntikBuild/nevision-chromium-150")
    )
    cleanup_projection = load_cleanup_projection(
        project_root=project_root,
        disk_cleanup_plan=disk_cleanup_plan,
        required_free_gib=plan.minimum_prepare_free_gib,
    )
    safe_cleanup_ready = bool(
        cleanup_projection
        and cleanup_projection.get("safeDisposableCleanupCanSatisfyLocalBuildRoot") is True
    )
    return {
        "schemaVersion": 1,
        "generatedAt": generated_at,
        "mode": "chromium-150-build-root-readiness",
        "targetChromiumVersion": plan.target_version,
        "minimumPrepareFreeGiB": plan.minimum_prepare_free_gib,
        "preservedEvidenceBuildRoot": str(plan.preserved_evidence_build_root),
        "releaseBoundary": (
            "This report is read-only. It does not delete files, clone sources, "
            "apply patches, build Chromium, or qualify a public release. It only "
            "selects build-root candidates that pass the Chromium 150 preflight."
        ),
        "summary": {
            "candidateCount": len(candidates),
            "readyCount": len(ready),
            "hasReadyBuildRoot": bool(ready),
            "recommendedBuildRoot": ready[0]["buildRoot"] if ready else None,
            "safeDisposableCleanupCanSatisfyLocalBuildRoot": safe_cleanup_ready,
            "localBuildRootRequiresExternalVolumeOrOwnerDecision": not bool(ready)
            and not safe_cleanup_ready,
        },
        "cleanupProjection": cleanup_projection,
        "ownerDecisionContract": build_owner_decision_contract(
            required_free_gib=plan.minimum_prepare_free_gib,
            preserved_evidence_build_root=plan.preserved_evidence_build_root,
            external_build_root=preferred_external,
        ),
        "ownerBuildRootInputTemplate": build_owner_build_root_input_template(
            required_free_gib=plan.minimum_prepare_free_gib,
            preserved_evidence_build_root=plan.preserved_evidence_build_root,
            recommended_external_build_root=preferred_external,
        ),
        "candidates": candidates,
        "nextSteps": [
            "Choose a candidate whose ready=true.",
            "If no candidate is ready, provision /Volumes/NeAntikBuild or make an explicit owner cleanup/storage decision.",
            "Run its bootstrapCommand to clone the pinned source pair.",
            "Unpack Chromium source into <buildRoot>/build/src with the approved build flow.",
            "Run scripts/preflight-runtime-rebase-150.py <buildRoot> --source-root <buildRoot>/build/src.",
            "Only then port the owned NeAntik Chromium 150 patchset.",
        ],
    }


def format_markdown(report: dict[str, Any]) -> str:
    summary = report["summary"]
    lines = [
        "# NeAntik Chromium 150 build-root readiness",
        "",
        f"- Generated: `{report['generatedAt']}`",
        f"- Target Chromium: `{report['targetChromiumVersion']}`",
        f"- Minimum free space: `{report['minimumPrepareFreeGiB']} GiB`",
        f"- Ready candidates: `{summary['readyCount']}` / `{summary['candidateCount']}`",
        f"- Recommended build root: `{summary['recommendedBuildRoot']}`",
        "- Safe-disposable cleanup can satisfy local build root: "
        f"`{str(summary.get('safeDisposableCleanupCanSatisfyLocalBuildRoot', False)).lower()}`",
        "- Local build root requires external volume or owner decision: "
        f"`{str(summary.get('localBuildRootRequiresExternalVolumeOrOwnerDecision', not bool(summary.get('hasReadyBuildRoot')))).lower()}`",
        "",
        report["releaseBoundary"],
        "",
        "## Cleanup projection",
        "",
    ]
    projection = report.get("cleanupProjection")
    if isinstance(projection, dict) and projection.get("available"):
        lines.extend(
            [
                f"- Source: `{projection['source']}`",
                f"- Current free: `{projection['currentFreeGiB']} GiB`",
                f"- Safe-disposable reclaim: `{projection['safeDisposableReclaimGiB']} GiB`",
                f"- After safe-disposable cleanup: `{projection['afterSafeDisposableGiB']} GiB`",
                f"- Deficit after safe-disposable cleanup: `{projection['deficitAfterSafeDisposableGiB']} GiB`",
                f"- Approval required: `{str(projection['approvalRequired']).lower()}`",
            ]
        )
    elif isinstance(projection, dict):
        lines.append(f"- Cleanup projection unavailable: {projection.get('error')}")
    else:
        lines.append("- Cleanup projection unavailable.")
    lines.extend(
        [
            "",
            "## Owner storage decision contract",
            "",
        ]
    )
    contract = report["ownerDecisionContract"]
    lines.extend(
        [
            f"- Status: `{contract['status']}`",
            f"- Required free space: `{contract['requiredFreeGiB']} GiB`",
            f"- Recommended external volume: `{contract['recommendedExternalVolume']}`",
            f"- Recommended external build root: `{contract['recommendedExternalBuildRoot']}`",
            f"- Preserved evidence build root: `{contract['preservedEvidenceBuildRoot']}`",
            "",
            "Accepted choices:",
            "",
        ]
    )
    for choice in contract["acceptedChoices"]:
        lines.append(f"- {choice}")
    lines.extend(["", "Commands after owner storage is ready:", "", "```bash"])
    lines.extend(contract["commands"])
    lines.extend(["```", "", "Prohibited actions:", ""])
    for action in contract["prohibitedActions"]:
        lines.append(f"- {action}")
    template = report["ownerBuildRootInputTemplate"]
    lines.extend(
        [
            "",
            contract["releaseBoundary"],
            "",
            "## Owner build-root input template",
            "",
            f"- Target: `{template['target']}`",
            f"- Format: `{template['format']}`",
            f"- Default recommended value: `{template['defaultRecommendedValue']}`",
            "",
            "Required environment:",
            "",
            "```bash",
        ]
    )
    lines.extend(template["requiredEnvironment"])
    lines.extend(["```", "", "Validation rules:", ""])
    for rule in template["validationRules"]:
        lines.append(f"- {rule}")
    lines.extend(["", "Apply, then verify:", "", "```bash"])
    lines.extend(template["applyThenVerify"])
    lines.extend(["```", "", "Safety boundary:", ""])
    for item in template["safetyBoundary"]:
        lines.append(f"- {item}")
    lines.extend(["", "## Candidates", ""])
    lines.extend(["| Ready | Status | Build root | Error |", "| --- | --- | --- | --- |"])
    for candidate in report["candidates"]:
        error = candidate.get("error", "")
        lines.append(
            f"| `{str(candidate['ready']).lower()}` | `{candidate['status']}` | "
            f"`{candidate['buildRoot']}` | {error} |"
        )
    lines.extend(["", "## Next steps", ""])
    for step in report["nextSteps"]:
        lines.append(f"- {step}")
    return "\n".join(lines) + "\n"


def write_outputs(report: dict[str, Any], *, output: Path, markdown: Path | None) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    if markdown is not None:
        markdown.parent.mkdir(parents=True, exist_ok=True)
        markdown.write_text(format_markdown(report), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Export a read-only Chromium 150 build-root readiness report.",
    )
    parser.add_argument("--project-root", type=Path, default=PROJECT_ROOT)
    parser.add_argument("--candidate-root", type=Path, action="append")
    parser.add_argument(
        "--output",
        type=Path,
        default=PROJECT_ROOT / "dist" / "NeAntik-Chromium-150-build-root-readiness.json",
    )
    parser.add_argument(
        "--markdown",
        type=Path,
        default=PROJECT_ROOT / "dist" / "NeAntik-Chromium-150-build-root-readiness.md",
    )
    parser.add_argument(
        "--free-gib",
        type=int,
        default=None,
        help="Test override for preflight free-space checks; do not use for real readiness.",
    )
    parser.add_argument(
        "--disk-cleanup-plan",
        type=Path,
        default=DEFAULT_DISK_CLEANUP_PLAN,
        help="Read-only disk cleanup plan used to project safe-disposable local build-root readiness.",
    )
    args = parser.parse_args()
    report = build_readiness(
        project_root=args.project_root.resolve(),
        candidate_roots=args.candidate_root,
        free_gib=args.free_gib,
        disk_cleanup_plan=args.disk_cleanup_plan,
    )
    write_outputs(report, output=args.output, markdown=args.markdown)
    print(args.output)
    print(
        "Ready build roots: "
        f"{report['summary']['readyCount']} / {report['summary']['candidateCount']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
