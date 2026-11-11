#!/usr/bin/env python3
"""Verify the exact arm64 Chromium .79 app and build inputs before signing."""

from pathlib import Path
import subprocess
import sys

from chromium_15779_source import verify_unsigned_app


def main() -> int:
    if len(sys.argv) != 4:
        print("Usage: verify-chromium-15779-unsigned-candidate.py app args.gn provenance.json", file=sys.stderr)
        return 2
    try:
        verify_unsigned_app(*map(Path, sys.argv[1:]), Path(__file__).resolve().parents[1])
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"Unsigned Chromium .79 candidate rejected: {error}", file=sys.stderr)
        return 1
    print("PASS: unsigned Chromium .79 arm64 output matches exact source build evidence.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
