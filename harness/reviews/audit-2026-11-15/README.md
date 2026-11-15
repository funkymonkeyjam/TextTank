# TextTank independent improvement audit

Date: 2026-11-15. Audited local commit: `bcee103f2f6a845d68239ada65d1f7abaeabcb26`. Remote equivalent: `1a35c172ae0608f23a9fcfff3d7de35782b116f1`. Both have tree `1d8b1c74c9c65e783535be1646e24f6afacfb89a`.

## Assessment

The application is a useful but incomplete preview. The highest immediate priorities are restoring trustworthy acceptance checks, bounding automation resource use, and strengthening document safety. Recent visual improvements exposed gaps in the shared UI architecture and regression coverage. No full-parity, security-certification or release-readiness claim is justified.

This audit changed no production code or installed application. Findings below are open unless explicitly identified as an existing repair. A working feature or passing targeted suite does not cancel a different failure elsewhere. F07, F08, F11 and F13 are pre-existing issues discovered here; not all findings were introduced by recent UI changes.

## Review loop and independence

One integrator and three reviewers worked on the frozen source: native UX/accessibility and product coverage; automation/connectors/Run reliability; document/search/workspace safety and performance. Reviewers first examined their areas independently. A second adversarial pass challenged reachability, severity, existing mitigations and duplicate findings. The integrator checked source references, ran the full local acceptance entry point, inspected exact-candidate CI logs, and performed a bounded live keyboard/tab walkthrough.

Reviewers did not alter production files. Two reviewers independently exercised bounded automation expansion. Another pure-core probe used actual Run validation and storage primitives. No actual out-of-memory stress, connector writes, configured-command execution, personal-file mutation, or power-loss test was performed. Independence is procedural: reviewers are separate agents, not a separate external organization; the integrator authored some recent features and does not self-certify them.

## Observed verification

