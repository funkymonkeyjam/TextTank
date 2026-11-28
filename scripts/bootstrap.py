#!/usr/bin/env python3
"""Verify pinned sources; publish verified downloads and extracted trees atomically."""
import argparse
import errno
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def verify_tree(folder, manifest):
    if folder.is_symlink() or not folder.is_dir():
        raise ValueError(f'Missing or linked dependency tree: {folder}')
    for relative, expected in manifest.items():
        path = folder / relative
        if path.is_symlink() or not path.is_file() or digest(path) != expected:
            raise ValueError(f'Pinned source mismatch: {folder.name}/{relative}; restore the pinned source tree.')
    for path in folder.rglob('*'):
        relative = path.relative_to(folder).as_posix()
        if path.is_symlink():
            raise ValueError(f'Unexpected vendor symlink: {folder.name}/{relative}')
        if not path.is_file() or relative in manifest:
            continue
        # These are the exact outputs of the historical in-tree Lexilla make.
        # New builds write outputs under build/vendor instead. Never allow extra source files.
        if folder.name == 'lexilla' and ((path.parent == folder / 'src' and path.suffix == '.o')
                                         or relative == 'bin/liblexilla.a'):
            continue
        if path.name == '.DS_Store':
            continue
        raise ValueError(f'Unexpected vendor file: {folder.name}/{relative}')


def obtain_archive(dependency, archive, provided=None):
    def valid(path):
        return (not path.is_symlink() and path.is_file()
                and path.stat().st_size == dependency['bytes']
                and digest(path) == dependency['sha256'])
    archive.parent.mkdir(parents=True, exist_ok=True)
    if archive.exists() or archive.is_symlink():
        if valid(archive):
            return archive
        # Refuse ambiguous links/directories; a regular corrupt cache can be reacquired next run.
        if archive.is_symlink() or not archive.is_file():
            raise ValueError(f'Unsafe dependency cache entry: {archive}')
        archive.unlink()
        raise ValueError(f'Archive checksum/size mismatch: {archive.name}; corrupt cache removed, rerun to reacquire.')
    descriptor, temporary_name = tempfile.mkstemp(prefix=archive.name + '.', suffix='.part', dir=archive.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, 'wb') as output:
            source = (provided / archive.name).open('rb') if provided else urllib.request.urlopen(dependency['url'], timeout=30)
            with source:
                size = 0
                while True:
                    block = source.read(1024 * 1024)
                    if not block:
                        break
                    size += len(block)
                    if size > dependency['bytes']:
                        raise ValueError(f'Archive exceeds pinned size: {archive.name}')
                    output.write(block)
                output.flush()
                os.fsync(output.fileno())
        if not valid(temporary):
            raise ValueError(f'Archive checksum/size mismatch: {archive.name}; partial download discarded.')
        os.replace(temporary, archive)
    finally:
        temporary.unlink(missing_ok=True)
    return archive


def extract_archive(archive, vendor, folder, manifest):
    vendor.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.texttank-extract-', dir=vendor) as work:
        stage = Path(work)
        with tarfile.open(archive) as source:
            seen = set()
            for member in source.getmembers():
                path = PurePosixPath(member.name)
                if (path.is_absolute() or '..' in path.parts or not path.parts
                        or path.parts[0] != folder or member.name in seen
                        or not (member.isfile() or member.isdir())):
                    raise ValueError(f'Unsafe archive member: {member.name}')
                seen.add(member.name)
            # Python 3.9 supplied by Xcode has no data filter. The explicit allow-list above
            # rejects links, devices, absolute/parent paths before the equivalent safe extraction.
            if hasattr(tarfile, 'data_filter'):
                source.extractall(stage, filter='data')
            else:
                source.extractall(stage)
        verify_tree(stage / folder, manifest)
        target = vendor / folder
        if target.exists() or target.is_symlink():
            raise ValueError(f'Vendor destination already exists: {folder}; no tree was overwritten.')
        os.replace(stage / folder, target)


