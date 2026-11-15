#!/bin/bash
# Explicit suite scripts keep their own source lists and defines. Only identical flags
# and native object compilation live here. Every owner run has a fresh object directory.
source "$TEXTTANK_ROOT/scripts/env.sh"

build_bridge_object() {
  [[ -f "$BRIDGE_OBJECT" ]] && return 0
  local temporary
  temporary=$(mktemp "$TEXTTANK_NATIVE_OBJECT_DIR/TTEditor.XXXXXX")
  if clang++ "${CXX_BASE[@]}" "${BRIDGE_INCLUDES[@]}" -c Sources/EditorBridge/TTEditor.mm -o "$temporary"; then
    mv "$temporary" "$BRIDGE_OBJECT"
  else
    local result=$?
    rm -f "$temporary"
    return "$result"
  fi
}

build_search_object() {
  [[ -f "$SEARCH_OBJECT" ]] && return 0
  local temporary
  temporary=$(mktemp "$TEXTTANK_NATIVE_OBJECT_DIR/TTSearchEngine.XXXXXX")
  if clang++ "${CXX_BASE[@]}" -I Sources/Search/Boost -c Sources/Search/TTSearchEngine.mm -o "$temporary"; then
    mv "$temporary" "$SEARCH_OBJECT"
  else
    local result=$?
    rm -f "$temporary"
    return "$result"
  fi
}

build_user_lexer_object() {
  [[ -f "$USER_LEXER_OBJECT" ]] && return 0
  local temporary
  local lexer_flags
  read -r -a lexer_flags < scripts/user-lexer-flags.txt
  temporary=$(mktemp "$TEXTTANK_NATIVE_OBJECT_DIR/UserLexer.XXXXXX")
  if clang++ -x c++ "${lexer_flags[@]}" "-mmacosx-version-min=$DEPLOYMENT_TARGET" -I Vendor/scintilla/include -I Vendor/lexilla/include -I Vendor/lexilla/lexlib -c Sources/Languages/LexUserPort/LexUser.cxx -o "$temporary"; then
    mv "$temporary" "$USER_LEXER_OBJECT"
  else
    local result=$?
    rm -f "$temporary"
    return "$result"
  fi
}
