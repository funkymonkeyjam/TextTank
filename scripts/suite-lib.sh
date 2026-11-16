#!/bin/bash
# Sourced by scripts/test-*.sh after they change to the repository root.
#
# Every build step and every suite is run, its outcome is recorded, and the run
# carries on, so one failure never hides the suites after it. Each suite runs
# under a watchdog. The script that started the run prints one summary table and
# exits non-zero if anything failed, timed out or could not be built.
#
#   suite_begin                      start (or join) a run
#   suite_require_build              stop with a clear message if scripts/build.sh has not run
#   suite_build "<suites>" cmd...    build step needed by the named suites
#   suite_run <suite> <log> cmd...   run one suite under the watchdog, tee to <log>
#   suite_script <script>            run another test script as part of this run
#   suite_finish                     summary (when this script started the run) and exit status
#
# TEXTTANK_SUITE_TIMEOUT sets the per-suite limit in seconds (default 300).

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

# First-party Swift is warning-clean. A new toolchain can be inspected with an explicit
# TEXTTANK_WARNINGS_AS_ERRORS=0 override; ordinary acceptance keeps warnings fatal.
SWIFT_WARNING_FLAGS=()
case "${TEXTTANK_WARNINGS_AS_ERRORS:-1}" in
  1) SWIFT_WARNING_FLAGS=(-warnings-as-errors); SWIFT_BASE+=(-warnings-as-errors) ;;
  0) ;;
  *) echo "TEXTTANK_WARNINGS_AS_ERRORS must be 0 or 1" >&2; exit 64 ;;
esac


SUITE_BROKEN=" "
SUITE_OWNER=0
SUITE_FIRST_RECORD=1

suite_begin() {
  mkdir -p build/tests harness/logs
  if [[ -z "${TEXTTANK_SUITE_RESULTS:-}" ]]; then
    TEXTTANK_SUITE_RESULTS=$(mktemp "${TMPDIR:-/tmp}/texttank-suites.XXXXXX")
    export TEXTTANK_SUITE_RESULTS
    SUITE_OWNER=1
  fi
  SUITE_FIRST_RECORD=$(( $(wc -l < "$TEXTTANK_SUITE_RESULTS") + 1 ))
  # The shared harness is passed by absolute path so that #filePath, and with it
  # the repository root the checks derive, does not depend on the current directory.
  SUITE_SUPPORT="$PWD/Tests/Support/Checks.swift"
}

suite_require_build() {
  local actual_app status=0
  TEXTTANK_ARTIFACT_MANIFEST="${TEXTTANK_ARTIFACT_MANIFEST:-$TEXTTANK_ROOT/build/artifacts/$CONFIGURATION/manifest.json}"
  actual_app=$(python3 scripts/runtime_artifacts.py validate --configuration "$CONFIGURATION" --manifest "$TEXTTANK_ARTIFACT_MANIFEST") || status=$?
  if [[ "$status" != 0 ]]; then
    suite_record "NOT-BUILT" "$(basename "$0")" "canonical signed artifacts are absent, stale or invalid; run scripts/build.sh first"
    suite_finish
  fi
  APP_PATH="$actual_app"
  TEXTTANK_FRAMEWORKS="$APP_PATH/Contents/Frameworks"
  NATIVE_BRIDGE_LIBRARY="$TEXTTANK_FRAMEWORKS/EditorBridge.framework/Versions/A/EditorBridge"
  NATIVE_SEARCH_LIBRARY="$TEXTTANK_FRAMEWORKS/NativeSearch.framework/Versions/A/NativeSearch"
  # Put the actual embedded signed frameworks before the dependency build folder.
  # Header input bytes are validated separately; no product source is compiled here.
  SWIFT_BASE+=(-F "$TEXTTANK_FRAMEWORKS" -Xlinker -rpath -Xlinker "$TEXTTANK_FRAMEWORKS")
  CXX_BASE+=(-F "$TEXTTANK_FRAMEWORKS" "-Wl,-rpath,$TEXTTANK_FRAMEWORKS")
  export APP_PATH TEXTTANK_FRAMEWORKS TEXTTANK_ARTIFACT_MANIFEST NATIVE_BRIDGE_LIBRARY NATIVE_SEARCH_LIBRARY
}

# status <TAB> suite <TAB> detail
suite_record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$TEXTTANK_SUITE_RESULTS"; }

suite_build() {
  local names="$1" name status
  shift
  "$@" && return 0
  status=$?
  for name in $names; do
    if [[ "$SUITE_BROKEN" != *" $name "* ]]; then
      SUITE_BROKEN+="$name "
      suite_record "BUILD-FAILED" "$name" "exit $status from: $(basename "$1") (output above)"
      echo "BUILD FAILED for $name: exit $status from $1"
    fi
  done
  return 0
}

