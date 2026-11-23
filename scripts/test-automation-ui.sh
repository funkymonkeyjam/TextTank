#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_require_build
suite_build "automation-controller-checks" swiftc -swift-version 5 "${SWIFT_BASE[@]}" -F "$VENDOR_BUILD" -framework Scintilla -framework Cocoa -framework EventKit -lc++ -Xlinker -rpath -Xlinker "$VENDOR_BUILD" "$SUITE_SUPPORT" Tests/Support/ModelessForms.swift Tests/Support/AutomationFixtures.swift Tests/AutomationControllerChecks.swift -Xlinker "$NATIVE_BRIDGE_LIBRARY" -o build/tests/automation-controller-checks
suite_run automation-controller-checks harness/logs/automation-controller-checks.log build/tests/automation-controller-checks
suite_finish
