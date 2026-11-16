#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_require_build
suite_build "workspace-browser-checks" swiftc -D TESTING "${SWIFT_BASE[@]}" -F "$VENDOR_BUILD" -framework Scintilla Sources/UI/*.swift -framework Cocoa -framework EventKit -lc++ -Xlinker -rpath -Xlinker "$VENDOR_BUILD" "${APP_SOURCES[@]}" "$SUITE_SUPPORT" Tests/Support/ModelessForms.swift Tests/WorkspaceBrowserChecks.swift -Xlinker "$NATIVE_BRIDGE_LIBRARY" -Xlinker "$NATIVE_SEARCH_LIBRARY" -o build/tests/workspace-browser-checks
suite_run workspace-browser-checks harness/logs/workspace-browser-checks.log build/tests/workspace-browser-checks
suite_finish
