#!/usr/bin/env python3
"""Bind check linkage to the application's actual signed native artifacts.

This records local build evidence, not package provenance. An exact-source archive
remains unbound to a Git checkout even when its input bytes match a checkout.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import stat
import subprocess

from build_config import load_identity
import bootstrap
import build_evidence

ROOT = Path(__file__).resolve().parents[1]
FRAMEWORKS = ['Scintilla', 'NativeSearch', 'EditorBridge']


def command(*arguments, cwd=None):
    return subprocess.check_output(arguments, cwd=cwd, text=True, stderr=subprocess.STDOUT).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def is_input(name):
    path = Path(name)
    if '__pycache__' in path.parts or path.name == '.DS_Store':
        return False
    if path.parts[0] in ('Sources', 'Resources', 'scripts'):
        return True
    if path.parts[0] == 'TextTank.xcodeproj':
        return path.suffix in ('.pbxproj', '.xcscheme', '.xcconfig', '.xcsettings', '.plist')
    return name == 'Dependencies.lock.json'


def tracked_inputs(root):
    try:
        if Path(command('git', 'rev-parse', '--show-toplevel', cwd=root)).resolve() != root.resolve():
            return None
        names = command('git', 'ls-files', '-z', cwd=root).split('\0')
        return {name for name in names if name and is_input(name)}
    except subprocess.CalledProcessError:
        return None


def inputs(root, require_checkout=False):
    names = {'Dependencies.lock.json'}
    for directory in ('Sources', 'Resources', 'scripts', 'TextTank.xcodeproj'):
        for path in (root / directory).rglob('*'):
            name = str(path.relative_to(root))
            if (path.is_file() or path.is_symlink()) and is_input(name):
                names.add(name)
    tracked = tracked_inputs(root)
    if require_checkout and tracked is None:
        raise ValueError('Checking reused artifacts requires the selected Git checkout root')
    if tracked is not None and names != tracked:
        raise ValueError(f'Unexpected/untracked or missing build inputs: extra={sorted(names - tracked)}, missing={sorted(tracked - names)}')
    result = {}
    for name in sorted(names):
        path = root / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f'Build input is not a regular file: {name}')
        result[name] = {'sha256': digest(path), 'mode': stat.S_IMODE(path.stat().st_mode)}
    return result


def snapshot(root, selected=None):
    result = {}
    for path in sorted(root.rglob('*')):
        relative = str(path.relative_to(root))
        if selected is not None and not selected(path):
            continue
        if path.is_symlink():
            target = os.readlink(path)
            if Path(target).is_absolute() or not path.resolve().is_relative_to(root.resolve()):
                raise ValueError(f'Artifact link leaves its own bundle: {relative}')
            result[relative] = {'link': target}
        elif path.is_file():
            result[relative] = {'sha256': digest(path), 'mode': stat.S_IMODE(path.stat().st_mode)}
    return result


def toolchain():
    return {'xcode': command('xcodebuild', '-version'),
            'swift': command('xcrun', 'swiftc', '-version'),
            'clang': command('xcrun', 'clang', '--version'),
            'sdk': command('xcrun', '--sdk', 'macosx', '--show-sdk-path'),
            'sdk_version': command('xcrun', '--sdk', 'macosx', '--show-sdk-version'),
            'machine': platform.machine(), 'host_macos': platform.mac_ver()[0]}


def verify_dependencies(root):
    for folder in ('scintilla', 'lexilla'):
        manifest = json.loads((root / 'scripts' / f'{folder}-source-hashes.json').read_text())
        bootstrap.verify_tree(root / 'Vendor' / folder, manifest)


def uuid(image):
    lines = command('dwarfdump', '--uuid', str(image)).splitlines()
    if len(lines) != 1 or '(arm64)' not in lines[0]:
        raise ValueError(f'Expected one arm64 code image: {image}')
    return lines[0].split()[1]


def begin(root, configuration, destination):
    verify_dependencies(root)
    value = {'schema': 1, 'configuration': configuration, 'inputs': inputs(root),
             'toolchain': toolchain(), 'target_settings': build_evidence.resolved_settings(root, configuration)}
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(value, indent=2) + '\n')
    return value


def code_and_metadata(build_root, app, configuration):
    products = build_root / 'build/DerivedData/Build/Products' / configuration
    metadata = {}
    images = {}
    for name in FRAMEWORKS:
        produced = ((build_root / 'build/vendor' / configuration) if name == 'Scintilla' else products) / f'{name}.framework'
        embedded = app / f'Contents/Frameworks/{name}.framework/Versions/A/{name}'
        original = produced / f'Versions/A/{name}'
        original_uuid, embedded_uuid = uuid(original), uuid(embedded)
        if original_uuid != embedded_uuid:
            raise ValueError(f'Embedded {name} is not the actual built code image')
        metadata[name] = snapshot(produced, lambda path: any(part in ('Headers', 'PrivateHeaders', 'Modules') for part in path.relative_to(produced).parts))
        images[name] = {'produced': str(original), 'produced_sha256': digest(original),
                        'embedded': str(embedded), 'embedded_sha256': digest(embedded),
                        'uuid': embedded_uuid}
    for name, source in [('NativeSearch', 'Sources/Search/TTSearchEngine.h'),
                         ('EditorBridge', 'Sources/EditorBridge/TTEditor.h')]:
        header = products / f'{name}.framework/Versions/A/Headers' / Path(source).name
        module = products / f'{name}.framework/Versions/A/Modules/module.modulemap'
        if digest(header) != digest(build_root / source) or digest(module) != digest(build_root / Path(source).parent / 'module.modulemap'):
            raise ValueError(f'{name} module/header metadata does not match its source inputs')
    return images, metadata


def record(root, app, configuration, destination, before_path):
    if configuration not in ('Debug', 'Release'):
        raise ValueError('Unsupported artifact configuration')
    source_inputs = inputs(root)
    before_path = before_path if before_path.is_absolute() else root / before_path
    before_path = before_path.resolve()
    before = json.loads(before_path.read_text())
    settings = build_evidence.resolved_settings(root, configuration)
    if before.get('schema') != 1 or before.get('configuration') != configuration or before.get('inputs') != source_inputs or before.get('toolchain') != toolchain() or before.get('target_settings') != settings:
        raise ValueError('Source/dependency/configuration/toolchain inputs changed during the canonical build')
    previous = json.loads(destination.read_text()) if destination.exists() else {}
    producer = build_evidence.cpp_producer(root, configuration, settings, previous.get('user_lexer_producer') if previous.get('schema') == 2 else None)
    verify_dependencies(root)
    command('codesign', '--verify', '--deep', '--strict', str(app))
    images, metadata = code_and_metadata(root, app, configuration)
    value = {'schema': 2, 'configuration': configuration, 'build_root': str(root), 'app': str(app),
             'identity': load_identity(root), 'toolchain': toolchain(), 'inputs': source_inputs,
             'app_files': snapshot(app), 'images': images, 'metadata': metadata,
             'user_lexer_producer': producer, 'target_settings': settings,
             'before': {'path': str(before_path), 'sha256': digest(before_path)},
             'source_checkout': tracked_inputs(root) is not None,
             'scope': 'Local native artifact/input identity only; no source-stable, archive-binding or package-provenance claim'}
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(value, indent=2) + '\n')
    return value


def validate(root, manifest, configuration):
    value = json.loads(manifest.read_text())
    if value.get('schema') != 2 or value.get('configuration') != configuration:
        raise ValueError('Artifact configuration/schema does not match this check invocation')
    if inputs(root, require_checkout=True) != value['inputs']:
        raise ValueError('Stale artifact: source/configuration/header input bytes or modes changed')
    if load_identity(root) != value['identity'] or toolchain() != value['toolchain']:
        raise ValueError('Stale artifact: target identity or compiler/SDK changed')
    verify_dependencies(root)
    build_root, app = Path(value['build_root']), Path(value['app'])
    if inputs(build_root) != value['inputs']:
        raise ValueError('Built archive source/configuration/header inputs changed')
    verify_dependencies(build_root)
    if snapshot(app) != value['app_files']:
        raise ValueError('Actual signed application artifact changed')
    images, metadata = code_and_metadata(build_root, app, configuration)
    if images != value['images'] or metadata != value['metadata']:
        raise ValueError('Built code image or compiler module/header metadata changed')
    before_path = Path(value['before']['path'])
    if digest(before_path) != value['before']['sha256']:
        raise ValueError('Actual before-build input/settings evidence changed')
    before = json.loads(before_path.read_text())
    if before['inputs'] != value['inputs'] or before['target_settings'] != value['target_settings'] or before['toolchain'] != value['toolchain']:
        raise ValueError('Before/after canonical input/settings evidence differs')
    if value['user_lexer_producer'] is not None:
        build_evidence.validate_cpp(build_root, value['user_lexer_producer'], value['target_settings']['EditorBridge'])
    command('codesign', '--verify', '--deep', '--strict', str(app))
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['begin', 'record', 'validate'])
    parser.add_argument('--root', type=Path, default=ROOT)
    parser.add_argument('--configuration', choices=['Debug', 'Release'], required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--app', type=Path)
    parser.add_argument('--before', type=Path)
    arguments = parser.parse_args()
    root = arguments.root.resolve()
    if arguments.operation == 'begin':
        begin(root, arguments.configuration, arguments.manifest)
    elif arguments.operation == 'record':
        if arguments.app is None or arguments.before is None:
            parser.error('record requires --app and --before')
        record(root, arguments.app.resolve(), arguments.configuration, arguments.manifest, arguments.before)
    else:
        value = validate(root, arguments.manifest, arguments.configuration)
        print(value['app'])


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        raise SystemExit(f'Runtime artifacts rejected: {error}')
