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
import zipfile
from bootstrap import obtain_archive
import runtime_artifacts
import ci_evidence


# Review documentation is an explicit product-facing set. Session state, agent
# prompts, one-off research generators and dated worker notes are not deliveries.
REVIEW_DOCUMENTS = (
    'docs/REVIEW-ME.md', 'docs/BUILDING.md', 'docs/product-spec.md',
    'docs/architecture.md', 'docs/tab-model.md', 'docs/preview-model.md', 'docs/review-model.md', 'docs/compare-model.md', 'docs/merge-model.md', 'docs/DESIGN-STANDARDS.md', 'docs/design-budget.json',
    'docs/AUTOMATION-RULES.md', 'docs/EXTENSIONS-AND-RUN.md',
    'docs/parity/README.md', 'docs/parity/capabilities.json',
    'docs/parity/user-validation-2026-11-14.json',
    'docs/research/README.md', 'docs/research/findings.md', 'docs/research/finding-ids.md',
    'docs/research/sources.json',
    'docs/research/utility-audit.md', 'docs/research/workspace-browser.md',
)


def review_at_package_root(text):
    """Move relative review links from docs/ to the delivery root, not other docs."""
    import posixpath
    from urllib.parse import urlsplit

    def replace(match):
        destination = match.group(2)
        if destination.startswith('#') or urlsplit(destination).scheme:
            return match.group(0)
        path, separator, fragment = destination.partition('#')
        resolved = posixpath.normpath(posixpath.join('docs', path))
        if resolved.startswith('../') or resolved.startswith('/'):
            raise ValueError('Review link leaves package: ' + destination)
        return match.group(1) + resolved + (separator + fragment if separator else '') + ')'

    return re.sub(r'(\[[^\]]+\]\()([^)]+)\)', replace, text)


def copy_documentation(root, package):
    for name in REVIEW_DOCUMENTS:
        source = root / name
        if source.is_symlink() or not source.is_file():
            raise ValueError('Required review document missing or linked: ' + name)
        target = package / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
    review = review_at_package_root((root / 'docs/REVIEW-ME.md').read_text(encoding='utf-8'))
    (package / 'REVIEW-ME.md').write_text(review, encoding='utf-8')

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
        boundary = r"(?=$|[/\s,;:)\]}>'\"])"
        text = re.sub(r'(?<![\w])' + re.escape(original) + boundary, lambda _: replacement, text)
    if re.search(r"/(?:Users|home)/[^/\s\"'<>(),;:]+(?:/|$|[\s\"'<>(),;:])", text):
        raise ValueError('Acceptance log contains an uncurated home path; review it before packaging.')
    return text


def public_diagnostics(value, root):
    if isinstance(value, str):
        return public_acceptance_log(value, root)
    if isinstance(value, list):
        return [public_diagnostics(item, root) for item in value]
    if isinstance(value, dict):
        return {key: public_diagnostics(item, root) for key, item in value.items()}
    return value


def prune_previous(output):
    previous = sorted(path for path in output.iterdir()
                      if re.fullmatch(r'review-previous-\d{8}-\d{6}-\d{6}', path.name)
                      and path.is_dir() and not path.is_symlink())
    for path in previous[:-1]:
        shutil.rmtree(path)


def copy_verified_release(root, destination):
    if os.environ.get('CONFIGURATION') != 'Release':
        raise ValueError('Review packaging requires CONFIGURATION=Release.')
    app = root / 'build/DerivedData/Build/Products/Release/TextTank.app'
    if os.environ.get('APP_PATH') != str(app):
        raise ValueError('Use the canonical Release application selected by scripts/package-review.sh.')
    manifest = root / 'build/artifacts/Release/manifest.json'
    manifest_hash = hashlib.sha256(manifest.read_bytes()).hexdigest()
    producer = runtime_artifacts.validate(root, manifest, 'Release')
    if pathlib.Path(producer['app']) != app or runtime_artifacts.digest(manifest) != manifest_hash:
        raise ValueError('Release manifest or application changed during validation.')
    subprocess.run(['ditto', '--norsrc', '--noextattr', '--noqtn', str(app), str(destination)], check=True)
    if runtime_artifacts.snapshot(destination) != producer['app_files']:
        raise ValueError('Packaged application differs from its verified Release producer.')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(destination)], check=True)
    return manifest_hash


def main():
    root = pathlib.Path(__file__).resolve().parents[1]
    os.chdir(root)
    sha = sys.argv[1]
    if sha != subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip():
        raise ValueError('The package source commit must match the checked-out Release producer.')
    output = root / 'output'
    output.mkdir(exist_ok=True)
    stage = pathlib.Path(tempfile.mkdtemp(prefix='.texttank-review-stage-', dir=output))
    try:
        package = stage / 'TextTank-review'
        package.mkdir()
        sources = package / 'Source'
        sources.mkdir()
        release_manifest = copy_verified_release(root, package / 'TextTank.app')
        source_tar = sources / 'TextTank-source.tar.gz'
        archive = subprocess.Popen(['git', 'archive', '--format=tar', '--prefix=TextTank-source/', sha], stdout=subprocess.PIPE)
        with source_tar.open('wb') as target:
            subprocess.run(['gzip', '-n'], stdin=archive.stdout, stdout=target, check=True)
        archive.stdout.close()
        if archive.wait() != 0:
            raise SystemExit('git archive failed')
        source_tree = subprocess.check_output(['git', 'rev-parse', 'HEAD^{tree}'], text=True).strip()
        validation = verify_validation(root, source_tree)
        try:
            validation['ci'] = ci_evidence.authenticate(sha, source_tree, os.environ.get('TEXTTANK_CI_RUN_ID'),
                                                        os.environ.get('TEXTTANK_CI_RUN_ATTEMPT'))
        except (KeyError, TypeError, zipfile.BadZipFile, subprocess.TimeoutExpired) as error:
            raise ValueError('Hosted native evidence is unavailable or malformed.') from error
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
        copy_documentation(root, package)
        shutil.copyfile(root / 'scripts/launch-review.sh', package / 'Launch-TextTank.command')
        (package / 'Launch-TextTank.command').chmod(493)
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
            'build_configuration': 'Release',
            'configuration': 'Release',
            'release_manifest_sha256': release_manifest,
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
            'ci_status': validation['ci']['conclusion'],
            'ci_run': validation['ci']['url'],
            'limitations': 'Not full Notepad++ parity; see REVIEW-ME.md. No Intel/older-macOS runtime claim; live EventKit happy path is user-confirmed, remaining live failure/retry cases are unverified.',
        }
        validation['app_tree_sha256'] = manifest['app_tree_sha256']
        validation = public_diagnostics(validation, root)
        (package / 'validation.json').write_text(json.dumps(validation, indent=2) + '\n')
        (package / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        zip_path = stage / 'TextTank-review.zip'
        subprocess.run(['ditto', '-c', '-k', '--norsrc', '--noextattr', '--keepParent', str(package), str(zip_path)], check=True)
        zip_hash = hashlib.sha256(zip_path.read_bytes()).hexdigest()
        if capture('git', 'rev-parse', 'HEAD') != sha or capture('git', 'status', '--porcelain', '--untracked-files=normal'):
            raise SystemExit('Source changed during packaging; staged files were not delivered')
        # Complete the deliverable before replacing its directory. Staging is on the
        # output filesystem, so publication uses directory renames, never a cross-device move.
        zip_path.rename(package / 'TextTank-review.zip')
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
