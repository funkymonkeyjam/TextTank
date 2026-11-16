#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_require_build
suite_build "automation-controller-checks" scripts/build-user-lexer.sh
suite_build "automation-controller-checks" build_bridge_object
suite_build "automation-controller-checks" swiftc Sources/Documents/Strings.swift Sources/Documents/FailureContext.swift Sources/Documents/PrivateFileStore.swift Sources/Documents/VersionedLibrary.swift -swift-version 5 "${SWIFT_BASE[@]}" -import-objc-header Sources/EditorBridge/TTEditor.h -F "$VENDOR_BUILD" -framework Scintilla Sources/UI/*.swift -framework Cocoa -framework EventKit -lc++ -Xlinker -rpath -Xlinker "$VENDOR_BUILD" Sources/Automations/*.swift Sources/Documents/LineOrder.swift Sources/Connectors/*.swift "$SUITE_SUPPORT" Tests/Support/ModelessForms.swift Tests/AutomationControllerChecks.swift "$BRIDGE_OBJECT" "$USER_LEXER_OBJECT" "$LEXILLA_LIBRARY" -o build/tests/automation-controller-checks
suite_run automation-controller-checks harness/logs/automation-controller-checks.log build/tests/automation-controller-checks
suite_finish
