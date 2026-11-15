#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p harness/logs
rm -f harness/logs/test-source-manifest.json harness/logs/test-source-state.json harness/logs/candidate-validation.json
set +e
scripts/test-suites.sh 2>&1 | tee harness/logs/full-acceptance.log
results=("${PIPESTATUS[@]}")
result=${results[0]}
if [[ "${results[1]}" != 0 ]]; then result=1; fi
python3 scripts/record-validation.py record --exit-code "$result"
record_result=$?
if [[ "$record_result" != 0 ]]; then exit "$record_result"; fi
exit "$result"
