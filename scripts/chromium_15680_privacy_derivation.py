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
    'chrome/browser/net/proxy_config_monitor.cc': 'obj/chrome/browser/net/impl/proxy_config_monitor.o',
    'third_party/blink/renderer/modules/peerconnection/rtc_peer_connection.cc': 'obj/third_party/blink/renderer/modules/peerconnection/peerconnection/rtc_peer_connection.o',
    'components/content_settings/core/browser/host_content_settings_map.cc': 'obj/components/content_settings/core/browser/browser/host_content_settings_map.o',
    'third_party/blink/renderer/modules/webgl/webgl_rendering_context_base.cc': 'obj/third_party/blink/renderer/modules/webgl/webgl/webgl_rendering_context_base.o',
    'chrome/browser/ui/views/frame/contents_container_view.cc': 'obj/chrome/browser/ui/views/frame/contents_container_view_impl/contents_container_view.o',
    'chrome/browser/chrome_content_browser_client.cc': 'obj/chrome/browser/core/chrome_content_browser_client.o',
    'components/autofill/core/common/autofill_prefs.cc': 'obj/components/autofill/core/common/common/autofill_prefs.o',
    'chrome/browser/password_manager/chrome_password_manager_client.cc': 'obj/chrome/browser/password_manager/impl/chrome_password_manager_client.o',
    'chrome/common/chrome_paths_mac.mm': 'obj/chrome/common/constants/chrome_paths_mac.o',
    'services/network/network_service_network_delegate.cc': 'obj/services/network/network_service/network_service_network_delegate.o',
    'components/ungoogled/nevision_fingerprint.cc': 'obj/components/ungoogled/ungoogled_switches/nevision_fingerprint.o',
    'third_party/blink/renderer/platform/fonts/mac/font_cache_mac.mm': 'obj/third_party/blink/renderer/platform/platform/font_cache_mac.o',
    'third_party/blink/renderer/platform/fonts/mac/font_matcher_mac.mm': 'obj/third_party/blink/renderer/platform/platform/font_matcher_mac.o',
    'third_party/blink/renderer/platform/fonts/mac/font_platform_data_mac.mm': 'obj/third_party/blink/renderer/platform/platform/font_platform_data_mac.o',
    'third_party/skia/src/ports/SkFontMgr_mac_ct.cpp': 'obj/skia/skia/SkFontMgr_mac_ct.o',
    'content/browser/font_access/font_enumeration_data_source_mac.mm': 'obj/content/browser/browser/font_enumeration_data_source_mac.o',
    'third_party/blink/renderer/platform/fonts/generic_font_family_settings.cc': 'obj/third_party/blink/renderer/platform/platform/generic_font_family_settings.o',
    'third_party/blink/renderer/core/workers/worker_settings.cc': 'obj/third_party/blink/renderer/core/core/worker_settings.o',
}


ARCHIVES = {
    'obj/third_party/blink/renderer/modules/peerconnection/peerconnection/rtc_peer_connection.o': 'obj/third_party/blink/renderer/modules/peerconnection/libpeerconnection.a',
    'obj/components/content_settings/core/browser/browser/host_content_settings_map.o': 'obj/components/content_settings/core/browser/libbrowser.a',
    'obj/third_party/blink/renderer/modules/webgl/webgl/webgl_rendering_context_base.o': 'obj/third_party/blink/renderer/modules/webgl/libwebgl.a',
    'obj/components/autofill/core/common/common/autofill_prefs.o': 'obj/components/autofill/core/common/libcommon.a',
    'obj/chrome/common/constants/chrome_paths_mac.o': 'obj/chrome/common/libconstants.a',
    'obj/services/network/network_service/network_service_network_delegate.o': 'obj/services/network/libnetwork_service.a',
    'obj/components/ungoogled/ungoogled_switches/nevision_fingerprint.o': 'obj/components/ungoogled/libungoogled_switches.a',
    'obj/third_party/blink/renderer/platform/platform/font_cache_mac.o': 'obj/third_party/blink/renderer/platform/libblink_platform.a',
    'obj/third_party/blink/renderer/platform/platform/font_matcher_mac.o': 'obj/third_party/blink/renderer/platform/libblink_platform.a',
    'obj/third_party/blink/renderer/platform/platform/font_platform_data_mac.o': 'obj/third_party/blink/renderer/platform/libblink_platform.a',
    'obj/skia/skia/SkFontMgr_mac_ct.o': 'obj/skia/libskia.a',
    'obj/third_party/blink/renderer/platform/platform/generic_font_family_settings.o': 'obj/third_party/blink/renderer/platform/libblink_platform.a',
    'obj/third_party/blink/renderer/core/core/worker_settings.o': 'obj/third_party/blink/renderer/core/libblink_core.a',
}


