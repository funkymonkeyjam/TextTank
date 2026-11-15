#!/usr/bin/env python3
"""Isolated fault checks for build inputs and exact-candidate evidence; no app launch."""
import hashlib
import importlib.util
import io
import json
import os
import shutil
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
            state = recording.source_state(archive)
            self.assertIsNone(state['source_tree'])
            logs = archive / 'harness/logs'
            recording.write_json(logs / 'test-source-state.json', state)
            (logs / 'full-acceptance.log').write_text('PASS synthetic source archive protocol\n')
            record = recording.record(archive, 0)
            self.assertFalse(record['source_stable'])
            self.assertIn('root', record['source_stable_reason'])
            with self.assertRaises(ValueError):
                package.verify_validation(archive, recording.source_state(outer)['source_tree'])

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
            for relative in ['scripts/env.sh', 'scripts/build_config.py', 'scripts/generate-project.py', 'scripts/user-lexer-flags.txt']:
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

    def test_standalone_lexer_build_recompiles_changed_headers(self):
        with tempfile.TemporaryDirectory() as work:
            fixture = Path(work)
            for relative in ['scripts/build-user-lexer.sh', 'scripts/env.sh', 'scripts/lib/test-common.sh',
                             'scripts/user-lexer-flags.txt', 'scripts/build_config.py', 'Dependencies.lock.json']:
                destination = fixture / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes((ROOT / relative).read_bytes())
            source = fixture / 'Sources/Languages/LexUserPort'
            source.mkdir(parents=True)
            (source / 'LexUser.cxx').write_text('#include "UserConstants.h"\nint fixtureValue = HEADER_VALUE;\n')
            header = source / 'UserConstants.h'
            header.write_text('#define HEADER_VALUE 1\n')
            command = ['bash', 'scripts/build-user-lexer.sh']
            environment = dict(os.environ)
            for key in ['TEXTTANK_NATIVE_OBJECT_DIR', 'TEXTTANK_SUITE_RESULTS', 'USER_LEXER_OBJECT', 'BRIDGE_OBJECT', 'SEARCH_OBJECT']:
                environment.pop(key, None)
            first = subprocess.run(command, cwd=fixture, env=environment, capture_output=True, text=True)
            self.assertEqual(first.returncode, 0, first.stderr)
            object_file = fixture / 'build/tests/UserLexer.o'
            previous = object_file.read_bytes()
            header.write_text('#define HEADER_VALUE 2\n')
            second = subprocess.run(command, cwd=fixture, env=environment, capture_output=True, text=True)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertNotEqual(previous, object_file.read_bytes())
            self.assertEqual(list((fixture / 'build/tests').glob('native-objects.*')), [])

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

    def test_resource_allowlist_keeps_runtime_inputs_and_excludes_design_sources(self):
        generator = module('generate_project', 'generate-project.py')
        resources = generator.resource_paths(ROOT)
        self.assertIn('Resources/LanguageProfiles.json', resources)
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
