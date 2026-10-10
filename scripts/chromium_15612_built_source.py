"""Admit an unchanged built candidate using the executed final9 proof.

This checks preserved build provenance and today's packaging inputs. It is not
a new observation of every current source file, and cannot authorize rebuilding
Chromium from the current tree. A changed native output requires new provenance.
Private producer paths are never copied into the application.
"""
import argparse
import hashlib
import json
from pathlib import Path
import chromium_15612_release_evidence as source
import chromium_15612_generated_cache as cache
import chromium_15612_live_source as observer
import chromium_15612_postbuild9 as postbuild
import chromium_15612_build_copy_links_v2 as copies

PINS = {
    'm156-postbuild-attempt-9-full-fd-observation.json': 'd6836d97a7a24d370663976063516306bfc646c826149f579a319fdb5578722c',
    'm156-postbuild-attempt-9-source-producer.json': 'a3b1056c4899630fa8ef2f0d24bf75d86f598afcc8d034ed5c97a3c56731109a',
    'postbuild-full-source-attempt-9-launch.json': '39ffc9d357ecf8d072c1ce518173ae81f610c42c57bc8a6b168e19721670f706',
    'm156-postbuild-attempt-9-native-copy-map.json': '5805296161bef349c36b7d52cf7c452e8067c5f04e55d1658c5db4fd8177fba9',
    'm156-postbuild-attempt-9-source-snapshot.json': '20bf2bbd12a7dbc146f02b6de8dc42161bef1e9a9d2dd1ac155032e3e3a57446',
}


def verify(root: Path, artifacts: Path, candidate: dict, project: Path) -> dict:
    source.verify_candidate_document(candidate, project_root=project)
    documents = {}
    for name, expected in PINS.items():
        path = source.safe_relative_regular(artifacts, name)
        source.need(source.sha256_file(path) == expected, 'Private final9 proof differs')
        documents[name] = source.strict_json(cache.read_source_file(artifacts, name, 512 * 1024 * 1024))
    launch = documents['postbuild-full-source-attempt-9-launch.json']
    fd = documents['m156-postbuild-attempt-9-full-fd-observation.json']
    producer = documents['m156-postbuild-attempt-9-source-producer.json']
    full = documents['m156-postbuild-attempt-9-source-snapshot.json']
    source.need(root.is_absolute() and not root.is_symlink() and root.is_dir() and
                str(root) == launch['source'], 'Source root is not the executed producer root')
    source.need(fd['producerReceiptSHA256'] == PINS['m156-postbuild-attempt-9-source-producer.json'] and
                fd['producerLaunchSHA256'] == producer['producerLaunchSHA256'] == PINS['postbuild-full-source-attempt-9-launch.json'] and
                fd['observedFullSHA256'] == producer['producedFullSHA256'] == PINS['m156-postbuild-attempt-9-source-snapshot.json'] and
                fd['producerExitCode'] == producer['producerExitCode'] == 0 and
                fd['freshProducerLaunchBindingStillRequired'] is False and
                fd['exactCoverageVerified'] is True and fd['fdSafeFullObservationVerified'] is True,
                'Executed final9 producer chain is incomplete')
    mapping = postbuild.require_copy_map(documents['m156-postbuild-attempt-9-native-copy-map.json'], full)
    observer.git_identity(root, full)
    source.verify_unsigned_binary_binding(root / 'out/NeAntikM156Qualified20261009/NeAntik Browser.app',
                                          root / source.ARGS_RELATIVE, candidate)
    # Signing imports and license generation execute/read source after the build.
    # Bind those inputs independently; native-code source is the historical proof.
    selected = [entry for entry in full['entries'] if entry['kind'] == 'file' and (
        entry['path'].startswith(('chrome/installer/mac/', 'tools/licenses/')) or
        entry['path'].endswith(('LICENSE', 'LICENSE.txt', 'LICENSE.md', 'README.chromium', '-entitlements.plist')))]
    source.need(len(selected) > 100, 'Packaging source closure is unexpectedly empty')
    for entry in selected:
        try:
            raw = (copies.read_known_copy_source(root, entry['path'], max(entry['sizeBytes'], 1), mapping[entry['path']])[0]
                   if entry['path'] in mapping else cache.read_source_file(root, entry['path'], max(entry['sizeBytes'], 1)))
        except ValueError as error:
            raise ValueError('Packaging input rejected: ' + entry['path'] + ': ' + str(error)) from error
        source.need(len(raw) == entry['sizeBytes'] and hashlib.sha256(raw).hexdigest() == entry['sha256'],
                    'Postbuild signing/license input changed: ' + entry['path'])
    source.need(cache.read_source_file(root, 'LICENSE', 1024 * 1024) == (project / 'runtime/licenses/Chromium-LICENSE').read_bytes(), 'Bundled Chromium license differs from built source')
    observer.git_identity(root, full)
    return {'schemaVersion': 1, 'sourceEvidenceMode': 'executed-final9-preserved-build-and-current-packaging-inputs',
            'fullFDObservationSHA256': PINS['m156-postbuild-attempt-9-full-fd-observation.json'],
            'unsignedNativeOutputVerified': True, 'packagingSourceFilesVerified': len(selected),
            'freshWholeSourceTreeObserved': False, 'rebuildAuthorized': False, 'releaseReady': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('source_root', type=Path)
    parser.add_argument('artifacts', type=Path)
    parser.add_argument('candidate', type=Path)
    args = parser.parse_args()
    try:
        result = verify(args.source_root, args.artifacts, source.read_object(args.candidate, 'M156 candidate'),
                        Path(__file__).resolve().parents[1])
    except (OSError, ValueError) as error:
        parser.exit(1, 'M156 preserved build rejected: ' + str(error) + '\n')
    print(json.dumps(result, sort_keys=True))
