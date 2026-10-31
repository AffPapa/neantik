"""Frozen report for one reviewed signed privacy runtime, never new authority."""
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path
from chromium_15612_release_evidence import safe_relative_regular, need

NAME = 'chromium-15680-privacy-v1-runtime-verification.json'
SHA256 = '94e7dd5997fa1beded8fb9cc981592d2bbf31eb4c31a7f5de00ab37b9d295dc4'


def preserved_report_bytes(observed: dict, project: Path) -> bytes:
    path = safe_relative_regular(project / 'runtime', NAME)
    raw = path.read_bytes()
    need(len(raw) <= 131072 and hashlib.sha256(raw).hexdigest() == SHA256,
         'Frozen privacy runtime report changed')
    saved = json.loads(raw)
    need(set(saved) == set(observed), 'Privacy report fields differ')
    need(all(saved[key] == value for key, value in observed.items() if key != 'createdAt'),
         'Current signed privacy runtime differs from frozen report')
    def date(value): return datetime.fromisoformat(value.replace('Z', '+00:00'))
    need(date(saved['createdAt']) <= date(observed['createdAt']) <= datetime.now(timezone.utc),
         'Privacy report timestamp order invalid')
    return raw
