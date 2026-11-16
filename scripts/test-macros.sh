#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_require_build
suite_build "macro-integration-checks" scripts/build-user-lexer.sh
suite_build "macro-integration-checks" build_bridge_object
suite_build "macro-integration-checks" build_search_object
suite_build "macro-integration-checks" swiftc Sources/Documents/FailureContext.swift Sources/Documents/PrivateFileStore.swift -D TEXTTANK_NATIVE_MACRO_TEST "${SWIFT_BASE[@]}" -import-objc-header Sources/EditorBridge/TTEditor.h -F "$VENDOR_BUILD" -framework Scintilla Sources/UI/*.swift -framework Cocoa -Xlinker -rpath -Xlinker "$VENDOR_BUILD" Sources/Documents/EditorCommandCatalog.swift Sources/Macros/MacroCore.swift Sources/Macros/MacroController.swift Sources/Search/SearchCore.swift Sources/Search/SearchController.swift "$SUITE_SUPPORT" Tests/MacroChecks.swift "$BRIDGE_OBJECT" "$SEARCH_OBJECT" "$USER_LEXER_OBJECT" "$LEXILLA_LIBRARY" -lc++ -o build/tests/macro-integration-checks
suite_run macro-integration-checks harness/logs/macro-native-checks.log build/tests/macro-integration-checks
suite_finish
