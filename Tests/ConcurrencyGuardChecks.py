#!/usr/bin/env python3
"""Real compiler controls for the production/test diagnostic gate; never executes UI."""
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
manifest = json.loads(Path(os.environ['TEXTTANK_ARTIFACT_MANIFEST']).read_text())
evidence = ROOT / 'build/tests' / ('concurrency-guard-' + uuid.uuid4().hex)
(evidence / 'Tests').mkdir(parents=True)
guard = ROOT / 'scripts/compile_diagnostics.py'
base = ['xcrun', '--sdk', 'macosx', 'swiftc', '-swift-version', '5', '-strict-concurrency=complete',
        '-warnings-as-errors', '-target', 'arm64-apple-macos14.0', '-sdk', manifest['toolchain']['sdk'],
        '-module-cache-path', str(ROOT / 'build/ModuleCache'), '-typecheck']
checks = 0


def check(condition, description):
    global checks
    if not condition:
        raise RuntimeError(description)
    checks += 1
    print('PASS ' + description)


for name, actor in [('good', '@MainActor '), ('bad', '')]:
    source = evidence / 'Tests' / (name + '.swift')
    source.write_text('import AppKit\n' + actor + 'func ownership(_ view: NSView) -> Bool { view.isHidden }\n')
    report = evidence / (name + '.json')
    command = [sys.executable, str(guard), '--report', str(report), '--', *base, str(source)]
    # Deliberate negative diagnostics have their own durable raw log. They are not
    # normal acceptance compiler output and are never suppressed or discarded.
    result = subprocess.run(command, capture_output=True)
    (evidence / (name + '.log')).write_bytes(result.stdout + result.stderr)
    value = json.loads(report.read_text())
    if name == 'good':
        check(result.returncode == 0 and value['compiler_exit'] == 0 and not value['diagnostic_headers'],
              'actual complete Swift 5 compiler accepts main-owned AppKit access with zero headers')
    else:
        check(result.returncode != 0 and value['diagnostic_headers'],
              'actual compiler diagnostic is rejected even when Swift 5 reports success')
        print('BAD_COMPILER_CONTROL raw_exit=' + str(value['compiler_exit'])
              + ' actual_headers=' + str(len(value['diagnostic_headers'])))
        # Exercise the exact saved-log gate used by the canonical producer too.
        raw = evidence / 'bad-compiler.log'
        raw.write_bytes(result.stdout)
        logged = subprocess.run([sys.executable, str(guard), '--log', str(raw)], capture_output=True)
        (evidence / 'bad-log-guard.log').write_bytes(logged.stdout + logged.stderr)
        check(logged.returncode != 0, 'canonical saved-log gate rejects the same real emitted diagnostic')
settings = manifest['target_settings']
advisory = (os.environ.get('GITHUB_ACTIONS') == 'true'
            and os.environ.get('TEXTTANK_WARNINGS_AS_ERRORS') == '0'
            and os.environ.get('XCODE_VERSION') == '16.4'
            and manifest['toolchain']['xcode'].splitlines()[0] == 'Xcode 16.4')
expected_warnings = 'NO' if advisory else 'YES'
check(all(settings[name].get('SWIFT_STRICT_CONCURRENCY') == 'complete'
          and settings[name].get('SWIFT_VERSION') == '5.0'
          and settings[name].get('SWIFT_TREAT_WARNINGS_AS_ERRORS') == expected_warnings
          for name in ['TextTankCore', 'TextTankRuntime', 'TextTank']),
      'actual resolved Swift producers retain complete checking, Swift 5 and SWIFT_TREAT_WARNINGS_AS_ERRORS='
      + expected_warnings)
print('COMPILER_CONTROL_EVIDENCE ' + str(evidence))
print(f'PASS ConcurrencyGuardChecks: {checks} assertions')
