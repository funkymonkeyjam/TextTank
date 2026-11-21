#!/usr/bin/env python3
"""Build pinned Lexilla in a private configuration tree without cross-run object reuse."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from bootstrap import verify_tree
from build_config import load_identity

ROOT = Path(__file__).resolve().parents[1]


def prepare_sources(root, output, manifest):
    source = output / 'lexilla-work/lexilla'
    verify_tree(root / 'Vendor/lexilla', manifest)
    for relative in manifest:
        original = root / 'Vendor/lexilla' / relative
        copied = source / relative
        copied.parent.mkdir(parents=True, exist_ok=True)
        if not copied.is_file() or copied.read_bytes() != original.read_bytes():
            shutil.copyfile(original, copied)
    verify_tree(source, manifest)
    # Never reuse objects across build invocations. All flags, compiler behavior and
    # transitive headers are therefore re-read even when make would trust old timestamps.
    for object_file in (source / 'src').glob('*.o'):
        object_file.unlink()
    (source / 'bin/liblexilla.a').unlink(missing_ok=True)
    return source


def main():
    configuration = os.environ.get('CONFIGURATION', 'Debug')
    if configuration not in ('Debug', 'Release'):
        raise ValueError('CONFIGURATION must be Debug or Release')
    identity = load_identity(ROOT)
    output = ROOT / 'build/vendor' / configuration
    manifest_path = ROOT / 'scripts/lexilla-source-hashes.json'
    manifest = json.loads(manifest_path.read_text())
    scintilla_manifest = ROOT / 'scripts/scintilla-source-hashes.json'
    verify_tree(ROOT / 'Vendor/scintilla', json.loads(scintilla_manifest.read_text()))
    source = prepare_sources(ROOT, output, manifest)
    headers = output / 'lexilla-work/scintilla'
    if not headers.exists():
        headers.symlink_to(ROOT / 'Vendor/scintilla', target_is_directory=True)
    optimization = '-g' if configuration == 'Debug' else '-O3'
    command = ['make', '-j' + str(os.cpu_count() or 1), 'CXX=clang++',
               'DEBUG=' + ('1' if configuration == 'Debug' else ''),
               'BASE_FLAGS=--std=c++17 -fvisibility=hidden -fPIC -arch ' + identity['architecture']
               + ' ' + optimization + ' -Wpedantic -Wall -Wextra',
               'CXXFLAGS=-mmacosx-version-min=' + identity['deploymentTarget'], '../bin/liblexilla.a']
    subprocess.run(command, cwd=source / 'src', check=True)
    descriptor, name = tempfile.mkstemp(prefix='liblexilla.', suffix='.a', dir=output)
    os.close(descriptor)
    try:
        shutil.copyfile(source / 'bin/liblexilla.a', name)
        os.replace(name, output / 'liblexilla.a')
    finally:
        Path(name).unlink(missing_ok=True)
    # Descriptive provenance only; this file is never a cache eligibility key.
    (output / 'lexilla-build-identity.json').write_text(json.dumps({
        **identity, 'configuration': configuration, 'command': command,
        'compiler': subprocess.check_output(['clang++', '--version'], text=True),
        'lock_sha256': hashlib.sha256((ROOT / 'Dependencies.lock.json').read_bytes()).hexdigest(),
        'lexilla_manifest_sha256': hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
        'scintilla_manifest_sha256': hashlib.sha256(scintilla_manifest.read_bytes()).hexdigest(),
        'cross_run_object_reuse': False}, indent=2) + '\n')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(f'Lexilla build stopped: {error}')
