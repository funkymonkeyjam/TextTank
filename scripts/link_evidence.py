#!/usr/bin/env python3
"""Immutable records of the canonical link commands and their selected inputs."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def regular(path):
    path = Path(path)
    if not path.is_file():
        raise ValueError(f'Link evidence is not a regular file: {path}')
    result = {'path': str(path), 'sha256': sha(path)}
    if path.resolve() != path:
        result['realpath'] = str(path.resolve())
    return result


def anchored(path, root):
    path = Path(path)
    if path.is_symlink() or not path.resolve().is_relative_to((root / 'build/artifacts').resolve()):
        raise ValueError('Link proof leaves selected build evidence root')
    return regular(path)


def retain(root, configuration, data, suffix):
    directory = root / 'build/artifacts' / configuration / 'producers'
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / (hashlib.sha256(data).hexdigest() + suffix)
    if path.exists():
        if path.read_bytes() != data:
            raise ValueError('Immutable link evidence collision')
    else:
        path.write_bytes(data)
    return regular(path)


def expand(arguments, cwd, responses, active=()):
    result = []
    for argument in arguments:
        if argument.startswith('@') and not any(argument == token or argument.startswith(token + '/') for token in ('@rpath', '@loader_path', '@executable_path')):
            path = Path(argument[1:])
            if not path.is_absolute():
                path = cwd / path
            path = Path(os.path.normpath(path))
            if str(path) in active:
                raise ValueError('Recursive linker response file')
            responses[str(path)] = regular(path)
            result.extend(expand(shlex.split(path.read_text()), cwd, responses, (*active, str(path))))
        else:
            result.append(argument)
    return result


def linker_arguments(arguments):
    # Preserve the driver argv separately; unwrap only documented forwarding syntax.
    result, index = [], 0
    while index < len(arguments):
        value = arguments[index]
        if value == '-Xlinker':
            index += 1
            if index == len(arguments):
                raise ValueError('Missing -Xlinker argument')
            result.append(arguments[index])
        elif value.startswith('-Wl,'):
            result.extend(value[4:].split(','))
        else:
            result.append(value)
        index += 1
    return result


def selected_inputs(arguments, cwd):
    files, lists = [], []
    def path(value):
        result = Path(value)
        return result if result.is_absolute() else cwd / result
    for index, value in enumerate(arguments):
        if value == '-filelist':
            if index+1 == len(arguments):
                raise ValueError('Missing linker file list')
            filelist = path(arguments[index+1])
            entries = filelist.read_text().splitlines()
            if not entries or any(not entry or '\x00' in entry for entry in entries):
                raise ValueError('Empty or malformed linker file list')
            # ld file lists use one path per line. Spaces are path bytes, not argv separators.
            selected = [regular(path(entry)) for entry in entries]
            lists.append({**regular(filelist), 'entries': selected})
            files.extend(selected)
        elif value == '-sectcreate':
            if index+3 >= len(arguments):
                raise ValueError('Malformed linker section input')
            files.append(regular(path(arguments[index+3])))
        elif value == '-add_ast_path':
            files.append(regular(path(arguments[index+1])))
        elif not value.startswith('-') and Path(value).suffix in ('.o', '.a', '.dylib', '.tbd'):
            # Only direct inputs: output and option payloads are excluded explicitly.
            if index and arguments[index-1] in ('-o', '-object_path_lto', '-install_name', '-dependency_info'):
                continue
            files.append(regular(path(value)))
    return files, lists


def dependency_info(path):
    # Apple's ld Options.h defines 00=version,10=found input,11=not found,40=output.
    # Each opcode is followed by one NUL-terminated UTF-8 string (Options.cpp writer).
    data, result, index = Path(path).read_bytes(), [], 0
    while index < len(data):
        opcode = data[index]
        if opcode not in (0, 0x10, 0x11, 0x40):
            raise ValueError('Unknown actual linker dependency opcode')
        end = data.find(b'\0', index+1)
        if end < 0:
            raise ValueError('Truncated actual linker dependency record')
        result.append((opcode, data[index+1:end].decode('utf-8')))
        index = end+1
    if not result or result[0][0] != 0 or sum(code == 0 for code, _ in result) != 1:
        raise ValueError('Missing/ambiguous actual linker version record')
    return result


def source_membership(root):
    project = json.loads(subprocess.check_output(
        ['plutil', '-convert', 'json', '-o', '-', str(root / 'TextTank.xcodeproj/project.pbxproj')], text=True))['objects']
    result = {}
    for target in project.values():
        if target.get('isa') != 'PBXNativeTarget':
            continue
        sources = []
        for phase in target['buildPhases']:
            phase = project[phase]
            if phase['isa'] == 'PBXSourcesBuildPhase':
                sources.extend(project[project[item]['fileRef']]['path'] for item in phase['files'])
        if len(set(sources)) != len(sources):
            raise ValueError('Duplicate source membership in actual project')
        result[target['name']] = sorted(sources)
    return result


def link_events(path):
    lines, result = path.read_text().splitlines(), {}
    for index, line in enumerate(lines):
        if not line.startswith('Ld '):
            continue
        header = shlex.split(line)
        if len(header) < 3 or header[2] != 'normal':
            raise ValueError('Unsupported actual linker architecture event')
        output = header[1]
        found = []
        cwd = None
        for following in lines[index+1:]:
            if following and not following.startswith(' '):
                break
            argv = shlex.split(following)
            if argv[:1] == ['cd']:
                if len(argv) != 2:
                    raise ValueError('Malformed actual link working directory')
                cwd = Path(argv[1])
            elif argv and Path(argv[0]).name in ('clang', 'clang++') and '-o' in argv:
                found.append(argv)
        if len(found) != 1 or cwd is None or output in result:
            raise ValueError('Missing/ambiguous actual link invocation')
        if found[0][found[0].index('-o')+1] != output:
            raise ValueError('Actual link invocation output differs from its Ld event')
        result[output] = {'header': line, 'cwd': str(cwd), 'arguments': found[0]}
    return result


def compile_events(path):
    result = {'__generated__': []}
    for line in path.read_text().splitlines():
        if line.startswith('CompileC '):
            words = shlex.split(line)
            if len(words) < 4 or words[1] in result:
                raise ValueError('Ambiguous native source/object producer')
            result[words[1]] = words[2]
        elif line.startswith('WriteAuxiliaryFile '):
            result['__generated__'].append(shlex.split(line)[1])
    return result


def source_objects(root, target, objects, membership, compiles, previous):
    if target in membership and membership[target] and all(Path(source).suffix == '.swift' for source in membership[target]):
        # The map is generated by the actual Swift producer, never reconstructed from stems.
        maps = {Path(item['path']).parent / f'{target}-OutputFileMap.json' for item in objects}
        if len(maps) != 1:
            raise ValueError('Swift link objects have ambiguous compiler output map')
        mapping = next(iter(maps))
        data = json.loads(mapping.read_text())
        whole_module = data.get('', {}).get('object')
        pairs = {str(Path(source).relative_to(root)): value.get('object', whole_module) for source, value in data.items() if source}
        selected_objects = set(pairs.values())
        if None in selected_objects or sorted(pairs) != membership[target] or selected_objects != {item['path'] for item in objects}:
            raise ValueError(f'Actual Swift source/object membership differs from target {target}')
        return {'map': regular(mapping), 'sources': {source: {**regular(root / source), 'object': value} for source, value in sorted(pairs.items())}}
    prior = previous.get('source_objects', {}).get('sources', {}) if previous else {}
    by_object = {value['object']: source for source, value in prior.items()}
    pairs = {}
    for item in objects:
        selected = compiles.get(item['path'], by_object.get(item['path']))
        if selected is None:
            raise ValueError(f'Native link object lacks actual CompileC producer: {item["path"]}')
        source = Path(selected)
        if not source.is_absolute():
            source = root / source
        if target == 'Scintilla':
            generated = Path(item['path']).parents[2] / 'DerivedSources/Scintilla_vers.c'
            if not source.resolve().is_relative_to((root / 'Vendor/scintilla').resolve()) and source != generated:
                raise ValueError('Scintilla object comes from outside pinned Scintilla/actual version source')
            if source == generated and str(source) not in compiles['__generated__'] and str(source) not in prior:
                raise ValueError('Scintilla version source has no actual generated-file producer')
            key = str(source.resolve())
        else:
            key = str(source.relative_to(root))
        if key in pairs:
            raise ValueError('Source compiled more than once in target')
        pairs[key] = {**regular(source), 'object': item['path']}
    if target != 'Scintilla' and sorted(pairs) != membership[target]:
        raise ValueError(f'Actual native source/object membership differs from target {target}')
    return {'map': None, 'sources': dict(sorted(pairs.items()))}


def link_snapshot(root, configuration, output, target, role, event, settings, membership, compiles, previous):
    cwd, responses = Path(event['cwd']), {}
    expanded = expand(event['arguments'], cwd, responses)
    arguments = linker_arguments(expanded)
    files, lists = selected_inputs(arguments, cwd)
    objects = [item for item in files if Path(item['path']).suffix == '.o']
    if len({item['path'] for item in objects}) != len(objects):
        raise ValueError('Duplicate actual link object')
    source_map = source_objects(root, target, objects, membership, compiles, previous) if objects else {'map': None, 'sources': {}}
    if not objects and role not in ('executable-stub', 'preview-auxiliary'):
        raise ValueError('Source-bearing link image has no object inputs')
    dependency = None
    resolved = []
    if '-dependency_info' in arguments:
        path = Path(arguments[arguments.index('-dependency_info')+1])
        entries = dependency_info(path)
        outputs = [value for code, value in entries if code == 0x40]
        if outputs == [str(output)]:
            dependency = {**regular(path), 'version': entries[0][1]}
            resolved = [regular(Path(value)) for code, value in entries if code == 0x10]
        elif role != 'preview-auxiliary':
            raise ValueError('Actual linker dependency file identifies another output')
        # Xcode's empty preview link shares the application's dependency path; it can
        # be overwritten by the application link. No library/framework resolution is
        # inferred for this source-free, argument-free auxiliary.
    needs_resolution = any(value in ('-framework', '-weak_framework') or value.startswith('-l') for value in arguments[1:])
    if needs_resolution and dependency is None:
        raise ValueError('Actual library/framework selections lack linker dependency evidence')
    if dependency:
        selected = {str(Path(item['path']).resolve()) for item in resolved}
        if any(str(Path(item['path']).resolve()) not in selected for item in objects):
            raise ValueError('Linker dependency evidence omits an actual object')
    tool = Path(event['arguments'][0]).resolve()
    sdk = Path(arguments[arguments.index('-isysroot')+1])
    allowed = [root.resolve(), (root / 'Vendor').resolve(), sdk.resolve(), tool.parents[1]]
    for item in files + resolved:
        support_archive = sdk.parents[1] / 'usr/lib/libPreviewsJITStubExecutor.a'
        allowed_support = role == 'executable-stub' and Path(item['path']) == support_archive
        if not allowed_support and not any(Path(item['path']).resolve().is_relative_to(base) for base in allowed):
            raise ValueError(f'Actual link input leaves selected build/pinned SDK/toolchain: {item["path"]}')
    return {'event': event, 'expanded_arguments': expanded, 'response_files': responses,
            'target': target, 'role': role, 'configuration': configuration,
            'target_settings': settings.get(target), 'compiler': regular(tool),
            'sdk': {'path': str(sdk), 'settings': regular(sdk / 'SDKSettings.json')},
            'files': files, 'filelists': lists, 'source_objects': source_map,
            'dependency_info': dependency, 'resolved_inputs': resolved,
            'output': {**regular(output), 'uuid': subprocess.check_output(['dwarfdump', '--uuid', str(output)], text=True).strip()}}


def swift_refresh_event(log, target, source):
    lines = log.read_text().splitlines()
    suffix = f"(in target '{target}' from project 'TextTank')"
    primary = [line for line in lines if line.startswith('SwiftCompile normal arm64 ')
               and line.endswith(suffix) and shlex.split(line)[3:4] == [str(source)]]
    if len(primary) != 1:
        raise ValueError('Changed source lacks one actual absolute SwiftCompile primary event')
    drivers = []
    for index, line in enumerate(lines):
        if not line.startswith(f'SwiftDriver {target} normal arm64 ') or not line.endswith(suffix):
            continue
        cwd = None
        for following in lines[index+1:]:
            if following and not following.startswith(' '):
                break
            words = shlex.split(following)
            if words[:1] == ['cd'] and len(words) == 2:
                cwd = words[1]
            elif words[:2] == ['builtin-SwiftDriver', '--']:
                drivers.append({'header': line, 'cwd': cwd, 'arguments': words[2:]})
    if len(drivers) != 1 or drivers[0]['cwd'] is None:
        raise ValueError('Changed source lacks one actual Swift driver invocation')
    return primary[0], drivers[0]


def make_refresh(root, configuration, target, source, object_input, settings, log):
    primary, driver = swift_refresh_event(log, target, source)
    responses = {}
    expanded = expand(driver['arguments'], Path(driver['cwd']), responses)
    def option(name):
        if name not in expanded or expanded.count(name) != 1:
            raise ValueError('Ambiguous actual Swift refresh option: ' + name)
        return expanded[expanded.index(name)+1]
    if str(source) not in expanded or option('-module-name') != target or option('-swift-version') != '5' or '-warnings-as-errors' not in expanded:
        raise ValueError('Actual Swift refresh is not the canonical target/compiler policy')
    levels = [argument.split('=',1)[1] for argument in expanded if argument.startswith('-strict-concurrency=')]
    if '-strict-concurrency' in expanded:
        levels.append(option('-strict-concurrency'))
    strict = bool(levels) or any(
        expanded[index] in ('-enable-experimental-feature', '-enable-upcoming-feature') and expanded[index+1] == 'StrictConcurrency'
        for index in range(len(expanded)-1))
    if not strict or any(level != 'complete' for level in levels) or '-suppress-warnings' in expanded or settings.get('SWIFT_STRICT_CONCURRENCY') != 'complete' or settings.get('SWIFT_TREAT_WARNINGS_AS_ERRORS') != 'YES' or option('-target') != 'arm64-apple-macos' + settings['MACOSX_DEPLOYMENT_TARGET'] or option('-sdk') != settings['SDKROOT']:
        raise ValueError('Actual Swift refresh concurrency/architecture/deployment/SDK differs')
    mapping = Path(option('-output-file-map'))
    outputs = json.loads(mapping.read_text())
    if outputs.get(str(source), {}).get('object') != object_input['path']:
        raise ValueError('Actual Swift refresh source-to-object map differs from linked object')
    value = {'target': target, 'source': regular(source), 'object': object_input,
             'primary_event': primary, 'driver': driver, 'expanded_arguments': expanded,
             'response_files': responses, 'output_map': regular(mapping),
             'compiler': regular(Path(driver['arguments'][0]).resolve()),
             'sdk_settings': regular(Path(settings['SDKROOT'])/'SDKSettings.json'),
             'target_settings': settings,
             'build_log': retain(root, configuration, log.read_bytes(), '.swift-refresh.log')}
    contents = (json.dumps(value, sort_keys=True, indent=2)+'\n').encode()
    value['proof'] = retain(root, configuration, contents, '.swift-refresh.json')
    return value


def validate_refresh(root, value, target, source, object_input, settings):
    proof = value['proof']
    if anchored(proof['path'], root) != proof or json.loads(Path(proof['path']).read_text()) != {key:item for key,item in value.items() if key != 'proof'}:
        raise ValueError('Immutable actual Swift refresh proof changed')
    if value['target'] != target or value['target_settings'] != settings or value['source'] != regular(source) or value['object'] != object_input or regular(object_input['path']) != object_input:
        raise ValueError('Actual Swift refresh source/object/settings identity differs')
    for item in [value['compiler'],value['sdk_settings'],value['output_map'],value['build_log'],*value['response_files'].values()]:
        if regular(item['path']) != item:
            raise ValueError('Actual Swift refresh compiler/SDK/map/response/log identity changed')
    if anchored(value['build_log']['path'], root) != value['build_log']:
        raise ValueError('Actual Swift refresh log leaves selected build evidence root')
    primary, driver = swift_refresh_event(Path(value['build_log']['path']), target, source)
    responses = {}
    if primary != value['primary_event'] or driver != value['driver'] or expand(driver['arguments'],Path(driver['cwd']),responses) != value['expanded_arguments'] or responses != value['response_files']:
        raise ValueError('Actual Swift refresh compiler event/arguments changed')
    outputs = json.loads(Path(value['output_map']['path']).read_text())
    if outputs.get(str(source),{}).get('object') != object_input['path']:
        raise ValueError('Actual Swift refresh map no longer identifies the byte-identical linked object')


def validate(root, producers, settings, lexer, expected=None, refreshes=None):
    if not isinstance(producers, dict) or not producers:
        raise ValueError('Actual application requires nonnull link producer evidence')
    if expected is not None and set(producers) != set(expected):
        raise ValueError('Missing/extra actual link producer outputs')
    refreshes = refreshes if isinstance(refreshes, dict) else {}
    required_refreshes = set()
    for path, value in producers.items():
        proof = value['proof']
        if anchored(proof['path'], root) != proof:
            raise ValueError('Immutable link proof changed')
        retained = json.loads(Path(proof['path']).read_text())
        if retained != {key: item for key, item in value.items() if key != 'proof'}:
            raise ValueError('Link producer differs from immutable retained proof')
        if value['target_settings'] != settings.get(value['target']):
            raise ValueError('Link target settings changed')
        checks = [value['compiler'], value['sdk']['settings'], value['build_log'], *value['files'], *value['resolved_inputs'], *value['response_files'].values()]
        if anchored(value['build_log']['path'], root) != value['build_log']:
            raise ValueError('Retained actual linker log changed')
        if value['dependency_info'] is not None:
            checks.append({key: item for key, item in value['dependency_info'].items() if key != 'version'})
        if value['source_objects']['map']:
            checks.append(value['source_objects']['map'])
        for source in value['source_objects']['sources'].values():
            historical = {key:item for key,item in source.items() if key != 'object'}
            if regular(source['path']) == historical:
                continue
            key = source['path']
            object_input = next((item for item in value['files'] if item['path'] == source['object']), None)
            if key not in refreshes or object_input is None:
                raise ValueError('Changed linked source requires actual compiler refresh evidence: ' + key)
            validate_refresh(root,refreshes[key],value['target'],Path(key),object_input,settings[value['target']])
            required_refreshes.add(key)
        checks.extend({key: item for key, item in filelist.items() if key != 'entries'} for filelist in value['filelists'])
        for item in checks:
            if regular(item['path']) != item:
                raise ValueError(f'Stale actual link input/output/evidence: {item["path"]}')
        responses = {}
        if expand(value['event']['arguments'], Path(value['event']['cwd']), responses) != value['expanded_arguments'] or responses != value['response_files']:
            raise ValueError('Actual link response expansion changed')
        if subprocess.check_output(['dwarfdump', '--uuid', str(path)], text=True).strip() != value['output']['uuid']:
            raise ValueError('Actual signed output UUID differs from its link producer')
        if str(Path(path)) != value['output']['path']:
            raise ValueError('Link producer output key changed')
    bridge = [value for value in producers.values() if value['target'] == 'EditorBridge']
    if lexer is not None:
        if len(bridge) != 1 or bridge[0]['files'].count(lexer['object']) != 1:
            raise ValueError('Actual LexUser compiler object must enter EditorBridge exactly once')
        library = regular(root / 'build/vendor' / next(iter(producers.values()))['configuration'] / 'liblexilla.a')
        if bridge[0]['files'].count(library) != 1 or library not in bridge[0]['resolved_inputs']:
            raise ValueError('Actual canonical Lexilla library must enter EditorBridge exactly once')
    if set(refreshes) != required_refreshes:
        raise ValueError('Missing/extra actual compiler refresh observations')
    return producers


def record(root, configuration, images, app, settings, lexer, previous=None, previous_outputs=None, previous_refreshes=None):
    previous = previous if isinstance(previous, dict) else {}
    membership = source_membership(root)
    logs = {name: root / 'harness/logs' / f'{name}-build.log' for name in ('app', 'scintilla')}
    events = {name: link_events(path) for name, path in logs.items()}
    compiles = {name: compile_events(path) for name, path in logs.items()}
    outputs = [(Path(value['produced']), name, 'framework', 'scintilla' if name == 'Scintilla' else 'app') for name, value in images.items()]
    debug = app / 'Contents/MacOS/TextTank.debug.dylib'
    for path in (app / 'Contents/MacOS').iterdir():
        if path.name == 'TextTank':
            role = 'executable-stub' if debug.exists() else 'application'
        elif path.name == 'TextTank.debug.dylib':
            role = 'application'
        elif path.name == '__preview.dylib' and debug.exists():
            role = 'preview-auxiliary'
        else:
            raise ValueError('Unclassified application link output')
        outputs.append((path, 'TextTank', role, 'app'))
    result, refreshes = {}, {}
    previous_refreshes = previous_refreshes if isinstance(previous_refreshes, dict) else {}
    for output, target, role, lane in outputs:
        key = str(output)
        if key not in events[lane]:
            if key not in previous:
                raise ValueError(f'Actual link output has no retained producer: {key}')
            if not isinstance(previous_outputs, dict) or previous_outputs.get(key) != regular(output):
                raise ValueError(f'Cached link output changed without a fresh producer: {key}')
            result[key] = previous[key]
            continue
        value = link_snapshot(root, configuration, output, target, role, events[lane][key], settings, membership, compiles[lane], previous.get(key))
        value['build_log'] = retain(root, configuration, logs[lane].read_bytes(), '.link.log')
        contents = (json.dumps(value, sort_keys=True, indent=2) + '\n').encode()
        value['proof'] = retain(root, configuration, contents, '.link.json')
        result[key] = value
    if len(result) != len(outputs):
        raise ValueError('Duplicate actual linker output')
    for value in result.values():
        for source in value['source_objects']['sources'].values():
            historical = {key:item for key,item in source.items() if key != 'object'}
            if regular(source['path']) == historical:
                continue
            if Path(source['path']).suffix != '.swift':
                raise ValueError('Changed native source lacks a fresh link producer')
            key = source['path']
            object_input = next(item for item in value['files'] if item['path'] == source['object'])
            old = previous_refreshes.get(key)
            if old is not None and old['source'] == regular(key) and old['object'] == object_input:
                refreshes[key] = old
            else:
                refreshes[key] = make_refresh(root,configuration,value['target'],Path(key),object_input,settings[value['target']],logs['app'])
    validate(root,result,settings,lexer,[str(output) for output,_,_,_ in outputs],refreshes)
    return result, refreshes
