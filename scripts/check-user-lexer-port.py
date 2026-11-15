#!/usr/bin/env python3
"""Checks that the user-defined-language lexer port is what its PROVENANCE.json says it is.

Always, with nothing but this repository:
  - the ported LexUser.cxx and UserConstants.h and the committed LexUser.patch have the recorded
    SHA-256 values;
  - undoing LexUser.patch on the ported LexUser.cxx gives a file with exactly the recorded SHA-256
    of the pinned upstream lexilla/lexers/LexUser.cxx, so port = pinned upstream + patch holds
    without the upstream file being present;
  - the Xcode project compiles LexUser.cxx as plain C++ with the flags in
    scripts/user-lexer-flags.txt, the same flags scripts/build-user-lexer.sh gives the test object.

With an upstream checkout (TEXTTANK_NOTEPAD_SOURCE=<checkout>, or --upstream <checkout>):
  - every recorded source file has its recorded SHA-256;
  - applying LexUser.patch to the upstream LexUser.cxx gives the ported file byte for byte;
  - every line of UserConstants.h after its heading is a line of the pinned SciLexer.h.

--update <checkout> rewrites LexUser.patch and the recorded hashes after a deliberate change to the
port. Nothing here downloads anything.
"""
import difflib, hashlib, json, os, re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PORT = ROOT / 'Sources/Languages/LexUserPort'
PROVENANCE = PORT / 'PROVENANCE.json'
PATCH = PORT / 'LexUser.patch'
UPSTREAM_LEXER = 'lexilla/lexers/LexUser.cxx'
PORTED = ['LexUser.cxx', 'UserConstants.h']
HUNK = re.compile(rb'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@')
failures = 0
passes = 0


def sha(data):
    return hashlib.sha256(data).hexdigest()


def check(condition, message):
    global failures, passes
    if condition:
        passes += 1
        print('PASS ' + message)
    else:
        failures += 1
        print('FAIL scripts/check-user-lexer-port.py ' + message)
    return condition


def make_patch(old, new):
    lines = difflib.unified_diff(
        old.decode('latin-1').splitlines(keepends=True), new.decode('latin-1').splitlines(keepends=True),
        'a/' + UPSTREAM_LEXER, 'b/Sources/Languages/LexUserPort/LexUser.cxx', n=3)
    return ''.join(lines).encode('latin-1')


def hunks(patch):
    """Yields (old_start, new_start, lines) for each hunk; lines keep their ' ', '-' or '+' mark."""
    current = None
    for line in patch.splitlines(keepends=True):
        match = HUNK.match(line)
        if match:
            if current:
                yield current
            current = (int(match.group(1)), int(match.group(3)), [])
        elif current is not None and line[:1] in (b' ', b'-', b'+'):
            current[2].append(line)
        elif current is not None:
            raise ValueError('unexpected patch line: %r' % line[:40])
    if current:
        yield current


def transform(source, patch, reverse):
    """Applies the patch to source, or undoes it when reverse is set. Exact matching, no fuzz."""
    take, give = (b'+', b'-') if reverse else (b'-', b'+')
    lines = source.splitlines(keepends=True)
    output, position = [], 0
    for old_start, new_start, body in hunks(patch):
        start = (new_start if reverse else old_start) - 1
        if start < position:
            raise ValueError('patch hunks overlap or are out of order')
        output += lines[position:start]
        position = start
        for line in body:
            mark, text = line[:1], line[1:]
            if mark in (b' ', take):
                if position >= len(lines) or lines[position] != text:
                    raise ValueError('patch does not match the file at line %d' % (position + 1))
                position += 1
                if mark == b' ':
                    output.append(text)
            else:
                output.append(text)
    return b''.join(output + lines[position:])


def upstream_root(argv):
    for flag in ('--upstream', '--update'):
        if flag in argv:
            return Path(argv[argv.index(flag) + 1])
    value = os.environ.get('TEXTTANK_NOTEPAD_SOURCE', '')
    return Path(value) if value else None


