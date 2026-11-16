#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_require_build
suite_build "folder-search-checks" swiftc Sources/Documents/Strings.swift Sources/Documents/FailureContext.swift Sources/Documents/PrivateFileStore.swift -swift-version 5 "${SWIFT_BASE[@]}" -import-objc-header Sources/Search/TTSearchEngine.h Sources/Documents/FileCodec.swift Sources/Search/SearchCore.swift Sources/Search/FolderSearchFilters.swift Sources/Search/FolderSearch.swift "$SUITE_SUPPORT" Tests/FolderSearchChecks.swift -Xlinker "$NATIVE_SEARCH_LIBRARY" -lc++ -o build/tests/folder-search-checks
suite_run folder-search-checks harness/logs/folder-search-checks.log build/tests/folder-search-checks
suite_build "folder-search-controller-checks" swiftc -swift-version 5 -D TESTING "${SWIFT_BASE[@]}" -import-objc-header Sources/TextTankApp/TextTank-Bridging-Header.h -F "$VENDOR_BUILD" -framework Scintilla Sources/UI/*.swift -framework Cocoa -framework EventKit -lc++ -Xlinker -rpath -Xlinker "$VENDOR_BUILD" "${APP_SOURCES[@]}" "$SUITE_SUPPORT" Tests/Support/ModelessForms.swift Tests/FolderSearchControllerChecks.swift -Xlinker "$NATIVE_BRIDGE_LIBRARY" -Xlinker "$NATIVE_SEARCH_LIBRARY" -o build/tests/folder-search-controller-checks
suite_run folder-search-controller-checks harness/logs/folder-search-controller-checks.log build/tests/folder-search-controller-checks
suite_finish
