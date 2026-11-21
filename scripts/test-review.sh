#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_require_build
suite_build "review-core-layering" swiftc -typecheck "${SWIFT_BASE[@]}" "$SUITE_SUPPORT" Tests/ReviewCoreChecks.swift
suite_run review-core-layering harness/logs/review-core-layering.log /bin/echo "PASS Review Core imports canonical Foundation-only Core"
suite_build "review-core-checks" swiftc "${SWIFT_BASE[@]}" "$SUITE_SUPPORT" Tests/ReviewCoreChecks.swift -o build/tests/review-core-checks
suite_run review-core-checks harness/logs/review-core-checks.log build/tests/review-core-checks
if [[ "${1:-}" != --core-only ]]; then
suite_build "review-applier-checks" swiftc "${SWIFT_BASE[@]}" -F "$VENDOR_BUILD" -framework Scintilla -framework Cocoa -lc++ -Xlinker -rpath -Xlinker "$VENDOR_BUILD" "$SUITE_SUPPORT" Tests/Support/ModelessForms.swift Tests/ReviewApplierChecks.swift -Xlinker "$NATIVE_BRIDGE_LIBRARY" -o build/tests/review-applier-checks
suite_run review-applier-checks harness/logs/review-applier-checks.log build/tests/review-applier-checks
fi
suite_finish
