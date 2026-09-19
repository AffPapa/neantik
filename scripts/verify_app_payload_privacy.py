"""Fail closed on private payload files and recognized secrets; never print values."""
import importlib.util
import os
from pathlib import Path
import stat
import sys

_spec = importlib.util.spec_from_file_location('history_patterns', Path(__file__).with_name('audit-git-history-secrets.py'))
_patterns = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_patterns)
PROFILE_FILES = {'Cookies', 'Login Data', 'History', 'Web Data', 'Local State',
                 'Cookies-journal', 'Login Data-journal'}


def verify(root):
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Payload must be a real directory')
    root = root.resolve()
    count = 0
    for directory, folders, files in os.walk(root, followlinks=False):
        for name in folders + files:
            path = Path(directory) / name
            relative = path.relative_to(root)
            if (_patterns.unsafe_path_reason(str(relative)) or name in PROFILE_FILES
                    or name.startswith('.env.') or name in {'.git', '.ssh'}):
                raise ValueError('Private payload path: ' + str(relative))
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                try:
                    path.resolve(strict=True).relative_to(root)
                except (OSError, RuntimeError, ValueError):
                    raise ValueError('Payload symlink escapes or is invalid: ' + str(relative)) from None
                continue
            if stat.S_ISDIR(mode):
                continue
            if not stat.S_ISREG(mode):
                raise ValueError('Nonregular payload entry: ' + str(relative))
            count += 1
            tail = b''
            with path.open('rb') as source:
                while chunk := source.read(1024 * 1024):
                    data = tail + chunk
                    for label, pattern in _patterns.SECRET_PATTERNS.items():
                        if pattern.search(data):
                            raise ValueError('Recognized secret (' + label + ') in ' + str(relative))
                    tail = data[-4096:]
    return count


if __name__ == '__main__':
    try:
        if len(sys.argv) != 2:
            raise ValueError('Usage: verify_app_payload_privacy.py APP')
        print('Payload privacy patterns checked:', verify(sys.argv[1]), 'regular files')
    except (OSError, ValueError) as error:
        print('Payload privacy rejected: ' + str(error), file=sys.stderr)
        sys.exit(1)
