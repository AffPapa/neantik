"""Resolve immutable source evidence separately from the current release gate."""
import hashlib
import re
from pathlib import Path


def bound_baseline_path(runtime: Path, expected_sha256: object) -> Path:
    if not isinstance(expected_sha256, str) or not re.fullmatch(r"[0-9a-f]{64}", expected_sha256):
        raise ValueError("Source-bound security baseline requires an exact SHA-256")
    # The current file supports freshly created source contracts and isolated
    # fixtures. Published contracts keep binding their original archived bytes.
    for path in (runtime / "security-baseline.json",
                 runtime / "security-baselines" / f"{expected_sha256}.json"):
        if path.is_symlink() or path.parent.is_symlink() or not path.is_file():
            continue
        if hashlib.sha256(path.read_bytes()).hexdigest() == expected_sha256:
            return path
    raise ValueError("Exact source-bound security baseline bytes are unavailable")
