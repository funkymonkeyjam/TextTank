#!/usr/bin/env python3
"""Verify pinned sources; publish verified downloads and extracted trees atomically."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
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


def main():
    lock = json.loads((ROOT / 'Dependencies.lock.json').read_text())
    if lock.get('patches'):
        raise ValueError('Dependency patches require an explicit verification workflow.')
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


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, tarfile.TarError) as error:
        raise SystemExit(f'Dependency bootstrap stopped: {error}')
