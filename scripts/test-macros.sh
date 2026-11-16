#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_require_build
suite_build "macro-integration-checks" swiftc -D TEXTTANK_NATIVE_MACRO_TEST "${SWIFT_BASE[@]}" -F "$VENDOR_BUILD" -framework Scintilla Sources/UI/*.swift -framework Cocoa -Xlinker -rpath -Xlinker "$VENDOR_BUILD" Sources/Macros/MacroController.swift Sources/Search/SearchController.swift "$SUITE_SUPPORT" Tests/Support/ModelessForms.swift Tests/MacroChecks.swift -Xlinker "$NATIVE_BRIDGE_LIBRARY" -Xlinker "$NATIVE_SEARCH_LIBRARY" -lc++ -o build/tests/macro-integration-checks
suite_run macro-integration-checks harness/logs/macro-native-checks.log build/tests/macro-integration-checks
suite_finish