- Exact-candidate GitHub run [43667148429](https://github.com/funkymonkeyjam/TextTank/actions/runs/43667148429): native build succeeded; acceptance failed in DocumentChecks at `switching tabs preserves window geometry`. A screen existed in CI. Production frame defect versus overly strict test assumptions remains unresolved.
- Fresh local `scripts/test.sh`: failed compiling macro integration, with `cannot find TTAlert in scope`. Earlier stages passed: FileChecks 642, AutomationChecks 121, ReminderChecks 43, DocumentChecks 94, MacroChecks pure core 12. Local geometry assertions explicitly skipped because the test process reported no screens. Subsequent suites did not run after the fail-fast compile error. These counts are not capability percentages.
- Live installed-app check: Command-N created a second blank tab; Ctrl+Tab did not change tabs; Window listed only the visible document. Command-W closed the synthetic second tab. This is bounded keyboard evidence, not a complete accessibility assessment.
- Safe probes: a validated 20-step doubling workflow expanded one byte to 1,048,576 bytes while its sample tester rejected the same workflow. Independent 21-step probe reached 2,097,152 bytes. No OOM was attempted.
- Run validation and production storage accepted a 1,200,191-byte configuration; the production startup reader rejected it as `tooLarge`. No command was executed.
- `output/review/validation.json`, promised by delivery instructions, is absent. Packaging does not generate or copy it.

## Prioritized findings

Priority definitions: P1 is a reliability/acceptance blocker to address before broader rollout. P2 is a significant correctness, usability or defensive-reliability improvement. Confidence describes the evidence, not how frequently users will encounter the scenario.

### F01 - P1: Acceptance pipeline has two independent failures

**Evidence:** Reproduced local compile failure and observed exact-tree CI failure. `scripts/test-macros.sh:7` compiles MacroController without the file containing TTAlert (`Sources/Automations/AutomationStepEditor.swift:6`). The app builds because its source set is larger. CI stops earlier at `Tests/DocumentChecks.swift:232`, the real-display tab geometry assertion.

**Improve:** Extract the real shared dialog implementation into a shared UI source/module and include it consistently in every affected native test target. Do not add test-only dialog stubs. Diagnose tab activation frames with screen, content constraints and before/after geometry recorded; retain meaningful geometry assertions.

**Acceptance:** Every standalone runner compiles; clean full local suite and exact-candidate CI complete successfully, with explicit environment skips. A screen-backed tab switch/close test verifies intended geometry.

### F02 - P1: Production automation can expand without a resource bound

**Evidence:** Independently reproduced bounded expansion. `AutomationCore.swift:49,69-72,139` permits up to 100 steps without bounding ordinary literal replacement output. `AutomationController.swift:382` chooses synchronous execution from initial input size. Sample testing has a separate limit that does not protect actual Run.

**Impact:** A small, explicitly invoked workflow can monopolize the UI or exhaust memory. OOM is inferred, not exercised. Editor mutation occurs only after transformation returns; existing recovery snapshots are not shown to be destroyed. Changes still awaiting recovery could be at risk if the process terminates.

**Improve/acceptance:** Use overflow-safe preallocation limits for intermediate/output text and cooperative cancellation regardless of initial input size. With an injected small budget, expansion must reject before large allocation and preserve original text, Undo and dirty state.

### F03 - P2 conditional: Post-save baseline can adopt external content

**Evidence:** Source-established race candidate, not reproduced. `Sources/TextTankApp/App.swift:316-322` checks the prior baseline, writes through NSDocument, then rereads the pathname and adopts whatever bytes exist as the new baseline while marking the editor saved.

**Impact:** A noncooperating writer replacing the destination between write and baseline read could make differing disk bytes appear acknowledged, weakening the next conflict check. Native coordination and filesystem behavior require controlled verification; no observed loss is claimed.

**Improve/acceptance:** Track the exact successfully submitted bytes/revision as the baseline and explicitly handle subsequent external changes. Add an injectable post-write/pre-baseline interleaving test; later Save must not silently overwrite the intervening external edit.

### F04 - P2: Saved Run configuration can fail its own restart reader

**Evidence:** Reproduced using actual validation/storage primitives. `RunCore.swift:15` validates individual arguments; `RunController.swift:26-29` saves the aggregate JSON, but `:15` reads at most 1 MiB. Two 600,000-byte arguments produce an accepted 1,200,191-byte file that restart rejects.

**Improve/acceptance:** Validate encoded aggregate size before replacing the existing file. Test JSON escaping, multiple commands, exact boundary values and restart roundtrip. On rejection the previous configuration must remain intact.

### F05 - P2: Reminders journal write/read size limits disagree

**Evidence:** Source-established. `RemindersConnector.swift:120` permits 10,000 rows up to 1 MiB each. `:182-184` reads journals up to 32 MiB, while `:197-211` writes without that aggregate bound. A sufficiently large initial batch becomes unreadable by subsequent persistence/history enumeration.

**Improve/acceptance:** Reject over-budget encoded batches before creating a journal or external item, reserving space for outcomes/identifiers. Use an injected store at boundary sizes; no poisoned journal or connector write may remain. Live failure/retry verification remains separate from the user-confirmed successful recipe transfer.

### F06 - P2: Tab keyboard navigation and discovery regressed

**Evidence:** Source and live UI. `App.swift:394-398,462-465,516` hides other document windows and disables native tabbing without replacement next/previous commands. Ctrl+Tab did nothing; Window exposed only the active document.

**Improve/acceptance:** Add explicit next/previous-tab commands, a discoverable open-document list and stable focus restoration. Traverse three tabs, close the middle tab and return to editing using only the keyboard. Drag/reorder and separate-window groups remain documented capability gaps.

### F07 - P2: Session restore bypasses language profile application

**Evidence:** Independently corroborated source path. `WorkspaceController.swift:49-56` assigns text directly then passes a saved profile ID to raw `setLanguage`. `LanguageController.swift:71-80` is the proper profile-to-lexer/keywords/properties/styles mapping. Restore does not later invoke that path.

**Improve/acceptance:** Restore through the language controller with an explicit missing-profile fallback. Verify actual styled output after JavaScript, HTML, customized-profile and UDL session roundtrips; checking the displayed profile name is insufficient.

### F08 - P2: Workspace/recent open detects language before assigning filename

**Evidence:** Source-established. `WorkspaceBrowserController.swift:119` calls `read` before setting `fileURL`; detection at `App.swift:275` therefore receives an empty filename. No later detection occurs in that route.

**Improve/acceptance:** Establish file identity before detection, or explicitly detect after assigning it. Open extension-neutral content from `.py` and `.js` files through workspace/recent paths and verify the applied lexer/profile.

### F09 - P2: Hidden-tab status polling scales poorly

**Evidence:** Two reviewers corroborated the work, not a latency measurement. `App.swift:532,537-558` retains a 5 Hz timer per document; each enumerates the tab inventory and bookmarks. Changed text triggers whole-buffer extraction, scalar counting and UTF-8 array scanning. `:434-459` rebuilds tab controls after title/dirty changes.

**Improve/acceptance:** Share an event-driven tab model, suspend hidden-view polling, and compute expensive statistics from bounded/debounced snapshots or incremental data. Measure typing latency and memory with a large active file and 100 real hidden document controllers. Earlier buffer-only benchmarks do not establish this UI cost.

### F10 - P1: Bookmark Matches repeatedly scans full prefixes on the UI thread

**Evidence:** Source-established at `SearchController.swift:130-136`. Each hit scans text from the beginning to its offset after background search returns. The work is O(matches times document length), with no cancellation inside the loop.

**Bounded probe:** An optimized standalone Swift run of the exact prefix-counting algorithm visited 49,950,000 UTF-16 units in 0.320 seconds (100,000-character string, 1,000 offsets). This is not an end-to-end UI timing. Per-document accepted ceilings of 100,000 hits and 67,108,864 UTF-16 units allow vastly larger work; the result/deadline limits do not bound this phase.

**Improve/acceptance:** Compute line indices in one forward pass over sorted matches, preferably off the UI thread, then apply markers after revision validation. A bounded dense-match fixture must complete responsively and preserve CR/LF/CRLF semantics.

### F11 - P2: Recovery blocks the UI and can starve during continuous edits

**Evidence:** `App.swift:239-246` invalidates the only 500 ms timer on every edit and performs full extraction/storage on the main thread. `RecoveryStore.swift:50,57,123-128` includes JSON work and synchronized disk writes. Latency and actual crash-loss magnitude were not measured.

**Improve/acceptance:** Combine debounce with a maximum checkpoint interval; capture revision/text on main and serialize/store on an ordered background queue. With changes every 100 ms, a checkpoint must appear before editing stops. A delayed writer must not block UI work or recreate discarded snapshots after Close.

### F12 - P2: Status refresh replaces focused controls

**Evidence:** `App.swift:356-363` removes all status badges when any displayed value changes. The 5 Hz refresh can therefore destroy the keyboard/AX object being navigated. Object replacement is source-confirmed; VoiceOver disruption is not yet observed.

**Improve/acceptance:** Retain controls keyed by stable semantic field identity and update only changed properties. Verify focus and accessibility identity survive unrelated cursor/count/dirty changes, with actual VoiceOver and keyboard testing.

### F13 - P2: Automation startup reads an unbounded/nonregular file

**Evidence:** `AutomationController.swift:25-26` uses `Data(contentsOf:)`; `AutomationLibrary.decode` has no input-byte ceiling. An externally altered support path can be a symlink, FIFO or oversized regular file. Ordinary editor input does not create this condition.

**Improve/acceptance:** Use the existing bounded, nonblocking, regular-file/no-follow reader and a matching encoded write limit. Test adversarial support-file types in an isolated directory, preserving the existing file and showing an actionable recovery error.

### F14 - P2: Delivery and progress records lag actual evidence

**Evidence:** `docs/REVIEW-ME.md` promises a `validation.json` absent from the current package; `scripts/package-review.sh` does not emit it. `harness/state.json` still points to older automation checkpoints; T19 still cites 88 document assertions while later targeted runs reached 94. Separate connector-published commit ancestry makes tree identity essential.

**Improve/acceptance:** Generate a candidate-bound validation record with local and remote commit/tree IDs, test exit status, skips, actual CI outcome and app/archive hashes. Validate its presence inside the ZIP and keep state/task references synchronized. Never inherit a prior green result onto a newer candidate.

## Ordered improvement loops

1. **Restore the evidence foundation:** F01 and F14. Exit only when all runners compile, display-backed geometry is diagnosed, full suite finishes and the package accurately records the result.
2. **Protect data and availability:** F02, F04-F05, F10 and F11; then the conditional F03 race. Use injected small budgets, deterministic race hooks and fake stores; independently re-review every repair. Keep Reminders sends explicit and recipe cleaning a single editor Undo.
3. **Make everyday use coherent:** F06-F08 and F12. Test three-document keyboard flows, real session styling and stable accessibility focus.
4. **Measure and control scaling:** F09 and F13, including end-to-end confirmation of F10. Establish latency/memory budgets using actual windows, not just buffers; reject unsafe storage inputs before allocation or blocking IO.
5. **Resume full capability work:** retain every open parity requirement, then close behavior rows using exact-candidate evidence. IME, VoiceOver, supported runtime/architecture, complete encoding/search/language/plugin equivalence and live connector fault cases remain open.

For each loop: capture a minimal failing case, make a bounded repair, rerun the affected suite, have a different reviewer challenge it, then run the integrated gate. Stop repeating tests when no new code or unresolved concern justifies them. Completion requires the expected behavior, not merely a green build.

## Boundaries and positive findings

NSDocument and Scintilla remain the authoritative document/Undo model. Existing stale-editor guards, explicit shell-mode selection, separate arguments and explicit connector dispatch are meaningful safeguards. User-confirmed Reminders success remains valid happy-path evidence. Prior tab identity/dirty-close repairs are present; this audit does not undo them.

The Reminders uncertainty journal's power-loss durability remains a known validation gap; atomic rename without directory synchronization is not proof of post-power-loss persistence, and no duplicate-send failure was demonstrated. No platform-wide accessibility, crash-fault, performance, Intel or macOS 14 certification was performed. Findings are a prioritized engineering backlog, not an exhaustive audit or completion percentage.

## Retained diagnostic

`BoundedProbes.swift` retains the non-destructive Run/automation diagnostic. It uses a unique temporary directory, removes its own fixture, and never executes a configured command. Compile it with `Sources/Run/RunCore.swift`, `Sources/Workspace/WorkspaceCore.swift`, `Sources/Documents/FileCodec.swift` and `Sources/Automations/AutomationCore.swift`. The diagnostic demonstrates the current mismatch; after repairs its expectations should be replaced by rejection/preservation regression tests.
