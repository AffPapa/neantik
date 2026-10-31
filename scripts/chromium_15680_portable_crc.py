"""Verify the narrowly scoped portable-CRC derivation of the completed .80 build.

The base build stays immutable. This evidence binds an overlay, one rebuilt
object and a relinked framework; it does not attest runtime or distribution.
"""
from __future__ import annotations

import difflib
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shlex

MANIFEST = 'runtime/chromium-15680-portable-crc.json'
PATCH = 'runtime/chromium-15680-portable-crc.patch'
HEX = re.compile(r'^[0-9a-f]{64}$')
INPUTS = {
    'baseCRC': 'base-crc.c',
    'baseGN': 'base-ffmpeg_generated.gni',
    'configuration': 'config.h',
    'compileCommand': 'compile-command.txt',
    'linkCommand': 'link-command.txt',
}


def digest(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError('Portable CRC: ' + message)


def checked_file(project: Path, relative: str, expected: str) -> Path:
    parts = PurePosixPath(relative).parts
    require(bool(parts) and not relative.startswith('/') and '\\' not in relative
            and all(p not in {'.', '..'} for p in parts), 'unsafe evidence path')
    require(isinstance(expected, str) and bool(HEX.fullmatch(expected)), 'invalid digest')
    path = project
    for part in parts:
        path = path / part
        require(not path.is_symlink(), 'symlink in evidence path')
    require(path.is_file() and digest(path) == expected, 'evidence hash mismatch: ' + relative)
    return path


def source_overlay(crc: str, gn: str) -> dict[str, tuple[str, str]]:
    portable = crc.replace('#if ARCH_AARCH64\n', '#if ARCH_AARCH64 && CONFIG_GPL\n')
    portable = portable.replace('#elif ARCH_AARCH64\n', '#elif ARCH_AARCH64 && CONFIG_GPL\n')
    require(portable.count('ARCH_AARCH64 && CONFIG_GPL') == 4, 'unexpected CRC guards')
    line = '    "libavutil/aarch64/crc.S",\n'
    require(gn.count(line) == 1, 'unexpected assembly source list')
    return {'libavutil/crc.c': (crc, portable), 'ffmpeg_generated.gni': (gn, gn.replace(line, ''))}


def verify(project: Path, contract: dict) -> dict | None:
    binding = contract.get('portableCRC')
    if binding is None:
        return None
    require(isinstance(binding, dict) and set(binding) == {'file', 'sha256'}
            and binding['file'] == MANIFEST, 'invalid contract binding')
    manifest_path = checked_file(project, MANIFEST, binding['sha256'])
    data = json.loads(manifest_path.read_text())
    require(isinstance(data, dict), 'manifest must be an object')
    require(data.get('schemaVersion') == 1 and data.get('chromiumVersion') == '156.0.8078.80'
            and data.get('status') == 'portable-crc-compiled-and-relinked-unqualified'
            and data.get('releaseQualified') is False, 'invalid derivation state')
    require(data.get('candidateOutputDirectory') == 'out/NeAntikStable156_80PortableCRC',
            'unexpected derived candidate directory')
    base_path = checked_file(project, 'runtime/chromium-15680-build-evidence.json',
                             data.get('baseBuildEvidenceSHA256'))
    require(data.get('baseBuildEvidenceSHA256') == contract.get('buildEvidenceSHA256')
            == digest(base_path), 'base build binding mismatch')
    base = json.loads(base_path.read_text())
    require(data.get('browserExecutableSHA256') == base.get('browserExecutableSHA256')
            and data.get('baseFrameworkSHA256') == base.get('frameworkSHA256')
            and data.get('buildArgsSHA256') == base.get('buildConfigurationSHA256'),
            'base binary/configuration identity mismatch')
    inputs = data.get('inputs', {})
    require(isinstance(inputs, dict) and set(inputs) == set(INPUTS), 'unexpected input set')
    paths = {}
    for key, filename in INPUTS.items():
        entry = inputs[key]
        relative = 'runtime/chromium-15680-portable-crc/' + filename
        require(isinstance(entry, dict) and entry.get('file') == relative, 'input path mismatch')
        paths[key] = checked_file(project, relative, entry.get('sha256'))
    require(re.search(r'^#define CONFIG_GPL 0$', paths['configuration'].read_text(), re.M)
            is not None, 'GPL-disabled configuration required')
    overlay = source_overlay(paths['baseCRC'].read_text(), paths['baseGN'].read_text())
    expected_sources = {
        path: {'beforeSHA256': hashlib.sha256(before.encode()).hexdigest(),
               'afterSHA256': hashlib.sha256(after.encode()).hexdigest()}
        for path, (before, after) in overlay.items()
    }
    require(data.get('sourceOverlay') == expected_sources, 'source overlay mismatch')
    expected_patch = ''.join(''.join(difflib.unified_diff(
        before.splitlines(True), after.splitlines(True),
        fromfile='a/' + name, tofile='b/' + name))
        for name, (before, after) in overlay.items()).encode()
    patch = checked_file(project, PATCH, data.get('patchSHA256'))
    require(patch.read_bytes() == expected_patch, 'patch differs from reviewed transformation')
    command = shlex.split(paths['compileCommand'].read_text())
    require(command[0] == '../../third_party/llvm-build/Release+Asserts/bin/clang'
            and '-I../../third_party/ffmpeg/chromium/config/Chrome/mac/arm64' in command
            and command[-4:] == ['-c', '../../third_party/ffmpeg/libavutil/autorename_libavutil_crc.c',
                                 '-o', 'obj/third_party/ffmpeg/ffmpeg_internal/autorename_libavutil_crc.o'],
            'unexpected single-object compile command')
    require('-Wl,--thinlto-jobs=2' in shlex.split(paths['linkCommand'].read_text()),
            'bounded link parallelism required')
    archive = data.get('archive', {})
    require(isinstance(archive, dict) and archive.get('removedMember') == 'ffmpeg_internal/crc.o'
            and archive.get('beforeMemberCount') == 296 and archive.get('afterMemberCount') == 295
            and archive.get('remainingMembersUnchanged') is True, 'archive derivation mismatch')
    require(type(data.get('compileExitCode')) is int and type(data.get('linkExitCode')) is int
            and data['compileExitCode'] == data['linkExitCode'] == 0,
            'compile and link must both succeed')
    outputs = data.get('outputs', {})
    require(isinstance(outputs, dict)
            and set(outputs) == {'crcObjectSHA256', 'ffmpegArchiveSHA256', 'frameworkSHA256'}
            and all(isinstance(x, str) and HEX.fullmatch(x) for x in outputs.values()),
            'invalid output binding')
    require(outputs['frameworkSHA256'] != base['frameworkSHA256'],
            'original framework cannot substitute for portable CRC output')
    return data


def verify_source(project: Path, contract: dict, source: Path) -> None:
    data = verify(project, contract)
    if data is None:
        return
    for name, binding in data['sourceOverlay'].items():
        checked_file(source, 'third_party/ffmpeg/' + name, binding['beforeSHA256'])
    checked_file(source, 'third_party/ffmpeg/chromium/config/Chrome/mac/arm64/config.h',
                 data['inputs']['configuration']['sha256'])


def for_lock(project: Path, lock: dict) -> dict | None:
    contract = json.loads((project / 'runtime/chromium-15680-source-contract.json').read_text())
    data = verify(project, contract)
    expected = contract.get('portableCRC', {}).get('sha256')
    owned = lock.get('ownedInputs', {})
    require(isinstance(owned, dict) and owned.get('portableCrcManifestSHA256') == expected,
            'runtime lock does not bind the selected CRC derivation')
    return data
