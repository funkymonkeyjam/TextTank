#!/bin/bash
# Launch a generated review build outside cloud file-provider metadata injection.
set -euo pipefail
texttank_script_dir="$(cd "$(dirname "$0")" && pwd)"
if [[ -d "$texttank_script_dir/TextTank.app" ]]; then
  texttank_package_dir="$texttank_script_dir"
else
  texttank_package_dir="$(cd "$texttank_script_dir/../output/review" && pwd)"
fi
texttank_run_dir="$(mktemp -d /tmp/TextTank-review.XXXXXX)"
if [[ -f "$texttank_package_dir/TextTank-review.zip" ]]; then
  ditto -x -k "$texttank_package_dir/TextTank-review.zip" "$texttank_run_dir"
else
  mkdir -p "$texttank_run_dir/TextTank-review"
  ditto --norsrc --noextattr "$texttank_package_dir/TextTank.app" "$texttank_run_dir/TextTank-review/TextTank.app"
fi
texttank_run_app="$texttank_run_dir/TextTank-review/TextTank.app"
codesign --verify --deep --strict "$texttank_run_app"
printf 'Launching %s\n' "$texttank_run_app"
open "$texttank_run_app"
