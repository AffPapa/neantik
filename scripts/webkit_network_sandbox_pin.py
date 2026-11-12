"""Verify the exact generated NetworkProcess sandbox resource before sealing."""
from hashlib import sha256
from pathlib import Path
import re

PIN_KEY = "NeAntikWebKitNetworkSandboxSHA256"
RELATIVE_PATH = Path("WebKit.framework/Versions/A/Resources/com.apple.WebKit.NetworkProcess.sb")
MAX_BYTES = 1024 * 1024


def verify(frameworks: Path, expected: str) -> str:
    if not isinstance(expected, str) or re.fullmatch(r"[0-9a-f]{64}", expected) is None:
        raise ValueError("Malformed owned WebKit NetworkProcess sandbox pin")
    path = frameworks / RELATIVE_PATH
    for directory in (frameworks, *path.parents[:len(RELATIVE_PATH.parts) - 1]):
        if directory.is_symlink() or not directory.is_dir():
            raise ValueError("Unsafe owned WebKit NetworkProcess sandbox directory")
    if path.is_symlink() or not path.is_file() or not 0 < path.stat().st_size <= MAX_BYTES:
        raise ValueError("Missing or unsafe owned WebKit NetworkProcess sandbox")
    with path.open("rb") as stream:
        data = stream.read(MAX_BYTES + 1)
    if not 0 < len(data) <= MAX_BYTES or sha256(data).hexdigest() != expected:
        raise ValueError("Owned WebKit NetworkProcess sandbox changed")
    return expected
