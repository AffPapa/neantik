#!/usr/bin/env python3
"""Check recipe identity within a source offer; not a source/relink qualification."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def check(root: Path) -> None:
    if root.is_symlink() or not root.is_dir():
        raise ValueError('offer root must be a physical directory')
    manifest_path = root / 'manifest.json'
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise ValueError('missing physical manifest')
    manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
    recipe = manifest['webkitBuildRecipe']
    name, expected = recipe['path'], recipe['sha256']
    if not isinstance(name, str) or not name or Path(name).is_absolute() or '..' in Path(name).parts:
        raise ValueError('unsafe recipe path')
    if not isinstance(expected, str) or len(expected) != 64 or any(c not in '0123456789abcdef' for c in expected):
        raise ValueError('invalid recipe digest')
    rows = [row for row in manifest['sourceOfferComponents'] if row.get('path') == name]
    if len(rows) != 1 or rows[0].get('includedInOfferFolder') is not True:
        raise ValueError('recipe must have one included component')
    path = root
    for part in Path(name).parts:
        path = path / part
        if path.is_symlink():
            raise ValueError('symlink in recipe path')
    if not path.is_file():
        raise ValueError('recipe missing')
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != expected or rows[0].get('sha256') != digest or rows[0].get('bytes') != path.stat().st_size:
        raise ValueError('recipe identity differs between manifest, component and file')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('offer_root', type=Path)
    args = parser.parse_args()
    try:
        check(args.offer_root)
    except (ValueError, OSError, KeyError, TypeError) as error:
        print(json.dumps({'status': 'refused', 'reason': str(error)}))
        return 2
    print(json.dumps({'status': 'pass', 'scope': 'recipe identity only; not source or release qualification'}))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
