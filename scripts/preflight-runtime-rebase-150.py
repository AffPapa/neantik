#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


class RebasePreflightError(ValueError):
    pass


@dataclass(frozen=True)
class RebasePlan:
    target_version: str
    minimum_prepare_free_gib: int
    preserved_evidence_build_root: Path
    mac_commit: str
    mac_repository: str
    common_tag: str
    common_commit: str
    common_repository: str


def load_json(path: Path, label: str) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RebasePreflightError(f"Cannot read {label}: {error}") from error
    if not isinstance(value, dict):
        raise RebasePreflightError(f"{label} must be a JSON object")
    return value


def version_tuple(raw: object, label: str) -> tuple[int, int, int, int]:
    if not isinstance(raw, str):
        raise RebasePreflightError(f"{label} must be a string")
    parts = raw.split(".")
    if len(parts) != 4 or any(not part.isdigit() for part in parts):
        raise RebasePreflightError(f"{label} must be a four-part numeric version")
    return tuple(int(part) for part in parts)  # type: ignore[return-value]


def parse_plan(path: Path) -> RebasePlan:
    raw = load_json(path, "Chromium rebase plan")
    if raw.get("schemaVersion") != 1:
        raise RebasePreflightError("Unexpected Chromium rebase plan schema")
    mac = raw.get("macPackaging")
    common = raw.get("commonChromium")
    if not isinstance(mac, dict) or not isinstance(common, dict):
        raise RebasePreflightError("Rebase plan must contain macPackaging and commonChromium")
    minimum = raw.get("minimumPrepareFreeGiB")
    if not isinstance(minimum, int) or isinstance(minimum, bool) or minimum < 55:
        raise RebasePreflightError("minimumPrepareFreeGiB must be an integer >= 55")
    preserved = raw.get("preservedEvidenceBuildRoot")
    if not isinstance(preserved, str) or not preserved.startswith("/"):
        raise RebasePreflightError("preservedEvidenceBuildRoot must be an absolute path")

    required_strings = [
        (raw.get("targetChromiumVersion"), "targetChromiumVersion"),
        (mac.get("repository"), "macPackaging.repository"),
        (mac.get("commit"), "macPackaging.commit"),
        (common.get("repository"), "commonChromium.repository"),
        (common.get("tag"), "commonChromium.tag"),
        (common.get("commit"), "commonChromium.commit"),
    ]
    for value, label in required_strings:
        if not isinstance(value, str) or not value:
            raise RebasePreflightError(f"{label} must be a non-empty string")

    version_tuple(raw["targetChromiumVersion"], "targetChromiumVersion")
    return RebasePlan(
        target_version=str(raw["targetChromiumVersion"]),
        minimum_prepare_free_gib=minimum,
        preserved_evidence_build_root=Path(preserved),
        mac_commit=str(mac["commit"]),
        mac_repository=str(mac["repository"]),
        common_tag=str(common["tag"]),
        common_commit=str(common["commit"]),
        common_repository=str(common["repository"]),
    )


def existing_parent(path: Path) -> Path:
    probe = path
    while not probe.exists():
        if probe.parent == probe:
            raise RebasePreflightError(f"No existing parent for build root: {path}")
        probe = probe.parent
    if not probe.is_dir():
        raise RebasePreflightError(f"Existing parent is not a directory: {probe}")
    return probe


def assert_safe_build_root(build_root: Path, preserved: Path) -> None:
    if not build_root.is_absolute():
        raise RebasePreflightError("Build root must be an absolute path")
    resolved = build_root.resolve(strict=False)
    preserved_resolved = preserved.resolve(strict=False)
    project_root = Path(__file__).resolve().parents[1]
    user_home = Path.home().resolve()
    forbidden = {
        Path("/"),
        Path("/Users"),
        user_home,
        project_root,
        project_root.parent,
        Path("/private/tmp"),
        Path("/tmp"),
    }
    if resolved in forbidden:
        raise RebasePreflightError(f"Build root is too broad: {resolved}")
    if resolved == preserved_resolved:
        raise RebasePreflightError(
            "Build root must not be the preserved Chromium 144 evidence root"
        )
    if preserved_resolved in resolved.parents:
        raise RebasePreflightError(
            "Build root must not be nested inside the preserved Chromium 144 evidence root"
        )