SUPPLEMENTAL = {'third_party/blink/renderer/platform/fonts/neantik_system_generic_defaults.h', 'components/ungoogled/system_font_source.h', 'components/ungoogled/system_font_policy_mac.cc', 'components/ungoogled/system_font_source.cc', 'components/ungoogled/system_font_policy_mac.h'}


def thin_members(data: bytes) -> list[str]:
    """Read GNU thin-archive metadata; never follow a member or execute ar."""
    require(8 <= len(data) <= 128 * 1024 * 1024 and data[:8] == b'!<thin>\n', 'bounded thin archive required')
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
    require(isinstance(files, list) and len(files) == len(SOURCES), 'exact privacy source set required')
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
    supplemental = document.get('supplementalSources')
    require(isinstance(supplemental, list) and len(supplemental) == len(SUPPLEMENTAL)
            and {x.get('source') for x in supplemental} == SUPPLEMENTAL,
            'exact supplemental font source set required')
    for item in supplemental:
        name = item['source']
        require(item.get('beforeAbsent') is True
                and item.get('preimage', {}).get('file') == 'runtime/privacy-policy-v1/preimages/' + name
                and item.get('postimage', {}).get('file') == 'runtime/privacy-policy-v1/postimages/' + name,
                'invalid supplemental source provenance')
        require(evidence(project, item['preimage']).read_bytes() == b'', 'new source preimage must be absent')
        after = evidence(project, item['postimage']).read_text()
        patch.extend(difflib.unified_diff([], after.splitlines(True), fromfile='/dev/null', tofile='b/' + name))
        if source is not None: checked_file(source, name, item['postimage']['sha256'])
    licenses = document.get('licenses')
    require(isinstance(licenses, list) and len(licenses) == 1 and licenses[0].get('spdx') == 'MPL-2.0',
            'font source license binding required')
    evidence(project, {key: licenses[0][key] for key in ('file', 'sha256')})
    evidence(project, document.get('notice'))
    require(evidence(project, document.get('patch')).read_bytes() == ''.join(patch).encode(),
            'privacy patch must exactly reproduce all reviewed source images')
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
            'exact privacy thin archive set required')
    for target in SOURCES.values():
        if target not in ARCHIVES:
            require(tokens.count(target) == 1, 'missing or duplicated direct privacy object')
            continue
        archive = ARCHIVES[target]
        require(tokens.count(archive) == 1 and target not in tokens, 'invalid privacy archive input')
        entry = archive_entries[archive]
        require(isinstance(entry, dict) and set(entry) == {'members', 'sha256'}
                and isinstance(entry['sha256'], str) and HEX.fullmatch(entry['sha256']), 'invalid thin archive binding')
        proof = json.loads(evidence(project, entry['members']).read_text())
        members = proof.get('members')
        require(proof.get('schemaVersion') == 1 and proof.get('archive') == archive and proof.get('kind') == 'thin'
                and proof.get('sourceArchiveSHA256') == entry['sha256']
                and isinstance(members, list) and 1 <= len(members) <= 100_000
                and all(isinstance(x, str) and x and not x.startswith('/') and '\\' not in x
                        and all(part not in {'', '.', '..'} for part in x.split('/')) for x in members),
                'invalid thin archive member projection')
        member = str(Path(target).relative_to(Path(archive).parent))
        require(members.count(member) == 1, 'missing or duplicated thin privacy object')
        if source is not None:
            actual = checked_file(source, OUT + '/' + archive, entry['sha256'])
            require(thin_members(actual.read_bytes()) == members, 'live thin archive members changed')
    rebuild = json.loads(evidence(project, link.get('archiveRebuilds')).read_text())
    font_archives = {'obj/components/ungoogled/libungoogled_switches.a', 'obj/skia/libskia.a',
                     'obj/third_party/blink/renderer/core/libblink_core.a',
                     'obj/third_party/blink/renderer/platform/libblink_platform.a'}
    rows = rebuild.get('archives')
    require(rebuild.get('schemaVersion') == 1
            and rebuild.get('method') == 'fresh-archive-with-recorded-GN-flags-verify-then-rename'
            and rebuild.get('flags') == ['-T', '-s', '-r', '-c', '-s', '-D']
            and isinstance(rows, list) and len(rows) == len(font_archives)
            and {x.get('archive') for x in rows} == font_archives, 'font archive reconstruction recipe required')
    for row in rows:
        archive = row['archive']
        proof = json.loads(evidence(project, archive_entries[archive]['members']).read_text())
        expected_inputs = [str(Path(archive).parent / member) for member in proof['members']]
        require(evidence(project, row.get('memberInputs')).read_text().splitlines() == expected_inputs
                and row.get('afterSHA256') == archive_entries[archive]['sha256']
                and isinstance(row.get('beforeSHA256'), str) and HEX.fullmatch(row['beforeSHA256'])
                and row.get('memberCount') == len(expected_inputs) and row.get('membersUnchanged') is True
                and row.get('freshCreationRequired') is True
                and type(row.get('exitCode')) is int and row['exitCode'] == 0,
                'font archive recipe/input/result mismatch')
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


