#!/bin/bash
# Checks of the test harness itself: the shared check helper and the suite runner.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" == --runner-selftest ]]; then
  # Drives scripts/suite-lib.sh with stand-in suites: one passes, one cannot be
  # built, one fails, one hangs, and one more runs after all of them.
  work=$(mktemp -d "${TMPDIR:-/tmp}/texttank-runner-selftest.XXXXXX")
  trap 'rm -rf "$work"' EXIT
  status=0
  TEXTTANK_SUITE_RESULTS='' TEXTTANK_SUITE_TIMEOUT=1 GITHUB_ACTIONS='' SELFTEST_WORK="$work" bash -c '
    set -euo pipefail
    source scripts/suite-lib.sh
    suite_begin
    suite_run stand-in-pass "$SELFTEST_WORK/pass.log" /bin/sh -c "echo PASS StandIn: 1 assertions"
    suite_build "stand-in-unbuilt" /usr/bin/false
    suite_run stand-in-unbuilt "$SELFTEST_WORK/unbuilt.log" /bin/sh -c "echo must not run"
    suite_run stand-in-fail "$SELFTEST_WORK/fail.log" /bin/sh -c "echo FAIL Tests/StandIn.swift:7 deliberate failure; exit 3"
    suite_run stand-in-hang "$SELFTEST_WORK/hang.log" /bin/sleep 30
    suite_run stand-in-after "$SELFTEST_WORK/after.log" /bin/sh -c "echo PASS StandInAfter: 2 assertions"
    suite_finish
  ' > "$work/output.txt" 2>&1 || status=$?
  failures=0
  expect() { if grep -Eq -- "$2" "$work/output.txt"; then echo "PASS $1"; else echo "FAIL scripts/test-harness.sh $1"; failures=$((failures+1)); fi; }
  refuse() { if grep -Eq -- "$2" "$work/output.txt"; then echo "FAIL scripts/test-harness.sh $1"; failures=$((failures+1)); else echo "PASS $1"; fi; }
  if [[ "$status" == 1 ]]; then echo "PASS runner exits non-zero when any suite did not pass"; else echo "FAIL scripts/test-harness.sh runner exits non-zero when any suite did not pass (exit $status)"; failures=$((failures+1)); fi
  expect "passing suite is listed with its summary line" '^  PASS +stand-in-pass +PASS StandIn: 1 assertions$'
  expect "failed build step is recorded against its suite" '^  BUILD-FAILED +stand-in-unbuilt +exit 1 from: false'
  refuse "suite whose build failed is not run" '^must not run$'
  expect "failed suite is listed with its exit status and log" '^  FAILED +stand-in-fail +exit 3; log '
  expect "hung suite is stopped by the watchdog and named" '^  TIMEOUT +stand-in-hang +no result after 1 s; log '
  expect "suites after a failure and a hang still run" '^  PASS +stand-in-after +PASS StandInAfter: 2 assertions$'
  expect "summary repeats the named failure line from the log" '^FAIL Tests/StandIn.swift:7 deliberate failure$'
  expect "summary counts passed and not passed" '^2 passed, 3 not passed$'
  status=0
  scripts/build.sh --logged-selftest > "$work/output.txt" 2>&1 || status=$?
  if [[ "$status" == 5 ]]; then echo "PASS failed build step exits with the step's status"; else echo "FAIL scripts/test-harness.sh failed build step exits with the step's status (exit $status)"; failures=$((failures+1)); fi
  expect "failed build step names the step and its exit status" "^Build step 'build-selftest' failed with exit 5\\. Last 60 lines of .*harness/logs/build-selftest\\.log:\$"
  expect "failed build step prints the end of its log" '^selftest error line$'
  expect "failed build step prints the full log path" '^Full log: /.*harness/logs/build-selftest\.log$'
  rm -f harness/logs/build-selftest.log
  if [[ "$failures" == 0 ]]; then echo "PASS RunnerSelfTest: 13 assertions"; exit 0; fi
  echo "FAILED RunnerSelfTest: $failures failed"; cat "$work/output.txt"; exit 1
fi

source scripts/suite-lib.sh
suite_begin
suite_build "harness-checks" swiftc -target arm64-apple-macos14.0 -module-cache-path build/ModuleCache "$SUITE_SUPPORT" Tests/HarnessChecks.swift -o build/tests/harness-checks
suite_run harness-checks harness/logs/harness-checks.log build/tests/harness-checks
suite_run runner-selftest harness/logs/runner-selftest.log scripts/test-harness.sh --runner-selftest
# The tool that proves a formatting commit changed layout only must itself accept
# layout changes and reject every other kind of edit.
suite_run layout-proof-selftest harness/logs/layout-proof-selftest.log python3 scripts/check-layout-only.py --self-test
suite_finish
