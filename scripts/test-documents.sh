#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_require_build
suite_build "document-checks design-settings-input-checks tab-workspace-checks" swiftc -swift-version 5 "${SWIFT_BASE[@]}" -F "$VENDOR_BUILD" -framework Scintilla -framework Cocoa -framework EventKit -lc++ -Xlinker -rpath -Xlinker "$VENDOR_BUILD" "$SUITE_SUPPORT" Tests/Support/ModelessForms.swift Tests/Support/UnicodeFixtures.swift Tests/DocumentChecks.swift Tests/TabWorkspaceNativeChecks.swift Tests/DocumentPinningChecks.swift Tests/DocumentOpenSaveChecks.swift Tests/DocumentSplitViewChecks.swift Tests/DocumentWindowMenuChecks.swift Tests/SettingsShortcutValidationChecks.swift Tests/Audit26PresentationChecks.swift Tests/Audit29ServiceChecks.swift Tests/Audit29FactoryChecks.swift Tests/DocumentCoreChecks.swift Tests/Audit29IntentChecks.swift Tests/ToolbarChecks.swift Tests/DesignSettingsChecks.swift Tests/DesignStatusChecks.swift -Xlinker "$NATIVE_BRIDGE_LIBRARY" -Xlinker "$NATIVE_SEARCH_LIBRARY" -o build/tests/document-checks
suite_run document-checks harness/logs/document-checks.log build/tests/document-checks
# Both native processes are required, even if the first fails. Share compilation,
# not AppKit state; neither result can replace the other's completion marker.
suite_run design-settings-input-checks harness/logs/design-settings-input-checks.log build/tests/document-checks --configuration-input-accessibility
workspace_client=build/tests/document-checks
if [[ "$SUITE_BROKEN" != *" tab-workspace-checks "* ]]; then
  if workspace_client=$(python3 scripts/prepare-native-check-app.py --executable build/tests/document-checks --application "$APP_PATH"); then
    :
  else
    preparation_status=$?
    suite_record "BUILD-FAILED" "tab-workspace-checks" "native app context preparation exit $preparation_status"
    SUITE_BROKEN="$SUITE_BROKEN tab-workspace-checks "
  fi
fi
# The copied client is byte-identical and remains under build/tests: normal process exit,
# watchdog, completion summary and all five actual signed-image proofs remain mandatory.
suite_run tab-workspace-checks harness/logs/tab-workspace-checks.log "$workspace_client" --tab-workspace
suite_finish