def free_gib_for(path: Path) -> int:
    usage = shutil.disk_usage(existing_parent(path))
    return usage.free // (1024**3)


def git_head(path: Path) -> str | None:
    if not (path / ".git").exists():
        return None
    completed = subprocess.run(
        ["git", "-C", str(path), "rev-parse", "HEAD"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if completed.returncode != 0:
        return None
    return completed.stdout.strip()


def chromium_version_from_source_root(source_root: Path) -> str:
    version_path = source_root / "chrome" / "VERSION"
    try:
        lines = version_path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise RebasePreflightError(
            f"Chromium source root is missing chrome/VERSION: {source_root}"
        ) from error
    values: dict[str, str] = {}
    for line in lines:
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    try:
        version = ".".join(
            values[key] for key in ("MAJOR", "MINOR", "BUILD", "PATCH")
        )
    except KeyError as error:
        raise RebasePreflightError(
            f"chrome/VERSION is incomplete in Chromium source root: {source_root}"
        ) from error
    version_tuple(version, "chrome/VERSION")
    return version


def verify_source_root_version(source_root: Path, plan: RebasePlan) -> dict[str, object]:
    if not source_root.is_absolute():
        raise RebasePreflightError("Chromium source root must be an absolute path")
    if not source_root.is_dir():
        raise RebasePreflightError(f"Chromium source root does not exist: {source_root}")
    actual = chromium_version_from_source_root(source_root)
    if actual != plan.target_version:
        raise RebasePreflightError(
            f"Chromium source root version is {actual}, expected {plan.target_version}"
        )
    return {
        "sourceRoot": str(source_root),
        "chromiumVersion": actual,
        "versionVerified": True,
    }


def verify_existing_checkout(build_root: Path, plan: RebasePlan) -> list[str]:
    messages: list[str] = []
    if not build_root.exists():
        messages.append("Source checkout: not present yet")
        return messages
    if not build_root.is_dir():
        raise RebasePreflightError(f"Build root exists and is not a directory: {build_root}")
    if any(build_root.iterdir()) and not (build_root / ".git").exists():
        raise RebasePreflightError(
            "Build root is non-empty but is not a mac packaging checkout"
        )
    mac_head = git_head(build_root)
    if mac_head is not None:
        if mac_head != plan.mac_commit:
            raise RebasePreflightError(
                f"mac packaging checkout is at {mac_head}, expected {plan.mac_commit}"
            )
        messages.append("mac packaging checkout: pinned commit verified")
    common_root = build_root / "ungoogled-chromium"
    common_head = git_head(common_root)
    if common_root.exists() and common_head is None:
        raise RebasePreflightError(
            "common Chromium path exists but is not a git checkout"
        )
    if common_head is not None:
        if common_head != plan.common_commit:
            raise RebasePreflightError(
                f"common Chromium checkout is at {common_head}, expected {plan.common_commit}"
            )
        messages.append("common Chromium checkout: pinned commit verified")
    return messages


def verify(
    *,
    plan_path: Path,
    baseline_path: Path,
    build_root: Path,
    free_gib: int | None = None,
    source_root: Path | None = None,
) -> str:
    report = verify_report(
        plan_path=plan_path,
        baseline_path=baseline_path,
        build_root=build_root,
        free_gib=free_gib,
        source_root=source_root,
    )
    target_major = str(report["targetChromiumVersion"]).split(".", 1)[0]
    lines = [
        f"Chromium {target_major} rebase preflight passed for {report['buildRoot']}",
        f"Target Chromium: {report['targetChromiumVersion']}",
        f"mac packaging commit: {report['macPackaging']['commit']}",
        f"common Chromium tag: {report['commonChromium']['tag']}",
        f"common Chromium commit: {report['commonChromium']['commit']}",
        f"Free space: {report['freeGiB']} GiB",
        "Preserved Chromium 144 evidence root: untouched",
    ]
    lines.extend(str(message) for message in report["checkoutMessages"])
    source_report = report["sourceRoot"]
    if isinstance(source_report, dict) and source_report.get("versionVerified"):
        lines.append(
            "Chromium source root version: "
            f"{source_report['chromiumVersion']} verified"
        )
    return "\n".join(lines)


def verify_report(
    *,
    plan_path: Path,
    baseline_path: Path,
    build_root: Path,
    free_gib: int | None = None,
    source_root: Path | None = None,
) -> dict[str, object]:
    plan = parse_plan(plan_path)
    baseline = load_json(baseline_path, "runtime security baseline")
    minimum_public = baseline.get("minimumPublicChromiumVersion")
    if version_tuple(plan.target_version, "targetChromiumVersion") < version_tuple(
        minimum_public, "minimumPublicChromiumVersion"
    ):
        raise RebasePreflightError(
            f"Chromium rebase target {plan.target_version} is below security baseline {minimum_public}"
        )

    assert_safe_build_root(build_root, plan.preserved_evidence_build_root)
    actual_free = free_gib if free_gib is not None else free_gib_for(build_root)
    if actual_free < plan.minimum_prepare_free_gib:
        raise RebasePreflightError(
            f"At least {plan.minimum_prepare_free_gib} GiB free is required for Chromium prepare; available: {actual_free} GiB"
        )

    checkout_messages = verify_existing_checkout(build_root, plan)
    selected_source_root = source_root
    if selected_source_root is None:
        default_source_root = build_root / "build" / "src"
        selected_source_root = (
            default_source_root
            if (default_source_root / "chrome" / "VERSION").is_file()
            else None
        )
    source_report: dict[str, object] = {
        "sourceRoot": str(selected_source_root) if selected_source_root is not None else None,
        "chromiumVersion": None,
        "versionVerified": False,
        "state": "not-present-yet" if selected_source_root is None else "unchecked",
    }
    if selected_source_root is not None:
        source_report = verify_source_root_version(
            selected_source_root.resolve(strict=False),
            plan,
        )
        source_report["state"] = "verified"
    return {
        "ok": True,
        "buildRoot": str(build_root),
        "targetChromiumVersion": plan.target_version,
        "minimumPublicChromiumVersion": minimum_public,
        "minimumPrepareFreeGiB": plan.minimum_prepare_free_gib,
        "freeGiB": actual_free,
        "preservedEvidenceBuildRoot": str(plan.preserved_evidence_build_root),
        "preservedEvidenceBuildRootTouched": False,
        "macPackaging": {
            "repository": plan.mac_repository,
            "commit": plan.mac_commit,
        },
        "commonChromium": {
            "repository": plan.common_repository,
            "tag": plan.common_tag,
            "commit": plan.common_commit,
        },
        "sourceRoot": source_report,
        "checkoutMessages": checkout_messages,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Preflight a safe NeAntik Chromium source rebase workspace.",
    )
    parser.add_argument(
        "build_root",
        type=Path,
        nargs="?",
        default=Path("/private/tmp/nevision-chromium-150"),
    )
    parser.add_argument(
        "--project-root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
    )
    parser.add_argument(
        "--plan",
        type=Path,
        help=(
            "Rebase plan path. Defaults to "
            "<project-root>/runtime/chromium-151-rebase-plan.json for "
            "backward compatibility."
        ),
    )
    parser.add_argument("--free-gib", type=int, default=None)
    parser.add_argument(
        "--source-root",
        type=Path,
        help=(
            "Optional Chromium source root to verify against the rebase target. "
            "If omitted, build_root/build/src is verified only when it already exists."
        ),
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print a machine-readable preflight report. On failure, prints ok=false and exits non-zero.",
    )
    args = parser.parse_args()
    project_root = args.project_root.resolve()
    plan_path = (
        args.plan.resolve()
        if args.plan is not None
        else project_root / "runtime" / "chromium-150-rebase-plan.json"
    )
    try:
        if args.json:
            print(
                json.dumps(
                    verify_report(
                        plan_path=plan_path,
                        baseline_path=project_root / "runtime" / "security-baseline.json",
                        build_root=args.build_root,
                        free_gib=args.free_gib,
                        source_root=args.source_root,
                    ),
                    indent=2,
                    ensure_ascii=False,
                )
            )
        else:
            print(
                verify(
                    plan_path=plan_path,
                    baseline_path=project_root / "runtime" / "security-baseline.json",
                    build_root=args.build_root,
                    free_gib=args.free_gib,
                    source_root=args.source_root,
                )
            )
    except RebasePreflightError as error:
        if args.json:
            print(
                json.dumps(
                    {"ok": False, "error": str(error), "buildRoot": str(args.build_root)},
                    indent=2,
                    ensure_ascii=False,
                )
            )
        else:
            print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
