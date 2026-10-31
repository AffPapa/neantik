"""Bind the selected .80 FFmpeg CRC source derivation to compliance output.

This supplement does not establish a complete corresponding-source offer.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LGPL_SHA256 = '246041b6ecf9bc32d718a62c57877c78b5eb397b6467e74ed7ae2626ab189c30'
PORTABLE_NOTICE = b"""FFmpeg portable CRC source notice

The selected Chromium framework was relinked with the portable libavutil CRC
implementation and CONFIG_GPL=0. The libavutil/aarch64/crc.S object was excluded
from the FFmpeg archive. The exact source change is in ffmpeg-portable-crc.patch;
the modified CRC source and LGPL version 2.1 text accompany this notice.

This describes the specific CRC change. It does not replace the complete
corresponding source, replacement/relink materials, or other third-party notices.
"""

VERSION = "156.0.8078.80"
FILES = {
    "ffmpeg-crc.S": ("third_party/ffmpeg/libavutil/aarch64/crc.S", "03682b2b1de7ef13a22664e532b67d8ed77dccf8d31f4d431a5fb3864aeb8d71"),
    "ffmpeg-COPYING.GPLv2": ("third_party/ffmpeg/COPYING.GPLv2", "8177f97513213526df2cf6184d8ff986c675afb514d4e68a404010521b880643"),
}
NOTICE = b"""FFmpeg ARM64 CRC source notice\n\nChromium 156.0.8078.80 includes machine code matching the FFmpeg\nlibavutil/aarch64/crc.S source shipped alongside this notice. That source\nidentifies GPL version 2 or, at your option, any later version. Its copyright\nnotices and complete license header are retained in ffmpeg-crc.S. The GPL\nversion 2 text is supplied as ffmpeg-COPYING.GPLv2.\n\nThis supplement does not replace the full corresponding source, build and\nrelink materials, or the other third-party notices.\n"""

def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()

def portable_payloads(data: dict) -> dict[str, bytes]:
    from chromium_15680_portable_crc import source_overlay, PATCH
    folder = ROOT / 'runtime/chromium-15680-portable-crc'
    overlay = source_overlay((folder / 'base-crc.c').read_text(),
                             (folder / 'base-ffmpeg_generated.gni').read_text())
    return {'ffmpeg-crc-portable.c': overlay['libavutil/crc.c'][1].encode(),
            'ffmpeg-portable-crc.patch': (ROOT / PATCH).read_bytes(),
            'ffmpeg-crc-NOTICE.txt': PORTABLE_NOTICE}


def make(source: Path, output: Path, *, lock: dict | None = None) -> dict:
    if lock is not None:
        from chromium_15680_portable_crc import for_lock, verify_source
        portable = for_lock(ROOT, lock)
        if portable is not None:
            contract = json.loads((ROOT / 'runtime/chromium-15680-source-contract.json').read_text())
            if lock.get('variant') == 'recipient-privacy-policy-v1':
                from chromium_15680_privacy_derivation import verify_lock_binding
                from chromium_15680_portable_crc import checked_file
                verify_lock_binding(lock, ROOT)
                for name, binding in portable['sourceOverlay'].items():
                    checked_file(source, 'third_party/ffmpeg/' + name, binding['afterSHA256'])
                checked_file(source, 'third_party/ffmpeg/chromium/config/Chrome/mac/arm64/config.h',
                             portable['inputs']['configuration']['sha256'])
            else:
                verify_source(ROOT, contract, source)
            license_path = source / 'third_party/ffmpeg/COPYING.LGPLv2.1'
            if license_path.is_symlink() or digest(license_path.read_bytes()) != LGPL_SHA256:
                raise ValueError('unexpected portable CRC LGPL input')
            payloads = portable_payloads(portable)
            payloads['ffmpeg-COPYING.LGPLv2.1'] = license_path.read_bytes()
            for name, payload in payloads.items():
                (output / name).write_bytes(payload)
            return {'mode': 'portable-crc',
                    'bindingSHA256': lock['ownedInputs']['portableCrcManifestSHA256'],
                    'files': {name: digest(payload) for name, payload in payloads.items()}}
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

def verify(output: Path, metadata: object, *, lock: dict | None = None) -> None:
    if lock is not None:
        from chromium_15680_portable_crc import for_lock
        portable = for_lock(ROOT, lock)
        if portable is not None:
            expected = {name: digest(payload) for name, payload in portable_payloads(portable).items()}
            expected['ffmpeg-COPYING.LGPLv2.1'] = LGPL_SHA256
            if metadata != {'mode': 'portable-crc',
                            'bindingSHA256': lock['ownedInputs']['portableCrcManifestSHA256'],
                            'files': expected}:
                raise ValueError('Portable CRC supplemental manifest mismatch')
            for name, sha in expected.items():
                path = output / name
                if path.is_symlink() or not path.is_file() or digest(path.read_bytes()) != sha:
                    raise ValueError('Portable CRC supplement missing or changed: ' + name)
            return
    expected = {name: value[1] for name, value in FILES.items()}
    expected["ffmpeg-crc-NOTICE.txt"] = digest(NOTICE)
    if metadata != {"files": expected}:
        raise ValueError("FFmpeg CRC supplemental manifest mismatch")
    for name, sha in expected.items():
        path = output / name
        if path.is_symlink() or not path.is_file() or digest(path.read_bytes()) != sha:
            raise ValueError(f"FFmpeg CRC supplement missing or changed: {name}")
