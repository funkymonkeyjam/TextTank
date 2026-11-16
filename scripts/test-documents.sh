#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_require_build
suite_build "document-checks design-settings-input-checks" swiftc -swift-version 5 -D TESTING "${SWIFT_BASE[@]}" -import-objc-header Sources/TextTankApp/TextTank-Bridging-Header.h -F "$VENDOR_BUILD" -framework Scintilla Sources/UI/*.swift -framework Cocoa -framework EventKit -lc++ -Xlinker -rpath -Xlinker "$VENDOR_BUILD" "${APP_SOURCES[@]}" "$SUITE_SUPPORT" Tests/Support/ModelessForms.swift Tests/Support/UnicodeFixtures.swift Tests/DocumentChecks.swift Tests/DocumentPinningChecks.swift Tests/DocumentOpenSaveChecks.swift Tests/DocumentSplitViewChecks.swift Tests/DocumentWindowMenuChecks.swift Tests/SettingsShortcutValidationChecks.swift Tests/Audit26PresentationChecks.swift Tests/Audit29ServiceChecks.swift Tests/Audit29FactoryChecks.swift Tests/DocumentCoreChecks.swift Tests/Audit29IntentChecks.swift Tests/ToolbarChecks.swift Tests/DesignSettingsChecks.swift Tests/DesignStatusChecks.swift -Xlinker "$NATIVE_BRIDGE_LIBRARY" -Xlinker "$NATIVE_SEARCH_LIBRARY" -o build/tests/document-checks
suite_run document-checks harness/logs/document-checks.log build/tests/document-checks
# Both native processes are required, even if the first fails. Share compilation,
# not AppKit state; neither result can replace the other's completion marker.
suite_run design-settings-input-checks harness/logs/design-settings-input-checks.log build/tests/document-checks --configuration-input-accessibility
suite_finish
