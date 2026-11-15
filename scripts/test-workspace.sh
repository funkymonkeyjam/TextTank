#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_build "workspace-checks" swiftc Sources/Documents/FailureContext.swift "${SWIFT_BASE[@]}" Sources/Documents/FileCodec.swift Sources/Workspace/WorkspaceCore.swift "$SUITE_SUPPORT" Tests/WorkspaceChecks.swift -o build/tests/workspace-checks
suite_run workspace-checks harness/logs/workspace-checks.log build/tests/workspace-checks
suite_finish
