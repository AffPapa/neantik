"""Check a full private source inventory transition against reviewed overlays.

This does not qualify patches or caches itself. Callers supply independently
replayed patch records and verified cache records, then bind this result and
those inputs into the release evidence. Unknown deltas always fail.
"""
from __future__ import annotations

import re
from pathlib import PurePosixPath

from chromium_154_source_snapshot import compact_snapshot


class TransitionError(ValueError):
    pass


def _path(value):
    if (not isinstance(value, str) or not value or "\\" in value
            or PurePosixPath(value).is_absolute()
            or any(x in ("", ".", "..") for x in value.split("/"))):
        raise TransitionError("Unsafe transition path")
    return value


def _hash(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
        raise TransitionError("Invalid transition digest")
    return value


def _inventory(snapshot):
    compact_snapshot(snapshot)  # Check schema and inventory counts first.
    entries = snapshot["entries"]
    names = [_path(x["path"]) for x in entries]
    if names != sorted(set(names)):
        raise TransitionError("Inventory paths must be unique and sorted")
    return dict(zip(names, entries))


def verify_transition(before, after, overlays, caches=()):
    """Allow ordered file-content patches and exact added derived caches only."""
    overlays, caches = list(overlays), list(caches)
    old, new = _inventory(before), _inventory(after)
    headers = lambda snapshot: {k: v for k, v in snapshot.items()
                                if k not in ("entries", "sourceFileCount")}
    if headers(before) != headers(after):
        raise TransitionError("Unexpected source snapshot metadata change")
    if old.keys() - new.keys():
        raise TransitionError("Unexpected source deletion")

    chain = {}
    for record in overlays:
        path = _path(record["path"])
        pre, post = _hash(record["beforeSHA256"]), _hash(record["afterSHA256"])
        _hash(record["patchSHA256"])
        entry = old.get(path)
        if entry is None or entry.get("kind") != "file":
            raise TransitionError("Overlay must modify an existing regular file")
        if pre != chain.get(path, entry["sha256"]):
            raise TransitionError(f"Broken overlay order: {path}")
        chain[path] = post

    added_caches = {}
    for record in caches:
        path, source = _path(record["path"]), _path(record["sourcePath"])
        if (path in added_caches or path in old or "/__pycache__/" not in path
                or not path.endswith(".pyc") or not source.endswith(".py")
                or record.get("timestampAndCodeMatch") is not True):
            raise TransitionError("Invalid derived-cache attribution")
        source_entry = new.get(source, {})
        if (source_entry.get("kind") != "file"
                or source_entry.get("sha256") != _hash(record["sourceSHA256"])):
            raise TransitionError("Cache source digest mismatch")
        added_caches[path] = _hash(record["pycSHA256"])

    changes = []
    for path, entry in new.items():
        previous = old.get(path)
        if previous is None:
            if (entry.get("kind") != "file" or entry.get("mode") != 0o644
                    or added_caches.get(path) != entry.get("sha256")):
                raise TransitionError(f"Unexplained added source input: {path}")
        elif path in chain:
            if (entry.get("kind") != "file" or entry.get("mode") != previous.get("mode")
                    or entry.get("sha256") != chain[path]
                    or set(entry) != set(previous)):
                raise TransitionError(f"Overlay postimage or metadata mismatch: {path}")
            if any(entry[k] != previous[k] for k in entry if k not in ("sha256", "sizeBytes")):
                raise TransitionError("Overlay changed non-content metadata")
        elif entry != previous:
            raise TransitionError(f"Unexplained source change: {path}")
        if entry != previous:
            changes.append({"path": path, "before": previous, "after": entry})
    if set(added_caches) != new.keys() - old.keys():
        raise TransitionError("Cache attribution differs from added inputs")
    return {
        "schemaVersion": 1,
        "scope": "Exact full-inventory transition; overlay/cache provenance is a separate check",
        "beforeSnapshot": compact_snapshot(before),
        "afterSnapshot": compact_snapshot(after),
        "overlaySteps": overlays,
        "verifiedCaches": list(caches),
        "changes": changes,
        "unexplainedChanges": 0,
        "releaseReady": False,
    }
