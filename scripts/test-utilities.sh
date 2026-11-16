#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_require_build
suite_build "utility-checks" swiftc "${SWIFT_BASE[@]}" -F "$VENDOR_BUILD" -framework Scintilla Sources/UI/*.swift -framework Cocoa -Xlinker -rpath -Xlinker "$VENDOR_BUILD" Sources/Utilities/UtilityController.swift "$SUITE_SUPPORT" Tests/Support/ModelessForms.swift Tests/UtilityChecks.swift -Xlinker "$NATIVE_BRIDGE_LIBRARY" -lc++ -o build/tests/utility-checks
suite_run utility-checks harness/logs/utility-checks.log build/tests/utility-checks
suite_finish
