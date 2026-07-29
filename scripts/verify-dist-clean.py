#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
FORBIDDEN_DIRS = {"__MACOSX"}


class DistCleanError(RuntimeError):
    pass


def is_forbidden(path: Path) -> bool:
    name = path.name
    return name == ".DS_Store" or name.startswith("._") or name in FORBIDDEN_DIRS


def find_forbidden_metadata(root: Path) -> list[Path]:
    if not root.exists():
        return []
    return sorted(path for path in root.rglob("*") if is_forbidden(path))


def verify_dist_clean(*, dist_root: Path) -> list[Path]:
    forbidden = find_forbidden_metadata(dist_root)
    if forbidden:
        raise DistCleanError(
            "Forbidden Finder metadata in dist: "
            + ", ".join(str(path) for path in forbidden[:10])
        )
    return forbidden


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify NeAntik dist has no Finder metadata files.",
    )
    parser.add_argument("--dist-root", type=Path, default=PROJECT_ROOT / "dist")
    args = parser.parse_args()
    try:
        verify_dist_clean(dist_root=args.dist_root.resolve())
    except (OSError, DistCleanError) as error:
        print(f"Dist clean verification failed: {error}", file=sys.stderr)
        return 65
    print(f"Dist clean verified: {args.dist_root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
