#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests harness/logs
scripts/build-user-lexer.sh
clang++ -std=c++17 -fobjc-arc -mmacosx-version-min=14.0 -I Sources/EditorBridge -I Vendor/scintilla/cocoa -I Vendor/scintilla/include -I Vendor/lexilla/include -F build/vendor/Debug -framework Scintilla -framework Cocoa Sources/EditorBridge/TTEditor.mm Tests/PerformanceChecks.mm build/tests/UserLexer.o Vendor/lexilla/bin/liblexilla.a -Wl,-rpath,"$PWD/build/vendor/Debug" -o build/tests/performance-checks
build/tests/performance-checks | tee harness/logs/performance-checks.log
