#!/usr/bin/env python3
"""Actual resolved settings and immutable, object-scoped compiler evidence."""
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def resolved_settings(root, configuration):
    from build_config import load_identity
    identity = load_identity(root)
    shared = ['-showBuildSettings', '-json', '-configuration', configuration, 'CODE_SIGNING_ALLOWED=NO']
    # Xcode rejects -scheme together with -alltargets. Query every product target
    # with the canonical DerivedData products/intermediates paths explicitly.
    queries = [(['-project', 'TextTank.xcodeproj', '-alltargets',
                 'SYMROOT=' + str(root / 'build/DerivedData/Build/Products'),
                 'OBJROOT=' + str(root / 'build/DerivedData/Build/Intermediates.noindex')],
                {'TextTank', 'NativeSearch', 'EditorBridge', 'TextTankCore', 'TextTankRuntime', 'tt'}),
               (['-project', 'Vendor/scintilla/cocoa/Scintilla/Scintilla.xcodeproj', '-scheme', 'Scintilla',
                 '-derivedDataPath', str(root / 'build/ScintillaDerived' / configuration),
                 'ARCHS=' + identity['architecture'], 'ONLY_ACTIVE_ARCH=YES',
                 'MACOSX_DEPLOYMENT_TARGET=' + identity['deploymentTarget'],
                 'CONFIGURATION_BUILD_DIR=' + str(root / 'build/vendor' / configuration),
                 'CLANG_MODULE_CACHE_PATH=' + str(root / 'build/ModuleCache')], {'Scintilla'})]
    selected = {}
    for arguments, expected in queries:
        result = subprocess.run(['xcodebuild', *shared, *arguments], cwd=root, capture_output=True, text=True)
        if result.returncode:
            raise ValueError('Resolved target settings failed: ' + result.stdout + result.stderr)
        values = json.loads(result.stdout)
        settings = {entry['target']: entry['buildSettings'] for entry in values}
        if set(settings) != expected:
            raise ValueError('Resolved settings have missing/extra canonical targets')
        selected.update(settings)
    return selected


def cpp_settings(settings):
    exact = {'ARCHS', 'VALID_ARCHS', 'ONLY_ACTIVE_ARCH', 'CURRENT_ARCH', 'CONFIGURATION',
             'HEADER_SEARCH_PATHS', 'USER_HEADER_SEARCH_PATHS', 'SYSTEM_HEADER_SEARCH_PATHS',
             'FRAMEWORK_SEARCH_PATHS', 'SYSTEM_FRAMEWORK_SEARCH_PATHS', 'SDKROOT',
             'MACOSX_DEPLOYMENT_TARGET', 'DEFINES_MODULE', 'MODULEMAP_FILE', 'PRODUCT_MODULE_NAME',
             'PRODUCT_NAME', 'SRCROOT', 'PROJECT_DIR', 'TOOLCHAIN_DIR', 'DT_TOOLCHAIN_DIR',
             'OTHER_CFLAGS', 'OTHER_CPLUSPLUSFLAGS', 'WARNING_CFLAGS', 'ENABLE_NS_ASSERTIONS'}
    return {key: value for key, value in settings.items()
            if key in exact or key.startswith(('CLANG_', 'GCC_'))}


def expand(arguments, responses):
    result = []
    for argument in arguments:
        if argument.startswith('@'):
            path = Path(argument[1:])
            if str(path) in responses:
                raise ValueError('Repeated or recursive compiler response file')
            text = path.read_text()
            responses[str(path)] = {'sha256': sha(path), 'contents': text}
            result.extend(expand(shlex.split(text), responses))
        else:
            result.append(argument)
    return result


def check_effective_options(arguments, flags):
    language = standard = optimization = None
    for index, value in enumerate(arguments):
        if value == '-x' and index + 1 < len(arguments):
            language = arguments[index + 1]
        elif value.startswith('-x') and len(value) > 2:
            language = value[2:]
        elif value.startswith('-std='):
            standard = value
        elif value == '-O' or re.fullmatch(r'-O(?:[0-9]+|s|g|z|fast)', value):
            optimization = value
    if language != 'c++' or standard != '-std=c++17' or optimization != '-Os':
        raise ValueError('Effective user-lexer language/standard/optimization is not canonical')
    if flags != ['-std=c++17', '-Os']:
        raise ValueError('Unsupported canonical user-lexer flag contract')


def dependency_files(path, root, sdk):
    text = path.read_text().replace('\\\n', '')
    separator = re.search(r':\s', text)
    if separator is None:
        raise ValueError('Malformed actual compiler dependency file')
    paths = shlex.split(text[separator.end():])
    result = {}
    for name in paths:
        dependency = Path(name)
        if not dependency.is_absolute():
            dependency = root / dependency
        dependency = Path(os.path.normpath(str(dependency)))
        if dependency.is_symlink():
            raise ValueError('User-lexer dependency is an unexpected leaf symlink')
        if dependency.is_relative_to(root):
            relative = dependency.relative_to(root)
            allowed = (root / 'Vendor').resolve() if relative.parts[0] == 'Vendor' else root.resolve()
            if not dependency.resolve().is_relative_to(allowed):
                raise ValueError('User-lexer dependency leaves its selected source/dependency root')
            key = str(relative)
        elif dependency.resolve().is_relative_to(sdk.resolve()):
            key = '@sdk/' + str(dependency.resolve().relative_to(sdk.resolve()))
        else:
            raise ValueError('User-lexer dependency leaves its selected build root and SDK')
        result[key] = sha(dependency)
    if not result:
        raise ValueError('Actual user-lexer dependency file is empty')
    return result


