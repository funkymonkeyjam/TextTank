#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests harness/logs
scripts/build-user-lexer.sh
clang++ -std=c++17 -fobjc-arc -mmacosx-version-min=14.0 \
  -I Sources/EditorBridge -I Vendor/scintilla/cocoa -I Vendor/scintilla/include -I Vendor/lexilla/include \
  -F build/vendor/Debug -c Sources/EditorBridge/TTEditor.mm -o build/tests/AutomationBridge.o
swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path build/ModuleCache \
  -import-objc-header Sources/EditorBridge/TTEditor.h -F build/vendor/Debug \
  -framework Scintilla -framework Cocoa -framework EventKit -lc++ \
  -Xlinker -rpath -Xlinker "$PWD/build/vendor/Debug" \
  Sources/Automations/*.swift Sources/Connectors/*.swift \
  Tests/AutomationControllerChecks.swift build/tests/AutomationBridge.o build/tests/UserLexer.o Vendor/lexilla/bin/liblexilla.a \
  -o build/tests/automation-controller-checks
build/tests/automation-controller-checks 2>&1 | tee harness/logs/automation-controller-checks.log
