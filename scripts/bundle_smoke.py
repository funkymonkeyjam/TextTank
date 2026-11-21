#!/usr/bin/env python3
"""Inspect the built bundle and open a disposable UTF-8 file through its real entry point."""
import json
import os
import pathlib
import plistlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]


def verify_resources(app):
    source = ROOT / 'Resources'
    resources = app / 'Contents/Resources'
    info = app / 'Contents/Info.plist'
    subprocess.run(['plutil', '-lint', str(info)], check=True, stdout=subprocess.DEVNULL)
    with info.open('rb') as handle:
        product = plistlib.load(handle)
    with (source / 'Info.plist').open('rb') as handle:
        declared = plistlib.load(handle)
    expected = {'CFBundleIdentifier': 'app.texttank.editor', 'CFBundleExecutable': 'TextTank',
                'LSMinimumSystemVersion': os.environ['DEPLOYMENT_TARGET']}
    for key in ['CFBundleVersion', 'CFBundleShortVersionString', 'CFBundleDocumentTypes']:
        expected[key] = declared[key]
    for key, value in expected.items():
        if product.get(key) != value:
            raise ValueError(f'Incorrect bundle {key}: {product.get(key)!r}')
    # Brand SVGs/ICON.md are design sources. The two font licenses ship with the app.
    for path in sorted(source.rglob('*')):
        if not path.is_file() or path.name.startswith('.') or path == source / 'Info.plist':
            continue
        if path.parent == source / 'Brand' and (path.suffix == '.svg' or path.name == 'ICON.md'):
            continue
        if path.suffix == '.xcstrings':
            catalog = json.loads(path.read_bytes())
            locales = {catalog['sourceLanguage']}
            for entry in catalog['strings'].values():
                locales.update(entry.get('localizations', {}))
            for locale in locales:
                compiled = resources / (locale + '.lproj') / (path.stem + '.strings')
                subprocess.run(['plutil', '-lint', str(compiled)], check=True, stdout=subprocess.DEVNULL)
                if not compiled.is_file():
                    raise ValueError(f'Missing compiled catalog {compiled.name} for {locale}')
        elif (resources / path.name).read_bytes() != path.read_bytes():
            raise ValueError(f'Incorrect bundled resource {path.name}')
    return app / 'Contents/MacOS' / product['CFBundleExecutable']


def launch(executable):
    with tempfile.TemporaryDirectory(prefix='texttank-bundle-') as temporary:
        root = pathlib.Path(temporary).resolve()
        file = root / 'owned smoke document.txt'
        expected = 'Bundled editor\n雪\n'.encode()
        file.write_bytes(expected)
        env = dict(os.environ, TMPDIR=str(root), CFFIXED_USER_HOME=str(root),
                   TEXTTANK_SUPPORT_DIRECTORY=str(root / 'support'))
        result = subprocess.run([executable, '--smoke-test', file], env=env, capture_output=True, timeout=20)
        if result.returncode:
            raise ValueError(f'Bundle launch failed ({result.returncode}): {result.stderr.decode(errors="replace")}')
        lines = result.stdout.splitlines()
        if len(lines) != 1:
            raise ValueError('Expected one JSON status line from the application')
        status = json.loads(lines[0])
        if (pathlib.Path(status['file']).resolve() != file or status['editorBytes'] != len(expected)
                or status['windowCreated'] is not True or file.read_bytes() != expected):
            raise ValueError(f'Bundled application did not present the owned document: {status!r}')


def main():
    app = pathlib.Path(sys.argv[1]).resolve()
    executable = verify_resources(app)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', app], check=True)
    bridge = app / 'Contents/Frameworks/EditorBridge.framework/Versions/A/EditorBridge'
    linkage = subprocess.check_output(['otool', '-L', bridge], text=True)
    if '@rpath/Scintilla.framework/' not in linkage:
        raise ValueError('EditorBridge lacks its bundled Scintilla dependency')
    launch(executable)
    print('PASS BundleSmoke: signed bundled resources and file-backed editor window')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        sys.exit(f'Bundle smoke failed: {error}')
