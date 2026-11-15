#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests harness/logs
scripts/build-user-lexer.sh
clang++ -std=c++17 -fobjc-arc -mmacosx-version-min=14.0 -I Sources/EditorBridge -I Vendor/scintilla/cocoa -I Vendor/scintilla/include -I Vendor/lexilla/include -F build/vendor/Debug -c Sources/EditorBridge/TTEditor.mm -o build/tests/UtilityBridge.o
swiftc -D NATIVE_UTILITY_CHECKS -target arm64-apple-macos14.0 -module-cache-path build/ModuleCache -import-objc-header Sources/EditorBridge/TTEditor.h -F build/vendor/Debug -framework Scintilla Sources/UI/*.swift -framework Cocoa -Xlinker -rpath -Xlinker "$PWD/build/vendor/Debug" Sources/Utilities/*.swift Tests/UtilityChecks.swift build/tests/UtilityBridge.o build/tests/UserLexer.o Vendor/lexilla/bin/liblexilla.a -lc++ -o build/tests/utility-checks
build/tests/utility-checks | tee harness/logs/utility-checks.log
