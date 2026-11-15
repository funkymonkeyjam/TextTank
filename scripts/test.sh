#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p harness/logs
python3 - <<'PYRESET'
from pathlib import Path
for name in ['test-source-manifest.json','candidate-validation.json']:
    Path('harness/logs',name).unlink(missing_ok=True)
PYRESET
set +e
scripts/test-suites.sh 2>&1 | tee harness/logs/full-acceptance.log
results=("${PIPESTATUS[@]}")
result=${results[0]}
if [[ "${results[1]}" != 0 ]]; then result=1; fi
TEXTTANK_TEST_EXIT="$result" python3 scripts/record-validation.py
record_result=$?
if [[ "$record_result" != 0 ]]; then exit "$record_result"; fi
exit "$result"
