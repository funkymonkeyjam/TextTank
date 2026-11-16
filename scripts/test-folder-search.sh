#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_require_build
suite_build "folder-search-checks folder-search-controller-checks" scripts/build-user-lexer.sh
suite_build "folder-search-checks" build_search_object
suite_build "folder-search-checks" swiftc Sources/Documents/Strings.swift Sources/Documents/FailureContext.swift Sources/Documents/PrivateFileStore.swift -swift-version 5 "${SWIFT_BASE[@]}" -import-objc-header Sources/Search/TTSearchEngine.h Sources/Documents/FileCodec.swift Sources/Search/SearchCore.swift Sources/Search/FolderSearchFilters.swift Sources/Search/FolderSearch.swift "$SUITE_SUPPORT" Tests/FolderSearchChecks.swift "$SEARCH_OBJECT" -lc++ -o build/tests/folder-search-checks
suite_run folder-search-checks harness/logs/folder-search-checks.log build/tests/folder-search-checks
suite_build "folder-search-controller-checks" build_bridge_object
suite_build "folder-search-controller-checks" build_search_object
suite_build "folder-search-controller-checks" swiftc -swift-version 5 -D TESTING "${SWIFT_BASE[@]}" -import-objc-header Sources/EditorBridge/TTEditor.h -F "$VENDOR_BUILD" -framework Scintilla Sources/UI/*.swift -framework Cocoa -framework EventKit -lc++ -Xlinker -rpath -Xlinker "$VENDOR_BUILD" "${APP_SOURCES[@]}" "$SUITE_SUPPORT" Tests/FolderSearchControllerChecks.swift "$BRIDGE_OBJECT" "$SEARCH_OBJECT" "$USER_LEXER_OBJECT" "$LEXILLA_LIBRARY" -o build/tests/folder-search-controller-checks
suite_run folder-search-controller-checks harness/logs/folder-search-controller-checks.log build/tests/folder-search-controller-checks
suite_finish
