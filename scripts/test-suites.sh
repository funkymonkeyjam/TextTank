#!/bin/bash
# Runs every suite, records each outcome and prints one summary. A failed,
# hung or unbuildable suite never hides the suites after it; the exit status is
# non-zero if any of them did not pass. See scripts/suite-lib.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/suite-lib.sh
suite_begin
suite_require_build
# The source manifest binds a run to a git tree. A source archive has no git
# metadata: the suites still run, and scripts/record-validation.py then records
# the run as not bound to a stable source tree.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
python3 - <<'PYMANIFEST'
import datetime,hashlib,json,pathlib,subprocess
root=pathlib.Path.cwd()
paths=[root/pathlib.Path(p) for p in subprocess.check_output(['git','ls-files','-z'],text=True).split('\0') if p and (root/p).is_file()]
record={'timestamp':datetime.datetime.now(datetime.timezone.utc).isoformat(),'local_commit':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'source_tree':subprocess.check_output(['git','rev-parse','HEAD^{tree}'],text=True).strip(),'dirty':bool(subprocess.check_output(['git','status','--porcelain'],text=True).strip()),'sha256':{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}}
(root/'harness/logs/test-source-manifest.json').write_text(json.dumps(record,indent=2)+'\n')
PYMANIFEST
else
  echo "SKIP source manifest: not a git checkout"
fi
suite_script scripts/test-harness.sh
ALL_DIRECT="file-checks automation-checks reminder-checks bridge-checks"
suite_build "$ALL_DIRECT" scripts/build-user-lexer.sh
suite_build "file-checks" swiftc -target arm64-apple-macos14.0 -module-cache-path build/ModuleCache -o build/tests/file-checks Sources/Documents/FileCodec.swift Sources/Documents/RecoveryStore.swift Sources/Documents/RecoveryWriter.swift "$SUITE_SUPPORT" Tests/FileChecks.swift
suite_run file-checks harness/logs/file-checks.log build/tests/file-checks
suite_build "automation-checks" swiftc -target arm64-apple-macos14.0 -module-cache-path build/ModuleCache -o build/tests/automation-checks Sources/Automations/AutomationCore.swift "$SUITE_SUPPORT" Tests/AutomationChecks.swift
suite_run automation-checks harness/logs/automation-checks.log build/tests/automation-checks
suite_build "reminder-checks" swiftc -target arm64-apple-macos14.0 -module-cache-path build/ModuleCache -o build/tests/reminder-checks Sources/Connectors/RemindersConnector.swift "$SUITE_SUPPORT" Tests/ReminderChecks.swift
suite_run reminder-checks harness/logs/reminder-checks.log build/tests/reminder-checks
suite_build "bridge-checks" clang++ -std=c++17 -fobjc-arc -mmacosx-version-min=14.0 -I Tests/Support -I Sources/EditorBridge -I Vendor/scintilla/cocoa -I Vendor/scintilla/include -I Vendor/lexilla/include -F build/vendor/Debug -framework Scintilla -framework Cocoa Sources/EditorBridge/TTEditor.mm Tests/BridgeChecks.mm build/tests/UserLexer.o Vendor/lexilla/bin/liblexilla.a -Wl,-rpath,"$PWD/build/vendor/Debug" -o build/tests/bridge-checks
suite_run bridge-checks harness/logs/bridge-checks.log build/tests/bridge-checks

suite_script scripts/test-documents.sh

# The Foundation-only macro core must keep compiling without AppKit. Its checks
# run once, in the native build made by scripts/test-macros.sh.
suite_build "macro-core-layering" swiftc -typecheck -target arm64-apple-macos14.0 -module-cache-path build/ModuleCache Sources/Macros/MacroCore.swift "$SUITE_SUPPORT" Tests/MacroChecks.swift
suite_run macro-core-layering harness/logs/macro-core-layering.log /bin/echo "PASS MacroCore compiles without AppKit; its checks run in macro-integration-checks"

suite_script scripts/test-macros.sh

suite_script scripts/test-automation-ui.sh
suite_script scripts/test-user-recipes.sh

suite_script scripts/test-workspace.sh

suite_script scripts/test-folder-search.sh

suite_script scripts/test-search.sh
suite_script scripts/test-utilities.sh
suite_script scripts/test-run.sh
suite_script scripts/test-languages.sh
suite_script scripts/test-workspace-browser.sh
suite_run parity-inventory harness/logs/parity-inventory.log python3 docs/parity/check_inventory.py
suite_finish