VARIANT = 'recipient-privacy-policy-v1'
CONTRACT = 'runtime/chromium-15680-privacy-v1-source-contract.json'


def verify_contract(project: Path) -> tuple[dict, dict]:
    """An additive contract. The published base/CRC contract stays immutable."""
    from chromium_15680_release_evidence import verify_contract as verify_base
    base = verify_base(project)
    path = project / CONTRACT
    require(not path.is_symlink() and path.is_file(), 'missing privacy source contract')
    contract = json.loads(path.read_text())
    require(set(contract) == {'schemaVersion', 'variant', 'sourceMode', 'targetChromiumVersion',
                             'targetArchitecture', 'base', 'privacyDerivation', 'releaseReady'}
            and type(contract['schemaVersion']) is int and contract['schemaVersion'] == 1
            and contract['variant'] == VARIANT
            and contract['sourceMode'] == 'published-recipient-source-with-reviewed-privacy-layer'
            and contract['targetChromiumVersion'] == '156.0.8078.80'
            and contract['targetArchitecture'] == 'arm64' and contract['releaseReady'] is False
            and contract['base'] == BASE, 'invalid additive privacy contract')
    document = verify(project, contract['privacyDerivation'])
    require(base['officialChromiumBase']['tag'] == document['chromiumVersion'], 'privacy base version mismatch')
    return contract, document


def expected_provenance(project: Path) -> dict:
    contract, layer = verify_contract(project)
    base = json.loads(evidence(project, BASE['sourceContract']).read_text())
    return {
        'schemaVersion': 1, 'status': 'source-qualified', 'variant': VARIANT,
        'sourceMode': contract['sourceMode'], 'targetChromiumVersion': '156.0.8078.80',
        'targetArchitecture': 'arm64', 'officialChromiumBase': base['officialChromiumBase'],
        'sourceContractSHA256': digest(project / CONTRACT),
        'privacyDerivation': contract['privacyDerivation'], 'base': BASE,
        'sourceChecks': {
            'publishedRecipientSourceOffer': 'pinned-base-reference',
            'privacySourceImagesAndRecipes': 'verified', 'compileAndLinkReceipts': 'verified',
            'fullGclientCheckout': 'not-claimed', 'fullCleanChromiumRebuild': 'not-claimed',
        },
        'binaryBinding': {'status': 'pending-runtime-report', 'requiredEvidence': 'schema-3-runtime-report',
                          'unsignedFrameworkSHA256': layer['link']['frameworkSHA256']},
        'releaseReady': False,
    }


