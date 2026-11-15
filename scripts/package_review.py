#!/usr/bin/env python3
"""Package the exact tested candidate; keep incomplete-preview evidence explicit."""
import datetime
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import sys
import re
from bootstrap import obtain_archive

def verify_validation(root, source_tree):
    path = root / 'harness/logs/candidate-validation.json'
    if not path.is_file():
        raise ValueError('Run scripts/test.sh on this clean candidate before packaging; validation evidence missing.')
    validation = json.loads(path.read_text())
    if (validation.get('source_stable') is not True or validation.get('source_tree') != source_tree
            or validation.get('dirty') is not False
            or validation.get('local_acceptance', {}).get('exit_code') != 0):
        raise ValueError('Current clean candidate requires a successful exact-tree full acceptance record.')
    log = root / 'harness/logs/full-acceptance.log'
    if not log.is_file() or hashlib.sha256(log.read_bytes()).hexdigest() != validation.get('local_acceptance', {}).get('log_sha256'):
        raise ValueError('Acceptance log missing or changed after validation.')
    return validation


def public_acceptance_log(text, root):
    # Public delivery policy: preserve diagnostics, but remove known local filesystem prefixes.
    # Do not capture the ambient environment or attempt to classify arbitrary user data as secrets.
    replacements = [(str(root), '<repository>'), (str(root.resolve()), '<repository>'),
                    (str(pathlib.Path.home()), '<home>'), (tempfile.gettempdir(), '<temporary>')]
    for original, replacement in sorted(replacements, key=lambda pair: len(pair[0]), reverse=True):
        text = text.replace(original + '/', replacement + '/')
    if re.search(r'/(?:Users|home)/[^/\s]+/', text):
        raise ValueError('Acceptance log contains an uncurated home path; review it before packaging.')
    return text


def prune_previous(output):
    previous = sorted(path for path in output.iterdir()
                      if re.fullmatch(r'review-previous-\d{8}-\d{6}-\d{6}', path.name)
                      and path.is_dir() and not path.is_symlink())
    for path in previous[:-1]:
        shutil.rmtree(path)