def compiler_identity(arguments, settings):
    compiler = Path(arguments[0]).resolve()
    sdk = Path(settings['SDKROOT'])
    return {'compiler': str(compiler), 'compiler_sha256': sha(compiler),
            'compiler_version': subprocess.check_output([str(compiler), '--version'], text=True),
            'sdk': str(sdk), 'sdk_settings_sha256': sha(sdk / 'SDKSettings.json')}


def validate_cpp(root, producer, settings):
    proof = Path(producer['proof']['path'])
    if not proof.resolve().is_relative_to((root / 'build/artifacts').resolve()) or sha(proof) != producer['proof']['sha256']:
        raise ValueError('Immutable user-lexer compiler proof changed')
    retained = json.loads(proof.read_text())
    if retained != {key: value for key, value in producer.items() if key != 'proof'}:
        raise ValueError('User-lexer compiler record differs from its retained proof')
    if cpp_settings(settings) != producer['cpp_settings']:
        raise ValueError('User-lexer C++ target settings changed without a fresh producer')
    if compiler_identity(producer['arguments'], settings) != producer['compiler_identity']:
        raise ValueError('User-lexer compiler/SDK identity changed')
    if sha(root / 'scripts/user-lexer-flags.txt') != producer['flags_sha256']:
        raise ValueError('Canonical user-lexer flags changed')
    if sha(Path(producer['object']['path'])) != producer['object']['sha256']:
        raise ValueError('Actual user-lexer object changed')
    dependency = Path(producer['dependency_file']['path'])
    if sha(dependency) != producer['dependency_file']['sha256'] or dependency_files(dependency, root, Path(settings['SDKROOT'])) != producer['dependencies']:
        raise ValueError('Actual user-lexer source/transitive-header dependency identity changed')
    responses = {}
    expanded = expand(producer['arguments'], responses)
    if responses != producer['response_files'] or expanded != producer['expanded_arguments']:
        raise ValueError('Actual user-lexer compiler response identity changed')
    if sha(Path(producer['build_log']['path'])) != producer['build_log']['sha256']:
        raise ValueError('Retained actual compiler log changed')
    check_effective_options(expanded, producer['canonical_flags'])
    return producer


def cpp_producer(root, configuration, settings, previous=None):
    source = root / 'Sources/Languages/LexUserPort/LexUser.cxx'
    if not source.exists():
        return None
    log = root / 'harness/logs/app-build.log'
    lines = log.read_text().splitlines()
    headers = [line for line in lines if line.startswith('CompileC ') and str(source) in shlex.split(line)]
    if not headers:
        if previous is None:
            raise ValueError('Cached user-lexer object has no verifiable retained compiler evidence; use a fresh canonical output')
        return validate_cpp(root, previous, settings['EditorBridge'])
    if len(headers) != 1 or "(in target 'EditorBridge' from project 'TextTank')" not in headers[0]:
        raise ValueError('Expected one actual EditorBridge user-lexer producer')
    matches = []
    for line in lines:
        if not line.startswith('    '):
            continue
        try:
            arguments = shlex.split(line)
        except ValueError:
            continue
        if arguments and Path(arguments[0]).name in ('clang', 'clang++') and str(source) in arguments:
            matches.append(arguments)
    if len(matches) != 1:
        raise ValueError('Actual user-lexer compiler invocation is absent or ambiguous')
    arguments = matches[0]
    responses = {}
    expanded = expand(arguments, responses)
    flags = (root / 'scripts/user-lexer-flags.txt').read_text().split()
    check_effective_options(expanded, flags)
    output = Path(arguments[arguments.index('-o') + 1])
    if output.suffix != '.o' or 'EditorBridge.build' not in output.parts:
        raise ValueError('Actual user-lexer object does not belong to EditorBridge')
    dependency = Path(arguments[arguments.index('-MF') + 1])
    directory = root / 'build/artifacts' / configuration / 'producers'
    directory.mkdir(parents=True, exist_ok=True)
    log_copy = directory / ('compiler-' + sha(log) + '.log')
    if not log_copy.exists():
        log_copy.write_bytes(log.read_bytes())
    producer = {'source': str(source.relative_to(root)), 'target': 'EditorBridge',
                'arguments': arguments, 'expanded_arguments': expanded, 'canonical_flags': flags,
                'flags_sha256': sha(root / 'scripts/user-lexer-flags.txt'),
                'response_files': responses, 'cpp_settings': cpp_settings(settings['EditorBridge']),
                'compiler_identity': compiler_identity(arguments, settings['EditorBridge']),
                'dependency_file': {'path': str(dependency), 'sha256': sha(dependency)},
                'dependencies': dependency_files(dependency, root, Path(settings['EditorBridge']['SDKROOT'])),
                'object': {'path': str(output), 'sha256': sha(output)},
                'build_log': {'path': str(log_copy), 'sha256': sha(log_copy)}}
    contents = json.dumps(producer, sort_keys=True, indent=2) + '\n'
    proof = directory / (hashlib.sha256(contents.encode()).hexdigest() + '.json')
    if not proof.exists():
        proof.write_text(contents)
    producer['proof'] = {'path': str(proof), 'sha256': sha(proof)}
    return validate_cpp(root, producer, settings['EditorBridge'])