def build_provenance(source: Path, project: Path) -> dict:
    contract, _ = verify_contract(project)
    verify(project, contract['privacyDerivation'], source=source)
    base = json.loads(evidence(project, BASE['sourceContract']).read_text())
    checked_file(source, OUT + '/args.gn', base['buildArgsSHA256'])
    crc = json.loads(evidence(project, BASE['portableCRC']).read_text())
    for name, entry in crc['sourceOverlay'].items():
        checked_file(source, 'third_party/ffmpeg/' + name, entry['afterSHA256'])
    checked_file(source, OUT + '/obj/third_party/ffmpeg/ffmpeg_internal/autorename_libavutil_crc.o',
                 crc['outputs']['crcObjectSHA256'])
    checked_file(source, OUT + '/obj/third_party/ffmpeg/libffmpeg_internal.a',
                 crc['outputs']['ffmpegArchiveSHA256'])
    version = (source / 'chrome/VERSION').read_text()
    require(all(line in version.splitlines() for line in ['MAJOR=156', 'MINOR=0', 'BUILD=8078', 'PATCH=80']),
            'privacy recipient version mismatch')
    return expected_provenance(project)


def verify_provenance(document: dict, project: Path) -> None:
    require(document == expected_provenance(project), 'privacy provenance stale or mutated')


def expected_lock(provenance_path: Path, project: Path) -> dict:
    document = json.loads(provenance_path.read_text())
    verify_provenance(document, project)
    contract, layer = verify_contract(project)
    base = json.loads(evidence(project, BASE['sourceContract']).read_text())
    official = base['officialChromiumBase']
    return {
        'schemaVersion': 4, 'status': 'source-qualified', 'variant': VARIANT,
        'targetArchitecture': 'arm64', 'sourceContract': CONTRACT,
        'sourceContractSHA256': digest(project / CONTRACT), 'sourceProvenanceSHA256': digest(provenance_path),
        'sourceAdoptionManifestSHA256': base['sourceAdoptionManifestSHA256'],
        'fingerprintChromium': {
            **official, 'chromiumVersion': '156.0.8078.80', 'licenseSHA256': base['chromiumLicenseSHA256'],
        },
        'ownedInputs': {
            **{key: base[key] for key in ('sourcePatchSHA256', 'devtoolsCompatibilityPatchSHA256',
               'v8CompatibilityPatchSHA256', 'dependencyLockSHA256', 'depsFileSHA256', 'buildArgsSHA256')},
            'portableCrcManifestSHA256': BASE['portableCRC']['sha256'],
            'privacyDerivationSHA256': contract['privacyDerivation']['sha256'],
            'privacyPatchSHA256': layer['patch']['sha256'],
        },
        'ownedManifests': {
            'neantikPatchSeriesSHA256': digest(project / 'runtime/nevision-patches/series.json'),
            'appleDeviceTuplesSHA256': digest(project / 'runtime/apple-device-tuples.json'),
            'securityBaselineSHA256': base['securityBaselineSHA256'],
        },
        'binaryBinding': {
            'status': 'not-attested-by-this-document', 'requiredEvidence': 'schema-3-runtime-report',
            'unsignedFrameworkSHA256': layer['link']['frameworkSHA256'],
            'policy': 'Recipient derivation only; native execution, signed bytes and publication remain separate gates.',
        },
    }


def verify_lock(lock: dict, provenance_path: Path, project: Path) -> dict:
    require(lock == expected_lock(provenance_path, project), 'privacy candidate lock stale or mutated')
    return lock