def main():
    root = pathlib.Path(__file__).resolve().parents[1]
    sha = sys.argv[1]
    output = root / 'output'
    output.mkdir(exist_ok=True)
    stage = pathlib.Path(tempfile.mkdtemp(prefix='.texttank-review-stage-', dir=output))
    try:
        package = stage / 'TextTank-review'
        package.mkdir()
        sources = package / 'Source'
        sources.mkdir()
        app = pathlib.Path(os.environ.get('APP_PATH', str(root / 'build/DerivedData/Build/Products/Debug/TextTank.app')))
        if not app.is_dir():
            raise SystemExit('Built application is missing')
        subprocess.run(['ditto', '--norsrc', '--noextattr', '--noqtn', str(app), str(package / 'TextTank.app')], check=True)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(package / 'TextTank.app')], check=True)
        source_tar = sources / 'TextTank-source.tar.gz'
        archive = subprocess.Popen(['git', 'archive', '--format=tar', '--prefix=TextTank-source/', sha], stdout=subprocess.PIPE)
        with source_tar.open('wb') as target:
            subprocess.run(['gzip', '-n'], stdin=archive.stdout, stdout=target, check=True)
        archive.stdout.close()
        if archive.wait() != 0:
            raise SystemExit('git archive failed')
        source_tree = subprocess.check_output(['git', 'rev-parse', 'HEAD^{tree}'], text=True).strip()
        validation = verify_validation(root, source_tree)
        ci_path = root / 'harness/logs/candidate-ci.json'
        validation['ci'] = {'status': 'not_observed', 'source_tree': source_tree}
        if ci_path.exists():
            ci = json.loads(ci_path.read_text())
            if ci.get('source_tree') == source_tree:
                validation['ci'] = {'status': 'self_reported', 'source_tree': source_tree, 'reported_status': ci.get('status', 'unknown')}
        validation['packaged_source_commit'] = sha
        log = root / 'harness/logs/full-acceptance.log'
        if not log.is_file():
            raise SystemExit('Full acceptance log missing')
        if hashlib.sha256(log.read_bytes()).hexdigest() != validation.get('local_acceptance', {}).get('log_sha256'):
            raise SystemExit('Acceptance log changed after validation')
        evidence = package / 'Evidence'
        evidence.mkdir()
        public_log = public_acceptance_log(log.read_text(errors='replace'), root).encode()
        (evidence / 'full-acceptance.log').write_bytes(public_log)
        validation['local_acceptance']['original_log_sha256'] = validation['local_acceptance']['log_sha256']
        validation['local_acceptance']['log_sha256'] = hashlib.sha256(public_log).hexdigest()
        validation['local_acceptance']['path_normalization'] = 'Repository, home and temporary prefixes replaced in the public log; original SHA-256 retained.'
        validation['local_acceptance']['log'] = 'Evidence/full-acceptance.log'
        validation['local_acceptance']['observed_skips'] = [line for line in log.read_text(errors='replace').splitlines() if line.startswith('SKIP ')]
        lock = json.loads((root / 'Dependencies.lock.json').read_text())
        cache = root / 'build/downloads'
        cache.mkdir(parents=True, exist_ok=True)
        for dependency in lock['dependencies']:
            name = dependency['file']
            if pathlib.PurePath(name).name != name:
                raise SystemExit('Unsafe dependency filename')
            provided = os.environ.get('TEXTTANK_SOURCE_ARCHIVES')
            cached = obtain_archive(dependency, cache / name, pathlib.Path(provided) if provided else None)
            shutil.copyfile(cached, sources / name)
        for name in ['README.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md', 'Dependencies.lock.json']:
            shutil.copyfile(root / name, package / name)
        for raw in subprocess.check_output(['git', 'ls-files', '-z', '--', 'docs', 'harness/reviews']).split(b'\x00'):
            if not raw:
                continue
            relative = pathlib.Path(os.fsdecode(raw))
            target = package / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(root / relative, target)
        shutil.copyfile(root / 'scripts/launch-review.sh', package / 'Launch-TextTank.command')
        (package / 'Launch-TextTank.command').chmod(493)
        review = (root / 'docs/REVIEW-ME.md').read_text().replace('](parity/', '](docs/parity/').replace('](../harness/', '](harness/')
        (package / 'REVIEW-ME.md').write_text(review)
        licenses = package / 'Licenses'
        licenses.mkdir()
        for path in [root / 'Resources/scintilla-License.txt', root / 'Resources/lexilla-License.txt', root / 'Resources/boost-License.txt', root / 'Resources/Brand/Inter-OFL.txt', root / 'Resources/Brand/SpaceGrotesk-OFL.txt']:
            shutil.copyfile(path, licenses / path.name)
        def tree_hash(directory):
            digest = hashlib.sha256()
            for path in sorted(directory.rglob('*'), key=lambda p: p.relative_to(directory).as_posix()):
                relative = path.relative_to(directory).as_posix().encode()
                if path.is_symlink():
                    kind = b'L'
                    value = os.readlink(path).encode()
                elif path.is_file():
                    kind = b'F'
                    value = hashlib.sha256(path.read_bytes()).digest()
                else:
                    continue
                digest.update(kind + b'\x00' + relative + b'\x00' + value + b'\x00')
            return digest.hexdigest()
        def capture(*args):
            return subprocess.check_output(args, text=True).strip()
        manifest = {
            'schema_version': 1,
            'status': 'INCOMPLETE PREVIEW',
            'source_commit': sha,
            'source_tree': source_tree,
            'built_from_clean_commit': True,
            'created_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'app_tree_sha256': tree_hash(package / 'TextTank.app'),
            'app_tree_hash_algorithm': 'Sorted relative paths: SHA256 of type byte F/L, NUL, UTF8 path, NUL, raw SHA256 file bytes or UTF8 symlink target, NUL; directories/xattrs excluded.',
            'architecture': capture('lipo', '-archs', str(package / 'TextTank.app/Contents/MacOS/TextTank')),
            'host_macos': capture('sw_vers', '-productVersion'),
            'xcode': capture('xcodebuild', '-version'),
            'deployment_target': lock['deploymentTarget'],
            'signing': 'local ad-hoc; codesign deep/strict verification passed; not notarized',
            'dependencies': lock['dependencies'],
            'files': {str(p.relative_to(package)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(sources.iterdir())},
            'ci_status': 'Not inferred by packaging. Consult the exact source-commit CI result.',
            'limitations': 'Not full Notepad++ parity; see REVIEW-ME.md. No Intel/older-macOS runtime claim; live EventKit happy path is user-confirmed, remaining live failure/retry cases are unverified.',
        }
        validation['app_tree_sha256'] = manifest['app_tree_sha256']
        (package / 'validation.json').write_text(json.dumps(validation, indent=2) + '\n')
        (package / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        zipfile = stage / 'TextTank-review.zip'
        subprocess.run(['ditto', '-c', '-k', '--norsrc', '--noextattr', '--keepParent', str(package), str(zipfile)], check=True)
        zip_hash = hashlib.sha256(zipfile.read_bytes()).hexdigest()
        if capture('git', 'rev-parse', 'HEAD') != sha or capture('git', 'status', '--porcelain', '--untracked-files=normal'):
            raise SystemExit('Source changed during packaging; staged files were not delivered')
        # Complete the deliverable before replacing its directory. Staging is on the
        # output filesystem, so publication uses directory renames, never a cross-device move.
        zipfile.rename(package / 'TextTank-review.zip')
        manifest['zip_sha256'] = zip_hash
        (package / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        checks = [f'{zip_hash}  TextTank-review.zip'] + [f'{digest}  {name}' for name, digest in manifest['files'].items()]
        (package / 'SHA256SUMS').write_text('\n'.join(checks) + '\n')
        destination = output / 'review'
        previous = None
        if destination.exists() or destination.is_symlink():
            if destination.is_symlink():
                raise SystemExit('Refusing to replace a symlink at output/review')
            previous = output / ('review-previous-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
            destination.rename(previous)
        try:
            package.rename(destination)
        except OSError:
            if previous is not None and not destination.exists():
                previous.rename(destination)
            raise
        prune_previous(output)
        print('Packaged output/review/TextTank.app and output/review/TextTank-review.zip')
        print('Source commit: ' + sha)
        print('ZIP SHA256: ' + zip_hash)
        print('App tree SHA256: ' + manifest['app_tree_sha256'])
    finally:
        shutil.rmtree(stage, ignore_errors=True)


if __name__ == '__main__':
    try:
        if len(sys.argv) != 2:
            raise ValueError('Usage: package_review.py COMMIT_SHA (use scripts/package-review.sh)')
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(f'Packaging stopped: {error}')
