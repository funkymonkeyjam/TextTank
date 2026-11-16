#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_require_build
suite_build "workspace-browser-checks" scripts/build-user-lexer.sh
suite_build "workspace-browser-checks" build_bridge_object
suite_build "workspace-browser-checks" build_search_object
suite_build "workspace-browser-checks" swiftc -D TESTING "${SWIFT_BASE[@]}" -import-objc-header Sources/TextTankApp/TextTank-Bridging-Header.h -F "$VENDOR_BUILD" -framework Scintilla Sources/UI/*.swift -framework Cocoa -framework EventKit -lc++ -Xlinker -rpath -Xlinker "$VENDOR_BUILD" "${APP_SOURCES[@]}" "$SUITE_SUPPORT" Tests/Support/ModelessForms.swift Tests/WorkspaceBrowserChecks.swift "$BRIDGE_OBJECT" "$SEARCH_OBJECT" "$USER_LEXER_OBJECT" "$LEXILLA_LIBRARY" -o build/tests/workspace-browser-checks
suite_run workspace-browser-checks harness/logs/workspace-browser-checks.log build/tests/workspace-browser-checks
suite_finish