suite_run() {
  local name="$1" log="$2" status=0 limit="${TEXTTANK_SUITE_TIMEOUT:-300}"
  local requires_completion="${TEXTTANK_NATIVE_COMPLETION_REQUIRED:-0}"
  local log_status=0 log_detail
  local -a pipeline_status
  shift 2
  if [[ "$SUITE_BROKEN" == *" $name "* ]]; then echo "NOT RUN $name: its build failed"; return 0; fi
  if [[ "$1" == build/tests/* || "$1" == "$PWD"/build/tests/* ]]; then requires_completion=1; fi
  # alarm() survives exec, so the suite itself receives SIGALRM when the limit passes.
  # Both branches copy PIPESTATUS before any other command can overwrite it (Bash 3.2).
  if perl -e 'alarm shift; exec { $ARGV[0] } @ARGV or die "cannot run $ARGV[0]: $!\n"' "$limit" "$@" 2>&1 | tee "$log"; then
    pipeline_status=("${PIPESTATUS[@]}")
  else
    pipeline_status=("${PIPESTATUS[@]}")
  fi
  status=${pipeline_status[0]}
  log_status=${pipeline_status[1]}
  log_detail="log $log"
  if [[ "$log_status" != 0 ]]; then
    log_detail="log unavailable: $log (tee exit $log_status; check exit $status)"
    echo "FAIL $name: log write failed (tee exit $log_status; check exit $status); stale log contents are not accepted" >&2
    # Keep the check's failure/timeout when it already failed; a successful check
    # cannot turn a failed evidence write into acceptance.
    if [[ "$status" == 0 ]]; then status=1; fi
  fi
  if [[ "$status" == 0 && "$requires_completion" == 1 ]] && ! grep -Eq '^(PASS )?[A-Za-z][A-Za-z0-9]*Checks: [0-9]+ (native )?assertions' "$log"; then
    echo "FAIL $name: exited zero without its native completion summary; the suite is incomplete" | tee -a "$log"
    status=1
  fi
  if [[ "$status" == 0 && ( "$1" == build/tests/* || "$1" == "$PWD"/build/tests/* ) ]]; then
    local native_dependencies image_name inspection_status
    if native_dependencies=$(otool -L "$1" 2>&1); then
      for image_name in NativeSearch EditorBridge Scintilla; do
        if [[ "$native_dependencies" == *"/$image_name.framework/"* ]] && ! grep -q "^ARTIFACT_IMAGE $image_name " "$log"; then
          echo "FAIL $name: missing actual loaded signed $image_name image proof" | tee -a "$log"
          status=1
        fi
      done
    else
      inspection_status=$?
      echo "FAIL $name: dependency inspection failed (otool exit $inspection_status)" | tee -a "$log"
      printf '%s\n' "$native_dependencies" | tee -a "$log"
      status=1
    fi
  fi
  if [[ "$status" == 0 ]]; then
    suite_record "PASS" "$name" "$(tail -n 1 "$log" | cut -c1-110)"
  elif [[ "$status" == 142 ]]; then
    suite_record "TIMEOUT" "$name" "no result after $limit s; $log_detail"
    echo "TIMEOUT $name: stopped after $limit s (TEXTTANK_SUITE_TIMEOUT); $log_detail"
    if [[ "${GITHUB_ACTIONS:-}" == true ]]; then echo "::error::$name timed out after $limit s"; fi
  else
    suite_record "FAILED" "$name" "exit $status; $log_detail"
    echo "FAILED $name: exit $status; $log_detail"
    if [[ "${GITHUB_ACTIONS:-}" == true ]]; then echo "::error::$name failed with exit $status"; fi
  fi
  return 0
}

suite_script() {
  local before status=0
  before=$(grep -vc '^PASS' "$TEXTTANK_SUITE_RESULTS" || true)
  "$@" || status=$?
  if [[ "$status" != 0 && "$(grep -vc '^PASS' "$TEXTTANK_SUITE_RESULTS" || true)" == "$before" ]]; then
    suite_record "FAILED" "$(basename "$1")" "exit $status without a recorded failure"
  fi
  return 0
}

suite_summary() {
  local status name detail log
  echo
  echo "Suite summary"
  while IFS=$'\t' read -r status name detail; do
    printf '  %-13s %-34s %s\n' "$status" "$name" "$detail"
  done < "$TEXTTANK_SUITE_RESULTS"
  while IFS=$'\t' read -r status name detail; do
    [[ "$status" == FAILED || "$status" == TIMEOUT ]] || continue
    log="${detail##*log }"
    [[ -f "$log" ]] || continue
    echo
    echo "--- $status $name: failure lines, then the end of $log"
    grep -E '^(FAIL|FAILED) ' "$log" | head -n 40 || true
    tail -n 20 "$log"
  done < "$TEXTTANK_SUITE_RESULTS"
  echo
  echo "$(grep -c '^PASS' "$TEXTTANK_SUITE_RESULTS" || true) passed, $(grep -vc '^PASS' "$TEXTTANK_SUITE_RESULTS" || true) not passed"
}

suite_finish() {
  local failed
  failed=$(tail -n "+$SUITE_FIRST_RECORD" "$TEXTTANK_SUITE_RESULTS" | grep -vc '^PASS' || true)
  if [[ "$SUITE_OWNER" == 1 ]]; then
    suite_summary
    rm -f "$TEXTTANK_SUITE_RESULTS"
  fi
  if [[ "$failed" != 0 ]]; then exit 1; fi
  exit 0
}
