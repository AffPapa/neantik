#!/usr/bin/env python3
"""Remove build-machine Swift toolchain search paths before signing the manager."""
from pathlib import Path
import re
import subprocess
import sys


def toolchain_rpaths(load_commands: str) -> list[str]:
    return [path for path in re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset \d+\)', load_commands)
            if '.xctoolchain/' in path and path.startswith(('/Users/', '/Applications/', '/Library/'))]


def main() -> None:
    binary = Path(sys.argv[1])
    if binary.is_symlink() or not binary.is_file():
        raise SystemExit('Expected a regular manager executable')
    dependencies = subprocess.check_output(['xcrun', 'otool', '-L', str(binary)], text=True).splitlines()[1:]
    # This manager uses system Swift libraries. Do not silently change a binary
    # whose dependencies need a toolchain or an unresolved @rpath library.
    if any(not line.strip().startswith(('/usr/lib/', '/System/Library/')) for line in dependencies):
        raise SystemExit('Manager has non-system dependencies; review before removing toolchain paths')
    commands = subprocess.check_output(['xcrun', 'otool', '-l', str(binary)], text=True)
    paths = toolchain_rpaths(commands)
    for path in paths:
        subprocess.run(['xcrun', 'install_name_tool', '-delete_rpath', path, str(binary)], check=True)
    remaining = subprocess.check_output(['xcrun', 'otool', '-l', str(binary)], text=True)
    if toolchain_rpaths(remaining):
        raise SystemExit('Toolchain RPATH removal failed')
    print(f'Manager packaging: removed {len(paths)} build-only toolchain RPATH entries.')


if __name__ == '__main__':
    main()
