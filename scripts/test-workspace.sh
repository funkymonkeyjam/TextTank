#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_require_build
suite_build "workspace-checks" swiftc "${SWIFT_BASE[@]}" "$SUITE_SUPPORT" Tests/WorkspaceChecks.swift -o build/tests/workspace-checks
suite_run workspace-checks harness/logs/workspace-checks.log build/tests/workspace-checks
suite_finish
