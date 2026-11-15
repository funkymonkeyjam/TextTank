#!/usr/bin/env python3
"""Prove that a formatting commit changed layout only.

Usage: scripts/check-layout-only.py <before-rev> <after-rev> [--self-test]

For every first-party Swift file that differs between the two revisions, two
independent comparisons must both hold:

1. Lexical. The file is split into code, string literals and comments. Code is
   compared with whitespace, statement-separating semicolons and the optional
   trailing comma of a collection literal removed; string literals are compared
   exactly (a multi-line literal after removing the indentation of its closing
   delimiter, which is how Swift defines its value); comments are compared
   exactly apart from leading and trailing whitespace on each line, and each
   must stay between the same two tokens. So every identifier, literal,
   operator and comment is unchanged and in the same place.
2. Syntactic. `swiftc -frontend -dump-parse` output is compared after removing
   source locations, pointer values and the `trailing_semi` marker, so the two
   files parse to the same tree.

Files added or removed between the revisions, and files that are not Swift,
are listed and are not accepted as layout-only. Exit status 0 means every
changed Swift file passed both comparisons and nothing else changed under the
checked paths.
"""
import re
import subprocess
import sys

CHECKED = ('Sources/', 'Tests/')


def git(*args, text=True):
    return subprocess.check_output(['git', *args], text=text)


def lex(source):
    """Returns (code, strings, comments). Raises ValueError on unterminated input."""
    code, strings, comments = [], [], []
    position, length = 0, len(source)

    def string_end(start):
        """Index just past the string literal that begins at start (at its # or quote)."""
        index = start
        while source[index] == '#':
            index += 1
        hashes = index - start
        multiline = source.startswith('"""', index)
        quote = '"""' if multiline else '"'
        index += len(quote)
        closing = quote + '#' * hashes
        escape = '\\' + '#' * hashes
        while index < length:
            if source.startswith(closing, index):
                return index + len(closing)
            if source.startswith(escape, index):
                index += len(escape)
                if index < length and source[index] == '(':
                    index = interpolation_end(index)
                else:
                    index += 1
                continue
            if source[index] == '\n' and not multiline:
                raise ValueError('unterminated string literal')
            index += 1
        raise ValueError('unterminated string literal')

    def interpolation_end(start):
        """Index just past the parenthesis that closes the one at start."""
        depth, index = 0, start
        while index < length:
            character = source[index]
            if character == '"' or (character == '#' and re.match(r'#+"', source[index:index + 8])):
                index = string_end(index)
                continue
            if character == '(':
                depth += 1
            elif character == ')':
                depth -= 1
                if depth == 0:
                    return index + 1
            index += 1
        raise ValueError('unterminated interpolation')

    while position < length:
        character = source[position]
        if source.startswith('//', position):
            end = source.find('\n', position)
            end = length if end < 0 else end
            comments.append(source[position:end].strip())
            code.append('\x01')
            position = end
        elif source.startswith('/*', position):
            depth, index = 1, position + 2
            while depth and index < length:
                if source.startswith('/*', index):
                    depth, index = depth + 1, index + 2
                elif source.startswith('*/', index):
                    depth, index = depth - 1, index + 2
                else:
                    index += 1
            if depth:
                raise ValueError('unterminated block comment')
            comments.append('\n'.join(line.strip() for line in source[position:index].split('\n')))
            code.append('\x01')
            position = index
        elif character == '"' or (character == '#' and re.match(r'#+"', source[position:position + 8])):
            end = string_end(position)
            literal = source[position:end]
            if '"""' in literal[:8]:
                lines = literal.split('\n')
                indentation = re.match(r'[ \t]*', lines[-1]).group()
                lines = [line[len(indentation):] if line.startswith(indentation) else line.lstrip(' \t')
                         for line in lines[1:]]
                literal = literal.split('\n')[0] + '\n' + '\n'.join(lines)
            strings.append(literal)
            code.append('\x00')
            position = end
        elif character.isspace() or character == ';':
            position += 1
        else:
            code.append(character)
            position += 1
    # A trailing comma before the closing bracket of a collection literal is not a token of the
    # program: the formatter drops it when it joins or re-breaks the literal.
    return re.sub(r',([\x01]*)\]', r'\1]', ''.join(code)), strings, comments


LOCATION = re.compile(r'\b(?:range|location|decl_context|init_context|bridged_range)=(?:\[[^\]]*\]|\S+)')
POINTER = re.compile(r'0x[0-9a-fA-F]+')


