# TextTank — INCOMPLETE PREVIEW

A launchable native Swift/AppKit editor using Scintilla Cocoa and Lexilla, with the selected Carbon Caret identity. This is a working review checkpoint, **not** a completed Notepad++ replacement. Every standard capability in the frozen reference remains required; no missing feature has been waived.

Repository: https://github.com/funkymonkeyjam/TextTank

Unmerged implementation PR: https://github.com/funkymonkeyjam/TextTank/pull/1

## Run and rebuild

From the repository root, launch the packaged candidate:

```sh
open output/review/TextTank.app
```

The packaging script produces `output/review/TextTank-review.zip`. The development build can also be launched with:

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
4. Choose **Automations → Manage Automations**. Keep the generated UUID, choose your own name, set input to `selection` or `clipboard`, and output to `newDocument`. The example steps remove bullet markers and blank rows. An optional lowercase `shortcut` binds Command-Option-letter. Save, invoke it, edit/cancel the preview, then apply. Try `• 2 eggs`, `- ½ cup flour`, `1/2 tsp salt` and duplicate rows. Quantities and duplicates should survive. Rename the workflow while keeping its ID to retain bindings.
5. In a scratch document choose **Macros → Start Recording**, type a short string, then **Stop Recording**. Play the last recording with a repeat count and Undo. Save it under your chosen name. Native capture and replay tests pass; this exact menu walkthrough has not yet been observed through CUA.

Reminders export is implemented behind explicit access, destination and Send choices, with durable per-row results/history. **No real export was tested.** Live testing requires your consent and a designated writable scratch list. Do not mistake the fake-store tests for EventKit verification.

## Observed checks at this checkpoint

| Check | Observed result | What it establishes |
|---|---|---|
| FileChecks | 642 assertions passed | Supported encodings, private recovery storage and actual SIGKILL persistence fixtures |
| AutomationChecks | 17 assertions passed | Transform preservation, schema validation, identity/bindings |
| ReminderChecks | 33 assertions passed, injected stores only | Permission/destination/error/retry/privacy contracts at the fake boundary |
| BridgeChecks | 45 PASS lines in inspected log | Actual native Scintilla bytes, clones/undo, selected commands, styles/folding and macro capture |
| DocumentChecks | 49 assertions passed after repairs | Native saves/conflicts/failures, clone geometry, BOM/revert, private workflow storage and clean-quit policy |
| MacroChecks | 12 pure; 24 with native conditional enabled | Persistence, actual find/replace repeat/grouped Undo, and rejection of incomplete recordings |
| Native CUA | Selected flows observed | Window, Unicode clipboard paste, shared editing/Undo, dirty-close Cancel, Save, named automation shortcut/preview/new-document output, forced restart recovery of two snapshots, both panes visibly rendering |

**UI rechecks still open after the final routing changes:** physical clean/dirty Quit termination; Save-panel filename selection; modal editing shortcuts; immediate replacement-field execution; and the saved-macro menu walkthrough. Native clean-quit policy tests do not prove that the onscreen process exited. The final CUA recheck failed with `cgWindowNotFound` while targeting Finder, so it did not supply that missing verification. IME and VoiceOver remain unverified.

These are assertion counts, not feature counts. The [limited evidence ledger](parity/implementation-evidence.json) records source/log hashes and limitations. [Native UI observations](../harness/reviews/native-ui-observations.json) identify observed flows and remaining UI rechecks. The broad capability matrix is deliberately not marked complete.

## Required work still open

- Finish the normalized reference inventory and freeze the actual official standard distribution artifact; package profile currently relies on pinned source recipes.
- Complete all encoding interpretation/conversion options, session/tab/window variants, external-change handling, metadata, broader fault/crash recovery and dirty-clone quit cases. A synthetic forced termination/restart recovered two snapshots, but that is not exhaustive recovery verification.
- Implement reference-compatible Boost regex/extended search and replacements, all scopes/results, count/mark, cancellation and macro search semantics.
- Complete advanced selections/column editing, all sort/case/comment variants, UDL/LexUser, language keyword/style data, completion/call tips, function lists and themes.
- Complete document/project/folder panels, monitoring, printing, preferences, shortcut/context customization and localization.
- Implement required Mac extension facilities, configured Run commands, and bundled mimeTools/NppConverter/NppExport equivalents. Windows DLL compatibility is not claimed.
- Complete macro command coverage/run-until-end and automation ask-at-run parameters, progress/cancellation, multi-selection output, individual toolbar pins and all trigger/output combinations. Generic toolbar/palette/context entry points exist; their complete UI behavior is not yet verified.
- Verify real EventKit with consent, IME/dead keys, VoiceOver, performance budgets, older macOS/Intel runtime, clean-checkout build, final exact-SHA CI and integrated independent review.

No tagged release or merge is authorized by this preview. Review findings and remaining gaps should drive the next implementation checkpoint.
