#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
source scripts/lib/test-common.sh
mkdir -p build/tests
# scripts/user-lexer-flags.txt is shared with the app's plain-C++ project entry.
# There is no cross-run cache: fresh owner directories include every header/flag/toolchain change.
if [[ -z "${TEXTTANK_NATIVE_OBJECT_DIR:-}" ]]; then
  TEXTTANK_NATIVE_OBJECT_DIR=$(mktemp -d "$PWD/build/tests/native-objects.XXXXXX")
  trap 'rm -rf "$TEXTTANK_NATIVE_OBJECT_DIR"' EXIT
  USER_LEXER_OBJECT="$TEXTTANK_NATIVE_OBJECT_DIR/UserLexer.o"
  build_user_lexer_object
  cp "$USER_LEXER_OBJECT" build/tests/UserLexer.o
else
  build_user_lexer_object
fi
