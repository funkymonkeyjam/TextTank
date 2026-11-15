#!/bin/bash
# Shared native build identity. Only configurations exercised by these scripts are accepted.
TEXTTANK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Debug}"
case "$CONFIGURATION" in Debug|Release) ;; *) echo 'CONFIGURATION must be Debug or Release.' >&2; return 2 ;; esac
ARCH="${ARCH:-arm64}"
if [[ "$ARCH" != arm64 ]]; then echo 'Only arm64 is currently built and verified.' >&2; return 2; fi
DEPLOYMENT_TARGET="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["deploymentTarget"])' "$TEXTTANK_ROOT/Dependencies.lock.json")"
VENDOR_BUILD="$TEXTTANK_ROOT/build/vendor/$CONFIGURATION"
APP_PATH="$TEXTTANK_ROOT/build/DerivedData/Build/Products/$CONFIGURATION/TextTank.app"
LEXILLA_LIBRARY="$VENDOR_BUILD/liblexilla.a"
SWIFT_BASE=(-target "$ARCH-apple-macos$DEPLOYMENT_TARGET" -module-cache-path build/ModuleCache)
CXX_BASE=(-std=c++17 -fobjc-arc "-mmacosx-version-min=$DEPLOYMENT_TARGET")
BRIDGE_INCLUDES=(-I Sources/EditorBridge -I Vendor/scintilla/cocoa -I Vendor/scintilla/include -I Vendor/lexilla/include -F "$VENDOR_BUILD")
APP_LINK=(-framework Scintilla -framework Cocoa -Xlinker -rpath -Xlinker "$VENDOR_BUILD")
APP_SOURCES=(Sources/Languages/*.swift Sources/Run/*.swift Sources/Utilities/*.swift Sources/Search/*.swift Sources/Workspace/*.swift Sources/Macros/*.swift Sources/Documents/*.swift Sources/Automations/*.swift Sources/Connectors/*.swift Sources/TextTankApp/*.swift)
if [[ "$CONFIGURATION" == Release ]]; then SWIFT_BASE+=(-O); CXX_BASE+=(-O2); fi
export CONFIGURATION ARCH DEPLOYMENT_TARGET VENDOR_BUILD APP_PATH LEXILLA_LIBRARY
