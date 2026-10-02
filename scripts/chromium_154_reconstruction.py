"""Validate current-source evidence without promoting it to a release verdict."""
from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path, PurePosixPath


class ReconstructionError(ValueError):
    pass


def verify_live_external_inputs(source_root: Path, paths: dict[str, Path]) -> None:
    """A symlink snapshot binds its target text, not bytes outside the checkout."""
    observed = json.loads(paths['esbuild-observed-inputs.json'].read_text())
    expected_package = {x['path']: x['sha256'] for x in observed['packageFiles']}
    prefix = source_root / 'third_party/devtools-frontend/src/node_modules'
    for relative, digest in (('.bin/esbuild', expected_package['bin/esbuild']),
                             ('@esbuild/darwin-arm64/bin/esbuild', observed['binarySHA256'])):
        path = prefix / relative
        if not path.is_symlink() or not path.is_file() or sha256(path) != digest:
            raise ReconstructionError('Live external esbuild executable changed')
    package = prefix / 'esbuild'
    if not package.is_symlink() or not package.is_dir():
        raise ReconstructionError('Live external esbuild package link changed')
    actual_package = {}
    for path in package.resolve().rglob('*'):
        if path.is_symlink():
            raise ReconstructionError('Unexpected nested esbuild package symlink')
        if path.is_file():
            actual_package[path.relative_to(package.resolve()).as_posix()] = sha256(path)
    if actual_package != expected_package:
        raise ReconstructionError('Live external esbuild package bytes changed')


def verify_reconstruction(root: Path, manifest: dict, experiment: dict) -> dict:
    """Audit frozen reports. A final live snapshot remains a separate gate."""
    paths = bound_evidence(root, manifest)
    if manifest.get('chromiumVersion') != '154.0.8037.93':
        raise ReconstructionError('Wrong reconstruction Chromium version')
    snapshot_name = manifest.get('sourceSnapshotPath')
    if snapshot_name not in paths or sha256(paths[snapshot_name]) != manifest.get('sourceSnapshotSHA256'):
        raise ReconstructionError('Snapshot is not bound to the manifest')
    snapshot = json.loads(paths[snapshot_name].read_text())
    if (snapshot.get('schemaVersion') != 2
            or snapshot.get('inventoryDigestAlgorithm') != 'sha256-canonical-json-v1'
            or snapshot.get('targetChromiumVersion') != manifest['chromiumVersion']
            or snapshot.get('argsGN', {}).get('sha256') != manifest.get('buildArgsSHA256')
            or snapshot.get('officialChromiumBase') != {
                'commit': 'f89f3a4363808e117c592adedcf9947882ac3b79',
                'tree': '658e81c77627fcf91e6784bd353e0d31a4ca70b5'}):
        raise ReconstructionError('Snapshot metadata differs from pinned build')
    result = {}
    result.update(verify_replay_bindings(paths, experiment))
    result.update(verify_tracked_attribution(paths))
    result.update(verify_tools_and_untracked(paths))
    if 'sourceTransition' in manifest:
        result.update(verify_bound_transition(paths, manifest['sourceTransition'], snapshot))
    result.update({'scope': 'Frozen current-input reconstruction reports verified; final live source and built-binary binding remain required',
                   'liveSourceVerified': False, 'releaseReady': False,
                   'sourceSnapshotSHA256': manifest['sourceSnapshotSHA256']})
    return result


