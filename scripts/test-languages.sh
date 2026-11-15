#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_require_build
# G331/F324: the port's recorded hashes, its patch against the pinned upstream file and its build
# flags. Set TEXTTANK_NOTEPAD_SOURCE to an upstream checkout to compare with the source files too.
suite_run user-lexer-port harness/logs/user-lexer-port.log python3 scripts/check-user-lexer-port.py
suite_build "language-checks language-controller-checks comment-checks" scripts/build-user-lexer.sh
suite_build "language-checks" swiftc "${SWIFT_WARNING_FLAGS[@]}" Sources/Documents/FailureContext.swift -target arm64-apple-macos14.0 -module-cache-path build/ModuleCache Sources/Languages/LanguageCore.swift Sources/Languages/UserDefinedLanguage.swift "$SUITE_SUPPORT" Tests/LanguageChecks.swift -o build/tests/language-checks
suite_run language-checks harness/logs/language-checks.log build/tests/language-checks
suite_build "language-controller-checks comment-checks" clang++ -std=c++17 -fobjc-arc -mmacosx-version-min=14.0 -I Sources/EditorBridge -I Vendor/scintilla/cocoa -I Vendor/scintilla/include -I Vendor/lexilla/include -F build/vendor/Debug -c Sources/EditorBridge/TTEditor.mm -o build/tests/LanguageBridge.o
suite_build "language-controller-checks" swiftc "${SWIFT_WARNING_FLAGS[@]}" Sources/Documents/FailureContext.swift -target arm64-apple-macos14.0 -module-cache-path build/ModuleCache -import-objc-header Sources/EditorBridge/TTEditor.h -F build/vendor/Debug -framework Scintilla Sources/UI/*.swift -framework Cocoa -Xlinker -rpath -Xlinker "$PWD/build/vendor/Debug" Sources/Languages/*.swift "$SUITE_SUPPORT" Tests/LanguageControllerChecks.swift build/tests/LanguageBridge.o build/tests/UserLexer.o Vendor/lexilla/bin/liblexilla.a -lc++ -o build/tests/language-controller-checks
suite_run language-controller-checks harness/logs/language-controller-checks.log build/tests/language-controller-checks
suite_build "comment-checks" swiftc "${SWIFT_WARNING_FLAGS[@]}" Sources/Documents/FailureContext.swift -target arm64-apple-macos14.0 -module-cache-path build/ModuleCache -import-objc-header Sources/EditorBridge/TTEditor.h -F build/vendor/Debug -framework Scintilla Sources/UI/*.swift -framework Cocoa -Xlinker -rpath -Xlinker "$PWD/build/vendor/Debug" Sources/Languages/LanguageCore.swift Sources/Languages/UserDefinedLanguage.swift Sources/Documents/CommentCommands.swift "$SUITE_SUPPORT" Tests/CommentCommandChecks.swift build/tests/LanguageBridge.o build/tests/UserLexer.o Vendor/lexilla/bin/liblexilla.a -lc++ -o build/tests/comment-checks
suite_run comment-checks harness/logs/comment-checks.log build/tests/comment-checks
suite_finish
