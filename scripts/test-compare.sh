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
if [[ "${1:-}" != --core-only ]]; then
suite_build "compare-controller-checks" swiftc "${SWIFT_BASE[@]}" -F "$VENDOR_BUILD" -framework Scintilla -framework Cocoa -lc++ -Xlinker -rpath -Xlinker "$VENDOR_BUILD" "$SUITE_SUPPORT" Tests/Support/ModelessForms.swift Tests/CompareControllerChecks.swift -Xlinker "$NATIVE_BRIDGE_LIBRARY" -o build/tests/compare-controller-checks
compare_client=build/tests/compare-controller-checks
if [[ "$SUITE_BROKEN" != *" compare-controller-checks "* ]]; then
  if compare_client=$(python3 scripts/prepare-native-check-app.py --executable build/tests/compare-controller-checks --application "$APP_PATH"); then :; else
    suite_record "BUILD-FAILED" "compare-controller-checks" "owned native app preparation failed"
    SUITE_BROKEN="$SUITE_BROKEN compare-controller-checks "
  fi
fi
TEXTTANK_TEST_PASTEBOARD=1 suite_run compare-controller-checks harness/logs/compare-controller-checks.log "$compare_client"
fi
suite_finish
