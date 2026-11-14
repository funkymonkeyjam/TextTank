# TextTank — INCOMPLETE PREVIEW

A launchable native Swift/AppKit editor using Scintilla Cocoa and Lexilla, with the selected Carbon Caret identity. This is a working review checkpoint, **not** a completed Notepad++ replacement. Every standard capability in the frozen reference remains required; no missing feature has been waived.

Repository: https://github.com/funkymonkeyjam/TextTank

Unmerged implementation PR: https://github.com/funkymonkeyjam/TextTank/pull/1

## Run and rebuild

From the repository root, launch the packaged candidate:

```sh
./scripts/launch-review.sh
```

The packaging script produces `output/review/TextTank-review.zip` and a `Launch-TextTank.command` launcher. Use that launcher from the extracted review folder; it stages the app outside synced storage before launch. The development build can also be launched with:

```sh
open build/DerivedData/Build/Products/Debug/TextTank.app
```

Reproduce the native arm64 build and checks on a Mac with Xcode:

```sh
./scripts/build.sh
./scripts/test.sh
./scripts/test-macros.sh
```

The build pins Scintilla 5.6.9 and Lexilla 5.5.5 with SHA-256 verification in `Dependencies.lock.json`. Initial dependency downloads need network access; ordinary editor and deterministic automation behavior do not require an account, subscription or paid API. Deployment target is macOS 14. The observed host is arm64; Intel and macOS 14 runtime behavior are not verified. Local ad-hoc signing is not notarized public distribution.

To package a committed, clean candidate with corresponding source and pinned dependency archives:

```sh
./scripts/package-review.sh
(cd output/review && shasum -a 256 -c SHA256SUMS)
```

Packaging rebuilds the committed source, verifies local signatures, preserves an earlier delivery under `output/review-previous-*`, and emits `manifest.json`, `SHA256SUMS`, the app and ZIP. `manifest.json` records the commit, dependency pins, architecture, ZIP hash and documented app-tree fingerprint. It does not infer CI success. Use `TEXTTANK_SOURCE_ARCHIVES` to supply a directory of pinned archives for offline packaging if they are absent from `build/downloads`.

**Candidate-specific records:** `output/review/manifest.json` records the source commit and artifact fingerprints. The accompanying `output/review/validation.json` records final observed test/review results and exact-SHA CI status. Consult those records for the delivered candidate; this source document does not certify later changes or infer CI success. Validation is kept alongside the ZIP to avoid self-referential source/ZIP hashes.

## Five-minute walkthrough

1. Create a document and paste `café · ½ cup · 👩🏽‍💻` plus several lines. Exercise typing, selection, Undo/Redo and Save. Use synthetic review files.
2. Choose **View → Clone in Split View**. Edit either pane, Undo from the other, then close the split. The shared document should remain intact. The repaired viewport passed native tests and a CUA recheck showing both panes rendering Unicode text.
3. Use **Search → Find and Replace** for literal text, then try line move/duplicate, braces, bookmarks, folding and whitespace controls. Regex and multi-file search are not implemented.
4. Choose **Automations → Add Recipe Buttons** if your existing configuration has no recipe buttons. Give the two workflows your own names. Paste the full ingredient section, then click the cleanup toolbar button: it cleans the current editor directly, with one Undo. Click the separate Reminders button when ready to choose a list and Send. The saved step configuration controls behavior; the user-visible name never selects code. Advanced JSON supports editing steps, header regex, input/output, preview, shortcut and toolbar pin. Unknown unmarked content in a marked list aborts safely instead of dropping ingredients.
5. In a scratch document choose **Macros → Start Recording**, type a short string, then **Stop Recording**. Play the last recording with a repeat count and Undo. Save it under your chosen name. Native capture and replay tests pass; this exact menu walkthrough has not yet been observed through CUA.

6. Try the visible **Close Tab** X, then Cancel the unsaved-document dialog. Use **File → Save Session Snapshot** and **Open Session Snapshot**: snapshots restore as new unsaved documents, preserving text, encoding, selection and bookmarks without overwriting originals. **File → Print** creates a static monospaced print representation; complete reference printing options remain open.

Reminders export requires explicit access, destination and Send choices, with durable per-row outcomes/history. **No real EventKit access or export was tested.** Injected-store tests do not establish live connector behavior.

## Observed checks at this checkpoint

| Check | Observed result |
|---|---|
| FileChecks | 642 assertions |
| AutomationChecks | 47 assertions, including exact Markdown/native-copy28 rows and regex timeout |
| AutomationControllerChecks | 30 native assertions, direct same-editor apply/Undo and failure preservation |
| ReminderChecks | 35 assertions using injected stores only |
| BridgeChecks | 54 PASS lines |
| DocumentChecks | 64 native assertions, including detached-controller crash regression, session restore/recovery and static print view |
| WorkspaceChecks | 39 assertions, including private persistence and nonblocking FIFO rejection |
| MacroChecks | 12 pure; 24 native assertions |

The integrator observed Chrome's open RecipeTin ingredient container selected and copied with Command-C, then pasted into native TextTank with Command-V. One cleanup click produced all 28 rows in the same editor, without a preview. Only this one site was observed. Browser bookmark-manager access was blocked by browser security; no workaround was attempted. Separate named cleanup/send toolbar buttons, native naming configuration, visible close control, dirty-close Cancel/Undo and dirty-quit Cancel followed by saved quit were observed. Earlier observations include Unicode shared-pane editing and forced restart recovery of two snapshots.

Two concrete quit crash reports identified a detached document force-cast in a window-update observer. The controller teardown repair removes observers/callbacks and retains its editor safely; native lifecycle regression tests pass. See `harness/reviews/quit-crash-2026-11-14.md`. Full physical clean/dirty Quit Save/Discard/Cancel coverage remains open; absence of a new crash report alone does not prove process exit. Saved macro menu walkthrough, IME, VoiceOver and modal keyboard edge cases remain unverified.

Counts are assertions, not completed capabilities. The limited evidence ledger and external `output/review/validation.json` bind checks to sources and the delivered candidate. No final exact-SHA CI outcome is claimed here.

## Required work still open

- Finish the normalized reference inventory and freeze the actual official standard distribution artifact; package profile currently relies on pinned source recipes.
- Complete all encoding interpretation/conversion options, session/tab/window variants, external-change handling, metadata, broader fault/crash recovery and dirty-clone quit cases. A synthetic forced termination/restart recovered two snapshots, but that is not exhaustive recovery verification.
- Implement reference-compatible Boost regex/extended search and replacements, all scopes/results, count/mark, cancellation and macro search semantics.
- Complete advanced selections/column editing, all sort/case/comment variants, UDL/LexUser, language keyword/style data, completion/call tips, function lists and themes.
- Complete document/project/folder panels, monitoring, full printing options, preferences, shortcut/context customization and localization.
- Implement required Mac extension facilities, configured Run commands, and bundled mimeTools/NppConverter/NppExport equivalents. Windows DLL compatibility is not claimed.
- Complete macro command coverage/run-until-end and automation ask-at-run parameters, progress/cancellation, multi-selection output and all trigger/output combinations. Individual user-named toolbar pins now exist; complete trigger UI coverage remains open.
- Verify real EventKit with consent, IME/dead keys, VoiceOver, performance budgets, older macOS/Intel runtime, clean-checkout build, final exact-SHA CI and integrated independent review.

No tagged release or merge is authorized by this preview. Review findings and remaining gaps should drive the next implementation checkpoint.
