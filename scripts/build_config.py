#!/usr/bin/env python3
"""Read the single supported native target identity from the dependency lock."""
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def load_identity(root=ROOT):
    lock = json.loads((root / 'Dependencies.lock.json').read_text())
    if lock.get('architecture') != 'arm64':
        raise ValueError('Only the canonical arm64 build architecture is supported.')
    target = lock.get('deploymentTarget', '')
    if not isinstance(target, str) or re.fullmatch(r'[0-9]+\.[0-9]+', target) is None:
        raise ValueError('deploymentTarget must be a major.minor macOS version.')
    return {'architecture': lock['architecture'], 'deploymentTarget': target}


if __name__ == '__main__':
    try:
        identity = load_identity()
        print(identity['deploymentTarget'], identity['architecture'])
    except (OSError, ValueError) as error:
        raise SystemExit(f'Native build configuration stopped: {error}')
