#!/usr/bin/env python3
"""Apply the reviewed M154 Apple tuple renderer to official 154.0.8037.98."""

from __future__ import annotations

import importlib.util
from pathlib import Path


base = Path(__file__).with_name("apply-owned-runtime-device-tuples-154.py")
spec = importlib.util.spec_from_file_location("neantik_tuple_15493", base)
if spec is None or spec.loader is None:
    raise SystemExit("M154 tuple renderer is unavailable")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

# The seven reviewed preimages and eight postimages are unchanged by the
# official .93 -> .98 source delta. The wrapper changes only source identity;
# the renderer still verifies every exact byte hash before and after writing.
module.EXPECTED_SOURCE_COMMIT = "b859317bf11f6be47f9b7799ec690a0a42a1fb33"
module.EXPECTED_SOURCE_TREE = "e3eac82f3bb5479e80ab245c514083b5db4fedf3"
module.EXPECTED_CHROMIUM_VERSION = "154.0.8037.98"

if __name__ == "__main__":
    raise SystemExit(module.main())
