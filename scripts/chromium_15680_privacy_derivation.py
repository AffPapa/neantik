"""A bounded recipient derivation; never impersonates a full gclient build.

Compiled-layer verification is useful during development. Release callers must
use verify() with its default require_link=True and a separately trusted binding.
No command recorded by this module is ever executed by verification.
"""
from __future__ import annotations
import difflib
import json
import shlex
from pathlib import Path
from chromium_15680_portable_crc import HEX, checked_file, digest, require, verify as verify_crc

MANIFEST = 'runtime/privacy-policy-v1/derivation.json'
OUT = 'out/NeAntikStable156_48'
COMPILER = '../../third_party/llvm-build/Release+Asserts/bin/clang++'
FRAMEWORK = 'obj/chrome/chrome_framework_shared_library/NeAntik Browser Framework'
BASE = {
    'sourceContract': {'file': 'runtime/chromium-15680-source-contract.json',
                       'sha256': '47535a1d5a121e71a3bb77b5528d8e2ef6173863ff75b07657104324709be92f'},
    'portableCRC': {'file': 'runtime/chromium-15680-portable-crc.json',
                    'sha256': '81b2ab0cd60f08b59310f624eda403af0a23636c66bfaac097832a2a15e1cdf0'},
    'sourceOfferManifestSHA256': '1a28ebe4729b0cde8f3770315a15237f4a025aec9b6fd0fcd9edfc278fcdff5a',
}
SOURCES = {
    'third_party/blink/renderer/modules/peerconnection/rtc_peer_connection.cc': 'obj/third_party/blink/renderer/modules/peerconnection/peerconnection/rtc_peer_connection.o',
    'components/content_settings/core/browser/host_content_settings_map.cc': 'obj/components/content_settings/core/browser/browser/host_content_settings_map.o',
    'third_party/blink/renderer/modules/webgl/webgl_rendering_context_base.cc': 'obj/third_party/blink/renderer/modules/webgl/webgl/webgl_rendering_context_base.o',
    'chrome/browser/ui/views/frame/contents_container_view.cc': 'obj/chrome/browser/ui/views/frame/contents_container_view_impl/contents_container_view.o',
    'chrome/browser/chrome_content_browser_client.cc': 'obj/chrome/browser/core/chrome_content_browser_client.o',
    'components/autofill/core/common/autofill_prefs.cc': 'obj/components/autofill/core/common/common/autofill_prefs.o',
    'chrome/browser/password_manager/chrome_password_manager_client.cc': 'obj/chrome/browser/password_manager/impl/chrome_password_manager_client.o',
    'chrome/common/chrome_paths_mac.mm': 'obj/chrome/common/constants/chrome_paths_mac.o',
}


ARCHIVES = {
    'obj/third_party/blink/renderer/modules/peerconnection/peerconnection/rtc_peer_connection.o': 'obj/third_party/blink/renderer/modules/peerconnection/libpeerconnection.a',
    'obj/components/content_settings/core/browser/browser/host_content_settings_map.o': 'obj/components/content_settings/core/browser/libbrowser.a',
    'obj/third_party/blink/renderer/modules/webgl/webgl/webgl_rendering_context_base.o': 'obj/third_party/blink/renderer/modules/webgl/libwebgl.a',
    'obj/components/autofill/core/common/common/autofill_prefs.o': 'obj/components/autofill/core/common/libcommon.a',
    'obj/chrome/common/constants/chrome_paths_mac.o': 'obj/chrome/common/libconstants.a',
}


def thin_members(data: bytes) -> list[str]:
    """Read GNU thin-archive metadata; never follow a member or execute ar."""
    require(8 <= len(data) <= 64 * 1024 * 1024 and data[:8] == b'!<thin>\n', 'bounded thin archive required')
    offset = 8; strings = None; members = []
    while offset < len(data):
        require(offset + 60 <= len(data), 'truncated thin archive header')
        header = data[offset:offset + 60]; offset += 60
        require(header[-2:] == b'`\n' and header[48:58].strip().isdigit(), 'invalid thin archive header')
        size = int(header[48:58]); name = header[:16].strip()
        if name in (b'/', b'//', b'/SYM64/'):
            require(offset + size <= len(data), 'truncated thin archive metadata')
            if name == b'//':
                require(strings is None, 'duplicate thin archive name table')
                strings = data[offset:offset + size]
            offset += size + size % 2
            continue
        if name.startswith(b'/'):
            require(strings is not None and name[1:].isdigit(), 'invalid thin member name offset')
            start = int(name[1:]); end = strings.find(b'/\n', start)
            require(start < len(strings) and end >= start and (start == 0 or strings[start-2:start] == b'/\n'),
                    'invalid thin archive string reference')
            name = strings[start:end]
        else:
            require(name.endswith(b'/'), 'unsupported thin member encoding')
            name = name[:-1]
        value = name.decode('utf-8')
        require(value and not value.startswith('/') and '\\' not in value
                and all(part not in {'', '.', '..'} for part in value.split('/')), 'unsafe thin member path')
        members.append(value)
    require(offset == len(data) and members, 'incomplete thin archive')
    return members


def evidence(project: Path, entry: dict) -> Path:
    require(isinstance(entry, dict) and set(entry) == {'file', 'sha256'}, 'invalid privacy evidence binding')
    return checked_file(project, entry['file'], entry['sha256'])


