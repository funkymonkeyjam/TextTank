#!/bin/bash
# Launch a generated review build outside cloud file-provider metadata injection.
set -euo pipefail
texttank_script_dir="$(cd "$(dirname "$0")" && pwd)"
if [[ -d "$texttank_script_dir/TextTank.app" ]]; then
  texttank_package_dir="$texttank_script_dir"
elif [[ -d "$texttank_script_dir/../output/review" ]]; then
  texttank_package_dir="$(cd "$texttank_script_dir/../output/review" && pwd)"
else
  echo 'No review package exists. From the repository run scripts/build.sh, scripts/test.sh, then scripts/package-review.sh.' >&2
  exit 1
fi
if [[ -f "$texttank_package_dir/TextTank-review.zip" ]]; then
  if [[ ! -f "$texttank_package_dir/SHA256SUMS" ]]; then
    echo 'Review archive has no SHA256SUMS. Rebuild the package before launching.' >&2
    exit 1
  fi
  texttank_expected="$(awk '$2 == "TextTank-review.zip" && length($1) == 64 {print $1}' "$texttank_package_dir/SHA256SUMS")"
  texttank_actual="$(shasum -a 256 "$texttank_package_dir/TextTank-review.zip" | awk '{print $1}')"
  if [[ -z "$texttank_expected" || "$texttank_expected" != "$texttank_actual" ]]; then
    echo 'Review archive checksum does not match SHA256SUMS. Rebuild the package before launching.' >&2
    exit 1
  fi
fi
texttank_run_dir="$(mktemp -d "${TMPDIR:-/tmp}/TextTank-review.XXXXXX")"
texttank_launch_started=0
texttank_launch_finished=0
cleanup() {
  if [[ "$texttank_launch_started" == 0 || "$texttank_launch_finished" == 1 ]]; then
    rm -rf "$texttank_run_dir"
  else
    printf 'Launch wait interrupted; keeping the possibly running app at %s\n' "$texttank_run_dir" >&2
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ -f "$texttank_package_dir/TextTank-review.zip" ]]; then
  ditto -x -k "$texttank_package_dir/TextTank-review.zip" "$texttank_run_dir"
else
  mkdir -p "$texttank_run_dir/TextTank-review"
  ditto --norsrc --noextattr "$texttank_package_dir/TextTank.app" "$texttank_run_dir/TextTank-review/TextTank.app"
fi
texttank_run_app="$texttank_run_dir/TextTank-review/TextTank.app"
codesign --verify --deep --strict "$texttank_run_app"
printf 'Launching %s (this window waits until the app exits)\n' "$texttank_run_app"
texttank_launch_started=1
open -W "$texttank_run_app"
texttank_launch_finished=1
