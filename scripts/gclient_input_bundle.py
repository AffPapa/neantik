"""Hash-bound composition of reviewed gclient inputs, not binary attestation."""
import hashlib
import json
from pathlib import Path
import re

from gclient_git_recipe import exact_object, verify_git_recipe
from gclient_payload_recipe import verify_payload_recipe
from gclient_source_evidence import EvidenceError, checked_file, verify_files


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise EvidenceError('Duplicate JSON field')
        result[key] = value
    return result


def load_recipe(recipe_root: Path, reference: dict) -> dict:
    exact_object(reference, {'path', 'sha256'}, 'recipe reference')
    if not isinstance(reference['sha256'], str) or not re.fullmatch('[0-9a-f]{64}', reference['sha256']):
        raise EvidenceError('Invalid recipe reference hash')
    path = checked_file(recipe_root, reference['path'])
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != reference['sha256']:
        raise EvidenceError('Reviewed recipe hash differs')
    try:
        result = json.loads(data, object_pairs_hook=unique_object)
    except (ValueError, UnicodeDecodeError) as error:
        raise EvidenceError('Invalid recipe JSON') from error
    if not isinstance(result, dict):
        raise EvidenceError('Recipe must be an object')
    return result


def verify_input_bundle(source_root: Path, recipe_root: Path, bundle: dict) -> dict:
    """Verify all referenced maps against live inputs; never grant release status."""
    exact_object(bundle, {'schemaVersion', 'scope', 'chromiumVersion', 'gitRecipe',
                          'payloadRecipes', 'rawRecipe'}, 'input bundle')
    if type(bundle['schemaVersion']) is not int or bundle['schemaVersion'] != 1 or bundle['scope'] != 'gclient-reviewed-inputs':
        raise EvidenceError('Unsupported input bundle')
    source_root, recipe_root = Path(source_root), Path(recipe_root)
    for directory in (source_root, recipe_root):
        if not directory.is_absolute() or directory.is_symlink() or not directory.is_dir():
            raise EvidenceError('Absolute nonsymlink input directories required')
    version = bundle['chromiumVersion']
    if not isinstance(version, str) or not re.fullmatch(r'\d+\.\d+\.\d+\.\d+', version):
        raise EvidenceError('Invalid Chromium version')
    text = checked_file(source_root, 'chrome/VERSION').read_text()
    pairs = re.findall(r'^(MAJOR|MINOR|BUILD|PATCH)=(\d+)$', text, re.M)
    if len(pairs) != 4 or len(dict(pairs)) != 4 or '.'.join(dict(pairs)[key] for key in ('MAJOR', 'MINOR', 'BUILD', 'PATCH')) != version:
        raise EvidenceError('Chromium version differs from input bundle')
    references = bundle['payloadRecipes']
    if not isinstance(references, list) or not references:
        raise EvidenceError('Payload recipes required')
    # Validate all referenced bytes before starting expensive live traversal.
    git_recipe = load_recipe(recipe_root, bundle['gitRecipe'])
    payload_recipes = [load_recipe(recipe_root, item) for item in references]
    raw = load_recipe(recipe_root, bundle['rawRecipe'])
    exact_object(raw, {'scope', 'files', 'metadata'}, 'raw input recipe')
    if not isinstance(raw['scope'], str) or not raw['scope']:
        raise EvidenceError('Raw recipe scope required')
    git_result = verify_git_recipe(source_root, git_recipe)
    payload_counts = []
    for recipe in payload_recipes:
        result = verify_payload_recipe(source_root.parent, recipe)
        payload_counts.append({'files': len(result['files']), 'links': len(result['links'])})
    verify_files(source_root.parent, raw['files'])
    verify_files(source_root.parent, raw['metadata'])
    return {'scope': 'gclient-reviewed-inputs', 'chromiumVersion': version,
            'gitDependencies': len(git_result['dependencies']), 'payloadCounts': payload_counts,
            'rawFiles': len(raw['files']), 'rawMetadata': len(raw['metadata']),
            'binaryBinding': 'not-attested',
            'recipeReferences': {key: bundle[key] for key in ('gitRecipe', 'payloadRecipes', 'rawRecipe')}}
