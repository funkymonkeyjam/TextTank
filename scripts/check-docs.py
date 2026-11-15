#!/usr/bin/env python3
"""Check product documentation links and dated source mappings, not editor behavior."""
import importlib.util
import json
from pathlib import Path
import re
import sys
import tempfile
from urllib.parse import unquote, urlsplit
from capability_matrix import validate

ROOT = Path(__file__).resolve().parents[1]


def local_links(path):
    for match in re.finditer(r'!?\[[^\]]*\]\(([^)]+)\)', path.read_text(encoding='utf-8')):
        target = match.group(1)
        if target.startswith('#') or urlsplit(target).scheme:
            continue
        target = unquote(target.partition('#')[0])
        if target and not (path.parent / target).is_file():
            raise ValueError('Broken documentation link in ' + path.name + ': ' + target)


def main():
    spec = importlib.util.spec_from_file_location('package_review', ROOT / 'scripts/package_review.py')
    packaging = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(packaging)
    matrix = json.loads((ROOT / 'docs/parity/capabilities.json').read_text(encoding='utf-8'))
    counts = validate(ROOT, matrix)
    for relative in ('README.md',) + tuple(name for name in packaging.REVIEW_DOCUMENTS if name.endswith('.md')):
        local_links(ROOT / relative)
    with tempfile.TemporaryDirectory(prefix='texttank-doc-links-') as work:
        delivery = Path(work)
        packaging.copy_documentation(ROOT, delivery)
        for name in ['README.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md', 'Dependencies.lock.json']:
            (delivery / name).write_bytes((ROOT / name).read_bytes())
        for path in delivery.rglob('*.md'):
            local_links(path)
        delivered = {path.relative_to(delivery).as_posix() for path in delivery.rglob('*') if path.is_file()}
        expected = set(packaging.REVIEW_DOCUMENTS) | {'REVIEW-ME.md', 'README.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md', 'Dependencies.lock.json'}
        if delivered != expected:
            raise ValueError('Unexpected review documentation set')
    print('PASS documentation metadata: source/package links, explicit documentation set, %d reference/%d automation requirements and %d dated mappings. No behavioral certification.' % counts)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError) as error:
        raise SystemExit('Documentation check stopped: ' + str(error))
