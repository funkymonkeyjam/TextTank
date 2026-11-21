#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_require_build
suite_run bundle-smoke harness/logs/bundle-smoke.log python3 scripts/bundle_smoke.py "$APP_PATH"
suite_finish
