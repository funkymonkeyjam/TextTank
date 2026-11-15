#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_require_build
suite_build "utility-checks" scripts/build-user-lexer.sh
suite_build "utility-checks" clang++ -std=c++17 -fobjc-arc -mmacosx-version-min=14.0 -I Sources/EditorBridge -I Vendor/scintilla/cocoa -I Vendor/scintilla/include -I Vendor/lexilla/include -F build/vendor/Debug -c Sources/EditorBridge/TTEditor.mm -o build/tests/UtilityBridge.o
suite_build "utility-checks" swiftc "${SWIFT_WARNING_FLAGS[@]}" Sources/Documents/FailureContext.swift -target arm64-apple-macos14.0 -module-cache-path build/ModuleCache -import-objc-header Sources/EditorBridge/TTEditor.h -F build/vendor/Debug -framework Scintilla Sources/UI/*.swift -framework Cocoa -Xlinker -rpath -Xlinker "$PWD/build/vendor/Debug" Sources/Utilities/*.swift "$SUITE_SUPPORT" Tests/UtilityChecks.swift build/tests/UtilityBridge.o build/tests/UserLexer.o Vendor/lexilla/bin/liblexilla.a -lc++ -o build/tests/utility-checks
suite_run utility-checks harness/logs/utility-checks.log build/tests/utility-checks
suite_finish