def verify_bound_transition(paths: dict[str, Path], binding: dict, snapshot: dict) -> dict:
    """Check published delta consistency; full-inventory execution proves coverage."""
    def read(key):
        name = binding.get(key)
        if name not in paths:
            raise ReconstructionError('Missing bound transition ' + key)
        return json.loads(paths[name].read_text())

    baseline, inputs, report = read('baseline'), read('inputs'), read('report')
    if (report.get('schemaVersion') != 1 or report.get('releaseReady') is not False
            or report.get('unexplainedChanges') != 0
            or report.get('beforeSnapshot') != baseline
            or report.get('afterSnapshot') != snapshot
            or report.get('overlaySteps') != inputs.get('overlaySteps')
            or report.get('verifiedCaches') != inputs.get('verifiedCaches')
            or report.get('privateExecution', {}).get('inputsSHA256') != sha256(paths[binding['inputs']])):
        raise ReconstructionError('Transition report does not bind the final inputs and snapshots')
    replayed_steps, verified_caches = [], []
    step_keys = ('path', 'beforeSHA256', 'afterSHA256', 'patchSHA256')
    for item in inputs.get('evidence', []):
        if item.get('path') not in paths or sha256(paths[item['path']]) != item.get('sha256'):
            raise ReconstructionError('Transition replay/cache evidence is not manifest-bound')
        evidence = json.loads(paths[item['path']].read_text())
        if evidence.get('zeroFuzzZeroOffsetReplay') is True and all(k in evidence for k in step_keys):
            replayed_steps.append({k: evidence[k] for k in step_keys})
        for group in evidence.get('overlays', []):
            if group.get('zeroFuzzZeroOffsetReplay') is not True:
                raise ReconstructionError('Overlay replay is not exact')
            for file in group['files']:
                replayed_steps.append(dict(path=file['sourcePath'],
                    beforeSHA256=file['beforeSHA256'], afterSHA256=file['afterSHA256'],
                    patchSHA256=group['patchSHA256']))
        if evidence.get('passed') is True and 'verifiedCacheCount' in evidence:
            if evidence['verifiedCacheCount'] != len(evidence['items']):
                raise ReconstructionError('Verified cache count mismatch')
            verified_caches.extend(evidence['items'])
    if (any(step not in replayed_steps for step in inputs['overlaySteps'])
            or any(cache not in verified_caches for cache in inputs['verifiedCaches'])):
        raise ReconstructionError('Transition records differ from independent replay/cache evidence')

    def valid_path(path):
        if (not isinstance(path, str) or not path or '\\' in path
                or PurePosixPath(path).is_absolute()
                or any(x in ('', '.', '..') for x in path.split('/'))):
            raise ReconstructionError('Invalid source delta path')
        return path

    def valid_hash(value):
        if not re.fullmatch('[0-9a-f]{64}', str(value)):
            raise ReconstructionError('Invalid source delta digest')
        return value

    for key in ('beforeFullSHA256', 'afterFullSHA256', 'inputsSHA256', 'driverSHA256', 'verifierSHA256'):
        valid_hash(report.get('privateExecution', {}).get(key))
    chains = {}
    for step in inputs['overlaySteps']:
        path = valid_path(step['path'])
        pre, post = valid_hash(step['beforeSHA256']), valid_hash(step['afterSHA256'])
        valid_hash(step['patchSHA256'])
        if path in chains and chains[path][1] != pre:
            raise ReconstructionError('Broken bound overlay order')
        chains[path] = (chains.get(path, (pre,))[0], post)
    caches = {}
    for cache in inputs['verifiedCaches']:
        path = valid_path(cache['path'])
        valid_path(cache['sourcePath'])
        valid_hash(cache['sourceSHA256'])
        valid_hash(cache['pycSHA256'])
        if (path in caches or path in chains or '/__pycache__/' not in path
                or not path.endswith('.pyc') or not cache['sourcePath'].endswith('.py')
                or cache.get('timestampAndCodeMatch') is not True):
            raise ReconstructionError('Invalid bound cache attribution')
        caches[path] = cache
    changes = report.get('changes', [])
    names = [valid_path(change['path']) for change in changes]
    expected = {path for path, (pre, post) in chains.items() if pre != post} | set(caches)
    if len(names) != len(set(names)) or set(names) != expected:
        raise ReconstructionError('Bound transition omits or adds source changes')
    for change in changes:
        path, before, after = change['path'], change['before'], change['after']
        if not isinstance(after, dict) or after.get('path') != path or after.get('kind') != 'file':
            raise ReconstructionError('Invalid final delta entry')
        if path in caches:
            if before is not None or after.get('mode') != 0o644 or after.get('sha256') != caches[path]['pycSHA256']:
                raise ReconstructionError('Bound cache delta differs from verified cache')
        else:
            pre, post = chains[path]
            if (not isinstance(before, dict) or before.get('sha256') != pre
                    or after.get('sha256') != post or set(before) != set(after)
                    or any(before[k] != after[k] for k in before if k not in ('sha256', 'sizeBytes'))):
                raise ReconstructionError('Bound overlay delta differs from reviewed chain')
    stable = lambda value: {k: v for k, v in value.items() if k not in ('entriesSHA256', 'sourceFileCount')}
    if stable(baseline) != stable(snapshot) or snapshot['sourceFileCount'] != baseline['sourceFileCount'] + len(caches):
        raise ReconstructionError('Unexpected final snapshot metadata or count change')
    return {'boundTransitionChanges': len(changes), 'fullInventoryExecutionBound': True,
            'transitionCompletenessScope': 'Private full-inventory execution; final live equality is separate'}


