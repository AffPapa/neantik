"""Fixture binding for the private TURN/TLS trust scope."""
import hashlib
import os
from pathlib import Path
import plistlib
import stat
import uuid

KEY = "NeAntikQATURNSTrustScope"
RECEIPT_KEY = "qaTURNSTrustScope"
FILE = "turns-qa-scope.plist"
SELECTOR = b"_neAntikRequireRTCProxy:turnsFixturePort:anchorDER:"


def receipt(scope: dict) -> dict:
    if not isinstance(scope, dict) or set(scope) != {"profileID", "port", "anchorDER"}:
        raise ValueError("invalid private TURN/TLS scope fields")
    profile_id, port, anchor = (scope[key] for key in ("profileID", "port", "anchorDER"))
    if (not isinstance(profile_id, str) or str(uuid.UUID(profile_id)) != profile_id
            or type(port) is not int or not 1024 <= port <= 65535
            or not isinstance(anchor, bytes) or not 1 <= len(anchor) <= 4096):
        raise ValueError("invalid private TURN/TLS scope values")
    return {"profileID": profile_id, "port": port,
            "anchorSHA256": hashlib.sha256(anchor).hexdigest()}


def load(root: Path) -> dict | None:
    path = root / FILE
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return None
    with os.fdopen(fd, "rb") as stream:
        entry = os.fstat(stream.fileno())
        if (not stat.S_ISREG(entry.st_mode) or entry.st_uid != os.geteuid()
                or stat.S_IMODE(entry.st_mode) != 0o600 or entry.st_nlink != 1
                or not 1 <= entry.st_size <= 8192):
            raise ValueError("private TURN/TLS fixture scope must be owner-only")
        scope = plistlib.loads(stream.read(8193))
        receipt(scope)
        return scope
