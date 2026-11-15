#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests harness/logs
scripts/build-user-lexer.sh
python3 - <<'PYMANIFEST'
import datetime,hashlib,json,pathlib,subprocess
root=pathlib.Path.cwd()
paths=sorted(p for folder in ['Sources','Tests','scripts'] for p in (root/folder).rglob('*') if p.is_file())
record={'timestamp':datetime.datetime.now(datetime.timezone.utc).isoformat(),'local_commit':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'dirty':bool(subprocess.check_output(['git','status','--porcelain'],text=True).strip()),'sha256':{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}}
(root/'harness/logs/test-source-manifest.json').write_text(json.dumps(record,indent=2)+'\n')
PYMANIFEST
swiftc -target arm64-apple-macos14.0 -module-cache-path build/ModuleCache -o build/tests/file-checks Sources/Documents/FileCodec.swift Sources/Documents/RecoveryStore.swift Tests/FileChecks.swift
build/tests/file-checks | tee harness/logs/file-checks.log
swiftc -target arm64-apple-macos14.0 -module-cache-path build/ModuleCache -o build/tests/automation-checks Sources/Automations/AutomationCore.swift Tests/AutomationChecks.swift
build/tests/automation-checks | tee harness/logs/automation-checks.log
swiftc -target arm64-apple-macos14.0 -module-cache-path build/ModuleCache -o build/tests/reminder-checks Sources/Connectors/RemindersConnector.swift Tests/ReminderChecks.swift
build/tests/reminder-checks | tee harness/logs/reminder-checks.log
clang++ -std=c++17 -fobjc-arc -mmacosx-version-min=14.0 -I Sources/EditorBridge -I Vendor/scintilla/cocoa -I Vendor/scintilla/include -I Vendor/lexilla/include -F build/vendor/Debug -framework Scintilla -framework Cocoa Sources/EditorBridge/TTEditor.mm Tests/BridgeChecks.mm build/tests/UserLexer.o Vendor/lexilla/bin/liblexilla.a -Wl,-rpath,"$PWD/build/vendor/Debug" -o build/tests/bridge-checks
build/tests/bridge-checks | tee harness/logs/bridge-checks.log

scripts/test-documents.sh

swiftc -target arm64-apple-macos14.0 -module-cache-path build/ModuleCache -o build/tests/macro-checks Sources/Macros/MacroCore.swift Tests/MacroChecks.swift
build/tests/macro-checks | tee harness/logs/macro-checks.log

scripts/test-macros.sh

scripts/test-automation-ui.sh
scripts/test-user-recipes.sh

scripts/test-workspace.sh

scripts/test-folder-search.sh

scripts/test-search.sh
scripts/test-utilities.sh
scripts/test-run.sh
scripts/test-languages.sh
scripts/test-workspace-browser.sh
python3 docs/parity/check_inventory.py
