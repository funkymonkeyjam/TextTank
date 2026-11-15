#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
# One flag set for the ported lexer: scripts/generate-project.py gives the app's LexUser.cxx the
# same flags, so the object the checks exercise is built as the shipped one is (plain C++, no ARC).
read -r -a flags < scripts/user-lexer-flags.txt
fingerprint=$(shasum -a 256 Sources/Languages/LexUserPort/LexUser.cxx Sources/Languages/LexUserPort/UserConstants.h scripts/user-lexer-flags.txt | shasum -a 256 | cut -d ' ' -f1)
if [[ -f build/tests/UserLexer.o && -f build/tests/UserLexer.sha && "$(cat build/tests/UserLexer.sha)" == "$fingerprint" ]]; then exit 0; fi
object=$(mktemp build/tests/UserLexer.XXXXXX)
trap 'rm -f "$object"' EXIT
clang++ -x c++ "${flags[@]}" -mmacosx-version-min=14.0 -I Vendor/scintilla/include -I Vendor/lexilla/include -I Vendor/lexilla/lexlib -c Sources/Languages/LexUserPort/LexUser.cxx -o "$object"
mv "$object" build/tests/UserLexer.o
printf '%s' "$fingerprint" > build/tests/UserLexer.sha
