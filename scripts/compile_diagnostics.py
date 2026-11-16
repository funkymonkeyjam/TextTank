#!/usr/bin/env python3
"""Reject actual first-party Swift diagnostic headers, including Swift 5 exit-zero warnings."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
HEADER = re.compile(r'^(.*?\.swift):(\d+):(\d+): (warning|error): (.*)$')


def diagnostic(line, root=ROOT):
    match = HEADER.match(line.rstrip('\r\n'))
    if not match:
        return None
    path = Path(match[1])
    resolved = path if path.is_absolute() else Path.cwd() / path
    parts = path.parts
    # Source/Test headers can be absolute or relative. Generated test clients under
    # the selected checkout are first party too; SDK/vendor sources are separate.
    first_party = bool({'Sources', 'Tests', 'scripts'} & set(parts)) or resolved.is_relative_to(root)
    if not first_party or 'Vendor' in parts:
        return None
    return {'path': match[1], 'line': int(match[2]), 'column': int(match[3]),
            'severity': match[4], 'message': match[5]}


def scan(lines, emit=False):
    headers, digest = [], hashlib.sha256()
    for raw in lines:
        digest.update(raw)
        if emit:
            sys.stdout.buffer.write(raw)
            sys.stdout.buffer.flush()
        value = diagnostic(raw.decode('utf-8', errors='replace'))
        if value:
            headers.append(value)
    return headers, digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--log', type=Path)
    parser.add_argument('--report', type=Path)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    options = parser.parse_args()
    command = options.command
    if command[:1] == ['--']:
        command = command[1:]
    if bool(options.log) == bool(command):
        parser.error('provide either --log or a command after --')
    compiler_status = 0
    if options.log:
        with options.log.open('rb') as source:
            headers, digest = scan(source)
    else:
        # No shell interpolation, suppression, response rewriting or compiler fallback.
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        headers, digest = scan(process.stdout, emit=True)
        compiler_status = process.wait()
        if compiler_status < 0:
            compiler_status = 128 - compiler_status
    status = compiler_status or (1 if headers else 0)
    if headers:
        print(f'First-party Swift diagnostic gate rejected {len(headers)} actual headers', file=sys.stderr)
    report = {'compiler_exit': compiler_status, 'guard_exit': status, 'command': command,
              'log': str(options.log) if options.log else None, 'output_sha256': digest,
              'diagnostic_headers': headers}
    if options.report:
        temporary = options.report.with_name(options.report.name + '.tmp')
        temporary.write_text(json.dumps(report, indent=2) + '\n')
        os.replace(temporary, options.report)
    return status


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        raise SystemExit(f'Swift diagnostic gate failed: {error}')
