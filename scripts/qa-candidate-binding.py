#!/usr/bin/env python3
"""Non-authoritative QA declaration lint; never signs or launches code.

The candidate receipt is authoritative. This guard catches stale constants in
legacy launchers/fixtures before costly notarization or a one-shot native run.
It does not hash the archive or executables. Swift scanning is heuristic;
matching declarations cannot prove executable behavior. The exact-byte,
signature and profile gates in the real launcher remain mandatory.
"""
import argparse
import ast
import json
from pathlib import Path
import re


class BindingError(ValueError):
    pass


def require(condition, code):
    if not condition:
        raise BindingError(code)


def validate(candidate, plan, launcher, fixture, info):
    sha = candidate.get('sha256')
    require(isinstance(sha, str) and re.fullmatch(r'[0-9a-f]{64}', sha), 'invalid-candidate-sha')
    root = candidate.get('root', '')
    # mktemp can add a single dot before its random suffix. The app accepts
    # that one physical /private/tmp child; never admit an empty or ".." part.
    require(isinstance(root, str) and re.fullmatch(
        r'/private/tmp/neantik-[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*', root), 'invalid-root')
    for field, key in [('archiveSHA256', 'sha256'), ('root', 'root'),
                       ('profileSeedSHA256', 'profileSeedSHA256')]:
        require(plan.get(field) == candidate.get(key) and candidate.get(key), 'plan-' + field)
    require(info.get('NeAntikDevelopmentFixtureRoot') == root, 'embedded-root')
    require(info.get('CFBundleIdentifier') == 'app.neantik.desktop.dev', 'not-dev-bundle')
    for field, key in [('CFBundleShortVersionString', 'version'), ('CFBundleVersion', 'build')]:
        require(candidate.get(key) and info.get(field) == candidate[key], 'bundle-' + key)

    # Parse literals only, never execute third-party or fixture code.
    constants = {}
    for match in re.finditer(r'static let (\w+) = ("(?:[^"\\]|\\.)*")', launcher):
        require(match[1] not in constants, 'duplicate-launcher-constant')
        constants[match[1]] = json.loads(match[2])
    mapping = {'appPath': 'app', 'archivePath': 'archive', 'dataRoot': 'root',
               'archiveSHA256': 'sha256', 'profilesSHA256': 'profileSeedSHA256',
               'managerSHA256': 'managerSHA256', 'hostSHA256': 'hostSHA256'}
    for name, key in mapping.items():
        require(candidate.get(key) and constants.get(name) == candidate[key], 'launcher-' + name)
    canonical = re.findall(r'let canonicalRoot = "([^"]+)"', launcher)
    require(canonical == [root.replace('/private/tmp/', '/tmp/', 1)], 'launcher-canonical-root')
    tree = ast.parse(fixture)
    values = {}
    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            name = node.targets[0].id
            if name == 'ROOT':
                call = node.value
                require(isinstance(call, ast.Call) and isinstance(call.func, ast.Name)
                        and call.func.id == 'Path' and len(call.args) == 1, 'fixture-root-expression')
                values[name] = ast.literal_eval(call.args[0])
            elif name == 'PROFILES_SHA256':
                values[name] = ast.literal_eval(node.value)
    require(values.get('ROOT') == root, 'fixture-root')
    require(values.get('PROFILES_SHA256') == candidate['profileSeedSHA256'], 'fixture-seed')
    captions = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Dict):
            for key, value in zip(node.keys, node.values):
                if isinstance(key, ast.Constant) and key.value == 'candidateSHA256':
                    captions.append(ast.literal_eval(value))
    require(captions and all(value == sha for value in captions), 'fixture-candidate-caption')
    return {'status': 'declarations-consistent', 'archiveSHA256': sha,
            'scope': 'non-authoritative declaration lint', 'byteVerification': 'not-performed',
            'swiftParser': 'heuristic', 'nativeLaunch': False, 'releaseQualified': False}


def main():
    import plistlib
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--run-plan', type=Path, required=True)
    args = parser.parse_args()
    try:
        candidate = json.loads(args.candidate.read_text())
        plan = json.loads(args.run_plan.read_text())
        info = plistlib.loads((Path(candidate['app']) / 'Contents/Info.plist').read_bytes())
        result = validate(candidate, plan, Path(plan['launcherSource']).read_text(),
                          Path(plan['fixtureSource']).read_text(), info)
    except BindingError as error:
        print(json.dumps({'status': 'refused', 'code': str(error), 'nativeLaunch': False}))
        return 1
    except (OSError, ValueError, KeyError, TypeError, SyntaxError):
        print(json.dumps({'status': 'refused', 'code': 'unreadable-binding-input', 'nativeLaunch': False}))
        return 1
    print(json.dumps(result))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
