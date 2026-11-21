#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
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
log_warning_policy=strict
if [[ "${1:-}" == --advisory-swift-warnings ]]; then
  log_warning_policy=advisory
  shift
fi
if [[ "$#" != 0 ]]; then
  echo 'Usage: scripts/build.sh [--advisory-swift-warnings]' >&2
  exit 64
fi
rm -f harness/logs/app-build-diagnostics.json
python3 scripts/bootstrap.py
python3 scripts/runtime_artifacts.py begin --configuration "$CONFIGURATION" --manifest "build/artifacts/$CONFIGURATION/before.json"
logged scintilla-build xcodebuild -project Vendor/scintilla/cocoa/Scintilla/Scintilla.xcodeproj -scheme Scintilla -configuration "$CONFIGURATION" -derivedDataPath "$PWD/build/ScintillaDerived/$CONFIGURATION" ARCHS="$ARCH" ONLY_ACTIVE_ARCH=YES MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" CODE_SIGNING_ALLOWED=NO CONFIGURATION_BUILD_DIR="$VENDOR_BUILD" CLANG_MODULE_CACHE_PATH="$PWD/build/ModuleCache"
logged lexilla-build python3 scripts/build-lexilla.py
logged app-build xcodebuild -project TextTank.xcodeproj -scheme TextTank -configuration "$CONFIGURATION" -derivedDataPath "$PWD/build/DerivedData" CODE_SIGNING_ALLOWED=NO build
python3 scripts/compile_diagnostics.py --log harness/logs/app-build.log --log-warning-policy "$log_warning_policy" --report harness/logs/app-build-diagnostics.json
python3 scripts/check-runtime-linkage.py "$APP_PATH"
python3 scripts/runtime_artifacts.py links --configuration "$CONFIGURATION" --app "$APP_PATH" --manifest "build/artifacts/$CONFIGURATION/link-before-sign.json" --before "build/artifacts/$CONFIGURATION/before.json"
# Finder/file-provider metadata is not part of the generated application resources.
xattr -dr com.apple.FinderInfo "$APP_PATH" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$APP_PATH" 2>/dev/null || true
for framework in Scintilla NativeSearch EditorBridge TextTankCore TextTankRuntime; do
  codesign --force --sign - "$APP_PATH/Contents/Frameworks/$framework.framework"
done
# Metadata may arrive between steps. Reclean generated resources at the enclosing
# signing boundary too; a later signing or strict-verification failure is still fatal.
xattr -dr com.apple.FinderInfo "$APP_PATH" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$APP_PATH" 2>/dev/null || true
codesign --force --sign - "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
python3 scripts/runtime_artifacts.py record --configuration "$CONFIGURATION" --app "$APP_PATH" --manifest "build/artifacts/$CONFIGURATION/manifest.json" --before "build/artifacts/$CONFIGURATION/before.json"
printf 'Built %s\n' "$APP_PATH"
