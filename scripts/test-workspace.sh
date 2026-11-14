#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests harness/logs
swiftc -target arm64-apple-macos14.0 -module-cache-path build/ModuleCache Sources/Documents/FileCodec.swift Sources/Workspace/WorkspaceCore.swift Tests/WorkspaceChecks.swift -o build/tests/workspace-checks
build/tests/workspace-checks | tee harness/logs/workspace-checks.log
