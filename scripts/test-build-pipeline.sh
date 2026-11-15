#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_build build-pipeline-checks xcrun swiftc -module-cache-path build/ModuleCache scripts/build-icon.swift -o build/tests/icon-tool-checks
suite_run build-pipeline-checks harness/logs/build-pipeline-checks.log python3 Tests/BuildPipelineChecks.py
suite_finish
