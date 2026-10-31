#!/usr/bin/env python3
"""Freeze .80 privacy evidence before manager compilation; never sign/launch."""
import argparse
import importlib.util
import json
from pathlib import Path
import shutil
import sys
from chromium_15680_privacy_derivation import copy_evidence, verify_lock
from chromium_15680_privacy_report import preserved_report_bytes


def prepare(project, lock_path, provenance, args, report, destination):
    if destination.exists() or destination.is_symlink() or not destination.is_absolute():
        raise ValueError('Use a new absolute evidence directory')
    lock = json.loads(lock_path.read_text()); verify_lock(lock, provenance, project)
    observed = json.loads(report.read_text())
    frozen = preserved_report_bytes(observed, project)
    destination.mkdir(mode=0o755)
    copies = {
        'fingerprint-chromium.lock.json': lock_path,
        'security-baseline.json': project / 'runtime/security-baseline.json',
        'neantik-patch-series.json': project / 'runtime/nevision-patches/series.json',
        'apple-device-tuples.json': project / 'runtime/apple-device-tuples.json',
        'source-provenance.json': provenance, 'args.gn': args,
    }
    for name, source in copies.items():
        if source.is_symlink() or not source.is_file(): raise ValueError('Unsafe evidence source')
        shutil.copyfile(source, destination / name)
    names = ['chromium-15680-source-adoption-v1.json', 'chromium-15680-deps-lock.json',
        'chromium-15680-neantik.patch', 'chromium-15680-devtools-typescript6.patch',
        'chromium-15680-v8-scope-iterator-compat.patch', 'chromium-15680-rebase-plan.json',
        'chromium-15680-build-evidence.json', 'chromium-15680-args.gn']
    base = destination / 'chromium-15680-source-evidence'; base.mkdir(mode=0o755)
    for name in names: shutil.copyfile(project / 'runtime' / name, base / name)
    copy_evidence(project, destination)
    (destination / 'runtime-verification.json').write_bytes(frozen)
    (destination / 'runtime-verification.json').chmod(0o600)
    spec = importlib.util.spec_from_file_location('privacy_release_baseline', project / 'scripts/package-manager-release-baseline.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    module.package(project, destination)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['project', 'lock', 'provenance', 'args', 'report', 'destination']: parser.add_argument('--' + name, type=Path, required=True)
    options = parser.parse_args()
    prepare(options.project, options.lock, options.provenance, options.args, options.report, options.destination)
