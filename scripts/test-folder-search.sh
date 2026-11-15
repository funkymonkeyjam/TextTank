#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests harness/logs
scripts/build-user-lexer.sh
clang++ -std=c++17 -fobjc-arc -mmacosx-version-min=14.0 -I Sources/Search/Boost -c Sources/Search/TTSearchEngine.mm -o build/tests/BoostSearch.o
swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path build/ModuleCache -import-objc-header Sources/Search/TTSearchEngine.h Sources/Documents/FileCodec.swift Sources/Search/SearchCore.swift Sources/Search/FolderSearchFilters.swift Sources/Search/FolderSearch.swift Tests/FolderSearchChecks.swift build/tests/BoostSearch.o -lc++ -o build/tests/folder-search-checks
build/tests/folder-search-checks | tee harness/logs/folder-search-checks.log
clang++ -std=c++17 -fobjc-arc -mmacosx-version-min=14.0 -I Sources/EditorBridge -I Vendor/scintilla/cocoa -I Vendor/scintilla/include -I Vendor/lexilla/include -F build/vendor/Debug -c Sources/EditorBridge/TTEditor.mm -o build/tests/SearchBridge.o
clang++ -std=c++17 -fobjc-arc -mmacosx-version-min=14.0 -I Sources/Search/Boost -c Sources/Search/TTSearchEngine.mm -o build/tests/BoostSearch.o
swiftc -swift-version 5 -D TESTING -target arm64-apple-macos14.0 -module-cache-path build/ModuleCache -import-objc-header Sources/EditorBridge/TTEditor.h -F build/vendor/Debug -framework Scintilla Sources/UI/*.swift -framework Cocoa -framework EventKit -lc++ -Xlinker -rpath -Xlinker "$PWD/build/vendor/Debug" Sources/Languages/*.swift Sources/Run/*.swift Sources/Utilities/*.swift Sources/Search/*.swift Sources/Workspace/*.swift Sources/Macros/*.swift Sources/Documents/*.swift Sources/Automations/*.swift Sources/Connectors/*.swift Sources/TextTankApp/*.swift Tests/FolderSearchControllerChecks.swift build/tests/SearchBridge.o build/tests/BoostSearch.o build/tests/UserLexer.o Vendor/lexilla/bin/liblexilla.a -o build/tests/folder-search-controller-checks
build/tests/folder-search-controller-checks 2>&1 | tee harness/logs/folder-search-controller-checks.log
