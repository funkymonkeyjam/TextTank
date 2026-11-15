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
suite_build "language-checks" swiftc Sources/Documents/FailureContext.swift "${SWIFT_BASE[@]}" Sources/Languages/LanguageCore.swift Sources/Languages/UserDefinedLanguage.swift "$SUITE_SUPPORT" Tests/LanguageChecks.swift -o build/tests/language-checks
suite_run language-checks harness/logs/language-checks.log build/tests/language-checks
suite_build "language-controller-checks comment-checks" build_bridge_object
suite_build "language-controller-checks" swiftc Sources/Documents/FailureContext.swift "${SWIFT_BASE[@]}" -import-objc-header Sources/EditorBridge/TTEditor.h -F "$VENDOR_BUILD" -framework Scintilla Sources/UI/*.swift -framework Cocoa -Xlinker -rpath -Xlinker "$VENDOR_BUILD" Sources/Languages/*.swift "$SUITE_SUPPORT" Tests/LanguageControllerChecks.swift "$BRIDGE_OBJECT" "$USER_LEXER_OBJECT" "$LEXILLA_LIBRARY" -lc++ -o build/tests/language-controller-checks
suite_run language-controller-checks harness/logs/language-controller-checks.log build/tests/language-controller-checks
suite_build "comment-checks" swiftc Sources/Documents/FailureContext.swift "${SWIFT_BASE[@]}" -import-objc-header Sources/EditorBridge/TTEditor.h -F "$VENDOR_BUILD" -framework Scintilla Sources/UI/*.swift -framework Cocoa -Xlinker -rpath -Xlinker "$VENDOR_BUILD" Sources/Languages/LanguageCore.swift Sources/Languages/UserDefinedLanguage.swift Sources/Documents/CommentCommands.swift "$SUITE_SUPPORT" Tests/CommentCommandChecks.swift "$BRIDGE_OBJECT" "$USER_LEXER_OBJECT" "$LEXILLA_LIBRARY" -lc++ -o build/tests/comment-checks
suite_run comment-checks harness/logs/comment-checks.log build/tests/comment-checks
suite_finish
