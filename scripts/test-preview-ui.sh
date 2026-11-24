#!/bin/bash
# Source, Preview and Both: the per-tab preview, driven through the real tab adapter, the
# preview coordinator, the presenters and the web view, against the signed frameworks. The
# checks wait on explicit completion signals and do not need the window to be key, so they run
# with the screen locked.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_require_build
suite_build "preview-ui-checks" swiftc "${SWIFT_BASE[@]}" -F "$VENDOR_BUILD" -framework Scintilla -framework Cocoa -framework WebKit -framework EventKit -lc++ -Xlinker -rpath -Xlinker "$VENDOR_BUILD" "$SUITE_SUPPORT" Tests/Support/ModelessForms.swift Tests/PreviewNativeChecks.swift Tests/WorkspaceSidebarChecks.swift Tests/TabStripChecks.swift Tests/FindBarNativeChecks.swift -Xlinker "$NATIVE_BRIDGE_LIBRARY" -Xlinker "$NATIVE_SEARCH_LIBRARY" -o build/tests/preview-ui-checks
suite_run preview-ui-checks harness/logs/preview-ui-checks.log build/tests/preview-ui-checks
suite_finish
