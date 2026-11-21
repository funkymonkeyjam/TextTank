#!/bin/bash
# Package a clean committed candidate with its corresponding source and pinned dependencies.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
  echo 'Commit the curated candidate before packaging; the working tree must be clean.' >&2
  exit 1
fi
candidate_sha="$(git rev-parse HEAD)"
./scripts/build.sh
if [[ "$(git rev-parse HEAD)" != "$candidate_sha" || -n "$(git status --porcelain --untracked-files=normal)" ]]; then
  echo 'Source changed during build. Packaging stopped.' >&2
  exit 1
fi
python3 scripts/package_review.py "$candidate_sha"
