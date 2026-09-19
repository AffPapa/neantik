#!/usr/bin/env python3
"""Reject incompatible Ninja/log pairs before Ninja can discard its build log."""
from pathlib import Path
import re
import subprocess
import sys


def verify(ninja: Path, output: Path) -> None:
    result = subprocess.run([str(ninja), '--version'], capture_output=True, text=True, check=True)
    match = re.fullmatch(r'1\.(12|13)\.\d+(?:\.[A-Za-z0-9.-]+)?', result.stdout.strip())
    if not match:
        raise ValueError('Unreviewed Ninja version; check log compatibility before building')
    expected = 7 if match[1] == '13' else 6
    log = output / '.ninja_log'
    if log.is_symlink():
        raise ValueError('Build log must not be a symlink')
    if not log.exists():
        return
    with log.open('rb') as stream:
        header = stream.readline(128)
    if header != f'# ninja log v{expected}\n'.encode():
        raise ValueError('Ninja/log format mismatch: stop before the build log is discarded')


if __name__ == '__main__':
    try:
        if len(sys.argv) != 3:
            raise ValueError('Usage: verify_ninja_log_compatibility.py NINJA OUTPUT_DIRECTORY')
        verify(Path(sys.argv[1]), Path(sys.argv[2]))
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f'Ninja preflight failed: {error}', file=sys.stderr)
        sys.exit(1)
