#!/usr/bin/env python3
"""Version-neutral entrypoint for the pinned Chromium rebase preflight.

The implementation remains in the historical ``-150`` module because old
workbench fixtures import that path. Current callers must use this entrypoint
and pass the exact versioned rebase plan explicitly.
"""

from __future__ import annotations

import runpy
import sys
from pathlib import Path


IMPLEMENTATION = Path(__file__).with_name("preflight-runtime-rebase-150.py")


def main() -> int:
    namespace = runpy.run_path(
        str(IMPLEMENTATION),
        run_name="neantik_runtime_rebase_compatibility_module",
    )
    implementation_main = namespace["main"]
    return int(implementation_main())


if __name__ == "__main__":
    raise SystemExit(main())
