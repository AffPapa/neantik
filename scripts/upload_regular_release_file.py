"""Open an allowed regular payload before starting the restricted transport."""
import os
from pathlib import Path
import re
import stat
import subprocess
import sys


def open_payload(path):
    """Pin every directory component; never follow ancestor or final symlinks."""
    if '..' in path.parts:
        raise ValueError('Parent traversal is not allowed in upload paths')
    absolute = Path(os.path.abspath(path))
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    parent = os.open(absolute.anchor, directory_flags)
    try:
        for component in absolute.parts[1:-1]:
            child = os.open(component, directory_flags, dir_fd=parent)
            os.close(parent)
            parent = child
        return os.open(absolute.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
                       dir_fd=parent)
    finally:
        os.close(parent)


def upload(path, command):
    path = Path(path)
    if path.name not in ('release.json', 'content.json') and not re.fullmatch(
        r'NeAntik-[0-9]+\.[0-9]+\.[0-9]+-arm64-notarized\.(?:dmg|zip)(?:\.sha256)?', path.name
    ):
        raise ValueError('Upload filename is not allowed')
    # Directory descriptors also close ancestor check/open races. O_NONBLOCK
    # prevents a substituted FIFO from hanging before fstat.
    fd = open_payload(path)
    with os.fdopen(fd, 'rb') as payload:
        info = os.fstat(payload.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size <= 0:
            raise ValueError('Upload requires a nonempty regular file')
        return subprocess.run([*command, 'neantik-upload ' + path.name], stdin=payload, check=False).returncode


if __name__ == '__main__':
    try:
        if len(sys.argv) < 3:
            raise ValueError('Usage: upload_regular_release_file.py FILE TRANSPORT...')
        sys.exit(upload(sys.argv[1], sys.argv[2:]))
    except (OSError, ValueError) as error:
        print('Release upload rejected: ' + str(error), file=sys.stderr)
        sys.exit(1)
