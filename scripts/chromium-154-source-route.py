#!/usr/bin/env python3
"""Resolve M154 source/build inputs without changing the pinned M152 route."""

from __future__ import annotations

import json
import sys
from pathlib import Path

import runtime_source_provenance as provenance


VERSION = "154.0.8037.93"


def resolve(project_root: Path) -> dict[str, str]:
    project_root = project_root.resolve()
    contract, plan = provenance.contract_paths_for_version(
        VERSION,
        project_root=project_root,
    )
    toolchain_lock = project_root / "runtime" / "chromium-154-toolchain-lock.json"
    required = {
        "sourceContract": contract,
        "rebasePlan": plan,
        "toolchainLock": toolchain_lock,
    }
    missing = [str(path) for path in required.values() if not path.is_file()]
    if missing:
        raise provenance.SourceProvenanceError(
            "M154 route is incomplete; refusing to fall back to M152: "
            + ", ".join(missing)
        )
    return {key: str(path) for key, path in required.items()}


def main() -> int:
    if len(sys.argv) != 2:
        print(
            "Usage: chromium-154-source-route.py /absolute/path/to/project",
            file=sys.stderr,
        )
        return 64
    try:
        result = resolve(Path(sys.argv[1]))
    except provenance.SourceProvenanceError as error:
        print(str(error), file=sys.stderr)
        return 65
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