def scintilla_plan(root):
    """Identify the exact compiler input without acquiring or changing any files."""
    lock = json.loads((root / 'Dependencies.lock.json').read_text())
    upstream = json.loads((root / 'scripts/scintilla-source-hashes.json').read_text())
    patches = lock.get('patches', [])
    if not patches:
        return root / 'Vendor/scintilla', upstream, None
    allowed = (
        'scripts/dependency-patches/scintilla-loader-styles.patch',
        'scripts/dependency-patches/scintilla-cocoa-bidi.patch',
        'scripts/dependency-patches/scintilla-long-bidi-runs.patch',
        'scripts/dependency-patches/scintilla-ruler-layout.patch',
    )
    if tuple(item.get('path') for item in patches) != allowed[:len(patches)]:
        raise ValueError('Unsupported Scintilla patch path or order')

    expected = upstream
    layers = []
    for item in patches:
        if item.get('dependency') != 'scintilla':
            raise ValueError('Unsupported dependency patch set')
        patch = root / item['path']
        if patch.is_symlink() or not patch.is_file() or digest(patch) != item.get('sha256'):
            raise ValueError('Scintilla patch checksum mismatch')
        changes = item.get('files')
        if not isinstance(changes, dict) or not changes:
            raise ValueError('Missing pinned Scintilla patch results')
        source_path = r'src/[A-Za-z0-9_]+[.](h|cxx)'
        if item['path'] in allowed[1:]:
            source_path += r'|cocoa/[A-Za-z0-9_]+[.](h|mm)'
        for path, result in changes.items():
            if (path not in upstream or not re.fullmatch(source_path, path)
                    or not isinstance(result, str) or not re.fullmatch(r'[0-9a-f]{64}', result)
                    or expected[path] == result):
                raise ValueError(f'Invalid pinned Scintilla patch result: {path}')
        expected = {**expected, **changes}
        layers.append((patch, expected))
    dependency = next(entry for entry in lock['dependencies'] if entry['folder'] == 'scintilla')
    key = hashlib.sha256(json.dumps([dependency['sha256'], *patches], sort_keys=True).encode()).hexdigest()
    return root / 'build/scintilla-source' / key / 'scintilla', expected, layers


def prepare_scintilla(root):
    target, expected, layers = scintilla_plan(root)
    if not layers or target.exists() or target.is_symlink():
        verify_tree(target, expected)
        return target
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.prepare-', dir=target.parent) as work:
        stage = Path(work) / 'scintilla'
        shutil.copytree(root / 'Vendor/scintilla', stage, symlinks=True)
        # Run outside any enclosing checkout so Git applies vendor-relative paths.
        environment = {k: v for k, v in os.environ.items() if k not in ('GIT_DIR', 'GIT_WORK_TREE')}
        environment['GIT_CEILING_DIRECTORIES'] = str(stage.parent.resolve())
        for patch, layer_inputs in layers:
            applied = subprocess.run(['git', 'apply', '--whitespace=nowarn', str(patch)],
                                     cwd=stage, env=environment, capture_output=True, text=True)
            if applied.returncode:
                raise ValueError('Could not apply pinned Scintilla patch: ' + applied.stderr.strip())
            verify_tree(stage, layer_inputs)
        try:
            stage.rename(target)
        except OSError as error:
            if error.errno not in (errno.EEXIST, errno.ENOTEMPTY):
                raise
            verify_tree(target, expected)
    return target


def main():
    lock = json.loads((ROOT / 'Dependencies.lock.json').read_text())
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--print-scintilla-source', action='store_true')
    arguments = parser.parse_args()
    for dependency in lock['dependencies']:
        folder = dependency['folder']
        if folder not in ('scintilla', 'lexilla') or PurePosixPath(dependency['file']).name != dependency['file']:
            raise ValueError('Unsupported dependency folder or unsafe filename')
        manifest = json.loads((ROOT / 'scripts' / f'{folder}-source-hashes.json').read_text())
        target = ROOT / 'Vendor' / folder
        if target.exists():
            verify_tree(target, manifest)
            continue
        archive = obtain_archive(dependency, ROOT / 'build/downloads' / dependency['file'])
        extract_archive(archive, ROOT / 'Vendor', folder, manifest)
    source = prepare_scintilla(ROOT)
    if arguments.print_scintilla_source:
        print(source)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, tarfile.TarError) as error:
        raise SystemExit(f'Dependency bootstrap stopped: {error}')
