#!/usr/bin/env python3
"""Inspect the complete local Mach-O closure without launching any image."""
import hashlib
from pathlib import Path
import plistlib
import re
import subprocess

FRAMEWORKS = ('Scintilla', 'NativeSearch', 'EditorBridge', 'TextTankCore', 'TextTankRuntime')
HELPER = 'Contents/Helpers/tt'
MACH_MAGIC = {bytes.fromhex(value) for value in ('cffaedfe', 'cefaedfe', 'feedfacf', 'feedface', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}
LOADS = {'LC_LOAD_DYLIB', 'LC_LOAD_WEAK_DYLIB', 'LC_REEXPORT_DYLIB', 'LC_LOAD_UPWARD_DYLIB', 'LC_LAZY_LOAD_DYLIB'}


def output(*arguments):
    return subprocess.check_output(arguments, text=True, stderr=subprocess.STDOUT)


def system_path(path):
    return (not any(part in ('.', '..') for part in path.split('/'))
            and path.startswith(('/System/Library/Frameworks/', '/System/Library/PrivateFrameworks/', '/usr/lib/')))


def inspect(image):
    if output('lipo', '-archs', str(image)).strip() != 'arm64':
        raise ValueError(f'Expected one arm64 code image: {image}')
    text = output('otool', '-l', str(image))
    blocks = re.split(r'^Load command \d+\s*$', text, flags=re.M)[1:]
    if not blocks:
        raise ValueError(f'Malformed load-command inspection: {image}')
    identity, rpaths, loads, versions = [], [], [], []
    for block in blocks:
        match = re.search(r'^\s*cmd (LC_\w+)\s*$', block, re.M)
        if match is None:
            raise ValueError(f'Malformed load command: {image}')
        command = match[1]
        if command in LOADS or command == 'LC_ID_DYLIB':
            name = re.search(r'^\s*name (.+) \(offset \d+\)\s*$', block, re.M)
            if name is None:
                raise ValueError(f'Malformed dylib command: {image}')
            if command == 'LC_ID_DYLIB':
                identity.append(name[1])
            else:
                loads.append({'command': command, 'name': name[1]})
        elif command == 'LC_RPATH':
            path = re.search(r'^\s*path (.+) \(offset \d+\)\s*$', block, re.M)
            if path is None:
                raise ValueError(f'Malformed runpath command: {image}')
            rpaths.append(path[1])
        elif command == 'LC_BUILD_VERSION':
            platform = re.search(r'^\s*platform (\S+)\s*$', block, re.M)
            minimum = re.search(r'^\s*minos (\S+)\s*$', block, re.M)
            if platform is None or platform[1] not in ('1', 'MACOS', 'macos') or minimum is None:
                raise ValueError(f'Unsupported platform command: {image}')
            versions.append(minimum[1])
        elif command == 'LC_VERSION_MIN_MACOSX':
            minimum = re.search(r'^\s*version (\S+)\s*$', block, re.M)
            if minimum is None:
                raise ValueError(f'Malformed deployment command: {image}')
            versions.append(minimum[1])
        elif command == 'LC_DYLD_ENVIRONMENT':
            raise ValueError(f'Embedded dyld environment is unsupported: {image}')
    if len(identity) > 1 or len(versions) != 1:
        raise ValueError(f'Ambiguous identity/deployment commands: {image}')
    return {'identity': identity[0] if identity else None, 'rpaths': rpaths, 'loads': loads,
            'minimum_macos': versions[0], 'architecture': 'arm64',
            'uuid': output('dwarfdump', '--uuid', str(image)).split()[1],
            'sha256': hashlib.sha256(image.read_bytes()).hexdigest()}


def version_triple(text):
    parts = tuple(int(part) for part in text.split('.'))
    return parts + (0,) * (3 - len(parts))


def verify(app, deployment):
    """Check every code image and the property list against the locked minimum macOS."""
    app = Path(app).resolve()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    declared = info.get('LSMinimumSystemVersion')
    if not isinstance(declared, str) or re.fullmatch(r'\d+(\.\d+){0,2}', declared) is None \
            or version_triple(declared) != version_triple(deployment):
        raise ValueError(f'Contents/Info.plist LSMinimumSystemVersion is {declared!r}; '
                         f'the locked minimum macOS is {deployment}')
    executable = info['CFBundleExecutable']
    if executable != 'TextTank':
        raise ValueError('Unexpected application executable identity')
    main = f'Contents/MacOS/{executable}'
    expected = {f'Contents/Frameworks/{name}.framework/Versions/A/{name}': name for name in FRAMEWORKS}
    expected[main] = 'executable'
    expected[HELPER] = 'command-line-helper'
    debug = f'Contents/MacOS/{executable}.debug.dylib'
    preview = 'Contents/MacOS/__preview.dylib'
    if (app / debug).exists():
        expected[debug] = 'debug-application'
    if (app / preview).exists():
        if debug not in expected:
            raise ValueError('Preview support image has no Debug application image')
        expected[preview] = 'preview-auxiliary'
    inventory = set()
    for path in app.rglob('*'):
        if not path.is_file():
            continue
        resolved = path.resolve()
        if not resolved.is_relative_to(app):
            raise ValueError(f'Application file leaves its bundle: {path}')
        with path.open('rb') as stream:
            magic = stream.read(4)
        if magic in MACH_MAGIC:
            inventory.add(str(resolved.relative_to(app)))
    if inventory != set(expected):
        raise ValueError(f'Unclassified/missing code images: extra={sorted(inventory-set(expected))}, missing={sorted(set(expected)-inventory)}')
    images = {name: {**inspect(app / name), 'role': role} for name, role in sorted(expected.items())}
    for name, value in images.items():
        if version_triple(value['minimum_macos']) != version_triple(deployment):
            raise ValueError(f'{name} is built for minimum macOS {value["minimum_macos"]}; '
                             f'the locked minimum macOS is {deployment}')
        role = value['role']
        identity = (f'@rpath/{role}.framework/Versions/A/{role}' if role in FRAMEWORKS else
                    f'@rpath/{executable}.debug.dylib' if role in ('debug-application', 'preview-auxiliary') else None)
        if value['identity'] != identity:
            raise ValueError(f'{role} has an unsupported install name: {value["identity"]}')

    def location(token, loader, entry):
        if token == '@loader_path' or token.startswith('@loader_path/'):
            return str((app / loader).parent) + token[len('@loader_path'):]
        if token == '@executable_path' or token.startswith('@executable_path/'):
            return str((app / entry).parent) + token[len('@executable_path'):]
        if token.startswith('/'):
            return token
        raise ValueError(f'Unsupported relative/recursive runpath: {token}')

    forbidden = {'NativeSearch': {'Scintilla', 'EditorBridge', 'TextTankCore', 'TextTankRuntime'},
                 'TextTankCore': {'Scintilla', 'EditorBridge', 'TextTankRuntime'},
                 'EditorBridge': {'NativeSearch', 'TextTankCore', 'TextTankRuntime'},
                 'Scintilla': {'NativeSearch', 'EditorBridge', 'TextTankCore', 'TextTankRuntime'}}
    edges, visited, active = {}, set(), []

    def walk(name, inherited, entry):
        value = images[name]
        own_paths = [location(token, name, entry) for token in value['rpaths']]
        for path in own_paths:
            if not system_path(path.rstrip('/') + '/') and not Path(path).resolve().is_relative_to(app):
                raise ValueError(f'Runpath leaves selected bundle: {name}: {path}')
        runpaths = list(dict.fromkeys(own_paths + inherited))
        state = (name, tuple(runpaths))
        if name in active:
            raise ValueError(f'Native dependency cycle: {active + [name]}')
        if state in visited:
            return
        active.append(name)
        resolved_loads = []
        for load in value['loads']:
            token = load['name']
            if system_path(token):
                if value['role'] in ('NativeSearch', 'TextTankCore') and any(x in token for x in ('/AppKit.framework/', '/Cocoa.framework/', '/QuartzCore.framework/')):
                    raise ValueError(f'Foundation {value["role"]} depends on an editor/UI framework')
                resolved_loads.append({**load, 'system': token})
                continue
            if token.startswith('@rpath/'):
                candidates = [str(Path(path) / token[len('@rpath/'):]) for path in runpaths]
            else:
                candidates = [location(token, name, entry)]
            selected = next((Path(path).resolve() for path in candidates if Path(path).is_file()), None)
            if selected is None:
                # Shared-cache system Swift libraries need not exist as standalone files.
                platform = next((path for path in candidates if system_path(path)), None)
                if platform is not None and token.startswith('@rpath/libswift'):
                    resolved_loads.append({**load, 'system': platform})
                    continue
                raise ValueError(f'Unresolved dependency: {name}: {token}')
            if not selected.is_relative_to(app):
                if system_path(str(selected)):
                    resolved_loads.append({**load, 'system': str(selected)})
                    continue
                raise ValueError(f'Dependency leaves selected bundle: {name}: {token}')
            target = str(selected.relative_to(app))
            if target not in images:
                raise ValueError(f'Dependency resolves to unclassified code: {name}: {target}')
            role, target_role = value['role'], images[target]['role']
            if role == 'command-line-helper' or target_role == 'command-line-helper':
                raise ValueError('The standalone tt helper may only load system libraries')
            if target_role in forbidden.get(role, set()):
                if role == 'EditorBridge' and target_role == 'NativeSearch':
                    raise ValueError('EditorBridge depends on the snapshot search engine')
                raise ValueError(f'Forbidden native dependency: {role} -> {target_role}')
            if role in FRAMEWORKS and target_role not in FRAMEWORKS:
                raise ValueError('Framework depends on application/auxiliary code')
            if target_role == 'preview-auxiliary':
                raise ValueError('Runtime dependency resolves to inert preview auxiliary')
            resolved_loads.append({**load, 'image': target})
            walk(target, runpaths, entry)
        active.pop()
        if name in edges and edges[name] != resolved_loads:
            raise ValueError(f'Dependency resolution changes with loader chain: {name}')
        edges[name] = resolved_loads
        visited.add(state)

    walk(main, [], main)
    reachable = set(edges)
    required_runtime = set(images) - {preview, HELPER}
    if reachable != required_runtime:
        raise ValueError(f'Application runtime closure misses images: {sorted(required_runtime-reachable)}')
    walk(HELPER, [], HELPER)
    if preview in images:
        walk(preview, [location(path, main, main) for path in images[main]['rpaths']], main)
    return {'schema': 1, 'images': images, 'edges': edges,
            'runtime_images': sorted(reachable), 'command_line_images': [HELPER], 'auxiliary_images': [preview] if preview in images else []}
