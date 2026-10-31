#!/usr/bin/env python3
"""Bind the unchanged native M156 output to its authenticated postbuild proof."""
import argparse
from pathlib import Path
import chromium_15612_release_evidence as source

parser = argparse.ArgumentParser()
parser.add_argument('app', type=Path)
parser.add_argument('args_gn', type=Path)
parser.add_argument('candidate', type=Path)
args = parser.parse_args()
try:
    document = source.read_object(args.candidate, 'M156 candidate')
    source.verify_candidate_document(document, project_root=Path(__file__).resolve().parents[1])
    source.verify_unsigned_binary_binding(args.app, args.args_gn, document)
except (OSError, ValueError) as error:
    parser.exit(1, 'Unsigned M156 candidate rejected: ' + str(error) + '\n')
print('PASS: unchanged native M156 bytes and arguments match the authenticated source proof.')
