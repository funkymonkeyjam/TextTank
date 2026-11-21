#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_require_build
suite_build "workspace-browser-checks" swiftc "${SWIFT_BASE[@]}" -F "$VENDOR_BUILD" -framework Scintilla -framework Cocoa -framework EventKit -lc++ -Xlinker -rpath -Xlinker "$VENDOR_BUILD" "$SUITE_SUPPORT" Tests/Support/ModelessForms.swift Tests/ExternalFileObservationChecks.swift Tests/ExternalFilePolicyChecks.swift Tests/WorkspaceBrowserChecks.swift -Xlinker "$NATIVE_BRIDGE_LIBRARY" -Xlinker "$NATIVE_SEARCH_LIBRARY" -o build/tests/workspace-browser-checks
suite_run workspace-browser-checks harness/logs/workspace-browser-checks.log build/tests/workspace-browser-checks
suite_finish
