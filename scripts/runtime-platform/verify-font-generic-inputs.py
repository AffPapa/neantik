#!/usr/bin/env python3
"""Verify unqualified generic-font source inputs, never browser behavior."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import xml.etree.ElementTree as ET

FILES = {
    'third_party/blink/renderer/platform/BUILD.gn',
    'third_party/blink/renderer/platform/fonts/generic_font_family_settings.cc',
    'third_party/blink/renderer/platform/fonts/neantik_system_generic_defaults.h',
    'third_party/blink/renderer/core/workers/worker_settings.cc',
}
DEFAULTS = dict(Standard='Times', Fixed='Menlo', Serif='Times', SansSerif='Helvetica',
                Cursive='Apple Chancery', Fantasy='Papyrus', Math='STIX Two Math')
IDS = dict(Standard='STANDARD', Fixed='FIXED', Serif='SERIF', SansSerif='SANS_SERIF',
           Cursive='CURSIVE', Fantasy='FANTASY', Math='MATH')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def relative(value):
    p = PurePosixPath(value)
    if p.is_absolute() or '..' in p.parts or str(p) != value:
        raise ValueError('invalid source input path')
    return str(p)


def verify(directory, source=None):
    m = json.loads((directory / 'chromium-font-generic-defaults.json').read_text())
    if m['releaseReady'] is not False or m['defaults'] != DEFAULTS:
        raise ValueError('unqualified input defaults drift')
    for key, pin in [('parentManifest', 'parentManifestSHA256'), ('patchFile', 'patchSHA256')]:
        if digest(directory / relative(m[key])) != m[pin]:
            raise ValueError('source lineage/hash drift')
    if len(m['files']) != 4 or {relative(row['path']) for row in m['files']} != FILES:
        raise ValueError('unexpected source inventory')
    if source:
        for row in m['files']:
            if digest(source / relative(row['path'])) != row['postimageSHA256']:
                raise ValueError('applied source drift')
        defaults = source / 'chrome/app/resources/locale_settings_mac.grd'
        if digest(defaults) != m['defaultsSourceSHA256']:
            raise ValueError('mac defaults source drift')
        messages = {x.attrib['name']: ''.join(x.itertext()).strip()
                    for x in ET.parse(defaults).iter('message')}
        for key, value in DEFAULTS.items():
            if messages['IDS_' + IDS[key] + '_FONT_FAMILY'] != value:
                raise ValueError('mac defaults semantic drift')
    return dict(status='source-inputs-verified', files=4, commonDefaults=7,
                chromiumSourceChecked=source is not None, compiled=False,
                actualBrowser=False, releaseQualified=False)


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--directory', type=Path, default=Path(__file__).resolve().parents[2] / 'runtime/font-policy-v1')
    p.add_argument('--chromium-root', type=Path)
    args = p.parse_args()
    try:
        print(json.dumps(verify(args.directory, args.chromium_root)))
    except (OSError, KeyError, ValueError, TypeError, ET.ParseError):
        print(json.dumps(dict(status='FAIL', reason='generic source inputs drifted', releaseQualified=False)))
        raise SystemExit(1)
