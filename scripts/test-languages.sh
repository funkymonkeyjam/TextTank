#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests harness/logs
scripts/build-user-lexer.sh
swiftc -target arm64-apple-macos14.0 -module-cache-path build/ModuleCache Sources/Languages/LanguageCore.swift Sources/Languages/UserDefinedLanguage.swift Tests/LanguageChecks.swift -o build/tests/language-checks
build/tests/language-checks | tee harness/logs/language-checks.log
clang++ -std=c++17 -fobjc-arc -mmacosx-version-min=14.0 -I Sources/EditorBridge -I Vendor/scintilla/cocoa -I Vendor/scintilla/include -I Vendor/lexilla/include -F build/vendor/Debug -c Sources/EditorBridge/TTEditor.mm -o build/tests/LanguageBridge.o
swiftc -target arm64-apple-macos14.0 -module-cache-path build/ModuleCache -import-objc-header Sources/EditorBridge/TTEditor.h -F build/vendor/Debug -framework Scintilla -framework Cocoa -Xlinker -rpath -Xlinker "$PWD/build/vendor/Debug" Sources/Languages/*.swift Tests/LanguageControllerChecks.swift build/tests/LanguageBridge.o build/tests/UserLexer.o Vendor/lexilla/bin/liblexilla.a -lc++ -o build/tests/language-controller-checks
build/tests/language-controller-checks | tee harness/logs/language-controller-checks.log
swiftc -target arm64-apple-macos14.0 -module-cache-path build/ModuleCache -import-objc-header Sources/EditorBridge/TTEditor.h -F build/vendor/Debug -framework Scintilla -framework Cocoa -Xlinker -rpath -Xlinker "$PWD/build/vendor/Debug" Sources/Languages/LanguageCore.swift Sources/Languages/UserDefinedLanguage.swift Sources/Documents/CommentCommands.swift Tests/CommentCommandChecks.swift build/tests/LanguageBridge.o build/tests/UserLexer.o Vendor/lexilla/bin/liblexilla.a -lc++ -o build/tests/comment-checks
build/tests/comment-checks | tee harness/logs/comment-checks.log