def update(root):
    record = json.loads(PROVENANCE.read_text())
    upstream = (root / UPSTREAM_LEXER).read_bytes()
    pinned = {entry['path']: entry['sha256'] for entry in record['sources']}
    if sha(upstream) != pinned[UPSTREAM_LEXER]:
        sys.exit('The checkout is not at the pinned source: %s has a different SHA-256.' % UPSTREAM_LEXER)
    PATCH.write_bytes(make_patch(upstream, (PORT / 'LexUser.cxx').read_bytes()))
    record['port'] = [{'path': name, 'sha256': sha((PORT / name).read_bytes())} for name in PORTED]
    record['patch'] = {'path': PATCH.name, 'applies_to': UPSTREAM_LEXER, 'sha256': sha(PATCH.read_bytes())}
    PROVENANCE.write_text(json.dumps(record, indent=2) + '\n')
    print('Updated %s and %s' % (PATCH.relative_to(ROOT), PROVENANCE.relative_to(ROOT)))


def main(argv):
    root = upstream_root(argv)
    if '--update' in argv:
        update(root)
        return 0
    record = json.loads(PROVENANCE.read_text())
    pinned = {entry['path']: entry['sha256'] for entry in record['sources']}
    ported = (PORT / 'LexUser.cxx').read_bytes()
    patch = PATCH.read_bytes() if PATCH.is_file() else b''
    recorded = {entry['path']: entry['sha256'] for entry in record.get('port', [])}
    for name in PORTED:
        check(recorded.get(name) == sha((PORT / name).read_bytes()),
              '%s has the SHA-256 recorded in PROVENANCE.json' % name)
    check(record.get('patch', {}).get('sha256') == sha(patch) and record.get('patch', {}).get('path') == PATCH.name,
          'LexUser.patch has the SHA-256 recorded in PROVENANCE.json')
    try:
        rebuilt = transform(ported, patch, reverse=True)
        check(sha(rebuilt) == pinned[UPSTREAM_LEXER],
              'undoing LexUser.patch on the port gives the pinned upstream LexUser.cxx (SHA-256 %s...)'
              % pinned[UPSTREAM_LEXER][:12])
    except ValueError as error:
        check(False, 'LexUser.patch can be undone on the ported LexUser.cxx (%s)' % error)
    check(len(record.get('native_changes', [])) > 0
          and any('UserDefinedLanguage.words' in change for change in record['native_changes']),
          'native_changes records the Swift port of the quoted-keyword encoding')

    flags = (ROOT / 'scripts/user-lexer-flags.txt').read_text().split()
    project = (ROOT / 'TextTank.xcodeproj/project.pbxproj').read_text()
    reference = re.search(r'\{[^{}]*"path" = "Sources/Languages/LexUserPort/LexUser\.cxx"[^{}]*\}', project)
    check(reference is not None and '"lastKnownFileType" = "sourcecode.cpp.cpp"' in reference.group(0),
          'the Xcode project compiles LexUser.cxx as plain C++, not Objective-C++')
    check('-std=c++17' in flags and '"COMPILER_FLAGS" = %s' % json.dumps(' '.join(flags)) in project,
          'the Xcode project gives LexUser.cxx the flags in scripts/user-lexer-flags.txt (%s)' % ' '.join(flags))
    check('scripts/user-lexer-flags.txt' in (ROOT / 'scripts/build-user-lexer.sh').read_text(),
          'scripts/build-user-lexer.sh compiles the test object with the same flags file')

    if root is None:
        print('NOTE no upstream checkout given (TEXTTANK_NOTEPAD_SOURCE); the recorded hashes and the '
              'patch round trip above were checked without it')
    else:
        for path, expected in pinned.items():
            file = root / path
            check(file.is_file() and sha(file.read_bytes()) == expected, 'upstream %s has its recorded SHA-256' % path)
        try:
            applied = transform((root / UPSTREAM_LEXER).read_bytes(), patch, reverse=False)
            check(applied == ported, 'LexUser.patch applied to the upstream LexUser.cxx gives the port byte for byte')
        except (OSError, ValueError) as error:
            check(False, 'LexUser.patch applies to the upstream LexUser.cxx (%s)' % error)
        try:
            header = set((root / 'lexilla/include/SciLexer.h').read_text().split('\n'))
            constants = (PORT / 'UserConstants.h').read_text().split('\n')[1:]
            check(all(line in header for line in constants) and len(constants) > 80,
                  'every constant in UserConstants.h is a line of the pinned SciLexer.h')
        except OSError as error:
            check(False, 'the pinned SciLexer.h can be read (%s)' % error)
    if failures:
        print('FAILED UserLexerPortChecks: %d failed, %d passed' % (failures, passes))
        return 1
    print('PASS UserLexerPortChecks: %d assertions%s' % (passes, '' if root else '; upstream checkout not present'))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
