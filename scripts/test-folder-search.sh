#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_require_build
suite_build "folder-search-checks" swiftc -swift-version 5 "${SWIFT_BASE[@]}" "$SUITE_SUPPORT" Tests/FolderSearchChecks.swift -Xlinker "$NATIVE_SEARCH_LIBRARY" -lc++ -o build/tests/folder-search-checks
suite_run folder-search-checks harness/logs/folder-search-checks.log build/tests/folder-search-checks
suite_build "folder-search-controller-checks" swiftc -swift-version 5 "${SWIFT_BASE[@]}" -F "$VENDOR_BUILD" -framework Scintilla -framework Cocoa -framework EventKit -lc++ -Xlinker -rpath -Xlinker "$VENDOR_BUILD" "$SUITE_SUPPORT" Tests/Support/ModelessForms.swift Tests/FolderSearchControllerChecks.swift -Xlinker "$NATIVE_BRIDGE_LIBRARY" -Xlinker "$NATIVE_SEARCH_LIBRARY" -o build/tests/folder-search-controller-checks
suite_run folder-search-controller-checks harness/logs/folder-search-controller-checks.log build/tests/folder-search-controller-checks
suite_finish
