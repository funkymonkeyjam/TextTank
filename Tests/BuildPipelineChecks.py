#!/usr/bin/env python3
"""Isolated fault checks for build inputs and exact-candidate evidence; no app launch."""
import hashlib
import importlib.util
import io
import json
import os
import plistlib
import shutil
import shlex
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


class BuildPipelineChecks(unittest.TestCase):
    def swift_header_probe(self, header, body):
        with tempfile.TemporaryDirectory(prefix='bridge-types-', dir=ROOT / 'build/tests') as work:
            folder = Path(work)
            copied = folder / header.name
            shutil.copyfile(header, copied)
            probe = folder / 'probe.swift'
            probe.write_text(body)
            return subprocess.run(
                ['xcrun', '--sdk', 'macosx', 'swiftc', '-swift-version', '5', '-strict-concurrency=complete', '-warnings-as-errors',
                 '-sdk', json.loads(Path(os.environ['TEXTTANK_ARTIFACT_MANIFEST']).read_text())['toolchain']['sdk'],
                 '-target', 'arm64-apple-macos14.0', '-module-cache-path',
                 str(ROOT / 'build/ModuleCache'), '-typecheck',
                 '-import-objc-header', str(copied), str(probe)],
                text=True, capture_output=True)

    def test_command_boundary_rejects_an_untyped_swift_string(self):
        result = self.swift_header_probe(ROOT / 'Sources/EditorBridge/TTEditor.h', '''
import AppKit
@MainActor func rawCommand(_ editor: TTEditor) { _ = editor.executeCommand("typo") }
''')
        self.assertNotEqual(result.returncode, 0, 'An untyped String crossed the command boundary')
        self.assertIn('cannot convert value', result.stderr)
        self.assertIn('TTEditorCommandIdentifier', result.stderr)

    def test_search_boundary_rejects_an_untyped_swift_mode(self):
        result = self.swift_header_probe(ROOT / 'Sources/Search/TTSearchEngine.h', '''
import Foundation
func rawMode() throws {
    _ = try TTSearchEngine.searchText("x", range: NSRange(location: 0, length: 1),
        query: "x", replacement: "", mode: 0, matchCase: true, wholeWord: false,
        dotMatchesNewline: false, cancellation: TTSearchCancellation(),
        maximumMatches: 1, timeLimit: 1)
}
''')
        self.assertNotEqual(result.returncode, 0, 'An untyped Int crossed the search boundary')
        self.assertIn('cannot convert value', result.stderr)
        self.assertIn('TTSearchMode', result.stderr)

    def test_editor_header_compiles_without_the_search_tree(self):
        # The public editor interface uses AppKit, not the snapshot search engine.
        # Compile a copied header with no neighbouring Search directory; a hidden
        # transitive import is a real compiler failure rather than a text match.
        sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
        with tempfile.TemporaryDirectory(prefix='editor-header-', dir=ROOT / 'build/tests') as work:
            folder = Path(work)
            header = folder / 'EditorBridge/TTEditor.h'
            header.parent.mkdir()
            shutil.copyfile(ROOT / 'Sources/EditorBridge/TTEditor.h', header)
            probe = folder / 'probe.m'
            probe.write_text('#import "EditorBridge/TTEditor.h"\nTTEditor *editor;\n')
            result = subprocess.run(
                ['xcrun', 'clang', '-fsyntax-only', '-fobjc-arc', '-fmodules',
                 '-isysroot', sdk, '-mmacosx-version-min=14.0', str(probe)],
                text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_cpp_evidence_rejects_effective_later_response_overrides(self):
        import build_evidence
        with tempfile.TemporaryDirectory(prefix='cpp-options-', dir=ROOT / 'build/tests') as work:
            fixture = Path(work)
            source = fixture / 'probe.cxx'
            source.write_text('int fixture(void) { return 1; }\n')
            compiler = subprocess.check_output(['xcrun', '--find', 'clang++'], text=True).strip()
            arguments = [compiler, '-x', 'c++', '-std=c++17', '-Os']
            positive = subprocess.run([*arguments, '-c', str(source), '-o', str(fixture / 'positive.o')],
                                      capture_output=True, text=True)
            self.assertEqual(positive.returncode, 0, positive.stderr)
            build_evidence.check_effective_options(arguments, ['-std=c++17', '-Os'])
            response = fixture / 'later.rsp'
            response.write_text('-std=c++20 -O0\n')
            overridden = [*arguments, '@' + str(response), '-c', str(source), '-o', str(fixture / 'overridden.o')]
            negative = subprocess.run(overridden, capture_output=True, text=True)
            self.assertEqual(negative.returncode, 0, negative.stderr)
            expanded = build_evidence.expand(overridden, {})
            with self.assertRaisesRegex(ValueError, 'Effective'):
                build_evidence.check_effective_options(expanded, ['-std=c++17', '-Os'])

    def test_native_suite_rejects_dependency_inspection_failure(self):
        with tempfile.TemporaryDirectory(prefix='image-inspection-', dir=ROOT / 'build/tests') as work:
            fixture = Path(work)
            source = fixture / 'probe.c'
            source.write_text('#include <stdio.h>\nint main(void) { puts("PASS InspectionChecks: 1 assertions"); return 0; }\n')
            executable = fixture / 'probe'
            built = subprocess.run(['xcrun', 'clang', str(source), '-o', str(executable)], capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stderr)
            environment = dict(os.environ, TEXTTANK_SUITE_RESULTS='')
            runner = ['bash', '-c', 'source scripts/suite-lib.sh; suite_begin; suite_run dependency-inspection "$1" "$2"; suite_finish',
                      'fixture', str(fixture / 'run.log'), str(executable)]
            positive = subprocess.run(runner, cwd=ROOT, env=environment, capture_output=True, text=True)
            self.assertEqual(positive.returncode, 0, positive.stdout + positive.stderr)
            tools = fixture / 'bin'
            tools.mkdir()
            inspector = tools / 'otool'
            inspector.write_text('#!/bin/sh\necho "fixture dependency inspector failed" >&2\nexit 47\n')
            inspector.chmod(0o755)
            failed = subprocess.run(runner, cwd=ROOT, env={**environment, 'PATH': str(tools) + os.pathsep + environment['PATH']},
                                    capture_output=True, text=True)
            self.assertNotEqual(failed.returncode, 0, 'A real native binary passed with failed dependency inspection')
            self.assertIn('dependency inspection failed', failed.stdout)
            self.assertIn('fixture dependency inspector failed', failed.stdout)

    def test_runtime_linkage_rejects_real_absolute_framework_install_names(self):
        linkage = module('check_runtime_linkage', 'check-runtime-linkage.py')
        with tempfile.TemporaryDirectory(prefix='runtime-linkage-', dir=ROOT / 'build/tests') as work:
            fixture = Path(work)
            app = fixture / 'Fixture.app'
            executable = app / 'Contents/MacOS/TextTank'
            executable.parent.mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'TextTank'}))
            images = {}
            sources = {}
            def build(arguments):
                result = subprocess.run(['xcrun', '--sdk', 'macosx', 'clang', '-target', 'arm64-apple-macos14.0', *arguments], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
            for name in ['Scintilla', 'NativeSearch', 'EditorBridge', 'TextTankCore', 'TextTankRuntime']:
                images[name] = app / f'Contents/Frameworks/{name}.framework/Versions/A/{name}'
                images[name].parent.mkdir(parents=True)
                sources[name] = fixture / (name+'.c')
                sources[name].write_text(f'int fixture_{name}(void) {{ return 0; }}\n')
                build(['-dynamiclib', str(sources[name]), '-install_name', f'@rpath/{name}.framework/Versions/A/{name}', '-o', str(images[name])])
            main = fixture / 'main.c'
            main.write_text(''.join(f'extern int fixture_{name}(void);\n' for name in images)
                + 'int main(void) { return ' + ' + '.join(f'fixture_{name}()' for name in images) + '; }\n')
            def link(rpaths):
                build([str(main), *map(str, images.values()), '-Wl,-headerpad_max_install_names', *[argument for path in rpaths for argument in ['-Xlinker', '-rpath', '-Xlinker', path]], '-o', str(executable)])
            for identity, accepted in [('/Library/Frameworks/NativeSearch.framework/Versions/A/NativeSearch', False),
                                       ('@rpath/NativeSearch.framework/Versions/A/NativeSearch', True)]:
                build(['-dynamiclib', str(sources['NativeSearch']), '-install_name', identity, '-o', str(images['NativeSearch'])])
                link(['@executable_path/../Frameworks'])
                if accepted:
                    self.assertEqual(len(linkage.verify(app)['images']), 6)
                else:
                    with self.assertRaisesRegex(ValueError, 'install name'):
                        linkage.verify(app)
            link([])
            with self.assertRaisesRegex(ValueError, 'Unresolved'):
                linkage.verify(app)
            link(['/Library/Frameworks', '@executable_path/../Frameworks'])
            with self.assertRaisesRegex(ValueError, 'Runpath leaves'):
                linkage.verify(app)
            link(['@executable_path/../Frameworks'])
            for escaped in ['/usr/lib/../../Library/Frameworks/Other.framework/Other',
                            '/System/Library/Frameworks/../../../Library/Other.dylib']:
                target = images['TextTankRuntime']
                changed = subprocess.run(['install_name_tool', '-change', '/usr/lib/libSystem.B.dylib',
                                          escaped, str(target)], capture_output=True, text=True)
                self.assertEqual(changed.returncode, 0, changed.stderr)
                try:
                    with self.assertRaisesRegex(ValueError, 'Unresolved|leaves selected bundle'):
                        linkage.verify(app)
                finally:
                    restored = subprocess.run(['install_name_tool', '-change', escaped,
                        '/usr/lib/libSystem.B.dylib', str(target)], capture_output=True, text=True)
                    self.assertEqual(restored.returncode, 0, restored.stderr)
            extra = app / 'Contents/MacOS/unclassified.dylib'
            shutil.copyfile(images['NativeSearch'], extra)
            with self.assertRaisesRegex(ValueError, 'Unclassified'):
                linkage.verify(app)
            extra.unlink()
            sources['EditorBridge'].write_text('extern int fixture_NativeSearch(void); int fixture_EditorBridge(void) { return fixture_NativeSearch(); }\n')
            build(['-dynamiclib', str(sources['EditorBridge']), str(images['NativeSearch']), '-install_name',
                   '@rpath/EditorBridge.framework/Versions/A/EditorBridge', '-o', str(images['EditorBridge'])])
            with self.assertRaisesRegex(ValueError, 'snapshot search engine'):
                linkage.verify(app)

    def test_signing_cleans_metadata_at_each_boundary_and_keeps_failures_fatal(self):
        # Simulate metadata arriving between signing steps; this does not attribute
        # the real metadata recurrence to codesign, Finder or a file provider.
        fixture_parent = ROOT / 'tmp'
        fixture_parent.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='signing-boundary-', dir=fixture_parent) as work:
            fixture = Path(work).resolve()
            scripts = fixture / 'scripts'
            scripts.mkdir()
            shutil.copyfile(ROOT / 'scripts/build.sh', scripts / 'build.sh')
            shutil.copyfile(ROOT / 'scripts/compile_diagnostics.py', scripts / 'compile_diagnostics.py')
            (scripts / 'env.sh').write_text('''CONFIGURATION=Debug
ARCH=arm64
DEPLOYMENT_TARGET=14.0
VENDOR_BUILD="$PWD/build/vendor/Debug"
APP_PATH="$PWD/build/Fixture App.app"
export APP_PATH
''')
            for name in ['bootstrap.py', 'build-lexilla.py', 'check-runtime-linkage.py', 'runtime_artifacts.py']:
                (scripts / name).write_text('# isolated build fixture; no acquisition\n')
            app = fixture / 'build/Fixture App.app'
            framework = app / 'Contents/Frameworks/Scintilla.framework'
            framework.mkdir(parents=True)
            search_framework = app / 'Contents/Frameworks/NativeSearch.framework'
            search_framework.mkdir()
            editor_framework = app / 'Contents/Frameworks/EditorBridge.framework'
            editor_framework.mkdir()
            core_framework = app / 'Contents/Frameworks/TextTankCore.framework'
            core_framework.mkdir()
            runtime_framework = app / 'Contents/Frameworks/TextTankRuntime.framework'
            runtime_framework.mkdir()
            binary = fixture / 'bin'
            binary.mkdir()
            tool_source = '''#!/usr/bin/env python3
import json, os, pathlib, sys
tool = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
app = pathlib.Path(os.environ['APP_PATH'])
framework = app / 'Contents/Frameworks/Scintilla.framework'
flag = pathlib.Path(os.environ['TEXTTANK_FIXTURE_METADATA'])
scenario = os.environ['TEXTTANK_FIXTURE_SCENARIO']
with open(os.environ['TEXTTANK_FIXTURE_EVENTS'], 'a') as output:
    output.write(json.dumps([tool, args]) + '\\n')
if tool == 'xcodebuild':
    sys.exit(0)
if tool == 'xattr':
    if len(args) != 3 or args[0] != '-dr' or args[1] not in (
            'com.apple.FinderInfo', 'com.apple.ResourceFork') or args[2] != str(app):
        sys.exit(91)
    if scenario != 'persistent-metadata' and flag.exists():
        flag.unlink()
    sys.exit(0)
if tool != 'codesign':
    sys.exit(92)
if args == ['--force', '--sign', '-', str(app / 'Contents/Frameworks/TextTankRuntime.framework')]:
    sys.exit(78 if scenario == 'runtime-sign-error' else 0)
if args == ['--force', '--sign', '-', str(app / 'Contents/Frameworks/TextTankCore.framework')]:
    sys.exit(77 if scenario == 'core-sign-error' else 0)
if args == ['--force', '--sign', '-', str(app / 'Contents/Frameworks/EditorBridge.framework')]:
    sys.exit(76 if scenario == 'editor-sign-error' else 0)
if args == ['--force', '--sign', '-', str(app / 'Contents/Frameworks/NativeSearch.framework')]:
    sys.exit(75 if scenario == 'nested-sign-error' else 0)
if args == ['--force', '--sign', '-', str(framework)]:
    flag.write_text('metadata arrived between steps')
    sys.exit(0)
if args == ['--force', '--sign', '-', str(app)]:
    if scenario == 'ordinary-sign-error':
        print('fixture: unrelated signing failure', file=sys.stderr)
        sys.exit(73)
    if flag.exists():
        print('resource fork, Finder information, or similar detritus not allowed', file=sys.stderr)
        sys.exit(1)
    sys.exit(0)
if args == ['--verify', '--deep', '--strict', str(app)]:
    sys.exit(74 if scenario == 'strict-verify-error' else 0)
sys.exit(93)
'''
            for name in ['xcodebuild', 'xattr', 'codesign']:
                path = binary / name
                path.write_text(tool_source)
                path.chmod(0o755)
            events = fixture / 'events.jsonl'
            metadata = fixture / 'metadata-flag'
            expected = [
                ['--force', '--sign', '-', str(framework)],
                ['--force', '--sign', '-', str(search_framework)],
                ['--force', '--sign', '-', str(editor_framework)],
                ['--force', '--sign', '-', str(core_framework)],
                ['--force', '--sign', '-', str(runtime_framework)],
                ['--force', '--sign', '-', str(app)],
                ['--verify', '--deep', '--strict', str(app)],
            ]
            for scenario, code in [('arrival-between-steps', 0), ('persistent-metadata', 1),
                                   ('ordinary-sign-error', 73), ('strict-verify-error', 74), ('nested-sign-error', 75), ('editor-sign-error', 76), ('core-sign-error', 77), ('runtime-sign-error', 78)]:
                with self.subTest(scenario=scenario):
                    events.write_text('')
                    if metadata.exists():
                        metadata.unlink()
                    environment = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ['PATH'],
                                       TEXTTANK_FIXTURE_EVENTS=str(events),
                                       TEXTTANK_FIXTURE_METADATA=str(metadata),
                                       TEXTTANK_FIXTURE_SCENARIO=scenario)
                    result = subprocess.run(['bash', 'scripts/build.sh'], cwd=fixture,
                                            env=environment, capture_output=True, text=True)
                    self.assertEqual(result.returncode, code, result.stderr)
                    trace = [json.loads(line) for line in events.read_text().splitlines()]
                    signing = [args for tool, args in trace if tool == 'codesign']
                    self.assertEqual(signing, expected if code in (0, 74) else expected[:2 if code == 75 else 3 if code == 76 else 4 if code == 77 else 5 if code == 78 else 6])
                    for tool, args in trace:
                        if tool == 'xattr':
                            self.assertEqual(args[0], '-dr')
                            self.assertIn(args[1], ['com.apple.FinderInfo', 'com.apple.ResourceFork'])
                            self.assertEqual(args[2], str(app))
                    self.assertEqual('Built ' in result.stdout, code == 0)

    def test_shared_defaults_are_deferred_behind_isolation(self):
        owners = [str(path.relative_to(ROOT)) for path in (ROOT / 'Sources').rglob('*.swift')
                  if 'UserDefaults.standard' in path.read_text()]
        self.assertEqual(owners, ['Sources/Documents/PrivateFileStore.swift'])
        for relative in ['Sources/Search/SearchController.swift', 'Sources/Search/FolderSearchController.swift']:
            source = (ROOT / relative).read_text()
            self.assertIn('defaults: UserDefaults? = nil', source)
            self.assertIn('defaults ?? RuntimeEnvironment.legacyDefaults', source)
        self.assertIn('permitsLegacyDefaults ? provider() : nil',
                      (ROOT / owners[0]).read_text())
        frames = (ROOT / 'Sources/UI/WindowSupport.swift').read_text()
        self.assertIn('guard Bundle.main.bundleIdentifier != nil else { return nil }', frames)
        self.assertIn('return RuntimeEnvironment.legacyDefaults', frames)

    def test_support_override_has_one_source(self):
        owners = [str(path.relative_to(ROOT)) for path in (ROOT / 'Sources').rglob('*.swift')
                  if 'TEXTTANK_SUPPORT_DIRECTORY' in path.read_text()]
        self.assertEqual(owners, ['Sources/Documents/PrivateFileStore.swift'])

    def test_nested_source_archive_never_binds_to_an_unrelated_outer_git_tree(self):
        recording = module('record_validation', 'record-validation.py')
        package = module('package_review', 'package_review.py')
        with tempfile.TemporaryDirectory() as work:
            outer = Path(work)
            (outer / '.gitignore').write_text('archive/\n')
            for command in [['git', 'init', '-q'], ['git', 'add', '.gitignore'],
                            ['git', '-c', 'user.name=Build checks', '-c', 'user.email=checks@example.invalid',
                             'commit', '-qm', 'Unrelated outer fixture']]:
                subprocess.run(command, cwd=outer, check=True, capture_output=True)
            archive = outer / 'archive'
            archive.mkdir()
            (archive / 'source.swift').write_text('// source not tracked by outer repository\n')
            (outer / 'outer-only.txt').touch()
            with patch('sys.stdout', new_callable=io.StringIO) as output:
                state = recording.source_state(archive, report_dirty=True)
            self.assertEqual(output.getvalue(), '')
            self.assertIsNone(state['source_tree'])
            logs = archive / 'harness/logs'
            recording.write_json(logs / 'test-source-state.json', state)
            (logs / 'full-acceptance.log').write_text('PASS synthetic source archive protocol\n')
            record = recording.record(archive, 0)
            self.assertFalse(record['source_stable'])
            self.assertIn('root', record['source_stable_reason'])
            with self.assertRaises(ValueError):
                package.verify_validation(archive, recording.source_state(outer)['source_tree'])

    def test_acceptance_reports_dirty_paths_before_toolchain_guard(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            scripts = root / 'scripts'
            scripts.mkdir()
            for name in ('test.sh', 'test-suites.sh', 'record-validation.py', 'suite-lib.sh', 'env.sh'):
                shutil.copy2(ROOT / 'scripts' / name, scripts / name)
            (root / '.gitignore').write_text('harness/logs/\n')
            for name in ('staged', 'unstaged'):
                (root / name).touch()
            for command in (['git', 'init', '-q'], ['git', 'add', '.'],
                            ['git', '-c', 'user.name=Checks', '-c', 'user.email=checks@example.invalid',
                             'commit', '-qm', 'fixture']):
                subprocess.run(command, cwd=root, check=True, capture_output=True)

            def early_exit():
                result = subprocess.run([scripts / 'test.sh'], cwd=root, env={**os.environ, 'CONFIGURATION': 'invalid'},
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 2, result.stderr)
                logs = root / 'harness/logs'
                self.assertEqual(result.stdout, (logs / 'full-acceptance.log').read_text())
                record = json.loads((logs / 'candidate-validation.json').read_text())
                self.assertEqual(record['local_acceptance']['exit_code'], 2)
                return result.stdout, record

            clean, record = early_exit()
            self.assertNotIn('Dirty paths', clean)
            self.assertTrue(record['source_stable'])
            for name in ('staged', 'unstaged'):
                (root / name).write_text('private fixture contents\n')
            subprocess.run(['git', 'add', 'staged'], cwd=root, check=True)
            (root / 'nested').mkdir()
            (root / 'nested' / 'line\nSKIP false\t##[warning]path').touch()
            dirty, record = early_exit()
            self.assertEqual(dirty.splitlines(), [
                'Dirty paths at acceptance start:', 'M  staged', ' M unstaged',
                r'?? "nested/line\nSKIP false\t#\043[warning]path"', 'CONFIGURATION must be Debug or Release.'])
            self.assertFalse(record['source_stable'])
            self.assertTrue(record['source_start']['dirty'])
            self.assertEqual(record['local_acceptance']['observed_skips'], [])

    def test_canonical_build_identity_is_shared_and_rejects_unsupported_arch(self):
        config = module('build_config', 'build_config.py')
        identity = config.load_identity(ROOT)
        lock = json.loads((ROOT / 'Dependencies.lock.json').read_text())
        self.assertEqual(identity['architecture'], lock['architecture'])
        with tempfile.TemporaryDirectory() as work:
            fixture = Path(work)
            (fixture / 'Dependencies.lock.json').write_text(json.dumps({**lock, 'architecture': 'x86_64'}))
            with self.assertRaisesRegex(ValueError, 'arm64'):
                config.load_identity(fixture)
            (fixture / 'Dependencies.lock.json').write_text(json.dumps({**lock, 'deploymentTarget': '15.0'}))
            self.assertEqual(config.load_identity(fixture)['deploymentTarget'], '15.0')
            for relative in ['scripts/env.sh', 'scripts/build_config.py', 'scripts/generate-project.py', 'scripts/core_sources.py', 'scripts/user-lexer-flags.txt']:
                destination = fixture / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes((ROOT / relative).read_bytes())
            generator = module('generate_project', 'generate-project.py')
            for relative in generator.resource_paths(ROOT):
                destination = fixture / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / relative, destination)
            (fixture / 'TextTank.xcodeproj/xcshareddata/xcschemes').mkdir(parents=True)
            environment = dict(os.environ)
            environment.pop('ARCH', None)
            shell = subprocess.run(['bash', '-c', 'source scripts/env.sh; printf "%s %s" "$DEPLOYMENT_TARGET" "$ARCH"'],
                                   cwd=fixture, env=environment, capture_output=True, text=True)
            self.assertEqual(shell.returncode, 0, shell.stderr)
            self.assertEqual(shell.stdout, '15.0 arm64')
            generated = subprocess.run([sys.executable, 'scripts/generate-project.py'], cwd=fixture,
                                       env=environment, capture_output=True, text=True)
            self.assertEqual(generated.returncode, 0, generated.stderr)
            project = (fixture / 'TextTank.xcodeproj/project.pbxproj').read_text()
            self.assertIn('"MACOSX_DEPLOYMENT_TARGET" = "15.0"', project)
            self.assertIn('"ARCHS" = "arm64"', project)
            (fixture / 'Dependencies.lock.json').write_text(json.dumps({**lock, 'architecture': 'x86_64'}))
            for command in [['bash', '-c', 'source scripts/env.sh'], [sys.executable, 'scripts/generate-project.py']]:
                rejected = subprocess.run(command, cwd=fixture, env=environment, capture_output=True, text=True)
                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn('arm64', rejected.stderr)


    def test_public_path_boundaries_include_bare_prefixes_without_username_prefix_substitution(self):
        package = module('package_review', 'package_review.py')
        self.assertEqual(package.public_acceptance_log(str(ROOT), ROOT), '<repository>')
        self.assertEqual(package.public_acceptance_log(str(Path.home()), ROOT), '<home>')
        self.assertEqual(package.public_acceptance_log(tempfile.gettempdir(), ROOT), '<temporary>')
        for text in ['/Users/unrelated-person', 'Path: /Users/unrelated-person.',
                     str(Path.home()) + '-another-person/file.txt']:
            with self.assertRaises(ValueError):
                package.public_acceptance_log(text, ROOT)

    def test_public_derived_diagnostics_are_curated_without_mutating_raw_evidence(self):
        package = module('package_review', 'package_review.py')
        skip = f'SKIP fixture at {ROOT}/private-session/fixture.txt'
        original = {'local_acceptance': {'observed_skips': [skip]},
                    'limitations': ['Observed skip: ' + skip[5:]], 'source_tree': 'exact-tree-hash'}
        public = package.public_diagnostics(original, ROOT)
        self.assertNotIn(str(ROOT), json.dumps(public))
        self.assertIn('<repository>/private-session/fixture.txt', public['limitations'][0])
        self.assertEqual(public['source_tree'], 'exact-tree-hash')
        self.assertEqual(original['local_acceptance']['observed_skips'], [skip])

    def test_private_lexilla_preparation_never_reuses_prior_objects(self):
        lexilla = module('build_lexilla', 'build-lexilla.py')
        with tempfile.TemporaryDirectory() as work:
            fixture = Path(work)
            original = fixture / 'Vendor/lexilla/src/main.cxx'
            original.parent.mkdir(parents=True)
            original.write_bytes(b'pinned source')
            manifest = {'src/main.cxx': hashlib.sha256(original.read_bytes()).hexdigest()}
            output = fixture / 'build/vendor/Debug'
            copied = lexilla.prepare_sources(fixture, output, manifest)
            (copied / 'src/main.o').write_bytes(b'old flags object')
            (copied / 'bin').mkdir(exist_ok=True)
            (copied / 'bin/liblexilla.a').write_bytes(b'old library')
            lexilla.prepare_sources(fixture, output, manifest)
            self.assertFalse((copied / 'src/main.o').exists())
            self.assertFalse((copied / 'bin/liblexilla.a').exists())
            self.assertEqual(original.read_bytes(), b'pinned source')

    def test_every_native_check_keeps_an_explicit_script_source_reference(self):
        scripts = '\n'.join(path.read_text() for path in (ROOT / 'scripts').glob('*.sh'))
        native_checks = [path for path in (ROOT / 'Tests').glob('*Checks.*') if path.suffix in ('.swift', '.mm')]
        self.assertGreater(len(native_checks), 20)
        for path in native_checks:
            self.assertIn(path.name, scripts, str(path))
        for path in ['scripts/test-documents.sh', 'scripts/test-macros.sh', 'scripts/test-folder-search.sh', 'scripts/test.sh']:
            self.assertTrue((ROOT / path).is_file(), path)
        for log in ['macro-native-checks.log', 'document-checks.log', 'folder-search-controller-checks.log', 'full-acceptance.log']:
            self.assertIn(log, scripts)

    def test_atomic_extraction_failure_never_leaves_a_partial_vendor_tree(self):
        bootstrap = module('bootstrap', 'bootstrap.py')
        with tempfile.TemporaryDirectory() as work:
            archive = Path(work) / 'source.tgz'
            with tarfile.open(archive, 'w:gz') as output:
                entry = tarfile.TarInfo('lexilla/source.cxx')
                entry.size = 4
                output.addfile(entry, io.BytesIO(b'good'))
            vendor = Path(work) / 'Vendor'
            with self.assertRaises(ValueError):
                bootstrap.extract_archive(archive, vendor, 'lexilla', {'source.cxx': 'wrong digest'})
            self.assertEqual(list(vendor.iterdir()), [])
            bootstrap.extract_archive(archive, vendor, 'lexilla', {'source.cxx': hashlib.sha256(b'good').hexdigest()})
            self.assertEqual((vendor / 'lexilla/source.cxx').read_bytes(), b'good')

    def test_icon_rejects_invalid_input_without_crash_or_overwriting(self):
        tool = ROOT / 'build/tests/icon-tool-checks'
        if not tool.exists():
            self.fail('Compile icon-tool-checks through scripts/test-build-pipeline.sh first')
        usage = subprocess.run([str(tool)], capture_output=True, text=True)
        self.assertEqual(usage.returncode, 64)
        original = (ROOT / 'Resources/Brand/carbon-caret-app-square.svg').read_text()
        mutations = [original.replace('<rect width=', '<rect x="bad" width='),
                     original.replace('<path fill=', '<path opacity="0.5" fill=', 1),
                     original.replace('#C7F45B', '#+12345'), original[:-10],
                     original.replace('style="color:#15201F"', 'style="opacity:0.5"')]
        with tempfile.TemporaryDirectory() as work:
            source = Path(work) / 'icon.svg'
            destination = Path(work) / 'existing.icns'
            destination.write_bytes(b'keep previous icon')
            for text in mutations:
                source.write_text(text)
                result = subprocess.run([str(tool), str(source), str(Path(work) / 'iconset'), str(destination)],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertNotIn('Fatal error', result.stderr)
                self.assertEqual(destination.read_bytes(), b'keep previous icon')
            source.write_text(original.replace('M16 24H60', 'M16\t24\nH60'))
            result = subprocess.run([str(tool), str(source), str(Path(work) / 'iconset'), str(destination)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(list((Path(work) / 'iconset').glob('*.png'))), 10)

    def test_archive_rejects_escape_links_and_devices(self):
        bootstrap = module('bootstrap', 'bootstrap.py')
        for name, kind in [('../escape', tarfile.REGTYPE), ('wrong/source', tarfile.REGTYPE),
                           ('lexilla/link', tarfile.SYMTYPE), ('lexilla/hard', tarfile.LNKTYPE),
                           ('lexilla/fifo', tarfile.FIFOTYPE), ('/absolute', tarfile.REGTYPE)]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as work:
                archive = Path(work) / 'archive.tgz'
                with tarfile.open(archive, 'w:gz') as output:
                    info = tarfile.TarInfo(name)
                    info.type = kind
                    info.linkname = '/outside'
                    output.addfile(info)
                with self.assertRaises(ValueError):
                    bootstrap.extract_archive(archive, Path(work) / 'Vendor', 'lexilla', {})
                self.assertFalse((Path(work) / 'Vendor' / 'lexilla').exists())

    def test_vendor_rejects_extra_source_but_accepts_known_build_outputs(self):
        bootstrap = module('bootstrap', 'bootstrap.py')
        with tempfile.TemporaryDirectory() as work:
            folder = Path(work) / 'lexilla'
            (folder / 'src').mkdir(parents=True)
            (folder / 'src/main.cxx').write_bytes(b'source')
            manifest = {'src/main.cxx': hashlib.sha256(b'source').hexdigest()}
            bootstrap.verify_tree(folder, manifest)
            (folder / 'src/main.o').write_bytes(b'object')
            bootstrap.verify_tree(folder, manifest)
            (folder / 'src/Injected.cxx').write_bytes(b'injection')
            with self.assertRaisesRegex(ValueError, 'Unexpected'):
                bootstrap.verify_tree(folder, manifest)
            (folder / 'src/Injected.cxx').unlink()
            (folder / 'src/main.cxx').write_bytes(b'modified')
            with self.assertRaisesRegex(ValueError, 'mismatch'):
                bootstrap.verify_tree(folder, manifest)

    def test_download_never_publishes_partial_or_wrong_bytes(self):
        bootstrap = module('bootstrap', 'bootstrap.py')
        with tempfile.TemporaryDirectory() as work:
            cache = Path(work) / 'cache.tgz'
            dep = {'url': 'https://invalid.example/source', 'bytes': 4,
                   'sha256': hashlib.sha256(b'good').hexdigest()}
            with patch.object(bootstrap.urllib.request, 'urlopen', return_value=io.BytesIO(b'bad')):
                with self.assertRaises(ValueError):
                    bootstrap.obtain_archive(dep, cache)
            self.assertFalse(cache.exists())
            self.assertEqual(list(cache.parent.iterdir()), [])
            with patch.object(bootstrap.urllib.request, 'urlopen', side_effect=OSError('interrupted fixture')):
                with self.assertRaises(OSError):
                    bootstrap.obtain_archive(dep, cache)
            self.assertFalse(cache.exists())
            self.assertEqual(list(cache.parent.iterdir()), [])
            with patch.object(bootstrap.urllib.request, 'urlopen', return_value=io.BytesIO(b'good')):
                bootstrap.obtain_archive(dep, cache)
            self.assertEqual(cache.read_bytes(), b'good')

    def test_native_artifact_reuse_rejects_changed_inputs_metadata_dependencies_and_code(self):
        artifacts = module('runtime_artifacts', 'runtime_artifacts.py')
        with tempfile.TemporaryDirectory(prefix='artifact-reuse-', dir=ROOT / 'build/tests') as work:
            fixture = Path(work).resolve()
            subprocess.run(['xattr', '-w', 'com.apple.fileprovider.ignore#P', '1', str(fixture)], check=True)
            self.assertEqual(subprocess.check_output(['xattr', '-p', 'com.apple.fileprovider.ignore#P', str(fixture)]).strip(), b'1')
            subprocess.run(['git', 'init', '-q', str(fixture)], check=True, capture_output=True)
            inputs = {'Dependencies.lock.json': json.dumps({'architecture': 'arm64', 'deploymentTarget': '14.0'})}
            for name, folder, header in [('NativeSearch', 'Search', 'TTSearchEngine.h'),
                                          ('EditorBridge', 'EditorBridge', 'TTEditor.h')]:
                inputs[f'Sources/{folder}/{header}'] = f'// fixture public {name} header\n'
                inputs[f'Sources/{folder}/module.modulemap'] = f'framework module {name} {{ umbrella header "{header}" export * }}\n'
            for folder in ['scintilla', 'lexilla']:
                vendor = fixture / 'Vendor' / folder / 'fixture.h'
                vendor.parent.mkdir(parents=True)
                vendor.write_text('// pinned fixture dependency\n')
                inputs[f'scripts/{folder}-source-hashes.json'] = json.dumps({'fixture.h': hashlib.sha256(vendor.read_bytes()).hexdigest()})
            for name, text in inputs.items():
                path = fixture / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text)
            subprocess.run(['git', 'add', '--', *inputs], cwd=fixture, check=True, capture_output=True)
            products = fixture / 'build/DerivedData/Build/Products/Debug'
            app = products / 'TextTank.app'
            (app / 'Contents/MacOS').mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'TextTank',
                'CFBundleIdentifier': 'fixture.texttank.artifacts', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1'}))
            embedded = app / 'Contents/Frameworks'
            embedded.mkdir()
            before_path = fixture / 'build/artifacts/Debug/before.json'
            # Tiny real C producers exercise the same input/link/sign/closure/cache
            # protocol. Only Xcode settings are patched: this fixture has no Xcode
            # project build. Every compile and link below actually runs and succeeds.
            settings_patch = patch.object(artifacts.build_evidence, 'resolved_settings', return_value={})
            settings_patch.start()
            self.addCleanup(settings_patch.stop)
            compiler = subprocess.check_output(['xcrun', '--find', 'clang'], text=True).strip()
            sdk = json.loads(Path(os.environ['TEXTTANK_ARTIFACT_MANIFEST']).read_text())['toolchain']['sdk']
            project, sources = {}, {}
            for name in [*artifacts.FRAMEWORKS, 'TextTank']:
                source = fixture / ('Vendor/scintilla/fixture.c' if name == 'Scintilla' else f'Sources/{name}.c')
                if name == 'TextTank':
                    source.write_text(''.join(f'extern int fixture_{other}(void);\n' for other in artifacts.FRAMEWORKS)
                        + 'int main(void) { return ' + ' + '.join(f'fixture_{other}()' for other in artifacts.FRAMEWORKS) + '; }\n')
                else:
                    source.write_text(f'int fixture_{name}(void) {{ return 0; }}\n')
                sources[name] = source
                project[name] = {'isa': 'PBXNativeTarget', 'name': name, 'buildPhases': [name+'phase']}
                project[name+'phase'] = {'isa': 'PBXSourcesBuildPhase', 'files': [name+'build']}
                project[name+'build'] = {'fileRef': name+'file'}
                project[name+'file'] = {'path': str(source.relative_to(fixture))}
            dependency_manifest = fixture / 'scripts/scintilla-source-hashes.json'
            recorded = json.loads(dependency_manifest.read_text())
            recorded['fixture.c'] = hashlib.sha256(sources['Scintilla'].read_bytes()).hexdigest()
            dependency_manifest.write_text(json.dumps(recorded))
            project_path = fixture / 'TextTank.xcodeproj/project.pbxproj'
            project_path.parent.mkdir()
            project_path.write_text(json.dumps({'objects': project}))
            subprocess.run(['git', 'add', '--', 'Sources', 'scripts', 'TextTank.xcodeproj'], cwd=fixture, check=True, capture_output=True)
            artifacts.begin(fixture, 'Debug', before_path)
            logs = {'app': [], 'scintilla': []}
            def execute(arguments):
                result = subprocess.run(arguments, cwd=fixture, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
            def object_for(name):
                directory = fixture / 'build/objects' / name / 'Objects-normal/arm64'
                directory.mkdir(parents=True)
                obj = directory / (name+'.o')
                arguments = [compiler, '-target', 'arm64-apple-macos14.0', '-isysroot', sdk,
                             '-c', str(sources[name]), '-o', str(obj)]
                execute(arguments)
                lane = 'scintilla' if name == 'Scintilla' else 'app'
                logs[lane].extend([f'CompileC {shlex.quote(str(obj))} {shlex.quote(str(sources[name]))} normal arm64 c',
                                   '    cd '+shlex.quote(str(fixture)), '    '+shlex.join(arguments), ''])
                return obj
            def link(name, image, extra):
                obj = object_for(name)
                filelist = obj.parent / (name+'.LinkFileList')
                filelist.write_text(str(obj)+'\n')
                response = obj.parent / 'link.rsp'
                response.write_text(shlex.join(['-target', 'arm64-apple-macos14.0', '-isysroot', sdk])+'\n')
                arguments = [compiler, '@'+str(response),
                    '-filelist', str(filelist), '-Xlinker', '-dependency_info', '-Xlinker', str(obj.parent/'dependencies.dat'),
                    *extra, '-o', str(image)]
                execute(arguments)
                lane = 'scintilla' if name == 'Scintilla' else 'app'
                logs[lane].extend([f'Ld {shlex.quote(str(image))} normal', '    cd '+shlex.quote(str(fixture)),
                                   '    '+shlex.join(arguments), ''])
            built_images = []
            for name in artifacts.FRAMEWORKS:
                base = (fixture / 'build/vendor/Debug') if name == 'Scintilla' else products
                framework = base / f'{name}.framework'
                version = framework / 'Versions/A'
                (version / 'Resources').mkdir(parents=True)
                (version / 'Headers').mkdir()
                (version / 'Modules').mkdir()
                (version / 'Resources/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': name,
                    'CFBundleIdentifier': f'fixture.texttank.{name}', 'CFBundlePackageType': 'FMWK', 'CFBundleVersion': '1'}))
                (framework / 'Versions/Current').symlink_to('A')
                for entry in [name, 'Resources', 'Headers', 'Modules']:
                    (framework / entry).symlink_to(f'Versions/Current/{entry}')
                if name != 'Scintilla':
                    folder, header = ('Search', 'TTSearchEngine.h') if name == 'NativeSearch' else ('EditorBridge', 'TTEditor.h')
                    shutil.copyfile(fixture / f'Sources/{folder}/{header}', version / 'Headers' / header)
                    shutil.copyfile(fixture / f'Sources/{folder}/module.modulemap', version / 'Modules/module.modulemap')
                image = version / name
                link(name, image, ['-dynamiclib', '-install_name', f'@rpath/{name}.framework/Versions/A/{name}'])
                built_images.append(image)
                shutil.copytree(framework, embedded / framework.name, symlinks=True)
            link('TextTank', app / 'Contents/MacOS/TextTank', [*map(str, built_images), '-Xlinker', '-rpath', '-Xlinker', '@executable_path/../Frameworks'])
            for lane, lines in logs.items():
                path = fixture / 'harness/logs' / (lane+'-build.log')
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('\n'.join(lines))
            artifacts.capture_links(fixture, app, 'Debug', fixture / 'build/artifacts/Debug/link-before-sign.json', before_path)
            for copied in embedded.glob('*.framework'):
                for attribute in ['com.apple.FinderInfo', 'com.apple.ResourceFork']:
                    subprocess.run(['xattr', '-dr', attribute, str(app)], capture_output=True)
                signed = subprocess.run(['codesign', '--force', '--sign', '-', str(copied)], capture_output=True, text=True)
                self.assertEqual(signed.returncode, 0, signed.stderr)
            for attribute in ['com.apple.FinderInfo', 'com.apple.ResourceFork']:
                subprocess.run(['xattr', '-dr', attribute, str(app)], capture_output=True)
            signed = subprocess.run(['codesign', '--force', '--sign', '-', str(app)], capture_output=True, text=True)
            self.assertEqual(signed.returncode, 0, signed.stderr)
            manifest = fixture / 'build/artifacts/Debug/manifest.json'
            artifacts.record(fixture, app, 'Debug', manifest, before_path.relative_to(fixture))
            self.assertEqual(artifacts.validate(fixture, manifest, 'Debug')['app'], str(app))
            original_manifest = manifest.read_bytes()
            recorded = json.loads(original_manifest)
            for producers, message in [(None, 'nonnull'), ({}, 'nonnull'),
                ({key: value for key, value in list(recorded['link_producers'].items())[1:]}, 'Missing/extra')]:
                manifest.write_text(json.dumps({**recorded, 'link_producers': producers}))
                with self.assertRaisesRegex(ValueError, message):
                    artifacts.validate(fixture, manifest, 'Debug')
            manifest.write_bytes(original_manifest)
            with patch.object(artifacts.build_evidence, 'resolved_settings', return_value={'changed': {}}):
                with self.assertRaisesRegex(ValueError, 'live selected-build target settings'):
                    artifacts.validate(fixture, manifest, 'Debug')
            bridge = next(value for value in recorded['link_producers'].values() if value['target'] == 'EditorBridge')
            faults = [bridge['filelists'][0]['path'], bridge['files'][0]['path'],
                      next(iter(bridge['response_files'])), bridge['dependency_info']['path']]
            for filename in faults:
                selected = Path(filename)
                previous_bytes = selected.read_bytes()
                selected.write_bytes(previous_bytes+b'changed actual link input')
                try:
                    with self.assertRaisesRegex(ValueError, 'Stale actual link'):
                        artifacts.link_evidence.validate(fixture, recorded['link_producers'], {}, None)
                finally:
                    selected.write_bytes(previous_bytes)
            inspector = fixture / 'bin/otool'
            inspector.parent.mkdir()
            inspector.write_text('#!/bin/sh\necho actual-inspector-fault >&2\nexit 47\n')
            inspector.chmod(0o755)
            with patch.dict(os.environ, {'PATH': str(inspector.parent)+os.pathsep+os.environ['PATH']}):
                with self.assertRaises(subprocess.CalledProcessError) as failed:
                    artifacts.validate(fixture, manifest, 'Debug')
                self.assertEqual(failed.exception.returncode, 47)
            with self.assertRaisesRegex(ValueError, 'configuration'):
                artifacts.validate(fixture, manifest, 'Release')
            header = fixture / 'Sources/EditorBridge/TTEditor.h'
            previous = header.read_bytes()
            header.write_bytes(previous + b'// changed header\n')
            with self.assertRaisesRegex(ValueError, 'Stale artifact'):
                artifacts.validate(fixture, manifest, 'Debug')
            header.write_bytes(previous)
            extra = fixture / 'Sources/Unexpected.swift'
            extra.write_text('// untracked build input\n')
            with self.assertRaisesRegex(ValueError, 'untracked'):
                artifacts.validate(fixture, manifest, 'Debug')
            extra.unlink()
            metadata_header = products / 'EditorBridge.framework/Versions/A/Headers/TTEditor.h'
            metadata_header.write_bytes(previous + b'// changed compiler metadata\n')
            with self.assertRaisesRegex(ValueError, 'metadata'):
                artifacts.validate(fixture, manifest, 'Debug')
            metadata_header.write_bytes(previous)
            dependency = fixture / 'Vendor/lexilla/fixture.h'
            previous_dependency = dependency.read_bytes()
            dependency.write_bytes(b'changed pinned dependency\n')
            with self.assertRaisesRegex(ValueError, 'Pinned source mismatch'):
                artifacts.validate(fixture, manifest, 'Debug')
            dependency.write_bytes(previous_dependency)
            image = app / 'Contents/Frameworks/EditorBridge.framework/Versions/A/EditorBridge'
            previous_code = image.read_bytes()
            image.write_bytes(previous_code + b'tampered')
            with self.assertRaisesRegex(ValueError, 'application artifact'):
                artifacts.validate(fixture, manifest, 'Debug')
            image.write_bytes(previous_code)
            self.assertEqual(artifacts.validate(fixture, manifest, 'Debug')['app'], str(app))

    def test_target_environment_rejects_unsupported_configuration_and_architecture(self):
        for setting in ['CONFIGURATION=Typo', 'ARCH=x86_64']:
            result = subprocess.run(['bash', '-c', f'{setting}; source scripts/env.sh'],
                                    cwd=ROOT, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('Traceback', result.stderr)
        result = subprocess.run(['bash', '-c', 'CONFIGURATION=Release; source scripts/env.sh; printf "%s\\n" "$APP_PATH" "$DEPLOYMENT_TARGET"'],
                                cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('/Release/TextTank.app', result.stdout)
        self.assertIn('14.0', result.stdout)

    def test_validation_arguments_fail_cleanly_before_writing(self):
        for args in [[], ['record'], ['record', '--exit-code', 'bad'], ['record', '--exit-code', '-1']]:
            result = subprocess.run([sys.executable, str(ROOT / 'scripts/record-validation.py'), *args],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertNotIn('Traceback', result.stderr)

    def test_package_rejects_dirty_mismatched_and_tampered_evidence(self):
        package = module('package_review', 'package_review.py')
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            log = root / 'harness/logs/full-acceptance.log'
            log.parent.mkdir(parents=True)
            log.write_bytes(b'PASS exact candidate\n')
            record = {'source_stable': True, 'source_tree': 'tree', 'dirty': False,
                      'local_acceptance': {'exit_code': 0, 'log_sha256': hashlib.sha256(log.read_bytes()).hexdigest()}}
            path = log.parent / 'candidate-validation.json'
            path.write_text(json.dumps(record))
            package.verify_validation(root, 'tree')
            for field, value in [('dirty', True), ('source_tree', 'other'), ('source_stable', False)]:
                changed = dict(record)
                changed[field] = value
                path.write_text(json.dumps(changed))
                with self.assertRaises(ValueError):
                    package.verify_validation(root, 'tree')
            path.write_text(json.dumps(record))
            log.write_bytes(b'tampered\n')
            with self.assertRaises(ValueError):
                package.verify_validation(root, 'tree')

    def test_public_log_preserves_diagnostics_without_local_prefixes(self):
        package = module('package_review', 'package_review.py')
        original = f'{ROOT}/Sources/Example.swift:12: note: diagnostic\n'
        normalized = package.public_acceptance_log(original, ROOT)
        self.assertEqual(normalized, '<repository>/Sources/Example.swift:12: note: diagnostic\n')
        self.assertNotIn(str(ROOT), normalized)
        with self.assertRaises(ValueError):
            package.public_acceptance_log('/Users/unrelated-person/private/file: error', ROOT)

    def test_previous_delivery_retention_is_scoped_and_preserves_latest(self):
        package = module('package_review', 'package_review.py')
        with tempfile.TemporaryDirectory() as work:
            output = Path(work)
            for name in ['review-previous-20260101-000000-000001', 'review-previous-20260102-000000-000001', 'unrelated']:
                (output / name).mkdir()
            (output / 'review-previous-not-generated').mkdir()
            package.prune_previous(output)
            self.assertFalse((output / 'review-previous-20260101-000000-000001').exists())
            self.assertTrue((output / 'review-previous-20260102-000000-000001').is_dir())
            self.assertTrue((output / 'unrelated').is_dir())
            self.assertTrue((output / 'review-previous-not-generated').is_dir())

    def test_bounded_english_catalog_matches_explicit_source_fallbacks(self):
        import re
        expected = {}
        for path in (ROOT / 'Sources').rglob('*.swift'):
            prefix = r'(?<![A-Za-z])text' if path.name == 'Strings.swift' else r'Strings\.text'
            pattern = prefix + r'\(\s*"([^"\n]+)"\s*,\s*("(?:[^"\\]|\\.)*")\s*\)'
            for key, literal in re.findall(pattern, path.read_text()):
                value = json.loads(literal)
                if key in expected:
                    self.assertEqual(expected[key], value)
                expected[key] = value
        catalog = json.loads((ROOT / 'Resources/Localizable.xcstrings').read_text())
        actual = {key: value['localizations']['en']['stringUnit']['value']
                  for key, value in catalog['strings'].items()}
        self.assertGreater(len(actual), 50)
        self.assertEqual(actual, expected)
        self.assertEqual(catalog['sourceLanguage'], 'en')
        import plistlib
        self.assertEqual(plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())['CFBundleDevelopmentRegion'], 'en')

    def test_resource_allowlist_keeps_runtime_inputs_and_excludes_design_sources(self):
        generator = module('generate_project', 'generate-project.py')
        resources = generator.resource_paths(ROOT)
        self.assertIn('Resources/LanguageProfiles.json', resources)
        self.assertIn('Resources/Localizable.xcstrings', resources)
        self.assertIn('Resources/TextTank.icns', resources)
        self.assertIn('Resources/Brand/Inter-OFL.txt', resources)
        self.assertNotIn('Resources/Brand/ICON.md', resources)
        self.assertFalse(any(p.endswith('.svg') or '/.' in p for p in resources))
        self.assertEqual((ROOT / 'LICENSE').read_bytes(), (ROOT / 'Resources/TextTank-License.txt').read_bytes())
        self.assertEqual((ROOT / 'Sources/Search/Boost/LICENSE_1_0.txt').read_bytes(), (ROOT / 'Resources/boost-License.txt').read_bytes())


if __name__ == '__main__':
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(BuildPipelineChecks)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if result.wasSuccessful():
        print(f'PASS BuildPipelineChecks: {result.testsRun} fault scenarios; isolated fixtures, no app launch')
    sys.exit(not result.wasSuccessful())
