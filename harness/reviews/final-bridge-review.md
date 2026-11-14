# App and macro integration review — 2026-11-14

Reviewer: bridge worker, reviewing App.swift and macro service authored by the integrator/reference worker. The reviewer subsequently repaired the findings at the integrator's request; those repairs are not an independent second review.

Base HEAD: `0e79401506aae00134b64d129eb5e8e78d1d0bdd`. This review covers the working-tree candidate, not merely the base commit.

## Findings and disposition

### R1 — P1: recording across cloned editors silently omits edits — repaired

Original MacroController.swift lines 40–61 attached the native recorder to one TTEditor only. App.swift line 243 created and focused a clone without informing the macro recorder. Reproduction: start in primary; type A; clone/focus secondary; type B; stop. The shared document contains both edits but the saved recording contains only primary-view actions. No unsupported notification is emitted by the non-recording clone.

Repair: explicit editor focus/reset hooks invalidate the recording on view changes, close or reload. Stop reports the failure and cannot return/save a partial macro. Native integration regression tests exercise a recorded action followed by clone focus and require finishRecording to throw.

### R2 — P1: nonrecordable transforms silently produce partial macros — repaired

Original App.swift lines 220–226 dispatched every custom command without a recording policy. trimTrailing and joinLines use Scintilla target operations which do not emit SCN_MACRORECORD. A recording containing typing plus one such transform previously saved only the typing. Automation output and document reload had the same omission risk.

Repair: explicit command policy permits supported native macro commands and harmless view-only changes; other commands invalidate recording. Automation invocation and document reset explicitly invalidate recording. The original native unsupported-message rejection remains. Native responder Undo/Redo additionally invalidate through SCN_MODIFIED because Scintilla omits them from macro notifications. Tests reject partial recording after trim, automation, reload and Undo; valid recording and view-only zoom remain accepted.

### R3 — P2: standard editing selectors do not naturally reach modal text fields — repaired, physical UI recheck pending

Custom `EditorWindowController.command:` selectors are not necessarily in a save panel's responder chain. Routing to a field editor inside that method cannot help if AppKit cannot resolve the method in the first place. The integrator observed Command-A failing to replace a save-panel filename.

Repair: standard Undo/Redo/Cut/Copy/Paste/Select All menu items now use native responder selectors. Scintilla's content view already implements these. This permits native panels and text editors to resolve their own operations. Native Undo macro invalidation was added to preserve R2.

### Quit observation — hardening implemented; physical termination not claimed

The integrator observed windows closing while the UI tool still reported TextTank running. Static review did not establish whether that was stale process inventory or an application termination defect. Clean documents now take an explicit close-and-terminateNow path. Dirty documents retain asynchronous review and terminateLater/reply handling. Do not equate window disappearance with observed process termination.

## Checks observed after repairs

- `scripts/test-macros.sh`: PASS, 24 assertions, including real AppKit/Scintilla playback, grouping and recording-invalidation regressions.
- `scripts/test-documents.sh`: PASS, 49 assertions in the final observed log, including save/conflict/failure, shared document lifecycle, actual revert, BOM retention, clone geometry and clean-quit policy. Physical process exit remains unverified.
- Integrator reports CUA now renders both clone panes with Unicode and AX click succeeds. This reviewer did not independently execute those CUA interactions.

Review repair identities:

- App.swift SHA256 `1fd44b1b5f9641cd6e2feab5ca519af4ab11901d53c57f1f9fd50100a0e68525`
- MacroController.swift SHA256 `4600bae686da8f043e42af5e0eca71633c438e35ca9fcff044f7ec5a5e7d8b26`
- TTEditor.mm SHA256 `7e02b69418b33ccd3ec9d487c0b80e365e1a2e4e95310acce2a1989e7868a833`

## Remaining limitations

No full-parity approval. Macro playback is bounded but synchronous, with no interactive cancellation or run-until-end behavior. Switching views or using unsupported transforms now safely rejects recording rather than implementing those capabilities. Full dirty Quit/Cancel UI paths, native save-panel keyboard behavior, IME and VoiceOver still need their own observed evidence. Shell-native tests report no physical NSScreen and do not establish on-screen UX.
