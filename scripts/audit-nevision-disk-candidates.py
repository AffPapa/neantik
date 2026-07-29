#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shutil
from dataclasses import asdict, dataclass
from pathlib import Path


@dataclass(frozen=True)
class DiskCandidate:
    path: str
    sizeBytes: int
    sizeMiB: int
    classification: str
    reason: str


def size_bytes(path: Path) -> int:
    if path.is_symlink():
        return path.lstat().st_size
    if path.is_file():
        return path.stat().st_size
    total = 0
    for root, dirs, files in os.walk(path):
        root_path = Path(root)
        for name in files:
            item = root_path / name
            try:
                total += item.lstat().st_size if item.is_symlink() else item.stat().st_size
            except OSError:
                continue
        for name in dirs:
            item = root_path / name
            if item.is_symlink():
                try:
                    total += item.lstat().st_size
                except OSError:
                    continue
    return total


def classify(path: Path, *, preserved_evidence_root: Path) -> tuple[str, str]:
    name = path.name
    resolved = path.resolve(strict=False)
    preserved = preserved_evidence_root.resolve(strict=False)
    if resolved == preserved or name == preserved.name:
        return (
            "protected",
            "Chromium 144 evidence build root; do not delete automatically.",
        )

    disposable_tokens = [
        "extracted",
        "roundtrip",
        "final-verify",
        "verify-",
        "delivery",
        "sign-runtime-test",
        "signing-input",
        "official-adhoc",
        "build-direct",
        "final-test-build",
        "integrated-archive",
        "integrated-compliance",
        "integrated-restore",
        "branded-runtime",
        "branded-kit",
        "runtime-kit",
        "telemetry-node_modules-partial",
        "sites-npm-cache",
    ]
    if any(token in name for token in disposable_tokens):
        return (
            "safe-disposable",
            "Temporary NeAntik build, extraction, cache, or round-trip artifact.",
        )

    approval_tokens = [
        "metaltoolchain",
        "research",
        "cloak-runtime",
    ]
    if name.endswith(".dmg") or any(token in name for token in approval_tokens):
        return (
            "requires-approval",
            "Large reusable/downloaded toolchain or research artifact; verify before deleting.",
        )

    return (
        "review",
        "Unrecognized NeAntik temporary artifact; inspect manually before deletion.",
    )


def scan(
    roots: list[Path],
    *,
    preserved_evidence_root: Path,
    minimum_mib: int,
) -> list[DiskCandidate]:
    candidates: list[DiskCandidate] = []
    seen: set[Path] = set()
    for root in roots:
        if not root.exists() or not root.is_dir():
            continue
        for path in sorted(root.glob("nevision*")):
            resolved = path.resolve(strict=False)
            if resolved in seen:
                continue
            seen.add(resolved)
            size = size_bytes(path)
            size_mib = size // (1024 * 1024)
            if size_mib < minimum_mib:
                continue
            classification, reason = classify(
                path,
                preserved_evidence_root=preserved_evidence_root,
            )
            candidates.append(
                DiskCandidate(
                    path=str(path),
                    sizeBytes=size,
                    sizeMiB=size_mib,
                    classification=classification,
                    reason=reason,
                )
            )
    return sorted(candidates, key=lambda item: item.sizeBytes, reverse=True)


def summarize(candidates: list[DiskCandidate]) -> dict[str, object]:
    by_class: dict[str, int] = {}
    for candidate in candidates:
        by_class[candidate.classification] = (
            by_class.get(candidate.classification, 0) + candidate.sizeBytes
        )
    return {
        "candidates": [asdict(candidate) for candidate in candidates],
        "totalsMiB": {
            classification: size // (1024 * 1024)
            for classification, size in sorted(by_class.items())
        },
    }


def root_free_space(roots: list[Path]) -> dict[str, int]:
    free: dict[str, int] = {}
    for root in roots:
        probe = root if root.exists() else root.parent
        while not probe.exists() and probe != probe.parent:
            probe = probe.parent
        if not probe.exists():
            continue
        usage = shutil.disk_usage(probe)
        free[str(root)] = usage.free // (1024 * 1024 * 1024)
    return free


def rebase_readiness(
    *,
    free_gib_by_root: dict[str, int],
    totals_mib: dict[str, int],
    required_free_gib: int,
) -> dict[str, object]:
    safe_reclaim_gib = totals_mib.get("safe-disposable", 0) // 1024
    readiness: dict[str, object] = {
        "requiredFreeGiB": required_free_gib,
        "safeDisposableReclaimGiB": safe_reclaim_gib,
        "roots": {},
    }
    roots: dict[str, object] = {}
    for root, free_gib in sorted(free_gib_by_root.items()):
        after_safe = free_gib + safe_reclaim_gib
        roots[root] = {
            "currentFreeGiB": free_gib,
            "afterSafeDisposableGiB": after_safe,
            "deficitAfterSafeDisposableGiB": max(0, required_free_gib - after_safe),
            "passesAfterSafeDisposable": after_safe >= required_free_gib,
        }
    readiness["roots"] = roots
    return readiness


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Read-only NeAntik disk inventory for Chromium 150 planning.",
    )
    parser.add_argument(
        "--root",
        type=Path,
        action="append",
        default=[Path("/private/tmp")],
        help="Directory whose immediate nevision* children should be inventoried.",
    )
    parser.add_argument(
        "--preserved-evidence-root",
        type=Path,
        default=Path("/private/tmp/nevision-chromium-build-20260725"),
    )
    parser.add_argument("--minimum-mib", type=int, default=100)
    parser.add_argument("--required-free-gib", type=int, default=55)
    args = parser.parse_args()
    report = summarize(
        scan(
            args.root,
            preserved_evidence_root=args.preserved_evidence_root,
            minimum_mib=args.minimum_mib,
        )
    )
    free_gib_by_root = root_free_space(args.root)
    report["freeGiBByRoot"] = free_gib_by_root
    report["rebaseReadiness"] = rebase_readiness(
        free_gib_by_root=free_gib_by_root,
        totals_mib=report["totalsMiB"],  # type: ignore[arg-type]
        required_free_gib=args.required_free_gib,
    )
    print(
        json.dumps(
            report,
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
