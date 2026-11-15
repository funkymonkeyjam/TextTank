#!/usr/bin/env python3
"""Build existing verified Lexilla sources in a private configuration tree."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from bootstrap import verify_tree

ROOT = Path(__file__).resolve().parents[1]


def main():
    configuration = os.environ.get('CONFIGURATION', 'Debug')
    if configuration not in ('Debug', 'Release'):
        raise ValueError('CONFIGURATION must be Debug or Release')
    target = json.loads((ROOT / 'Dependencies.lock.json').read_text())['deploymentTarget']
    output = ROOT / 'build/vendor' / configuration
    source = output / 'lexilla-work/lexilla'
    # Make's relative target paths tolerate a working directory containing spaces.
    # Build products never touch the shared Vendor checkout or the other configuration.
    manifest = json.loads((ROOT / 'scripts/lexilla-source-hashes.json').read_text())
    verify_tree(ROOT / 'Vendor/lexilla', manifest)
    for relative in manifest:
        original = ROOT / 'Vendor/lexilla' / relative
        copied = source / relative
        copied.parent.mkdir(parents=True, exist_ok=True)
        if not copied.is_file() or copied.read_bytes() != original.read_bytes():
            shutil.copyfile(original, copied)
    headers = output / 'lexilla-work/scintilla'
    if not headers.exists():
        headers.symlink_to(ROOT / 'Vendor/scintilla', target_is_directory=True)
    verify_tree(source, manifest)
    optimization = '-g' if configuration == 'Debug' else '-O3'
    identity = json.dumps({'configuration': configuration, 'target': target,
                           'lock': hashlib.sha256((ROOT / 'Dependencies.lock.json').read_bytes()).hexdigest(),
                           'compiler': subprocess.check_output(['clang++', '--version'], text=True)}, sort_keys=True)
    stamp = output / 'lexilla-build-identity.json'
    if not stamp.is_file() or stamp.read_text() != identity:
        for object_file in (source / 'src').glob('*.o'):
            object_file.unlink()
        (source / 'bin/liblexilla.a').unlink(missing_ok=True)
    subprocess.run(['make', '-j' + str(os.cpu_count() or 1),
                    'DEBUG=' + ('1' if configuration == 'Debug' else ''),
                    'BASE_FLAGS=--std=c++17 -fvisibility=hidden -fPIC -arch arm64 ' + optimization + ' -Wpedantic -Wall -Wextra',
                    'CXXFLAGS=-mmacosx-version-min=' + target,
                    '../bin/liblexilla.a'], cwd=source / 'src', check=True)
    descriptor, name = tempfile.mkstemp(prefix='liblexilla.', suffix='.a', dir=output)
    os.close(descriptor)
    try:
        shutil.copyfile(source / 'bin/liblexilla.a', name)
        os.replace(name, output / 'liblexilla.a')
        stamp.write_text(identity)
    finally:
        Path(name).unlink(missing_ok=True)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(f'Lexilla build stopped: {error}')
