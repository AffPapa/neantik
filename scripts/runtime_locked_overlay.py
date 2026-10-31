"""Apply reviewed source postimages with all-input checks and rollback.

This is a source preparation step, never a runtime qualification verdict.
"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
from typing import Callable


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def safe_target(root: Path, name: str) -> Path:
    parts = name.split("/")
    if not parts or any(part in {"", ".", ".."} for part in parts) or Path(name).is_absolute():
        raise ValueError("unsafe overlay path")
    target = root / name
    if any(path.is_symlink() for path in (target, *target.parents)
           if path == root or path.is_relative_to(root)):
        raise ValueError("overlay path crosses a symlink")
    if target.exists() and not target.is_file():
        raise ValueError("overlay target is not a regular file")
    return target


def apply_overlay(source: Path, postimages: Path, records: list[dict],
                  replace: Callable = os.replace, commit_receipt: Callable | None = None) -> None:
    if source.is_symlink() or postimages.is_symlink():
        raise ValueError("overlay roots must not be symlinks")
    source, postimages = source.resolve(strict=True), postimages.resolve(strict=True)
    prepared = []
    seen = set()
    # Read and validate the entire batch before any write.
    for record in records:
        name = record["path"]
        if name in seen:
            raise ValueError("duplicate overlay target")
        seen.add(name)
        target = safe_target(source, name)
        payload = safe_target(postimages, name).read_bytes()
        before = target.read_bytes() if target.exists() else None
        if (digest(before) if before is not None else None) != record["preimageSHA256"]:
            raise ValueError(f"overlay preimage mismatch: {name}")
        if digest(payload) != record["postimageSHA256"]:
            raise ValueError(f"overlay postimage mismatch: {name}")
        prepared.append((target, before, payload))
    committed = []
    try:
        for target, before, payload in prepared:
            # Recheck at the commit point; never overwrite an unrelated edit.
            current = target.read_bytes() if target.exists() else None
            if current != before:
                raise ValueError("overlay target changed before commit")
            target.parent.mkdir(parents=True, exist_ok=True)
            temporary = target.with_name(target.name + ".neantik-overlay-tmp")
            created = False
            try:
                with temporary.open("xb") as stream:
                    created = True
                    stream.write(payload)
                    stream.flush()
                    os.fsync(stream.fileno())
                replace(temporary, target)
            finally:
                if created:
                    temporary.unlink(missing_ok=True)
            committed.append((target, before, payload))
        for target, _, payload in committed:
            if target.read_bytes() != payload:
                raise ValueError("overlay post-commit validation failed")
        if commit_receipt is not None:
            commit_receipt()
    except BaseException as original_error:
        # An injected failing writer must not prevent recovery using os.replace.
        rollback_failures = []
        for target, before, payload in reversed(committed):
            try:
                if target.read_bytes() != payload:
                    raise ValueError("unrelated edit preserved")
                if before is None:
                    target.unlink()
                else:
                    temporary = target.with_name(target.name + ".neantik-overlay-rollback")
                    created = False
                    try:
                        with temporary.open("xb") as stream:
                            created = True
                            stream.write(before)
                            stream.flush()
                            os.fsync(stream.fileno())
                        os.replace(temporary, target)
                    finally:
                        if created:
                            temporary.unlink(missing_ok=True)
            except (OSError, ValueError):
                # Restore independent targets even when one target conflicts.
                rollback_failures.append(target.relative_to(source).as_posix())
        if rollback_failures:
            raise ValueError("overlay rollback incomplete: " + ", ".join(rollback_failures)) from original_error
        raise
