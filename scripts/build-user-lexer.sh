#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
fingerprint=$(shasum -a 256 Sources/Languages/LexUserPort/LexUser.cxx Sources/Languages/LexUserPort/UserConstants.h | shasum -a 256 | cut -d ' ' -f1)
if [[ -f build/tests/UserLexer.o && -f build/tests/UserLexer.sha && "$(cat build/tests/UserLexer.sha)" == "$fingerprint" ]]; then exit 0; fi
object=$(mktemp build/tests/UserLexer.XXXXXX)
trap 'rm -f "$object"' EXIT
clang++ -std=c++17 -mmacosx-version-min=14.0 -I Vendor/scintilla/include -I Vendor/lexilla/include -I Vendor/lexilla/lexlib -c Sources/Languages/LexUserPort/LexUser.cxx -o "$object"
mv "$object" build/tests/UserLexer.o
printf '%s' "$fingerprint" > build/tests/UserLexer.sha
