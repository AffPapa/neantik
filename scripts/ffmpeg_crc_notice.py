"""Bind the .80 FFmpeg CRC source and GPL text to runtime compliance output.

This supplement does not establish a complete corresponding-source offer.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

VERSION = "156.0.8078.80"
FILES = {
    "ffmpeg-crc.S": ("third_party/ffmpeg/libavutil/aarch64/crc.S", "03682b2b1de7ef13a22664e532b67d8ed77dccf8d31f4d431a5fb3864aeb8d71"),
    "ffmpeg-COPYING.GPLv2": ("third_party/ffmpeg/COPYING.GPLv2", "8177f97513213526df2cf6184d8ff986c675afb514d4e68a404010521b880643"),
}
NOTICE = b"""FFmpeg ARM64 CRC source notice\n\nChromium 156.0.8078.80 includes machine code matching the FFmpeg\nlibavutil/aarch64/crc.S source shipped alongside this notice. That source\nidentifies GPL version 2 or, at your option, any later version. Its copyright\nnotices and complete license header are retained in ffmpeg-crc.S. The GPL\nversion 2 text is supplied as ffmpeg-COPYING.GPLv2.\n\nThis supplement does not replace the full corresponding source, build and\nrelink materials, or the other third-party notices.\n"""

def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()

def make(source: Path, output: Path) -> dict:
    entries = {}
    for name, (relative, expected) in FILES.items():
        path = source / relative
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"missing regular FFmpeg input: {relative}")
        data = path.read_bytes()
        if digest(data) != expected:
            raise ValueError(f"unexpected FFmpeg input hash: {relative}")
        (output / name).write_bytes(data)
        entries[name] = expected
    name = "ffmpeg-crc-NOTICE.txt"
    (output / name).write_bytes(NOTICE)
    entries[name] = digest(NOTICE)
    return {"files": entries}

def verify(output: Path, metadata: object) -> None:
    expected = {name: value[1] for name, value in FILES.items()}
    expected["ffmpeg-crc-NOTICE.txt"] = digest(NOTICE)
    if metadata != {"files": expected}:
        raise ValueError("FFmpeg CRC supplemental manifest mismatch")
    for name, sha in expected.items():
        path = output / name
        if path.is_symlink() or not path.is_file() or digest(path.read_bytes()) != sha:
            raise ValueError(f"FFmpeg CRC supplement missing or changed: {name}")
