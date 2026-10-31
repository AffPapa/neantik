"""Bounded current signing/license inputs; never a new full-source verdict."""
from pathlib import Path
import hashlib
import os
import stat
import chromium_15612_release_evidence as source
import chromium_15612_generated_cache as files
import chromium_15612_build_copy_links_v2 as copies
from chromium_15612_font_release_evidence import BASE_FULL_SHA256, PROOF_SHA256
from chromium_15612_variant import FONT_PREFIX, FONT_VARIANT, SECURITY_PREFIX, COMPONENT_PREFIX, SUCCESSOR_PREFIXES

MANIFEST = FONT_PREFIX + '-packaging-inputs.json'
MANIFEST_SHA256 = 'eb8d67e05d775cc0544f0dd5d178e6ebe04b6f323f37d75ab652f169403d74ea'


def manifest(project: Path) -> dict:
    value = source.bound(project / 'runtime', MANIFEST, MANIFEST_SHA256)
    source.need(value['schemaVersion'] == 1 and value['kind'] == 'font-successor-current-packaging-inputs'
                and value['sourceVariant'] == FONT_VARIANT and value['releaseReady'] is False
                and value['baseFullInventorySHA256'] == BASE_FULL_SHA256
                and value['sourceDeltaProofSHA256'] == PROOF_SHA256
                and len(value['entries']) == 9552, 'Packaging input projection identity differs')
    return value


def verify_entries(root: Path, entries: list[dict], copy_groups: list[dict]) -> None:
    """Shared byte reader also exercised on owned broken filesystem fixtures."""
    mapped = {entry['path']: entry for entry in copy_groups}
    source.need(len(mapped) == len(copy_groups), 'Duplicate native COPY packaging group')
    seen = set()
    for entry in entries:
        name = files.relative_path(entry['path'])
        source.need(name not in seen and entry['kind'] == 'file', 'Duplicate or non-file packaging input')
        seen.add(name)
        limit = max(entry['sizeBytes'], 1)
        source.need(limit <= 16 * 1024 * 1024, 'Packaging input exceeds file budget')
        if name in mapped:
            # Source + exactly named aliases must account for every link. Inode
            # numbers are observed locally, never shipped as machine identity.
            before = (root / name).lstat()
            group = {**mapped[name], 'device': before.st_dev, 'inode': before.st_ino}
            raw, info = copies.read_known_copy_source(root, name, limit, group)
        else:
            raw, info = files.read_source_record(root, name, limit)
        source.need(stat.S_IMODE(info.st_mode) == entry['mode'] and len(raw) == entry['sizeBytes']
                    and hashlib.sha256(raw).hexdigest() == entry['sha256'], 'Current signing/license input changed: ' + name)
    source.need(set(mapped) <= seen, 'Unknown native COPY packaging group')


def verify(root: Path, project: Path, *, prefix: str = FONT_PREFIX) -> dict:
    value = manifest(project)
    # All selected paths are inherited unchanged. New font files are already
    # authenticated by the separately pinned six-layer source proof.
    if prefix == FONT_PREFIX:
        from chromium_15612_font_release_evidence import verify_contract
        verify_contract(project)
    elif prefix in (SECURITY_PREFIX, COMPONENT_PREFIX):
        if prefix == COMPONENT_PREFIX:
            from chromium_15612_component_release_evidence import verify_contract
        else:
            from chromium_15612_security_release_evidence import verify_contract
        _, _, proof = verify_contract(project)
        source.need(not {entry['path'] for entry in value['entries']}.intersection(
            change['path'] for change in proof['changes']),
            'Security overlay changed inherited signing/license inputs')
    else:
        raise ValueError('Unknown M156 successor packaging inputs')
    from chromium_15612_live_source import anchored_root
    with anchored_root(root):
        verify_entries(root, value['entries'], value['knownNativeCopyGroups'])
    source.need(files.read_source_file(root, 'LICENSE', 1024 * 1024) ==
                (project / 'runtime/licenses/Chromium-LICENSE').read_bytes(), 'Bundled Chromium license differs')
    return {'status': 'verified-current-packaging-inputs', 'filesVerified': len(value['entries']),
            'knownNativeCopyGroups': len(value['knownNativeCopyGroups']), 'manifestSHA256': MANIFEST_SHA256,
            'freshWholeSourceTreeObserved': False, 'sourceExecuted': False, 'releaseQualified': False}


if __name__ == '__main__':
    import argparse
    import json
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source_root', type=Path)
    parser.add_argument('--variant-prefix', choices=SUCCESSOR_PREFIXES, default=FONT_PREFIX)
    args = parser.parse_args()
    try:
        result = verify(args.source_root, Path(__file__).resolve().parents[1], prefix=args.variant_prefix)
    except (OSError, ValueError) as error:
        parser.exit(1, 'Current font packaging inputs rejected: ' + str(error) + '\n')
    print(json.dumps(result, sort_keys=True))
