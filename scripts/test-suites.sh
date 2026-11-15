#!/bin/bash
# Runs every suite, records each outcome and prints one summary. A failed,
# hung or unbuildable suite never hides the suites after it; the exit status is
# non-zero if any of them did not pass. See scripts/suite-lib.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_require_build
# Bind acceptance to clean start/end git trees, including standalone full-suite invocations.
python3 scripts/record-validation.py capture
suite_script scripts/test-harness.sh
suite_script scripts/test-build-pipeline.sh
ALL_DIRECT="file-checks automation-checks reminder-checks bridge-checks"
suite_build "$ALL_DIRECT" scripts/build-user-lexer.sh
suite_build "file-checks" swiftc Sources/Documents/FailureContext.swift "${SWIFT_BASE[@]}" -o build/tests/file-checks Sources/Documents/FileCodec.swift Sources/Documents/RecoveryStore.swift Sources/Documents/RecoveryWriter.swift "$SUITE_SUPPORT" Tests/FileChecks.swift
suite_run file-checks harness/logs/file-checks.log build/tests/file-checks
suite_build "automation-checks" swiftc Sources/Documents/FailureContext.swift "${SWIFT_BASE[@]}" -o build/tests/automation-checks Sources/Automations/AutomationCore.swift Sources/Documents/LineOrder.swift "$SUITE_SUPPORT" Tests/AutomationChecks.swift
suite_run automation-checks harness/logs/automation-checks.log build/tests/automation-checks
suite_build "reminder-checks" swiftc Sources/Documents/FailureContext.swift "${SWIFT_BASE[@]}" -o build/tests/reminder-checks Sources/Connectors/RemindersConnector.swift "$SUITE_SUPPORT" Tests/ReminderChecks.swift
suite_run reminder-checks harness/logs/reminder-checks.log build/tests/reminder-checks
suite_build "bridge-checks" build_bridge_object
suite_build "bridge-checks" clang++ "${CXX_BASE[@]}" -I Tests/Support -I Sources/EditorBridge -I Vendor/scintilla/cocoa -I Vendor/scintilla/include -I Vendor/lexilla/include -F "$VENDOR_BUILD" -framework Scintilla -framework Cocoa "$BRIDGE_OBJECT" Tests/BridgeChecks.mm "$USER_LEXER_OBJECT" "$LEXILLA_LIBRARY" -Wl,-rpath,"$VENDOR_BUILD" -o build/tests/bridge-checks
suite_run bridge-checks harness/logs/bridge-checks.log build/tests/bridge-checks

suite_script scripts/test-documents.sh

# The Foundation-only macro core must keep compiling without AppKit. Its checks
# run once, in the native build made by scripts/test-macros.sh.
suite_build "macro-core-layering" swiftc Sources/Documents/FailureContext.swift -typecheck "${SWIFT_BASE[@]}" Sources/Macros/MacroCore.swift "$SUITE_SUPPORT" Tests/MacroChecks.swift
suite_run macro-core-layering harness/logs/macro-core-layering.log /bin/echo "PASS MacroCore compiles without AppKit; its checks run in macro-integration-checks"

suite_script scripts/test-macros.sh

suite_script scripts/test-automation-ui.sh
suite_script scripts/test-user-recipes.sh

suite_script scripts/test-workspace.sh

suite_script scripts/test-folder-search.sh

suite_script scripts/test-search.sh
suite_script scripts/test-utilities.sh
suite_script scripts/test-run.sh
suite_script scripts/test-languages.sh
suite_script scripts/test-workspace-browser.sh
# The reduced performance tier; its budgets can fail. The 100 MiB tier stays manual.
suite_script scripts/test-performance.sh gate
suite_run parity-inventory harness/logs/parity-inventory.log python3 docs/parity/check_inventory.py
# The countable part of docs/DESIGN-STANDARDS.md: budgets that only go down, and two hard rules.
suite_run design-standards-selftest harness/logs/design-standards-selftest.log python3 scripts/check-design-standards.py --selftest
suite_run design-standards harness/logs/design-standards.log python3 scripts/check-design-standards.py
suite_finish
