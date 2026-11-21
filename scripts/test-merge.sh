#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_require_build
suite_build "merge-core-layering" swiftc -typecheck "${SWIFT_BASE[@]}" "$SUITE_SUPPORT" Tests/MergeChecks.swift
suite_run merge-core-layering harness/logs/merge-core-layering.log /bin/echo "PASS Merge Core imports canonical Foundation-only Core"
suite_build "merge-checks" swiftc "${SWIFT_BASE[@]}" "$SUITE_SUPPORT" Tests/MergeChecks.swift -o build/tests/merge-checks
suite_run merge-checks harness/logs/merge-checks.log build/tests/merge-checks
if [[ "${1:-}" != --core-only ]]; then
suite_build "merge-controller-checks" swiftc "${SWIFT_BASE[@]}" -F "$VENDOR_BUILD" -framework Scintilla -framework Cocoa -lc++ -Xlinker -rpath -Xlinker "$VENDOR_BUILD" "$SUITE_SUPPORT" Tests/Support/ModelessForms.swift Tests/MergeControllerChecks.swift -Xlinker "$NATIVE_BRIDGE_LIBRARY" -o build/tests/merge-controller-checks
merge_client=build/tests/merge-controller-checks
if [[ "$SUITE_BROKEN" != *" merge-controller-checks "* ]]; then
  if merge_client=$(python3 scripts/prepare-native-check-app.py --executable build/tests/merge-controller-checks --application "$APP_PATH"); then :; else
    suite_record "BUILD-FAILED" "merge-controller-checks" "owned native app preparation failed"
    SUITE_BROKEN="$SUITE_BROKEN merge-controller-checks "
  fi
fi
TEXTTANK_TEST_PASTEBOARD=1 suite_run merge-controller-checks harness/logs/merge-controller-checks.log "$merge_client"
fi
suite_finish
