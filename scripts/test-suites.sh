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
suite_run concurrency-guard-checks harness/logs/concurrency-guard-checks.log python3 Tests/ConcurrencyGuardChecks.py
suite_build "file-checks" swiftc "${SWIFT_BASE[@]}" -o build/tests/file-checks "$SUITE_SUPPORT" Tests/FileChecks.swift
suite_run file-checks harness/logs/file-checks.log build/tests/file-checks
suite_build "automation-checks" swiftc "${SWIFT_BASE[@]}" -o build/tests/automation-checks "$SUITE_SUPPORT" Tests/AutomationChecks.swift
suite_run automation-checks harness/logs/automation-checks.log build/tests/automation-checks
suite_build "reminder-checks" swiftc "${SWIFT_BASE[@]}" -o build/tests/reminder-checks "$SUITE_SUPPORT" Tests/ReminderChecks.swift
suite_run reminder-checks harness/logs/reminder-checks.log build/tests/reminder-checks
suite_build "bridge-checks" clang++ "${CXX_BASE[@]}" -I Tests/Support -I Sources/EditorBridge -I Vendor/scintilla/cocoa -I Vendor/scintilla/include -I Vendor/lexilla/include -F "$VENDOR_BUILD" -framework Scintilla -framework Cocoa -Xlinker "$NATIVE_BRIDGE_LIBRARY" -Xlinker "$NATIVE_SEARCH_LIBRARY" Tests/BridgeChecks.mm -Wl,-rpath,"$VENDOR_BUILD" -o build/tests/bridge-checks
suite_run bridge-checks harness/logs/bridge-checks.log build/tests/bridge-checks

suite_build "module-contract-checks" swiftc "${SWIFT_BASE[@]}" "$SUITE_SUPPORT" Tests/ModuleContractChecks.swift -o build/tests/module-contract-checks
suite_run module-contract-checks harness/logs/module-contract-checks.log build/tests/module-contract-checks

suite_build "tab-core-layering" swiftc -typecheck "${SWIFT_BASE[@]}" "$SUITE_SUPPORT" Tests/TabCoreChecks.swift
suite_run tab-core-layering harness/logs/tab-core-layering.log /bin/echo "PASS TabCore imports canonical Foundation-only Core"
suite_build "tab-core-checks" swiftc "${SWIFT_BASE[@]}" "$SUITE_SUPPORT" Tests/TabCoreChecks.swift -o build/tests/tab-core-checks
suite_run tab-core-checks harness/logs/tab-core-checks.log build/tests/tab-core-checks

suite_build "tab-command-core-layering" swiftc -typecheck "${SWIFT_BASE[@]}" "$SUITE_SUPPORT" Tests/TabCommandCoreChecks.swift
suite_run tab-command-core-layering harness/logs/tab-command-core-layering.log /bin/echo "PASS TabCommandCore imports canonical Foundation-only Core"
suite_build "tab-command-core-checks" swiftc "${SWIFT_BASE[@]}" "$SUITE_SUPPORT" Tests/TabCommandCoreChecks.swift -o build/tests/tab-command-core-checks
suite_run tab-command-core-checks harness/logs/tab-command-core-checks.log build/tests/tab-command-core-checks

suite_build "tab-organization-core-layering" swiftc -typecheck "${SWIFT_BASE[@]}" "$SUITE_SUPPORT" Tests/TabOrganizationCoreChecks.swift
suite_run tab-organization-core-layering harness/logs/tab-organization-core-layering.log /bin/echo "PASS TabOrganizationCore imports canonical Foundation-only Core"
suite_build "tab-organization-core-checks" swiftc "${SWIFT_BASE[@]}" "$SUITE_SUPPORT" Tests/TabOrganizationCoreChecks.swift -o build/tests/tab-organization-core-checks
suite_run tab-organization-core-checks harness/logs/tab-organization-core-checks.log build/tests/tab-organization-core-checks

suite_script scripts/test-documents.sh

# The Foundation-only macro core must keep compiling without AppKit. Its checks
# run once, in the native build made by scripts/test-macros.sh.
suite_build "macro-core-layering" swiftc -typecheck "${SWIFT_BASE[@]}" "$SUITE_SUPPORT" Tests/MacroChecks.swift
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
# The countable part of docs/DESIGN-STANDARDS.md: budgets that only go down, and two hard rules.
suite_run design-standards-selftest harness/logs/design-standards-selftest.log python3 scripts/check-design-standards.py --selftest
suite_run design-standards harness/logs/design-standards.log python3 scripts/check-design-standards.py
suite_finish
