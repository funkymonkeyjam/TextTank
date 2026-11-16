#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_require_build
suite_build "search-checks" swiftc "${SWIFT_BASE[@]}" "$SUITE_SUPPORT" Tests/SearchChecks.swift Tests/SearchSessionChecks.swift -Xlinker "$NATIVE_SEARCH_LIBRARY" -lc++ -o build/tests/search-checks
suite_run search-checks harness/logs/search-checks.log build/tests/search-checks
suite_build "search-controller-checks" swiftc "${SWIFT_BASE[@]}" -F "$VENDOR_BUILD" -framework Scintilla -framework Cocoa -Xlinker -rpath -Xlinker "$VENDOR_BUILD" "$SUITE_SUPPORT" Tests/Support/ModelessForms.swift Tests/SearchControllerChecks.swift -Xlinker "$NATIVE_BRIDGE_LIBRARY" -Xlinker "$NATIVE_SEARCH_LIBRARY" -lc++ -o build/tests/search-controller-checks
suite_run search-controller-checks harness/logs/search-controller-checks.log build/tests/search-controller-checks
suite_build "search-replacement-checks" swiftc "${SWIFT_BASE[@]}" "$SUITE_SUPPORT" Tests/SearchReplacementChecks.swift -Xlinker "$NATIVE_SEARCH_LIBRARY" -lc++ -o build/tests/search-replacement-checks
suite_run search-replacement-checks harness/logs/search-replacement-checks.log build/tests/search-replacement-checks
suite_build "search-scope-checks" swiftc "${SWIFT_BASE[@]}" "$SUITE_SUPPORT" Tests/SearchScopeChecks.swift -Xlinker "$NATIVE_SEARCH_LIBRARY" -lc++ -o build/tests/search-scope-checks
suite_run search-scope-checks harness/logs/search-scope-checks.log build/tests/search-scope-checks
suite_finish
