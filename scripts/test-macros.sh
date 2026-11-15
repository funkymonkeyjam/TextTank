#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_require_build
suite_build "macro-integration-checks" scripts/build-user-lexer.sh
suite_build "macro-integration-checks" clang++ -std=c++17 -fobjc-arc -mmacosx-version-min=14.0 -I Sources/EditorBridge -I Vendor/scintilla/cocoa -I Vendor/scintilla/include -I Vendor/lexilla/include -F build/vendor/Debug -c Sources/EditorBridge/TTEditor.mm -o build/tests/TTEditor-macro.o
suite_build "macro-integration-checks" clang++ -std=c++17 -fobjc-arc -mmacosx-version-min=14.0 -I Sources/Search/Boost -c Sources/Search/TTSearchEngine.mm -o build/tests/MacroBoostSearch.o
suite_build "macro-integration-checks" swiftc Sources/Documents/FailureContext.swift -D TEXTTANK_NATIVE_MACRO_TEST -target arm64-apple-macos14.0 -module-cache-path build/ModuleCache -import-objc-header Sources/EditorBridge/TTEditor.h -F build/vendor/Debug -framework Scintilla Sources/UI/*.swift -framework Cocoa -Xlinker -rpath -Xlinker "$PWD/build/vendor/Debug" Sources/Macros/MacroCore.swift Sources/Macros/MacroController.swift Sources/Search/SearchCore.swift Sources/Search/SearchController.swift "$SUITE_SUPPORT" Tests/MacroChecks.swift build/tests/TTEditor-macro.o build/tests/MacroBoostSearch.o build/tests/UserLexer.o Vendor/lexilla/bin/liblexilla.a -lc++ -o build/tests/macro-integration-checks
suite_run macro-integration-checks harness/logs/macro-native-checks.log build/tests/macro-integration-checks
suite_finish
