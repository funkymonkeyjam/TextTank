#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_require_build
suite_build "performance-checks performance-gate-checks" clang++ "${CXX_BASE[@]}" -I Tests/Support -I Sources/EditorBridge -I Vendor/scintilla/cocoa -I Vendor/scintilla/include -I Vendor/lexilla/include -F "$VENDOR_BUILD" -framework Scintilla -framework Cocoa -Xlinker "$NATIVE_BRIDGE_LIBRARY" Tests/PerformanceChecks.mm -Wl,-rpath,"$VENDOR_BUILD" -o build/tests/performance-checks
# With no argument: the manual full tier, to 100 MiB. With "gate": the reduced tier that
# scripts/test-suites.sh runs as part of acceptance. Budgets are in Tests/PerformanceChecks.mm.
if [[ "${1:-}" == gate ]]; then
  suite_run performance-gate-checks harness/logs/performance-gate-checks.log build/tests/performance-checks
else
  suite_run performance-checks harness/logs/performance-checks.log build/tests/performance-checks full
fi
suite_finish
