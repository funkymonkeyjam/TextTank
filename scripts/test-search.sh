#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_require_build
suite_build "search-checks search-controller-checks search-replacement-checks search-scope-checks" scripts/build-user-lexer.sh
suite_build "search-checks search-controller-checks search-replacement-checks search-scope-checks" build_search_object
suite_build "search-checks" swiftc Sources/Documents/Strings.swift Sources/Documents/FailureContext.swift Sources/Documents/PrivateFileStore.swift "${SWIFT_BASE[@]}" -import-objc-header Sources/Search/TTSearchEngine.h Sources/Search/SearchCore.swift Sources/Search/SearchSession.swift "$SUITE_SUPPORT" Tests/SearchChecks.swift Tests/SearchSessionChecks.swift "$SEARCH_OBJECT" -lc++ -o build/tests/search-checks
suite_run search-checks harness/logs/search-checks.log build/tests/search-checks
suite_build "search-controller-checks" build_bridge_object
suite_build "search-controller-checks" swiftc Sources/Documents/Strings.swift Sources/Documents/FailureContext.swift Sources/Documents/PrivateFileStore.swift Sources/Documents/VersionedLibrary.swift "${SWIFT_BASE[@]}" -import-objc-header Sources/TextTankApp/TextTank-Bridging-Header.h -F "$VENDOR_BUILD" -framework Scintilla Sources/UI/*.swift -framework Cocoa -Xlinker -rpath -Xlinker "$VENDOR_BUILD" Sources/Search/SearchCore.swift Sources/Search/SearchController.swift Sources/Search/SearchSession.swift "$SUITE_SUPPORT" Tests/Support/ModelessForms.swift Tests/SearchControllerChecks.swift "$BRIDGE_OBJECT" "$SEARCH_OBJECT" "$USER_LEXER_OBJECT" "$LEXILLA_LIBRARY" -lc++ -o build/tests/search-controller-checks
suite_run search-controller-checks harness/logs/search-controller-checks.log build/tests/search-controller-checks
suite_build "search-replacement-checks" swiftc Sources/Documents/Strings.swift Sources/Documents/FailureContext.swift Sources/Documents/PrivateFileStore.swift "${SWIFT_BASE[@]}" -import-objc-header Sources/Search/TTSearchEngine.h Sources/Documents/FileCodec.swift Sources/Search/SearchCore.swift Sources/Search/FolderSearchFilters.swift Sources/Search/FolderSearch.swift Sources/Search/FolderReplacement.swift "$SUITE_SUPPORT" Tests/SearchReplacementChecks.swift "$SEARCH_OBJECT" -lc++ -o build/tests/search-replacement-checks
suite_run search-replacement-checks harness/logs/search-replacement-checks.log build/tests/search-replacement-checks
suite_build "search-scope-checks" swiftc Sources/Documents/Strings.swift Sources/Documents/FailureContext.swift Sources/Documents/PrivateFileStore.swift "${SWIFT_BASE[@]}" -import-objc-header Sources/Search/TTSearchEngine.h Sources/Documents/FileCodec.swift Sources/Search/SearchCore.swift Sources/Search/FolderSearchFilters.swift Sources/Search/FolderSearch.swift "$SUITE_SUPPORT" Tests/SearchScopeChecks.swift "$SEARCH_OBJECT" -lc++ -o build/tests/search-scope-checks
suite_run search-scope-checks harness/logs/search-scope-checks.log build/tests/search-scope-checks
suite_finish