def verify(project: Path, binding: dict, *, source: Path | None = None,
           require_link: bool = True) -> dict:
    require(isinstance(binding, dict) and binding.get('file') == MANIFEST, 'privacy manifest binding required')
    document = json.loads(evidence(project, binding).read_text())
    require(type(document.get('schemaVersion')) is int and document['schemaVersion'] == 1
            and document.get('chromiumVersion') == '156.0.8078.80'
            and document.get('architecture') == 'arm64' and document.get('releaseReady') is False,
            'invalid privacy derivation identity')
    require(document.get('base') == BASE, 'privacy derivation cannot repin base inputs')
    base_contract = json.loads(evidence(project, BASE['sourceContract']).read_text())
    crc = verify_crc(project, base_contract)
    require(crc is not None, 'portable CRC base required')
    evidence(project, BASE['portableCRC'])
    files = document.get('files')
    require(isinstance(files, list) and len(files) == len(SOURCES), 'exact eight privacy sources required')
    names = [entry.get('source') for entry in files if isinstance(entry, dict)]
    require(len(names) == len(files) and len(set(names)) == len(names) and set(names) == set(SOURCES),
            'missing, duplicate or extra privacy source')
    patch = []
    for item in files:
        name = item['source']; target = SOURCES[name]
        require(item.get('object') == target and type(item.get('compileExitCode')) is int
                and item['compileExitCode'] == 0, 'privacy object or compile result mismatch')
        require(item.get('preimage', {}).get('file') == 'runtime/privacy-policy-v1/preimages/' + name
                and item.get('postimage', {}).get('file') == 'runtime/privacy-policy-v1/postimages/' + name,
                'privacy source image path mismatch')
        before = evidence(project, item['preimage']).read_text()
        after = evidence(project, item['postimage']).read_text()
        patch.extend(difflib.unified_diff(before.splitlines(True), after.splitlines(True),
                                         fromfile='a/' + name, tofile='b/' + name))
        recipe = json.loads(evidence(project, item['recipe']).read_text())
        argv = recipe.get('argv')
        require(recipe.get('cwd') == OUT and recipe.get('source') == name and recipe.get('target') == target
                and recipe.get('sourceSHA256') == item['postimage']['sha256']
                and recipe.get('objectSHA256') == item.get('objectSHA256')
                and type(recipe.get('exitCode')) is int and recipe['exitCode'] == 0,
                'privacy compile recipe binding mismatch')
        require(isinstance(argv, list) and all(isinstance(x, str) and '\x00' not in x for x in argv)
                and argv[0] == COMPILER and argv[-4:] == ['-c', '../../' + name, '-o', target]
                and not any('/Users/' in x or '/private/tmp/' in x for x in argv),
                'unexpected privacy compile command')
        if source is not None:
            checked_file(source, name, item['postimage']['sha256'])
            checked_file(source, OUT + '/' + target, item['objectSHA256'])
    require(evidence(project, document.get('patch')).read_bytes() == ''.join(patch).encode(),
            'privacy patch must exactly reproduce all eight source images')
    if not require_link:
        require(document.get('status') in {'compiled-link-pending', 'compiled-and-relinked-unqualified'},
                'invalid compiled privacy state')
        return document
    require(document.get('status') == 'compiled-and-relinked-unqualified', 'privacy link not complete')
    link = document.get('link')
    require(isinstance(link, dict) and type(link.get('exitCode')) is int and link['exitCode'] == 0,
            'successful privacy link receipt required')
    command = evidence(project, link.get('recipe')).read_text()
    base_command = checked_file(project, 'runtime/chromium-15680-portable-crc/link-command.txt',
                                crc['inputs']['linkCommand']['sha256']).read_text()
    require(command == base_command and '-Wl,--thinlto-jobs=2' in shlex.split(command),
            'privacy link must reuse exact bounded portable link command')
    response_path = evidence(project, link.get('responseFile'))
    require(digest(response_path) == 'b72aab24ecbe6022bfae1af9dba138c23395d7993b0fa97509e990aa86c56b66',
            'privacy response file must match published recipient source offer')
    response = response_path.read_text()
    tokens = shlex.split(response)
    archive_entries = link.get('thinArchives')
    require(isinstance(archive_entries, dict) and set(archive_entries) == set(ARCHIVES.values()),
            'exact five privacy thin archives required')
    for target in SOURCES.values():
        if target not in ARCHIVES:
            require(tokens.count(target) == 1, 'missing or duplicated direct privacy object')
            continue
        archive = ARCHIVES[target]
        require(tokens.count(archive) == 1 and target not in tokens, 'invalid privacy archive input')
        entry = archive_entries[archive]
        archived = evidence(project, entry)
        members = thin_members(archived.read_bytes())
        member = str(Path(target).relative_to(Path(archive).parent))
        require(members.count(member) == 1, 'missing or duplicated thin privacy object')
        if source is not None:
            checked_file(source, OUT + '/' + archive, entry['sha256'])
    require(isinstance(link.get('frameworkSHA256'), str) and HEX.fullmatch(link['frameworkSHA256']),
            'invalid privacy framework digest')
    require(link.get('browserExecutableSHA256') == crc['browserExecutableSHA256']
            and link.get('frameworkSHA256') != crc['outputs']['frameworkSHA256'],
            'privacy derived binary binding mismatch')
    # Validation of the digest syntax and actual bytes is mandatory in live-source mode.
    if source is not None:
        checked_file(source, OUT + '/' + FRAMEWORK, link.get('frameworkSHA256'))
        checked_file(source, OUT + '/NeAntik Browser.app/Contents/MacOS/NeAntik Browser',
                     link.get('browserExecutableSHA256'))
    return document
