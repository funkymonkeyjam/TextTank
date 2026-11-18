#!/usr/bin/env python3
"""Give the exact compiled check client native document-type metadata in an owned bundle."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import stat
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]


def prepare(executable, application):
    executable = Path(executable).absolute()
    application = Path(application).absolute()
    test_root = ROOT / 'build/tests'
    if not executable.is_relative_to(test_root) or not stat.S_ISREG(executable.stat().st_mode):
        raise ValueError('The compiled client must be a regular file inside build/tests.')
    source_info = application / 'Contents/Info.plist'
    info_bytes = source_info.read_bytes()
    info = plistlib.loads(info_bytes)
    types = info.get('CFBundleDocumentTypes')
    if not types or not all(item.get('NSDocumentClass') == 'TextDocument' for item in types):
        raise ValueError('The selected product must declare the real TextDocument types.')
    folder = Path(tempfile.mkdtemp(prefix='tab-workspace-app-', dir=test_root))
    bundle = folder / 'WorkspaceChecks.app'
    target = bundle / 'Contents/MacOS/document-checks'
    target.parent.mkdir(parents=True)
    shutil.copy2(executable, target)
    digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    if digest(target) != digest(executable):
        raise ValueError('The copied check executable differs from the compiled client.')
    info.update(CFBundleExecutable='document-checks', CFBundleIdentifier='app.texttank.NativeChecks.' + uuid.uuid4().hex,
                CFBundleName='TextTank Native Checks', CFBundleDisplayName='TextTank Native Checks',
                CFBundlePackageType='APPL', NSPrincipalClass='NSApplication', LSUIElement=False, LSBackgroundOnly=False)
    info.pop('CFBundleIconFile', None)
    for item in info['CFBundleDocumentTypes']:
        item['LSHandlerRank'] = 'None'  # This fixture must never become a Finder default handler.
    (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    record = {'compiled_client': str(executable), 'bundle_client': str(target),
              'client_sha256': digest(executable), 'copied_client_sha256': digest(target),
              'product_info': str(source_info), 'product_info_sha256': hashlib.sha256(info_bytes).hexdigest(),
              'fixture_info_sha256': digest(bundle / 'Contents/Info.plist'),
              'document_types': info['CFBundleDocumentTypes'], 'bundle_identifier': info['CFBundleIdentifier'],
              'scope': 'Exact Tests executable and product document metadata; no product source recompilation.'}
    (folder / 'fixture.json').write_text(json.dumps(record, indent=2) + '\n')
    return target


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--executable', required=True)
    parser.add_argument('--application', required=True)
    args = parser.parse_args()
    print(prepare(args.executable, args.application))
