#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/icon-tool
xcrun swiftc -module-cache-path .build/icon-tool/module-cache scripts/build-icon.swift -o .build/icon-tool/build-icon
.build/icon-tool/build-icon Resources/Brand/carbon-caret-app-square.svg .build/icon-tool/TextTank.iconset Resources/TextTank.icns
