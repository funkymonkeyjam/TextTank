#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_require_build
suite_build "run-checks" swiftc Sources/Documents/Strings.swift Sources/Documents/FailureContext.swift Sources/Documents/PrivateFileStore.swift "${SWIFT_BASE[@]}" Sources/Run/RunCore.swift "$SUITE_SUPPORT" Tests/RunChecks.swift -o build/tests/run-checks
suite_run run-checks harness/logs/run-checks.log build/tests/run-checks
suite_build "run-controller-checks" swiftc -D TESTING "${SWIFT_BASE[@]}" -import-objc-header Sources/TextTankApp/TextTank-Bridging-Header.h -F "$VENDOR_BUILD" -framework Scintilla Sources/UI/*.swift -framework Cocoa -framework EventKit -lc++ -Xlinker -rpath -Xlinker "$VENDOR_BUILD" "${APP_SOURCES[@]}" "$SUITE_SUPPORT" Tests/Support/ModelessForms.swift Tests/RunControllerChecks.swift -Xlinker "$NATIVE_BRIDGE_LIBRARY" -Xlinker "$NATIVE_SEARCH_LIBRARY" -o build/tests/run-controller-checks
suite_run run-controller-checks harness/logs/run-controller-checks.log build/tests/run-controller-checks
suite_finish
