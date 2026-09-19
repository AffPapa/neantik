"""Schema-2 gclient contract validation; no binary/release qualification."""
import hashlib
import json
from pathlib import Path
import re

from gclient_git_recipe import exact_object
from gclient_input_bundle import load_recipe, unique_object, verify_input_bundle
from gclient_source_evidence import EvidenceError, checked_file, verify_files


def read_object(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise EvidenceError('Contract/plan must be regular nonsymlink files')
    data = path.read_bytes()
    try:
        value = json.loads(data, object_pairs_hook=unique_object)
    except (ValueError, UnicodeDecodeError) as error:
        raise EvidenceError('Invalid contract/plan JSON') from error
    if not isinstance(value, dict):
        raise EvidenceError('Contract/plan must be objects')
    return value, hashlib.sha256(data).hexdigest()


def verify_gclient_contract(project_root: Path, contract_path: Path, plan_path: Path) -> dict:
    project_root = Path(project_root)
    if not project_root.is_absolute() or project_root.is_symlink() or not project_root.is_dir():
        raise EvidenceError('Absolute nonsymlink project root required')
    contract, _ = read_object(contract_path)
    plan, plan_hash = read_object(plan_path)
    exact_object(contract, {'schemaVersion', 'sourceMode', 'binaryBindingStatus',
        'targetArchitecture', 'targetChromiumVersion', 'officialChromiumBase',
        'rebasePlanSHA256', 'inputBundle', 'buildToolFiles', 'ownedInputs'}, 'gclient contract')
    exact_object(plan, {'schemaVersion', 'sourceMode', 'targetChromiumVersion',
                        'officialChromiumCommit'}, 'gclient plan')
    for document in (contract, plan):
        if type(document['schemaVersion']) is not int or document['schemaVersion'] != 2 or document['sourceMode'] != 'gclient':
            raise EvidenceError('Unsupported gclient contract/plan schema')
    version = contract['targetChromiumVersion']
    if not isinstance(version, str) or not re.fullmatch(r'\d+\.\d+\.\d+\.\d+', version) or version != plan['targetChromiumVersion']:
        raise EvidenceError('Gclient target version mismatch')
    if contract['binaryBindingStatus'] != 'pending-new-build' or contract['targetArchitecture'] != 'arm64':
        raise EvidenceError('Unsupported target or premature binary claim')
    if contract['rebasePlanSHA256'] != plan_hash:
        raise EvidenceError('Gclient plan hash mismatch')
    official = exact_object(contract['officialChromiumBase'],
        {'repository', 'tag', 'commit', 'tree', 'licenseSHA256'}, 'official Chromium identity')
    if official['repository'] != 'https://chromium.googlesource.com/chromium/src.git' or official['tag'] != version:
        raise EvidenceError('Unexpected official Chromium repository/tag')
    for key in ('commit', 'tree'):
        if not isinstance(official[key], str) or not re.fullmatch('[0-9a-f]{40}', official[key]):
            raise EvidenceError('Invalid official Git object')
    if plan['officialChromiumCommit'] != official['commit']:
        raise EvidenceError('Plan and contract official commits differ')
    verify_files(project_root, {'runtime/licenses/Chromium-LICENSE': official['licenseSHA256']})
    verify_files(project_root, contract['ownedInputs'])
    tools = contract['buildToolFiles']
    if not isinstance(tools, dict) or not tools:
        raise EvidenceError('Explicit build-tool bindings required')
    for path, digest in tools.items():
        if not isinstance(path, str) or path.startswith('/') or any(p in ('', '.', '..') for p in path.split('/')) or '\\' in path:
            raise EvidenceError('Unsafe tool binding path')
        if not isinstance(digest, str) or not re.fullmatch('[0-9a-f]{64}', digest):
            raise EvidenceError('Invalid tool binding hash')
    bundle = load_recipe(project_root, contract['inputBundle'])
    exact_object(bundle, {'schemaVersion', 'scope', 'chromiumVersion', 'gitRecipe', 'payloadRecipes', 'rawRecipe'}, 'input bundle')
    if type(bundle['schemaVersion']) is not int or bundle['schemaVersion'] != 1 or bundle['scope'] != 'gclient-reviewed-inputs' or bundle['chromiumVersion'] != version:
        raise EvidenceError('Input bundle differs from contract')
    if not isinstance(bundle['payloadRecipes'], list) or not bundle['payloadRecipes']:
        raise EvidenceError('Input payload recipes missing')
    recipe_root = checked_file(project_root, contract['inputBundle']['path']).parent
    git_recipe = load_recipe(recipe_root, bundle['gitRecipe'])
    if not isinstance(git_recipe.get('root'), dict) or not all(key in git_recipe['root'] for key in ('commit', 'tree')):
        raise EvidenceError('Input recipe official identity missing')
    if any(git_recipe['root'][key] != official[key] for key in ('commit', 'tree')):
        raise EvidenceError('Input recipe official identity differs')
    for reference in [*bundle['payloadRecipes'], bundle['rawRecipe']]:
        load_recipe(recipe_root, reference)
    return contract


def verify_gclient_source(project_root: Path, source_root: Path,
                          contract_path: Path, plan_path: Path) -> dict:
    """Check live inputs and tools without attesting a compiled binary."""
    contract = verify_gclient_contract(project_root, contract_path, plan_path)
    source_root = Path(source_root)
    if not source_root.is_absolute() or source_root.is_symlink() or not source_root.is_dir():
        raise EvidenceError('Absolute nonsymlink source root required')
    verify_files(source_root, contract['buildToolFiles'])
    bundle = load_recipe(project_root, contract['inputBundle'])
    recipe_root = checked_file(project_root, contract['inputBundle']['path']).parent
    result = verify_input_bundle(source_root, recipe_root, bundle)
    # Recheck tools after traversal so a concurrent replacement cannot silently
    # inherit a successful check from before the dependency scan.
    verify_files(source_root, contract['buildToolFiles'])
    return {'schemaVersion': 2, 'sourceMode': 'gclient',
            'chromiumVersion': contract['targetChromiumVersion'],
            'binaryBinding': 'not-attested', 'inputs': result,
            'buildToolFiles': dict(contract['buildToolFiles'])}
