#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_require_build
# With nounset, Bash 3.2 treats an empty array as unbound. Expand only its existing elements.
suite_build build-pipeline-checks xcrun --sdk macosx swiftc -swift-version 5 -strict-concurrency=complete ${SWIFT_WARNING_FLAGS[@]+"${SWIFT_WARNING_FLAGS[@]}"} -target "$ARCH-apple-macos$DEPLOYMENT_TARGET" -sdk "$TEXTTANK_SDKROOT" -module-cache-path build/ModuleCache scripts/build-icon.swift -o build/tests/icon-tool-checks
suite_run build-pipeline-checks harness/logs/build-pipeline-checks.log python3 Tests/BuildPipelineChecks.py
suite_finish