def parse_tree(source, name):
    result = subprocess.run(['xcrun', 'swiftc', '-frontend', '-dump-parse', '-'], input=source,
                            capture_output=True, text=True)
    text = result.stdout + result.stderr
    text = LOCATION.sub('', text)
    text = POINTER.sub('', text)
    text = text.replace(' trailing_semi', '')
    text = re.sub(r'<stdin>:\d+:\d+', '', text)
    text = re.sub(r'\bline:\d+:\d+', '', text)
    return [line.strip() for line in text.splitlines()]


def first_difference(before, after):
    for index, (left, right) in enumerate(zip(before, after)):
        if left != right:
            return index, left, right
    if len(before) != len(after):
        index = min(len(before), len(after))
        return index, (before[index:index + 1] or ['<end>'])[0], (after[index:index + 1] or ['<end>'])[0]
    return None


def compare(before, after, name, syntactic=True):
    problems = []
    try:
        old, new = lex(before), lex(after)
    except ValueError as error:
        return [f'{name}: could not be split into tokens: {error}']
    for label, left, right in (('code', old[0], new[0]), ('string literals', old[1], new[1]),
                               ('comments', old[2], new[2])):
        difference = first_difference(left, right)
        if difference:
            index, was, now = difference
            if label == 'code':
                was, now = left[max(0, index - 40):index + 40], right[max(0, index - 40):index + 40]
            problems.append(f'{name}: {label} differ at {index}: {was!r} became {now!r}')
    if syntactic:
        difference = first_difference(parse_tree(before, name), parse_tree(after, name))
        if difference:
            problems.append(f'{name}: parse trees differ at line {difference[0]}: '
                            f'{difference[1]!r} became {difference[2]!r}')
    return problems


def self_test():
    """The comparison must accept layout changes and reject every other kind."""
    base = ('// why: keep\nimport Foundation\nfunc f(_ a: Int) -> String { let b = a + 1; let s = "x; \\(b) y"; '
            'let list = [1, 2,]; _ = list; return s }\n')
    accepted = ('// why: keep\nimport Foundation\nfunc f(_ a: Int) -> String {\n    let b = a + 1\n'
                '    let s = "x; \\(b) y"\n    let list = [1, 2]\n    _ = list\n    return s\n}\n')
    rejected = {
        'changed operator': accepted.replace('a + 1', 'a - 1'),
        'changed string': accepted.replace('"x; ', '"x;  '),
        'changed comment': accepted.replace('why: keep', 'why: kept'),
        'removed comment': accepted.replace('// why: keep\n', ''),
        'renamed identifier': accepted.replace('let b', 'let c').replace('(b)', '(c)'),
        'added statement': accepted.replace('    return s', '    _ = b\n    return s'),
        'removed element': accepted.replace('[1, 2]', '[1]'),
        'moved comment': 'import Foundation\n// why: keep\n' + accepted.split('\n', 2)[2],
        'reordered statements': accepted.replace('    let b = a + 1\n', '').replace('    return s', '    let b = a + 1\n    return s'),
    }
    failures = []
    if compare(base, accepted, 'accepted'):
        failures.append('a layout-only change was rejected: ' + '; '.join(compare(base, accepted, 'accepted')))
    for label, text in rejected.items():
        if not compare(base, text, label):
            failures.append(f'{label} was accepted as layout-only')
        if label not in ('changed comment', 'removed comment', 'moved comment') \
                and first_difference(parse_tree(base, label), parse_tree(text, label)) is None:
            failures.append(f'{label} was not seen by the parse-tree comparison')
    for failure in failures:
        print('FAIL self-test: ' + failure)
    if failures:
        print(f'FAILED LayoutProofSelfTest: {len(failures)} failed')
    else:
        print(f'PASS LayoutProofSelfTest: {1 + len(rejected)} assertions')
    return not failures


def main():
    arguments = [argument for argument in sys.argv[1:] if argument != '--self-test']
    if '--self-test' in sys.argv[1:]:
        if not self_test():
            return 1
        if not arguments:
            return 0
    if len(arguments) != 2:
        print(__doc__)
        return 2
    before_rev, after_rev = arguments
    problems, checked = [], 0
    for line in git('diff', '--name-status', '--no-renames', before_rev, after_rev, '--', *CHECKED).splitlines():
        status, path = line.split('\t', 1)
        if status != 'M' or not path.endswith('.swift'):
            problems.append(f'{path}: status {status}; only modified Swift files can be layout-only')
            continue
        before = git('show', f'{before_rev}:{path}')
        after = git('show', f'{after_rev}:{path}')
        problems += compare(before, after, path)
        checked += 1
    for problem in problems:
        print('FAIL ' + problem)
    print(f'{checked} changed Swift files compared between {before_rev} and {after_rev}: '
          f'{"layout only" if not problems else str(len(problems)) + " problems"}')
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
