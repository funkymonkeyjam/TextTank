#!/bin/bash
# Formats or lints the first-party Swift sources with the swift-format that
# ships with the installed toolchain and the committed .swift-format, which
# enables layout rules only. Vendored code (Sources/Search/Boost, Vendor) is
# never touched.
#
#   scripts/swift-format.sh lint     report layout that differs; exit 1 if any
#   scripts/swift-format.sh format   rewrite the files in place
#
# Output differs between swift-format versions, so the version is printed and
# the CI lint step is advisory until CI and local toolchains are pinned alike.
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-lint}"
if ! xcrun --find swift-format >/dev/null 2>&1; then
  echo "swift-format is not in the installed toolchain; nothing was checked" >&2
  exit 2
fi
files=()
while IFS= read -r -d '' file; do files+=("$file"); done < <(
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git ls-files -z -- 'Sources/*.swift' 'Tests/*.swift' ':!Sources/Search/Boost'
  else
    find Sources Tests -path Sources/Search/Boost -prune -o -name '*.swift' -print0
  fi
)
echo "swift-format $(xcrun swift-format --version), ${#files[@]} files, configuration .swift-format"
case "$mode" in
  lint)
    status=0
    log=$(mktemp "${TMPDIR:-/tmp}/texttank-swift-format.XXXXXX")
    trap 'rm -f "$log"' EXIT
    xcrun swift-format lint --strict --configuration .swift-format "${files[@]}" > "$log" 2>&1 || status=$?
    count=$(grep -c -E ': (warning|error): ' "$log" || true)
    head -n 40 "$log"
    if [[ "$status" == 0 ]]; then echo "PASS SwiftFormatLint: ${#files[@]} files match .swift-format"; exit 0; fi
    echo "FAILED SwiftFormatLint: $count places differ from .swift-format (first 40 shown); run scripts/swift-format.sh format"
    exit 1
    ;;
  format)
    xcrun swift-format format --in-place --configuration .swift-format "${files[@]}"
    echo "Formatted ${#files[@]} files"
    ;;
  *)
    echo "usage: scripts/swift-format.sh lint|format" >&2
    exit 2
    ;;
esac
