#!/usr/bin/env python3
"""Independent reproduction of the fixed, installed M156 closure pins.

Read-only development/CI check, not update admission or installation authority.
Only an already qualified reference app may supply reference bytes. This script
never writes/replaces pins or signs an app. Native candidate validation uses the
compiled pins, not this script or an archive-selected reference directory.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import struct
import unicodedata

PROJECT = Path(__file__).resolve().parents[1]


def sized(value: str) -> bytes:
    data = value.encode('utf-8')
    return struct.pack('>I', len(data)) + data


def identity(value: os.stat_result) -> tuple:
    # Read access can update atime. It is neither custody nor reproducibility
    # evidence; detect object/size/owner/mode/link/mtime/ctime changes instead.
    return (value.st_dev, value.st_ino, value.st_uid, value.st_mode,
            value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns)


def transcript(scope: str, records: list[tuple[str, bytes]]) -> str:
    digest = hashlib.sha256(b'neantik-exact-runtime-closure-v1\0' + sized(scope)
                            + struct.pack('>I', len(records)))
    for _, record in sorted(records, key=lambda item: item[0].encode('utf-8')):
        digest.update(record)
    return digest.hexdigest()


def measure(root: Path, scope: str) -> dict:
    records: list[tuple[str, bytes]] = []
    total = 0
    machos: list[str] = []
    magics = [bytes.fromhex(x) for x in ('cffaedfe', 'cefaedfe', 'feedfacf',
              'feedface', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')]

    def walk(path: Path, relative: str) -> None:
        nonlocal total
        before = path.lstat()
        mode = stat.S_IMODE(before.st_mode)
        if len(records) >= 2_000 or mode & 0o7000:
            raise ValueError('reference entries/modes exceed policy')
        if stat.S_ISLNK(before.st_mode):
            if scope != 'runtime':
                raise ValueError('evidence link')
            kind = b'L'
            # No chmod on extraction symlinks: exact kind/path/target, no mode.
            payload = sized(os.readlink(path))
        elif stat.S_ISDIR(before.st_mode):
            kind = b'D'
            payload = struct.pack('>I', mode)
        elif stat.S_ISREG(before.st_mode):
            if before.st_nlink != 1:
                raise ValueError('hardlinked reference file')
            kind = b'F'
            total += before.st_size
            publication = scope == 'evidence' and relative == 'release-security-baseline.json'
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            try:
                actual = os.fstat(fd)
                if identity(before) != identity(actual):
                    raise ValueError('reference changed')
                head = os.pread(fd, 32, 0)
                if head[:4] in magics:
                    if scope != 'runtime' or len(head) != 32 or head[:8] != bytes.fromhex('cffaedfe0c000001'):
                        raise ValueError('reference architecture')
                    machos.append(relative)
                digest = hashlib.sha256()
                while chunk := os.read(fd, 1_048_576):
                    digest.update(chunk)
                if identity(os.fstat(fd)) != identity(actual):
                    raise ValueError('reference changed during hash')
            finally:
                os.close(fd)
            payload = struct.pack('>IQ', mode, before.st_size) + digest.digest()
        else:
            raise ValueError('reference special file')
        if kind == b'F' and publication:
            if mode != 0o600 or not 1 <= before.st_size <= 65_536:
                raise ValueError('publication baseline bounds/mode')
            total -= before.st_size
        else:
            records.append((relative, sized(relative) + kind + payload))
        if kind == b'D':
            for child in path.iterdir():
                # Match admitted NFC paths despite APFS decomposed enumeration.
                name = unicodedata.normalize('NFC', child.name)
                walk(child, relative + '/' + name if relative else name)
        if identity(path.lstat()) != identity(before):
            raise ValueError('reference changed during walk')

    walk(root, '')
    return {'digest': transcript(scope, records), 'entries': len(records),
            'bytes': total, 'machoCount': len(machos)}


def golden() -> None:
    records = [('', sized('') + b'D' + struct.pack('>I', 0o700)),
               ('dir', sized('dir') + b'D' + struct.pack('>I', 0o700)),
               ('dir/a.txt', sized('dir/a.txt') + b'F' + struct.pack('>IQ', 0o600, 6)
                + hashlib.sha256(b'hello\n').digest()),
               ('link', sized('link') + b'L' + sized('dir/a.txt')),
               ('é.txt', sized('é.txt') + b'F' + struct.pack('>IQ', 0o600, 0)
                + hashlib.sha256(b'').digest())]
    if transcript('runtime', records) != 'a43d10f462c05cff07b361bfce4885cff3f9bbb921f053e9629436331dc51fa3':
        raise ValueError('cross-language golden transcript mismatch')


def compiled_records(project: Path) -> list[dict]:
    """Read the two explicit compiled policies, never download-selected paths."""
    records = []
    for name, relative in (
        ('final9', 'Sources/DirectUpdateCore/DirectUpdateRuntimeProvenance.swift'),
        ('font-system-v1', 'Sources/DirectUpdateCore/DirectUpdateFontRuntimePins.swift'),
    ):
        path = project / relative
        if path.is_symlink() or path.stat().st_size > 256 * 1024:
            raise ValueError('compiled record source bound')
        source = path.read_text()
        def scalar(key: str, *, digest: bool = False):
            expression = (r'static let ' + key + r' = "([0-9a-f]{64})"' if digest
                          else r'\b' + key + r'(?:\s*:\s*Int64)?\s*=\s*([0-9_]+)')
            matches = re.findall(expression, source)
            if len(matches) != 1:
                raise ValueError('missing or ambiguous compiled record field: ' + key)
            return matches[0] if digest else int(matches[0].replace('_', ''))
        records.append({'name': name, 'reportDigest': scalar('reportDigest', digest=True),
            **{scope: {'digest': scalar(scope + 'Digest', digest=True),
                       'entries': scalar(scope + 'Entries'), 'bytes': scalar(scope + 'Bytes'),
                       'machoCount': 16 if scope == 'runtime' else 0}
               for scope in ('runtime', 'evidence')}})
    return records


def select_record(observed: dict, report_digest: str, records: list[dict]) -> str:
    matches = [record['name'] for record in records if
               all(observed.get(scope) == record[scope] for scope in ('runtime', 'evidence')) and
               report_digest == record['reportDigest']]
    if len(matches) != 1:
        raise ValueError('runtime/evidence/report do not match one complete compiled record')
    return matches[0]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference-app', type=Path, default=PROJECT / 'dist/NeAntik.app')
    args = parser.parse_args()
    try:
        golden()
        records = compiled_records(PROJECT)
        resources = args.reference_app / 'Contents/Resources'
        result = {}
        for scope, directory in [('runtime', 'NeAntik Browser.app'), ('evidence', 'NeAntikRuntimeEvidence')]:
            observed = measure(resources / directory, scope)
            result[scope] = observed
        report = resources / 'NeAntikRuntimeEvidence/runtime-verification.json'
        if report.stat().st_size > 65_536 or report.is_symlink():
            raise ValueError('report bound')
        selected = select_record(result, hashlib.sha256(report.read_bytes()).hexdigest(), records)
        # Source projections are reviewed checkout inputs, not values chosen by
        # the report. Large patch evidence is hashed, never executed or parsed
        # by native admission.
        from chromium_15612_packaged_evidence import process
        evidence = resources / 'NeAntikRuntimeEvidence'
        process(PROJECT, evidence, json.loads((evidence / 'fingerprint-chromium.lock.json').read_bytes()))
        # Publication is separately signed with the manager. It must match
        # today's reviewed release input, never the historical build date.
        spec = importlib.util.spec_from_file_location('update_publication_baseline',
            PROJECT / 'scripts/package-manager-release-baseline.py')
        publication = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(publication)
        publication.verify(PROJECT, evidence)
        print(json.dumps({'pass': True, 'scope': 'read-only reference reproducibility; not installer authority',
                          'completeCompiledRecord': selected,
                          'goldenTranscript': True, 'reviewedSourceProjections': True,
                          'publicationBaselineSeparatelyVerified': True, **result}, sort_keys=True))
        return 0
    except (OSError, ValueError) as error:
        print('Fixed runtime pin verification refused: ' + str(error))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
