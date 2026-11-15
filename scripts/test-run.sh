#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_require_build
suite_build "run-checks run-controller-checks" scripts/build-user-lexer.sh
suite_build "run-checks" swiftc -target arm64-apple-macos14.0 -module-cache-path build/ModuleCache Sources/Run/RunCore.swift "$SUITE_SUPPORT" Tests/RunChecks.swift -o build/tests/run-checks
suite_run run-checks harness/logs/run-checks.log build/tests/run-checks
suite_build "run-controller-checks" clang++ -std=c++17 -fobjc-arc -mmacosx-version-min=14.0 -I Sources/EditorBridge -I Vendor/scintilla/cocoa -I Vendor/scintilla/include -I Vendor/lexilla/include -F build/vendor/Debug -c Sources/EditorBridge/TTEditor.mm -o build/tests/RunBridge.o
suite_build "run-controller-checks" clang++ -std=c++17 -fobjc-arc -mmacosx-version-min=14.0 -I Sources/Search/Boost -c Sources/Search/TTSearchEngine.mm -o build/tests/RunSearch.o
suite_build "run-controller-checks" swiftc -D TESTING -target arm64-apple-macos14.0 -module-cache-path build/ModuleCache -import-objc-header Sources/EditorBridge/TTEditor.h -F build/vendor/Debug -framework Scintilla Sources/UI/*.swift -framework Cocoa -framework EventKit -lc++ -Xlinker -rpath -Xlinker "$PWD/build/vendor/Debug" Sources/Languages/*.swift Sources/Run/*.swift Sources/Utilities/*.swift Sources/Search/*.swift Sources/Workspace/*.swift Sources/Macros/*.swift Sources/Documents/*.swift Sources/Automations/*.swift Sources/Connectors/*.swift Sources/TextTankApp/*.swift "$SUITE_SUPPORT" Tests/RunControllerChecks.swift build/tests/RunBridge.o build/tests/RunSearch.o build/tests/UserLexer.o Vendor/lexilla/bin/liblexilla.a -o build/tests/run-controller-checks
suite_run run-controller-checks harness/logs/run-controller-checks.log build/tests/run-controller-checks
suite_finish
