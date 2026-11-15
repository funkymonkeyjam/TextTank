#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build harness/logs
# Runs one build step with its output in harness/logs/<name>.log. When the step
# fails, the end of that log and its path are printed, so a failed build is
# never a silent non-zero exit.
logged() {
  local name="$1" log="harness/logs/$1.log" status=0
  shift
  "$@" > "$log" 2>&1 || status=$?
  if [[ "$status" != 0 ]]; then
    echo "Build step '$name' failed with exit $status. Last 60 lines of $PWD/$log:" >&2
    tail -n 60 "$log" >&2
    echo "Full log: $PWD/$log" >&2
    if [[ "${GITHUB_ACTIONS:-}" == true ]]; then echo "::error::Build step '$name' failed with exit $status; see $log"; fi
    exit "$status"
  fi
}
if [[ "${1:-}" == --logged-selftest ]]; then
  # Used by scripts/test-harness.sh: a failing step must show its log and exit non-zero.
  logged build-selftest /bin/sh -c 'echo "selftest compiler output"; echo "selftest error line" >&2; exit 5'
  exit 0
fi
python3 scripts/bootstrap.py
logged scintilla-build xcodebuild -project Vendor/scintilla/cocoa/Scintilla/Scintilla.xcodeproj -scheme Scintilla -configuration Debug -derivedDataPath "$PWD/build/ScintillaDerived" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES MACOSX_DEPLOYMENT_TARGET=14.0 CODE_SIGNING_ALLOWED=NO CONFIGURATION_BUILD_DIR="$PWD/build/vendor/Debug" CLANG_MODULE_CACHE_PATH="$PWD/build/ModuleCache"
logged lexilla-build make -C Vendor/lexilla/src -j4 DEBUG=1 CXXFLAGS=-mmacosx-version-min=14.0 ../bin/liblexilla.a
logged app-build xcodebuild -project TextTank.xcodeproj -scheme TextTank -configuration Debug -derivedDataPath "$PWD/build/DerivedData" CODE_SIGNING_ALLOWED=NO build
# Finder/file-provider metadata is not part of the generated application resources.
python3 - <<'PYATTR'
import subprocess
for attribute in ('com.apple.FinderInfo','com.apple.ResourceFork'):
 subprocess.run(['xattr','-dr',attribute,'build/DerivedData/Build/Products/Debug/TextTank.app'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
PYATTR
codesign --force --sign - build/DerivedData/Build/Products/Debug/TextTank.app/Contents/Frameworks/Scintilla.framework
codesign --force --sign - build/DerivedData/Build/Products/Debug/TextTank.app
printf 'Built %s\n' "$PWD/build/DerivedData/Build/Products/Debug/TextTank.app"
