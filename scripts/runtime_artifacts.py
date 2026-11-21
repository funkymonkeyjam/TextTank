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
import tempfile

from build_config import load_identity
import bootstrap
import build_evidence
import link_evidence
import runtime_linkage

ROOT = Path(__file__).resolve().parents[1]
FRAMEWORKS = ['Scintilla', 'NativeSearch', 'EditorBridge', 'TextTankCore', 'TextTankRuntime']


def command(*arguments, cwd=None):
    return subprocess.check_output(arguments, cwd=cwd, text=True, stderr=subprocess.STDOUT).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def is_input(name):
    path = Path(name)
    if '__pycache__' in path.parts or path.name == '.DS_Store':
        return False
    if path.parts[0] in ('Sources', 'Resources', 'scripts', 'Tools'):
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
    for directory in ('Sources', 'Resources', 'scripts', 'Tools', 'TextTank.xcodeproj'):
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


def atomic_json(destination, value):
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', dir=destination.parent, delete=False) as output:
            temporary = Path(output.name)
            json.dump(value, output, indent=2)
            output.write('\n')
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, destination)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def matching_before(root, configuration, before_path, source_inputs, settings):
    before = json.loads(before_path.read_text())
    if before.get('schema') != 1 or before.get('configuration') != configuration or before.get('inputs') != source_inputs or before.get('toolchain') != toolchain() or before.get('target_settings') != settings:
        raise ValueError('Source/dependency/configuration/toolchain inputs changed during the canonical build')
    return before


def capture_links(root, app, configuration, destination, before_path):
    source_inputs = inputs(root)
    settings = build_evidence.resolved_settings(root, configuration)
    matching_before(root, configuration, before_path, source_inputs, settings)
    previous_path = destination.parent / 'manifest.json'
    previous = json.loads(previous_path.read_text()) if previous_path.exists() else {}
    if previous.get('schema') != 3:
        previous = {}
    lexer = build_evidence.cpp_producer(root, configuration, settings, previous.get('user_lexer_producer'))
    images, _ = code_and_metadata(root, app, configuration)
    if digest(app.parent / 'tt') != digest(app / runtime_linkage.HELPER):
        raise ValueError('Embedded unsigned tt does not match its actual linked producer')
    producers, refreshes = link_evidence.record(root, configuration, images, app, settings, lexer,
                                     previous.get('link_producers'), previous.get('linked_outputs'), previous.get('compiler_refreshes'))
    closure = runtime_linkage.verify(app, load_identity(root)['deploymentTarget'])
    value = {'schema': 1, 'configuration': configuration, 'inputs': source_inputs,
             'toolchain': toolchain(), 'target_settings': settings,
             'user_lexer_producer': lexer, 'link_producers': producers,
             'compiler_refreshes': refreshes,
             'unsigned_closure': closure}
    verify_dependencies(root)
    matching_before(root, configuration, before_path, inputs(root), build_evidence.resolved_settings(root, configuration))
    # Bind the final pre-sign bytes to the successful real link records in this turn.
    for path, producer in producers.items():
        if str(path) in previous.get('link_producers', {}) and producer == previous['link_producers'][path]:
            if link_evidence.regular(path) != previous['linked_outputs'][path]:
                raise ValueError('Reused linked bytes changed during capture')
        elif link_evidence.regular(path) != {key: item for key, item in producer['output'].items() if key != 'uuid'}:
            raise ValueError('Actual linked bytes changed during capture')
    atomic_json(destination, value)
    return value


