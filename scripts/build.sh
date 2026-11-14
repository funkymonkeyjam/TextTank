#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build harness/logs
python3 scripts/bootstrap.py
xcodebuild -project Vendor/scintilla/cocoa/Scintilla/Scintilla.xcodeproj -scheme Scintilla -configuration Debug -derivedDataPath "$PWD/build/ScintillaDerived" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES MACOSX_DEPLOYMENT_TARGET=14.0 CODE_SIGNING_ALLOWED=NO CONFIGURATION_BUILD_DIR="$PWD/build/vendor/Debug" CLANG_MODULE_CACHE_PATH="$PWD/build/ModuleCache" > harness/logs/scintilla-build.log 2>&1
make -C Vendor/lexilla/src -j4 DEBUG=1 CXXFLAGS=-mmacosx-version-min=14.0 ../bin/liblexilla.a > harness/logs/lexilla-build.log 2>&1
xcodebuild -project TextTank.xcodeproj -scheme TextTank -configuration Debug -derivedDataPath "$PWD/build/DerivedData" CODE_SIGNING_ALLOWED=NO build > harness/logs/app-build.log 2>&1
# Finder/file-provider metadata is not part of the generated application resources.
python3 - <<'PYATTR'
import subprocess
for attribute in ('com.apple.FinderInfo','com.apple.ResourceFork'):
 subprocess.run(['xattr','-dr',attribute,'build/DerivedData/Build/Products/Debug/TextTank.app'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
PYATTR
codesign --force --sign - build/DerivedData/Build/Products/Debug/TextTank.app/Contents/Frameworks/Scintilla.framework
codesign --force --sign - build/DerivedData/Build/Products/Debug/TextTank.app
printf 'Built %s\n' "$PWD/build/DerivedData/Build/Products/Debug/TextTank.app"
