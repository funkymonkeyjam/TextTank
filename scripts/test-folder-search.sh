#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_require_build
suite_build "folder-search-checks folder-search-controller-checks" scripts/build-user-lexer.sh
suite_build "folder-search-checks" clang++ -std=c++17 -fobjc-arc -mmacosx-version-min=14.0 -I Sources/Search/Boost -c Sources/Search/TTSearchEngine.mm -o build/tests/BoostSearch.o
suite_build "folder-search-checks" swiftc "${SWIFT_WARNING_FLAGS[@]}" Sources/Documents/FailureContext.swift -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path build/ModuleCache -import-objc-header Sources/Search/TTSearchEngine.h Sources/Documents/FileCodec.swift Sources/Search/SearchCore.swift Sources/Search/FolderSearchFilters.swift Sources/Search/FolderSearch.swift "$SUITE_SUPPORT" Tests/FolderSearchChecks.swift build/tests/BoostSearch.o -lc++ -o build/tests/folder-search-checks
suite_run folder-search-checks harness/logs/folder-search-checks.log build/tests/folder-search-checks
suite_build "folder-search-controller-checks" clang++ -std=c++17 -fobjc-arc -mmacosx-version-min=14.0 -I Sources/EditorBridge -I Vendor/scintilla/cocoa -I Vendor/scintilla/include -I Vendor/lexilla/include -F build/vendor/Debug -c Sources/EditorBridge/TTEditor.mm -o build/tests/SearchBridge.o
suite_build "folder-search-controller-checks" clang++ -std=c++17 -fobjc-arc -mmacosx-version-min=14.0 -I Sources/Search/Boost -c Sources/Search/TTSearchEngine.mm -o build/tests/BoostSearch.o
suite_build "folder-search-controller-checks" swiftc "${SWIFT_WARNING_FLAGS[@]}" -swift-version 5 -D TESTING -target arm64-apple-macos14.0 -module-cache-path build/ModuleCache -import-objc-header Sources/EditorBridge/TTEditor.h -F build/vendor/Debug -framework Scintilla Sources/UI/*.swift -framework Cocoa -framework EventKit -lc++ -Xlinker -rpath -Xlinker "$PWD/build/vendor/Debug" Sources/Languages/*.swift Sources/Run/*.swift Sources/Utilities/*.swift Sources/Search/*.swift Sources/Workspace/*.swift Sources/Macros/*.swift Sources/Documents/*.swift Sources/Automations/*.swift Sources/Connectors/*.swift Sources/TextTankApp/*.swift "$SUITE_SUPPORT" Tests/FolderSearchControllerChecks.swift build/tests/SearchBridge.o build/tests/BoostSearch.o build/tests/UserLexer.o Vendor/lexilla/bin/liblexilla.a -o build/tests/folder-search-controller-checks
suite_run folder-search-controller-checks harness/logs/folder-search-controller-checks.log build/tests/folder-search-controller-checks
suite_finish