def verify_tools_and_untracked(paths: dict[str, Path]) -> dict:
    def read(name):
        if name not in paths:
            raise ReconstructionError(f'Required input evidence missing: {name}')
        return json.loads(paths[name].read_text())

    def matching_files(items, expected_key, actual_key, count):
        if len(items) != count or len({x['path'] for x in items}) != count:
            raise ReconstructionError('Tool inventory incomplete or duplicated')
        for item in items:
            digest = item.get(expected_key)
            if (not re.fullmatch('[0-9a-f]{64}', str(digest))
                    or digest != item.get(actual_key) or item.get('matches') is not True):
                raise ReconstructionError('Tool payload checksum mismatch')

    archive_report = read('extracted-toolchain-verification.json')
    archives = archive_report['tools']
    if archive_report.get('complete') is not True or {x['tool'] for x in archives} != {'llvm', 'nodejs', 'rust'} or len(archives) != 3:
        raise ReconstructionError('Incomplete archive tool verification')
    for tool in archives:
        if tool.get('archiveDigestMatches') is not True:
            raise ReconstructionError('Unverified tool archive')
        pins = {
            'llvm': ('sha512', '8a19a4246feb12c956a04cad40c009f44505caa63c3c354ab8326eaf691ec805cae393d67aab48b1b4ddad7a7ad51829a1ae2cd6b656be0aff98cd537b4b4c98'),
            'nodejs': ('sha512', 'cd6b64563c73c4b482b557ab6715f513a1edde1fd05c33718d3bc0ab2361701b932953334c7fa07246f935dc5e36e74c10cb86d98ef59a6ac745b9f889e3bdcd'),
        }
        if tool['tool'] in pins and (tool.get('archiveDigestAlgorithm'), tool.get('archiveDigest')) != pins[tool['tool']]:
            raise ReconstructionError('Archive digest differs from pinned downloads input')
        matching_files(tool['files'], 'archiveSHA256', 'installedSHA256', {'llvm': 838, 'nodejs': 1, 'rust': 134}[tool['tool']])
    rust = next(x for x in archives if x['tool'] == 'rust')
    if rust['archiveDigest'] != read('rust-archive-official-checksum.json')['sha256']:
        raise ReconstructionError('Rust archive differs from official checksum')
    packages = read('cipd-tool-payload-verification.json')['packages']
    expected_packages = {'infra/3pp/tools/go/mac-arm64': (11509, 'GV753evfC30xSfiiI6ycB66mmNJupBAGnkcJo8F_mn4C'),
                         'chromium/third_party/typescript/mac-arm64': (117, '63sEajfB6_MIU0PehstKopK1_P_yfUm21-o-zedkrz0C')}
    if len(packages) != 2 or {x['package'] for x in packages} != set(expected_packages):
        raise ReconstructionError('Incomplete CIPD tool inventory')
    for package in packages:
        count, instance = expected_packages[package['package']]
        if package['instance'] != instance or any(x.get('executableMatches') is not True for x in package['files']):
            raise ReconstructionError('CIPD identity or executable mode mismatch')
        matching_files(package['files'], 'expectedSHA256', 'actualSHA256', count)
    native = read('esbuild-native-bottle-verification.json')
    observed = read('esbuild-observed-inputs.json')
    js = read('esbuild-npm-package-verification.json')
    if (native.get('version') != '0.28.2' or js.get('version') != '0.28.2'
            or native.get('installedBinaryMatchesBottle') is not True
            or native.get('bottleDigestMatchesRemoteOCIIndex') is not True
            or native.get('nativeBinarySHA256') != observed.get('binarySHA256')
            or len(js['files']) != 7 or any(x.get('matches') is not True for x in js['files'])
            or {x['path'] for x in js['files']} != {x['path'] for x in observed['packageFiles']}):
        raise ReconstructionError('Esbuild override lacks package proof')
    extra = read('extra-inputs-audit.json')
    prefix = 'third_party/devtools-frontend/src/node_modules/'
    expected_links = {prefix + '.bin/esbuild', prefix + '@esbuild/darwin-arm64/bin/esbuild', prefix + 'esbuild'}
    links = extra['externalSymlinks']
    if len(links) != 3 or {x['path'] for x in links} != expected_links or any(x.get('exists') is not True or x.get('snapshotTargetMatches') is not True for x in links):
        raise ReconstructionError('Unexpected external source symlinks')
    js_hashes = {x['path']: x['sha256'] for x in observed['packageFiles']}
    for link in links:
        if link['path'].endswith('/.bin/esbuild'):
            expected_digest = js_hashes['bin/esbuild']
        elif link['path'].endswith('/@esbuild/darwin-arm64/bin/esbuild'):
            expected_digest = native['nativeBinarySHA256']
        else:
            if link.get('isDirectory') is not True:
                raise ReconstructionError('Esbuild package directory link changed type')
            continue
        if link.get('isDirectory') is not False or link.get('sha256') != expected_digest:
            raise ReconstructionError('External esbuild payload differs from verified package')
    owners = {x['path'] for x in read('dependency-head-audit.json')['entries']}
    untracked_owners = [x['dependency'] for x in extra['dependencyUntracked']]
    if len(untracked_owners) != len(owners) or set(untracked_owners) != owners:
        raise ReconstructionError('Dependency untracked inventory omits or duplicates owners')
    for dep in extra['dependencyUntracked']:
        for item in dep['untracked']:
            # The saved git listing uses relative strings, not summary counts.
            relative = item if isinstance(item, str) else item['path']
            full = dep['dependency'].removeprefix('src/') + '/' + relative
            if full not in expected_links:
                raise ReconstructionError('Unexplained dependency untracked input')
    if 'root-untracked.zlist' not in paths:
        raise ReconstructionError('Missing root untracked inventory')
    untracked = [x.decode() for x in paths['root-untracked.zlist'].read_bytes().split(b'\0') if x]
    replayed = {x['path'] for x in read('sparse-replay-030tqb9v/report.json')['files'] if x.get('matches') is True and x.get('expected') == x.get('actual')}
    if len(untracked) != 21 or len(set(untracked)) != 21 or not set(untracked) <= replayed:
        raise ReconstructionError('Unexplained root untracked input')
    hooks = read('generated-revision-inputs.json')
    if len(hooks['files']) != 5 or any(x.get('revisionMatches') is not True or x.get('expectedRevision') not in x.get('content', '') for x in hooks['files']):
        raise ReconstructionError('Generated revision metadata mismatch')
    return {'toolPayloadFilesVerified': 838 + 1 + 134 + 11509 + 117,
            'rootUntrackedFilesVerified': 21, 'externalSymlinksReviewed': 3, 'releaseReady': False}


