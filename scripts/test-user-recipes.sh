#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_build "user-recipe-checks" swiftc "${SWIFT_BASE[@]}" Sources/Automations/AutomationCore.swift Sources/Documents/LineOrder.swift "$SUITE_SUPPORT" Tests/UserRecipeChecks.swift -o build/tests/user-recipe-checks
suite_run user-recipe-checks harness/logs/user-recipe-checks.log build/tests/user-recipe-checks
suite_finish
