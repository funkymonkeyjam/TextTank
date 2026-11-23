#!/bin/bash
# The Foundation-only preview core (Sources/Preview). The layering step proves the checks compile
# against Core alone, without Runtime or AppKit; the run step executes them.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_require_build
suite_build "preview-core-layering" swiftc -typecheck "${SWIFT_BASE[@]}" "$SUITE_SUPPORT" Tests/PreviewCoreChecks.swift
suite_run preview-core-layering harness/logs/preview-core-layering.log /bin/echo "PASS Preview Core imports canonical Foundation-only Core"
suite_build "preview-core-checks" swiftc "${SWIFT_BASE[@]}" "$SUITE_SUPPORT" Tests/PreviewCoreChecks.swift -o build/tests/preview-core-checks
suite_run preview-core-checks harness/logs/preview-core-checks.log build/tests/preview-core-checks
suite_finish