def verify_replay_bindings(paths: dict[str, Path], experiment: dict) -> dict:
    def read(name):
        if name not in paths:
            raise ReconstructionError(f'Required replay evidence missing: {name}')
        return json.loads(paths[name].read_text())

    heads = read('dependency-head-audit.json')['entries']
    if len(heads) != 149 or len({x['path'] for x in heads}) != 149:
        raise ReconstructionError('Incomplete or duplicate dependency HEAD inventory')
    for item in heads:
        if (item.get('status') != 'match' or item.get('actual') != item.get('expected')
                or not re.fullmatch('[0-9a-f]{40}', str(item.get('actual')))):
            raise ReconstructionError('Dependency HEAD mismatch')
    report_name = 'sparse-replay-030tqb9v/report.json'
    report = read(report_name)
    if len(report['files']) != 815 or len({x['path'] for x in report['files']}) != 815:
        raise ReconstructionError('Incomplete or duplicate replay postimages')
    for item in report['files']:
        if (item.get('matches') is not True or item.get('expected') != item.get('actual')
                or not re.fullmatch('[0-9a-f]{64}', str(item.get('actual')))):
            raise ReconstructionError('Replay postimage mismatch')
    groups = experiment['ownedPatchApplyCheck']['groups']
    patches = report['patches']
    ordered = read('ordered-patch-inputs.json')['patches']
    if [(x['name'], x['sha256']) for x in patches] != [(x['name'], x['sha256']) for x in ordered]:
        raise ReconstructionError('Full patch sequence differs from pinned input inventory')
    if len(groups) != 73 or len(patches) != 205:
        raise ReconstructionError('Unexpected ordered patch inventory')
    for group, patch in zip(groups, patches[129:202]):
        if group['sha256'] != patch['sha256'] or Path(group['patchFile']).name != patch['name']:
            raise ReconstructionError('Owned patch sequence differs from experiment')
    binding = read('sparse-replay-030tqb9v/review-binding.json')
    review_name = 'sparse-replay-9at859i5/offset-review.json'
    review = read(review_name)
    previous_name = 'sparse-replay-9at859i5/report.json'
    previous = read(previous_name)
    if (binding.get('reportSHA256') != sha256(paths[report_name])
            or binding.get('previousOffsetReviewSHA256') != sha256(paths[review_name])
            or review.get('reportSHA256') != sha256(paths[previous_name])
            or review.get('decision') != 'exact-context line relocations accepted for sparse replay only'):
        raise ReconstructionError('Offset review does not bind the reviewed reports')
    def offsets(value):
        return [(x['name'], x['sha256'], x['offsetMessages']) for x in value['patches'] if x['offsetMessages']]
    if offsets(report) != offsets(previous):
        raise ReconstructionError('Replay contains unreviewed offsets')
    return {'dependencyHEADsVerified': len(heads), 'postimagesVerified': len(report['files']),
            'ownedPatchOrderVerified': len(groups), 'releaseReady': False}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def bound_evidence(root: Path, manifest: dict) -> dict[str, Path]:
    if manifest.get('qualificationMethod') != 'current-input-reconstruction-v1':
        raise ReconstructionError('Unknown reconstruction method')
    if manifest.get('schemaVersion') != 1 or manifest.get('releaseReady') is not False:
        raise ReconstructionError('Invalid reconstruction manifest schema/readiness')
    paths = {}
    root = root.resolve()
    for item in manifest.get('evidence', []):
        name = item.get('path')
        if not isinstance(name, str) or not name or '\\' in name:
            raise ReconstructionError('Invalid evidence path')
        relative = PurePosixPath(name)
        if relative.is_absolute() or '..' in relative.parts or name in paths:
            raise ReconstructionError('Unsafe or duplicate evidence path')
        path = root / name
        if (path.is_symlink() or not path.is_file()
                or not path.resolve().is_relative_to(root)):
            raise ReconstructionError(f'Missing or unsafe evidence: {name}')
        # Reject symlinks in intermediate directories as well as the leaf.
        if any(parent.is_symlink() for parent in path.parents if parent != root and root in parent.parents):
            raise ReconstructionError(f'Symlinked evidence directory: {name}')
        if sha256(path) != item.get('sha256'):
            raise ReconstructionError(f'Evidence digest mismatch: {name}')
        paths[name] = path
    return paths


