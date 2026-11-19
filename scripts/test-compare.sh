#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_require_build
suite_build "compare-core-layering" swiftc -typecheck "${SWIFT_BASE[@]}" "$SUITE_SUPPORT" Tests/CompareChecks.swift
suite_run compare-core-layering harness/logs/compare-core-layering.log /bin/echo "PASS Compare Core imports canonical Foundation-only Core"
suite_build "compare-checks" swiftc "${SWIFT_BASE[@]}" "$SUITE_SUPPORT" Tests/CompareChecks.swift -o build/tests/compare-checks
suite_run compare-checks harness/logs/compare-checks.log build/tests/compare-checks
suite_finish
