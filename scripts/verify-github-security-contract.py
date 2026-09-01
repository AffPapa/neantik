#!/usr/bin/env python3
from __future__ import annotations

import re
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
FULL_COMMIT = re.compile(r"^[0-9a-f]{40}$")
USES = re.compile(r"^\s*-?\s*uses:\s*([^\s#]+)", re.MULTILINE)


class GitHubSecurityContractError(ValueError):
    pass


def verify(project_root: Path = PROJECT_ROOT) -> tuple[int, int]:
    workflow_root = project_root / ".github" / "workflows"
    workflows = sorted(
        path
        for pattern in ("*.yml", "*.yaml")
        for path in workflow_root.glob(pattern)
    )
    if not workflows:
        raise GitHubSecurityContractError("no GitHub Actions workflows found")

    action_references = 0
    for workflow in workflows:
        if not workflow.is_file() or workflow.is_symlink():
            raise GitHubSecurityContractError(
                f"unsafe workflow path: {workflow.relative_to(project_root)}"
            )
        text = workflow.read_text(encoding="utf-8")
        if "permissions:\n  contents: read" not in text:
            raise GitHubSecurityContractError(
                f"{workflow.name} lacks explicit read-only root permissions"
            )
        if re.search(r"permissions:\s*(?:write-all|read-all)", text):
            raise GitHubSecurityContractError(
                f"{workflow.name} uses a broad permissions preset"
            )
        for raw_reference in USES.findall(text):
            if raw_reference.startswith("./"):
                continue
            action_references += 1
            if "@" not in raw_reference:
                raise GitHubSecurityContractError(
                    f"unversioned action reference in {workflow.name}"
                )
            _, revision = raw_reference.rsplit("@", 1)
            if not FULL_COMMIT.fullmatch(revision):
                raise GitHubSecurityContractError(
                    f"action is not pinned to a full commit in {workflow.name}"
                )

    codeql = (workflow_root / "codeql.yml").read_text(encoding="utf-8")
    for marker in (
        "languages: swift",
        "build-mode: manual",
        "languages: python",
        "build-mode: none",
        "security-events: write",
        "swift build --disable-sandbox --arch arm64",
    ):
        if marker not in codeql:
            raise GitHubSecurityContractError(
                f"CodeQL workflow is missing {marker!r}"
            )

    dependabot = project_root / ".github" / "dependabot.yml"
    if not dependabot.is_file() or dependabot.is_symlink():
        raise GitHubSecurityContractError(
            "missing safe .github/dependabot.yml"
        )
    dependabot_text = dependabot.read_text(encoding="utf-8")
    for marker in (
        'package-ecosystem: "github-actions"',
        'directory: "/"',
        'interval: "weekly"',
    ):
        if marker not in dependabot_text:
            raise GitHubSecurityContractError(
                f"Dependabot configuration is missing {marker!r}"
            )
    return len(workflows), action_references


def main() -> int:
    try:
        workflow_count, action_count = verify()
    except (OSError, UnicodeError, GitHubSecurityContractError) as error:
        print(f"GitHub security contract failed: {error}", file=sys.stderr)
        return 1
    print(
        "PASS: GitHub workflows use least-privilege roots and full action "
        f"SHAs; CodeQL and Dependabot are configured ({workflow_count} "
        f"workflows, {action_count} action references)."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
