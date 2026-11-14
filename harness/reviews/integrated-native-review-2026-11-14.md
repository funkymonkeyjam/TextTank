# Integrated native review — 2026-11-14

Scope: independent review of the current App.swift print, close/quit, toolbar integration and session capture/restore wiring. AutomationController implementation was authored by this reviewer and is explicitly excluded from independent review. Initial review was read-only. Parent subsequently assigned the minimal recovery repair recorded below.

## Finding

RESOLVED P3 — Empty restored session documents were marked dirty but had no crash recovery snapshot. WorkspaceController.restore sets empty text and calls updateChangeCount(.changeDone), then flushRecovery. TextDocument.flushRecovery checks only editor.modified or format differing from savedFormat. Empty UTF-8/no-BOM content leaves both false, so recovery is removed rather than retained. Scratch native reproduction observed `EMPTY-RECOVERY false dirty=true`. Impact: the empty restored tab/identity can disappear after crash. Original session and original files are unchanged. Repair: recovery eligibility now also checks NSDocument.isDocumentEdited, preserving empty dirty session snapshots. Added a native regression restoring an empty UTF-8/no-BOM snapshot and verifying its recovery ID has an empty-text durable snapshot. The complete DocumentChecks suite passed 64 assertions after the repair (harness/logs/document-checks.log).

## Observed validation

Executed a scratch extension of DocumentChecks against all current Swift app sources and native Scintilla bridge, macOS 14 deployment target. 67 assertions passed (63 existing plus four print checks). A 500-line Unicode document produced a 10-page PDF through actual NSPrintOperation.run with panels disabled and save disposition; PDFKit confirmed multiple pages and final line 500. Editor revision and dirty state remained unchanged. Exact Unicode/FEFF/NUL print-view content and session content/encoding/selection/bookmark restoration passed existing assertions. Original file bytes stayed unchanged. Native close cleared callbacks and observers; clean quit returned terminateNow with no owned documents.

Logs: `harness/logs/integrated-review-checks.log`; generated probe: `build/tests/IntegratedReviewChecks.swift`, runner `build/tests/run-integrated-review.sh`. Probe artifacts are ignored scratch files, not permanent test-suite additions. PDF generated in isolated temporary directory and removed on exit.

## Source inspection conclusions

- Print preparation copies NSPrintInfo, uses a detached static NSTextView populated from the authoritative editor, and does not reset savepoints or edit the model. Automatic vertical pagination was observed, not merely inferred.
- Close calls prepareForClose before NSDocument detaches controllers; both observer tokens are removed and focus callbacks cleared. Active-editor lookup retains the primary editor independently of a disappearing document reference.
- Toolbar refresh responds to the matching controller notification, rebuilds current pinned UUID items and retains explicit Close Tab. Close Tab uses native performClose and therefore the document close review path.
- Quit's clean path closes all documents synchronously; dirty path schedules review after terminateLater can return, and only closes documents when review reports success.
- Session validation occurs before native restoration. Restored snapshots detach original URLs and preserve existing documents; capture reads authoritative shared text and active-pane selection. No writes to referenced originals occur during restore. Recovery errors remain surfaced via window status rather than thrown from restore.

Limits: this run exercises native AppKit objects with no physical screens attached; it does not certify physical toolbar appearance, print-panel interaction, printer hardware, or cancel/save choices in dirty quit dialogs. No EventKit access or real reminders occurred. Full Notepad++ parity is outside this targeted review.

## Reviewed source identity

Git HEAD (working tree includes changes): `1d41ee10fb39ce10054d5789e88a4f297fcf28de`

| File | SHA-256 |
|---|---|
| `Sources/TextTankApp/App.swift` | `01971c830ba4a2b39906cc597fee44bfc37a1a5c9737185057ad95965f9fedaa` |
| `Sources/Workspace/WorkspaceController.swift` | `98aafb55ee85f387cbd0d260e0b8a718744a084c0b54c404bd1f54668c2b0cd9` |
| `Sources/Workspace/WorkspaceCore.swift` | `7d1a60f01e78821c8d195bb1e4734b67b073c769351f567f2bf7c168b6bcb73c` |
| `Tests/DocumentChecks.swift` | `612cd5e280659ab9e9215e2adb65570d1728679a0bf51a3c22e8ad9b2559115a` |
| `build/tests/IntegratedReviewChecks.swift` | `f94a095b0e20b14d2e6f4ad6996063f6a5a2cd42517308cb55ac0c274e960a48` |

## Post-repair source identity

Only the recovery eligibility condition and empty-session regression were changed for this repair. Earlier source hashes describe the initial review/PDF probe; hashes below identify the repaired files.

| File | SHA-256 |
|---|---|
| `Sources/TextTankApp/App.swift` | `d4d68e9fce6c167b33030ab9eeb1bec4a234640d0ff28cb0a10b10c6582cf08b` |
| `Tests/DocumentChecks.swift` | `2eae90c661d5be292649e63ec27d36f7be0fe90e615f049e44e56563472ed389` |
