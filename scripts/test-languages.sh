#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_require_build
# G331/F324: the port's recorded hashes, its patch against the pinned upstream file and its build
# flags. Set TEXTTANK_NOTEPAD_SOURCE to an upstream checkout to compare with the source files too.
suite_run user-lexer-port harness/logs/user-lexer-port.log python3 scripts/check-user-lexer-port.py
suite_build "language-checks" swiftc "${SWIFT_BASE[@]}" "$SUITE_SUPPORT" Tests/LanguageChecks.swift -o build/tests/language-checks
suite_run language-checks harness/logs/language-checks.log build/tests/language-checks
suite_build "language-controller-checks" swiftc "${SWIFT_BASE[@]}" -F "$VENDOR_BUILD" -framework Scintilla -framework Cocoa -Xlinker -rpath -Xlinker "$VENDOR_BUILD" "$SUITE_SUPPORT" Tests/Support/ModelessForms.swift Tests/LanguageControllerChecks.swift -Xlinker "$NATIVE_BRIDGE_LIBRARY" -lc++ -o build/tests/language-controller-checks
suite_run language-controller-checks harness/logs/language-controller-checks.log build/tests/language-controller-checks
suite_build "comment-checks" swiftc "${SWIFT_BASE[@]}" -F "$VENDOR_BUILD" -framework Scintilla -framework Cocoa -Xlinker -rpath -Xlinker "$VENDOR_BUILD" "$SUITE_SUPPORT" Tests/Support/ModelessForms.swift Tests/CommentCommandChecks.swift -Xlinker "$NATIVE_BRIDGE_LIBRARY" -lc++ -o build/tests/comment-checks
suite_run comment-checks harness/logs/comment-checks.log build/tests/comment-checks
suite_finish
