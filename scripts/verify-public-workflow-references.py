#!/usr/bin/env python3
from __future__ import annotations

import argparse
import ast
import re
import sys
from collections import deque
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
PUBLIC_WORKFLOW_ENTRYPOINTS = (
    ".github/workflows/ci.yml",
    "README.md",
    "README.en.md",
    "CONTRIBUTING.md",
    "docs/BUILDING.md",
    "docs/DISTRIBUTION.md",
    "docs/RUNTIME_AUDIT_KIT_README.md",
    "scripts/release-direct.sh",
    "scripts/package-runtime-audit-kit.sh",
    "scripts/Run-NeAntik-0.3.12-DMG-Release.command",
    "scripts/Run-NeAntik-0.3.12-DMG-Hosted-Verification.command",
)
LOCAL_REFERENCE = re.compile(
    r"(?:"
    r"\$(?:PROJECT_DIR|PROJECT_ROOT|REPO_ROOT)/"
    r"|(?<![A-Za-z0-9_./-])(?:\./)?"
    r")"
    r"(?P<path>(?:scripts|docs)/[A-Za-z0-9_./-]+"
    r"\.(?:py|sh|command|md))"
)
SCRIPT_DIR_REFERENCE = re.compile(
    r"\$SCRIPT_DIR/"
    r"(?P<name>[A-Za-z0-9_.-]+\.(?:py|sh|command))"
)
MARKDOWN_LINK = re.compile(r"\[[^\]]+\]\((?P<target>[^)]+)\)")
EXPLICIT_NON_LOCAL_PLACEHOLDER_MARKERS = ("<", ">", "VERSION")
LOCAL_PYTHON_MODULE_PREFIXES = (
    "fingerprint_",
    "notary_",
    "release_",
    "runtime_",
)


class PublicWorkflowReferenceError(RuntimeError):
    pass


def is_explicit_non_local_placeholder(value: str) -> bool:
    return any(marker in value for marker in EXPLICIT_NON_LOCAL_PLACEHOLDER_MARKERS)


def require_safe_file(project_root: Path, relative: str, *, executable: bool) -> Path:
    path = project_root / relative
    if not path.is_file() or path.is_symlink():
        raise PublicWorkflowReferenceError(
            f"public workflow references missing or unsafe local file: {relative}"
        )
    if executable and not path.stat().st_mode & 0o111:
        raise PublicWorkflowReferenceError(
            f"public workflow invokes non-executable local script: {relative}"
        )
    return path


def reference_is_invoked_directly(line: str, reference: str) -> bool:
    prefix = line[: line.find(reference)]
    if re.search(r"(?:python3|python|bash|zsh|sh)\s+[\"']?$", prefix):
        return False
    if reference.endswith(".md"):
        return False
    return True


def verify_markdown_links(path: Path, *, project_root: Path) -> None:
    text = path.read_text(encoding="utf-8")
    for match in MARKDOWN_LINK.finditer(text):
        raw_target = match.group("target").strip()
        if (
            not raw_target
            or raw_target.startswith(("#", "mailto:"))
            or "://" in raw_target
            or is_explicit_non_local_placeholder(raw_target)
        ):
            continue
        target_without_anchor = raw_target.split("#", 1)[0]
        if not target_without_anchor:
            continue
        unresolved_candidate = path.parent / target_without_anchor
        candidate = unresolved_candidate.resolve()
        try:
            candidate.relative_to(project_root)
        except ValueError as error:
            raise PublicWorkflowReferenceError(
                f"{path.relative_to(project_root)} links outside the repository: "
                f"{raw_target}"
            ) from error
        if (
            not candidate.exists()
            or unresolved_candidate.is_symlink()
        ):
            raise PublicWorkflowReferenceError(
                f"{path.relative_to(project_root)} links to missing or unsafe "
                f"local target: {raw_target}"
            )


def local_python_imports(path: Path, text: str) -> set[str]:
    if path.suffix != ".py":
        return set()
    try:
        tree = ast.parse(text, filename=str(path))
    except SyntaxError as error:
        raise PublicWorkflowReferenceError(
            f"public Python workflow is invalid: {path.name}"
        ) from error
    references: set[str] = set()
    for node in ast.walk(tree):
        modules: list[str] = []
        if isinstance(node, ast.Import):
            modules.extend(alias.name for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module:
            modules.append(node.module)
        for module in modules:
            top_level = module.split(".", 1)[0]
            if top_level.startswith(LOCAL_PYTHON_MODULE_PREFIXES):
                references.add(
                    f"scripts/{top_level.replace('.', '/')}.py"
                )
    return references


def verify_public_workflow_references(
    *,
    project_root: Path = PROJECT_ROOT,
    entrypoints: tuple[str, ...] = PUBLIC_WORKFLOW_ENTRYPOINTS,
) -> tuple[int, int]:
    project_root = project_root.resolve()
    queue: deque[str] = deque(entrypoints)
    scanned: set[str] = set()
    references: set[str] = set()

    while queue:
        relative = queue.popleft()
        if relative in scanned:
            continue
        path = require_safe_file(
            project_root,
            relative,
            executable=relative.endswith((".sh", ".command")),
        )
        scanned.add(relative)
        if path.suffix == ".md":
            verify_markdown_links(path, project_root=project_root)

        text = path.read_text(encoding="utf-8")
        imported_references = local_python_imports(path, text)
        for reference in sorted(imported_references):
            require_safe_file(
                project_root,
                reference,
                executable=False,
            )
            references.add(reference)
            queue.append(reference)
        for line in text.splitlines():
            line_references = [
                match.group("path")
                for match in LOCAL_REFERENCE.finditer(line)
            ]
            line_references.extend(
                f"scripts/{match.group('name')}"
                for match in SCRIPT_DIR_REFERENCE.finditer(line)
            )
            for reference in line_references:
                if is_explicit_non_local_placeholder(reference):
                    continue
                invoked_directly = reference_is_invoked_directly(line, reference)
                require_safe_file(
                    project_root,
                    reference,
                    executable=(
                        invoked_directly
                        and reference.endswith((".sh", ".command"))
                    ),
                )
                references.add(reference)
                if (
                    reference.startswith("scripts/")
                    and not reference.startswith("scripts/tests/")
                ) or (
                    path.parts[-2:] == ("scripts", "package-runtime-audit-kit.sh")
                    and reference.startswith("docs/")
                ):
                    queue.append(reference)

    return len(scanned), len(references)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Verify the dependency closure of documented public build, release, "
            "hosted-download, and runtime-audit workflows."
        ),
    )
    parser.add_argument("--project-root", type=Path, default=PROJECT_ROOT)
    args = parser.parse_args()
    try:
        scanned, references = verify_public_workflow_references(
            project_root=args.project_root,
        )
    except (OSError, UnicodeDecodeError, PublicWorkflowReferenceError) as error:
        print(f"Public workflow reference verification failed: {error}", file=sys.stderr)
        return 65
    print(
        "PASS: public workflow dependency closure is complete; "
        f"{scanned} source file(s), {references} local reference(s)."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
