#!/usr/bin/env python3
"""Bind a full acceptance exit status to clean start/end git trees and its log."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def git(root, *args):
    return subprocess.check_output(['git', *args], cwd=root, text=True, stderr=subprocess.DEVNULL).strip()


def source_state(root):
    try:
        if git(root, 'rev-parse', '--is-inside-work-tree') != 'true':
            raise ValueError('not a git checkout')
        return {'source_commit': git(root, 'rev-parse', 'HEAD'),
                'source_tree': git(root, 'rev-parse', 'HEAD^{tree}'),
                'dirty': bool(git(root, 'status', '--porcelain'))}
    except (OSError, ValueError, subprocess.CalledProcessError):
        return {'source_commit': None, 'source_tree': None, 'dirty': None}


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(prefix=path.name + '.', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'w') as output:
            json.dump(value, output, indent=2)
            output.write('\n')
            output.flush()
            os.fsync(output.fileno())
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


def exit_code(value):
    try:
        code = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError('exit code must be an integer from 0 to 255') from error
    if not 0 <= code <= 255:
        raise argparse.ArgumentTypeError('exit code must be from 0 to 255')
    return code


def record(root, code):
    logs = root / 'harness/logs'
    checkpoint = logs / 'test-source-state.json'
    start = json.loads(checkpoint.read_text()) if checkpoint.exists() else {}
    end = source_state(root)
    stable = bool(start.get('source_tree') and start.get('source_tree') == end['source_tree']
                  and start.get('dirty') is False and end['dirty'] is False)
    if not start:
        reason = 'start-of-run source state is missing'
    elif not end['source_tree']:
        reason = 'not a git checkout; evidence cannot be bound to a tree'
    elif start.get('dirty') is not False or end['dirty'] is not False:
        reason = 'working tree was dirty at the start or end'
    elif start.get('source_tree') != end['source_tree']:
        reason = 'git tree changed during acceptance'
    else:
        reason = 'clean start and end have the same git tree'
    log = logs / 'full-acceptance.log'
    skips = [line for line in log.read_text(errors='replace').splitlines() if line.startswith('SKIP ')] if log.exists() else []
    value = {'schema_version': 1, 'timestamp': datetime.datetime.now(datetime.timezone.utc).isoformat(),
             **end, 'source_stable': stable, 'source_stable_reason': reason, 'source_start': start,
             'local_acceptance': {'command': 'scripts/test.sh', 'exit_code': code,
                                  'log': 'harness/logs/full-acceptance.log',
                                  'log_sha256': hashlib.sha256(log.read_bytes()).hexdigest() if log.exists() else None,
                                  'observed_skips': skips},
             'limitations': ['No live Reminders fault, VoiceOver, Intel or macOS14/15 runtime certification.']
                            + [f'Observed environment/opt-in skip: {skip[5:]}' for skip in skips]}
    write_json(logs / 'candidate-validation.json', value)
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('capture', help='record the starting git tree and dirty state')
    recording = commands.add_parser('record', help='record the completed acceptance result')
    recording.add_argument('--exit-code', required=True, type=exit_code)
    args = parser.parse_args()
    if args.command == 'capture':
        write_json(ROOT / 'harness/logs/test-source-state.json', source_state(ROOT))
    else:
        record(ROOT, args.exit_code)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError) as error:
        raise SystemExit(f'Validation recording stopped: {error}')