def verify_lock_binding(lock: dict, project: Path) -> None:
    contract, layer = verify_contract(project)
    base = json.loads(evidence(project, BASE['sourceContract']).read_text())
    require(lock.get('schemaVersion') == 4 and lock.get('status') == 'source-qualified'
            and lock.get('targetArchitecture') == 'arm64'
            and lock.get('fingerprintChromium') == {**base['officialChromiumBase'],
                'chromiumVersion': '156.0.8078.80', 'licenseSHA256': base['chromiumLicenseSHA256']}
            and lock.get('variant') == VARIANT and lock.get('sourceContract') == CONTRACT
            and lock.get('sourceContractSHA256') == digest(project / CONTRACT)
            and lock.get('ownedInputs', {}).get('privacyDerivationSHA256') == contract['privacyDerivation']['sha256']
            and lock.get('ownedInputs', {}).get('privacyPatchSHA256') == layer['patch']['sha256']
            and lock.get('ownedInputs', {}).get('portableCrcManifestSHA256') == BASE['portableCRC']['sha256']
            and lock.get('binaryBinding', {}).get('unsignedFrameworkSHA256') == layer['link']['frameworkSHA256'],
            'privacy runtime lock binding mismatch')


def evidence_closure(project: Path) -> dict[str, str]:
    """Packaged relative name -> reviewed project relative file. No dev logs."""
    contract, layer = verify_contract(project)
    paths = {MANIFEST, layer['patch']['file']}
    for item in layer['files'] + layer['supplementalSources']:
        paths.update(item[key]['file'] for key in ('preimage', 'postimage', 'recipe') if key in item)
    paths.update(layer['link'][key]['file'] for key in ('recipe', 'responseFile'))
    paths.update(item['members']['file'] for item in layer['link']['thinArchives'].values())
    rebuild_path = evidence(project, layer['link']['archiveRebuilds'])
    paths.add(layer['link']['archiveRebuilds']['file'])
    paths.update(item['memberInputs']['file'] for item in json.loads(rebuild_path.read_text())['archives'])
    paths.update(item['file'] for item in layer['licenses'])
    paths.add(layer['notice']['file'])
    crc = json.loads(evidence(project, BASE['portableCRC']).read_text())
    paths.update(item['file'] for item in crc['inputs'].values())
    paths.update({BASE['portableCRC']['file'], 'runtime/chromium-15680-portable-crc.patch'})
    result = {Path(CONTRACT).name: CONTRACT,
              Path(BASE['sourceContract']['file']).name: BASE['sourceContract']['file']}
    for name in sorted(paths):
        require(name.startswith('runtime/'), 'privacy evidence outside runtime closure')
        result['chromium-15680-source-evidence/' + name.removeprefix('runtime/')] = name
    return result


def copy_evidence(project: Path, destination: Path) -> None:
    import shutil
    for packaged, reviewed in evidence_closure(project).items():
        target = destination / packaged
        # The top-level selected contract may already have been copied by the
        # packager. Identical regular bytes are the only admitted existing file.
        expected = digest(project / reviewed)
        if target.exists() or target.is_symlink():
            checked_file(destination, packaged, expected)
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        for parent in target.parents:
            if parent == destination: break
            require(not parent.is_symlink(), 'symlink in privacy package directory')
        shutil.copyfile(project / reviewed, target)
        checked_file(destination, packaged, expected)


def verify_packaged_evidence(project: Path, destination: Path) -> None:
    closure = evidence_closure(project)
    for packaged, reviewed in closure.items():
        checked_file(destination, packaged, digest(project / reviewed))
    root = destination / 'chromium-15680-source-evidence/privacy-policy-v1'
    actual = set()
    for path in root.rglob('*'):
        require(not path.is_symlink(), 'symlink in privacy packaged closure')
        if path.is_file(): actual.add(str(path.relative_to(destination)))
    expected = {name for name in closure if name.startswith('chromium-15680-source-evidence/privacy-policy-v1/')}
    require(actual == expected, 'extra or missing privacy packaged evidence')
