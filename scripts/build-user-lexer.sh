#!/bin/bash
# Compatibility entry: the user lexer belongs to the canonical EditorBridge framework.
# Validate that actual artifact instead of compiling a second copy for checks.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
python3 scripts/runtime_artifacts.py validate --configuration "$CONFIGURATION" --manifest "${TEXTTANK_ARTIFACT_MANIFEST:-build/artifacts/$CONFIGURATION/manifest.json}"