def record(root, app, configuration, destination, before_path):
    if configuration not in ('Debug', 'Release'):
        raise ValueError('Unsupported artifact configuration')
    source_inputs = inputs(root)
    before_path = before_path if before_path.is_absolute() else root / before_path
    before_path = before_path.resolve()
    settings = build_evidence.resolved_settings(root, configuration)
    matching_before(root, configuration, before_path, source_inputs, settings)
    capture_path = root / 'build/artifacts' / configuration / 'link-before-sign.json'
    captured = json.loads(capture_path.read_text())
    if captured.get('schema') != 1 or captured.get('configuration') != configuration or captured.get('inputs') != source_inputs or captured.get('toolchain') != toolchain() or captured.get('target_settings') != settings:
        raise ValueError('Actual pre-sign link capture does not match canonical inputs/settings')
    producer = captured['user_lexer_producer']
    if producer is not None:
        build_evidence.validate_cpp(root, producer, settings['EditorBridge'])
    verify_dependencies(root)
    command('codesign', '--verify', '--deep', '--strict', str(app))
    images, metadata = code_and_metadata(root, app, configuration)
    closure = runtime_linkage.verify(app, load_identity(root)['deploymentTarget'])
    expected = {value['produced'] for value in images.values()} | {str(app / name) for name in closure['images'] if name.startswith('Contents/MacOS/')} | {str(app.parent / 'tt')}
    links = link_evidence.validate(root, captured['link_producers'], settings, producer, expected, captured['compiler_refreshes'])
    if uuid(app.parent / 'tt') != uuid(app / runtime_linkage.HELPER):
        raise ValueError('Signed tt identity differs from its actual linked producer')
    # Signature bytes may change; each signed result must keep its actual linked UUID.
    unsigned = captured['unsigned_closure']
    if {key: {field: item for field, item in value.items() if field != 'sha256'} for key, value in unsigned['images'].items()} != {key: {field: item for field, item in value.items() if field != 'sha256'} for key, value in closure['images'].items()} or unsigned['edges'] != closure['edges']:
        raise ValueError('Signing changed actual code identity/dependency commands')
    capture_proof = link_evidence.retain(root, configuration, capture_path.read_bytes(), '.capture.json')
    value = {'schema': 3, 'configuration': configuration, 'build_root': str(root), 'app': str(app),
             'identity': load_identity(root), 'toolchain': toolchain(), 'inputs': source_inputs,
             'app_files': snapshot(app), 'images': images, 'metadata': metadata,
             'user_lexer_producer': producer, 'target_settings': settings,
             'link_producers': links, 'linked_outputs': {path: link_evidence.regular(path) for path in links},
             'compiler_refreshes': captured['compiler_refreshes'],
             'dependency_closure': closure, 'link_capture': capture_proof,
             'before': {'path': str(before_path), 'sha256': digest(before_path)},
             'source_checkout': tracked_inputs(root) is not None,
             'scope': 'Local native artifact/input identity only; no source-stable, archive-binding or package-provenance claim'}
    if inputs(root) != source_inputs or build_evidence.resolved_settings(root, configuration) != settings or toolchain() != value['toolchain'] or snapshot(app) != value['app_files']:
        raise ValueError('Canonical inputs/settings/code changed before artifact publication')
    verify_dependencies(root)
    atomic_json(destination, value)
    return value


def validate(root, manifest, configuration):
    value = json.loads(manifest.read_text())
    if value.get('schema') != 3 or value.get('configuration') != configuration:
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
    # Query the selected archive, never the known-blocked synced checkout project.
    if build_evidence.resolved_settings(build_root, configuration) != value['target_settings']:
        raise ValueError('Stale artifact: live selected-build target settings changed')
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
    has_lexer = (build_root / 'Sources/Languages/LexUserPort/LexUser.cxx').is_file()
    producer = value['user_lexer_producer']
    if has_lexer and (not isinstance(producer, dict) or producer.get('source') != 'Sources/Languages/LexUserPort/LexUser.cxx' or producer.get('target') != 'EditorBridge'):
        raise ValueError('Actual user-lexer source requires complete nonnull EditorBridge producer evidence')
    if producer is not None:
        build_evidence.validate_cpp(build_root, value['user_lexer_producer'], value['target_settings']['EditorBridge'])
    closure = runtime_linkage.verify(app, value['identity']['deploymentTarget'])
    if closure != value['dependency_closure']:
        raise ValueError('Actual signed dependency/runpath closure changed')
    expected = {item['produced'] for item in images.values()} | {str(app / name) for name in closure['images'] if name.startswith('Contents/MacOS/')} | {str(app.parent / 'tt')}
    link_evidence.validate(build_root, value['link_producers'], value['target_settings'], producer, expected, value['compiler_refreshes'])
    if value['linked_outputs'] != {path: link_evidence.regular(path) for path in expected}:
        raise ValueError('Actual signed/produced link output bytes changed')
    capture_proof = value['link_capture']
    if link_evidence.anchored(capture_proof['path'], build_root) != capture_proof:
        raise ValueError('Immutable actual link capture changed')
    captured = json.loads(Path(capture_proof['path']).read_text())
    if captured['link_producers'] != value['link_producers'] or captured['compiler_refreshes'] != value['compiler_refreshes'] or captured['user_lexer_producer'] != producer or captured['inputs'] != value['inputs'] or captured['target_settings'] != value['target_settings']:
        raise ValueError('Immutable actual link capture differs from artifact manifest')
    command('codesign', '--verify', '--deep', '--strict', str(app))
    if inputs(root, require_checkout=True) != value['inputs'] or inputs(build_root) != value['inputs'] or build_evidence.resolved_settings(build_root, configuration) != value['target_settings'] or snapshot(app) != value['app_files']:
        raise ValueError('Inputs/settings/artifacts changed during validation')
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['begin', 'links', 'record', 'validate'])
    parser.add_argument('--root', type=Path, default=ROOT)
    parser.add_argument('--configuration', choices=['Debug', 'Release'], required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--app', type=Path)
    parser.add_argument('--before', type=Path)
    arguments = parser.parse_args()
    root = arguments.root.resolve()
    if arguments.operation == 'begin':
        begin(root, arguments.configuration, arguments.manifest)
    elif arguments.operation in ('links', 'record'):
        if arguments.app is None or arguments.before is None:
            parser.error('record requires --app and --before')
        operation = capture_links if arguments.operation == 'links' else record
        operation(root, arguments.app.resolve(), arguments.configuration, arguments.manifest, arguments.before.resolve())
    else:
        value = validate(root, arguments.manifest, arguments.configuration)
        print(value['app'])


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        raise SystemExit(f'Runtime artifacts rejected: {error}')
