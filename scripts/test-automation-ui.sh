#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_require_build
suite_build "automation-controller-checks" scripts/build-user-lexer.sh
suite_build "automation-controller-checks" clang++ -std=c++17 -fobjc-arc -mmacosx-version-min=14.0   -I Sources/EditorBridge -I Vendor/scintilla/cocoa -I Vendor/scintilla/include -I Vendor/lexilla/include -F build/vendor/Debug -c Sources/EditorBridge/TTEditor.mm -o build/tests/AutomationBridge.o
suite_build "automation-controller-checks" swiftc Sources/Documents/FailureContext.swift -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path build/ModuleCache   -import-objc-header Sources/EditorBridge/TTEditor.h -F build/vendor/Debug   -framework Scintilla Sources/UI/*.swift -framework Cocoa -framework EventKit -lc++   -Xlinker -rpath -Xlinker "$PWD/build/vendor/Debug"   Sources/Automations/*.swift Sources/Documents/LineOrder.swift Sources/Connectors/*.swift   "$SUITE_SUPPORT" Tests/AutomationControllerChecks.swift build/tests/AutomationBridge.o build/tests/UserLexer.o Vendor/lexilla/bin/liblexilla.a -o build/tests/automation-controller-checks
suite_run automation-controller-checks harness/logs/automation-controller-checks.log build/tests/automation-controller-checks
suite_finish
