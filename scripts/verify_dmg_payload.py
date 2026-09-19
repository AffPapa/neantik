"""Validate the minimal Direct DMG layout without following the app link."""
from pathlib import Path
import os
import sys


def verify(root):
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise ValueError('DMG root must be a directory')
    names = {entry.name for entry in root.iterdir()}
    if names != {'NeAntik.app', 'Applications'}:
        raise ValueError('DMG contains missing or unexpected top-level entries')
    app = root / 'NeAntik.app'
    if app.is_symlink() or not app.is_dir():
        raise ValueError('DMG app must be a real directory')
    shortcut = root / 'Applications'
    if not shortcut.is_symlink() or os.readlink(shortcut) != '/Applications':
        raise ValueError('DMG Applications shortcut is invalid')


if __name__ == '__main__':
    try:
        if len(sys.argv) != 2:
            raise ValueError('Usage: verify_dmg_payload.py MOUNT_POINT')
        verify(sys.argv[1])
    except (OSError, ValueError) as error:
        print('DMG payload rejected: ' + str(error), file=sys.stderr)
        sys.exit(1)
