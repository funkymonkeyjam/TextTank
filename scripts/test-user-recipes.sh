#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests harness/logs
swiftc -target arm64-apple-macos14.0 -module-cache-path build/ModuleCache Sources/Automations/AutomationCore.swift Sources/Automations/RecipeRulePreset.swift Tests/UserRecipeChecks.swift -o build/tests/user-recipe-checks
build/tests/user-recipe-checks | tee harness/logs/user-recipe-checks.log
