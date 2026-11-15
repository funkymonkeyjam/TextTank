#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_require_build
suite_build "utility-checks" scripts/build-user-lexer.sh
suite_build "utility-checks" build_bridge_object
suite_build "utility-checks" swiftc "${SWIFT_BASE[@]}" -import-objc-header Sources/EditorBridge/TTEditor.h -F "$VENDOR_BUILD" -framework Scintilla Sources/UI/*.swift -framework Cocoa -Xlinker -rpath -Xlinker "$VENDOR_BUILD" Sources/Utilities/*.swift "$SUITE_SUPPORT" Tests/UtilityChecks.swift "$BRIDGE_OBJECT" "$USER_LEXER_OBJECT" "$LEXILLA_LIBRARY" -lc++ -o build/tests/utility-checks
suite_run utility-checks harness/logs/utility-checks.log build/tests/utility-checks
suite_finish
