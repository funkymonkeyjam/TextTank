#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_build "workspace-checks" swiftc "${SWIFT_WARNING_FLAGS[@]}" Sources/Documents/FailureContext.swift -target arm64-apple-macos14.0 -module-cache-path build/ModuleCache Sources/Documents/FileCodec.swift Sources/Workspace/WorkspaceCore.swift "$SUITE_SUPPORT" Tests/WorkspaceChecks.swift -o build/tests/workspace-checks
suite_run workspace-checks harness/logs/workspace-checks.log build/tests/workspace-checks
suite_finish
