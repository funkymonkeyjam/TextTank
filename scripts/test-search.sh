#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests harness/logs
scripts/build-user-lexer.sh
clang++ -std=c++17 -fobjc-arc -mmacosx-version-min=14.0 -I Sources/Search/Boost -c Sources/Search/TTSearchEngine.mm -o build/tests/BoostSearch.o
swiftc -target arm64-apple-macos14.0 -module-cache-path build/ModuleCache -import-objc-header Sources/Search/TTSearchEngine.h Sources/Search/SearchCore.swift Tests/SearchChecks.swift build/tests/BoostSearch.o -lc++ -o build/tests/search-checks
build/tests/search-checks | tee harness/logs/search-checks.log
clang++ -std=c++17 -fobjc-arc -mmacosx-version-min=14.0 -I Sources/EditorBridge -I Vendor/scintilla/cocoa -I Vendor/scintilla/include -I Vendor/lexilla/include -F build/vendor/Debug -c Sources/EditorBridge/TTEditor.mm -o build/tests/SearchNativeBridge.o
swiftc -target arm64-apple-macos14.0 -module-cache-path build/ModuleCache -import-objc-header Sources/EditorBridge/TTEditor.h -F build/vendor/Debug -framework Scintilla Sources/UI/*.swift -framework Cocoa -Xlinker -rpath -Xlinker "$PWD/build/vendor/Debug" Sources/Search/SearchCore.swift Sources/Search/SearchController.swift Tests/SearchControllerChecks.swift build/tests/SearchNativeBridge.o build/tests/BoostSearch.o build/tests/UserLexer.o Vendor/lexilla/bin/liblexilla.a -lc++ -o build/tests/search-controller-checks
build/tests/search-controller-checks | tee harness/logs/search-controller-checks.log
swiftc -target arm64-apple-macos14.0 -module-cache-path build/ModuleCache -import-objc-header Sources/Search/TTSearchEngine.h Sources/Documents/FileCodec.swift Sources/Search/SearchCore.swift Sources/Search/FolderSearchFilters.swift Sources/Search/FolderSearch.swift Sources/Search/FolderReplacement.swift Tests/SearchReplacementChecks.swift build/tests/BoostSearch.o -lc++ -o build/tests/search-replacement-checks
build/tests/search-replacement-checks | tee harness/logs/search-replacement-checks.log
swiftc -target arm64-apple-macos14.0 -module-cache-path build/ModuleCache -import-objc-header Sources/Search/TTSearchEngine.h Sources/Documents/FileCodec.swift Sources/Search/SearchCore.swift Sources/Search/FolderSearchFilters.swift Sources/Search/FolderSearch.swift Tests/SearchScopeChecks.swift build/tests/BoostSearch.o -lc++ -o build/tests/search-scope-checks
build/tests/search-scope-checks | tee harness/logs/search-scope-checks.log
