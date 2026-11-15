#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_require_build
suite_build "performance-checks" scripts/build-user-lexer.sh
suite_build "performance-checks" clang++ -std=c++17 -fobjc-arc -mmacosx-version-min=14.0 -I Tests/Support -I Sources/EditorBridge -I Vendor/scintilla/cocoa -I Vendor/scintilla/include -I Vendor/lexilla/include -F build/vendor/Debug -framework Scintilla -framework Cocoa Sources/EditorBridge/TTEditor.mm Tests/PerformanceChecks.mm build/tests/UserLexer.o Vendor/lexilla/bin/liblexilla.a -Wl,-rpath,"$PWD/build/vendor/Debug" -o build/tests/performance-checks
suite_run performance-checks harness/logs/performance-checks.log build/tests/performance-checks
suite_finish