def verify_tracked_attribution(paths: dict[str, Path]) -> dict:
    def read(name):
        if name not in paths:
            raise ReconstructionError(f'Required evidence missing: {name}')
        return json.loads(paths[name].read_text())

    attribution = read('tracked-delta-attribution.json')
    # Reconstruct the set independently, not from reported counts.
    expected = set()
    for line in paths['root-tracked-delta.tsv'].read_text().splitlines():
        status, path = line.split('\t', 1)
        expected.add(('root', status, path))
    dependencies = read('dependency-tracked-deltas.json')['dependencies']
    heads = {x['path']: x['expected'] for x in read('dependency-head-audit.json')['entries']}
    if len(dependencies) != len(heads) or {x['dependency'] for x in dependencies} != set(heads):
        raise ReconstructionError('Dependency tracked inventory omits or duplicates owners')
    for dep in dependencies:
        if dep.get('commit') != heads[dep['dependency']]:
            raise ReconstructionError('Dependency delta base differs from pinned HEAD')
        prefix = dep['dependency'].removeprefix('src/')
        for change in dep['changes']:
            expected.add((dep['dependency'], change['status'], prefix + '/' + change['path']))
    replay = {}
    for name in ('sparse-replay-030tqb9v/report.json', 'root-domain-replay.json',
                 'dependency-domain-replay.json'):
        for item in read(name)['files']:
            if item.get('matches') is True and item.get('expected') == item.get('actual'):
                replay[(name, item['path'])] = item['actual']
    pruning = set(paths['pruning-present.list'].read_text().splitlines())
    package = 'third_party/devtools-frontend/src/node_modules/esbuild/'
    replaced = {package + item['path'] for item in read('esbuild-npm-package-verification.json')['files']
                if item.get('matches') is True}
    seen = set()
    for item in attribution['changes']:
        key = (item['owner'], item['status'], item['path'])
        if key in seen or key not in expected:
            raise ReconstructionError('Duplicate or unexpected attributed change')
        seen.add(key)
        decision = item.get('decision') or {}
        method = decision.get('method')
        valid = False
        if method == 'replayed-postimage':
            digest = replay.get((decision.get('report'), item['path']))
            valid = isinstance(digest, str) and len(digest) == 64 and digest == decision.get('postimageSHA256')
        elif method == 'upstream-pruning':
            valid = item['status'] == 'D' and item['path'] in pruning
        elif method == 'explicit-esbuild-package-symlink-override':
            valid = item['status'] == 'D' and item['path'] in replaced
        elif method == 'removed-derived-python-cache':
            valid = item['status'] == 'D' and item['path'] == 'third_party/harfbuzz/src/src/__pycache__/check_helpers.cpython-313.pyc'
        if not valid:
            raise ReconstructionError(f'Unproven attribution: {item["path"]}')
    if seen != expected:
        raise ReconstructionError('Tracked attribution omits changes')
    return {'trackedChangesVerified': len(seen), 'releaseReady': False,
            'scope': 'Recorded tracked deltas only; live source, untracked inputs, tools and binary require separate verification'}
