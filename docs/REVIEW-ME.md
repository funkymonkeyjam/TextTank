# TextTank — incomplete review build

Native Swift/AppKit, Scintilla Cocoa and Lexilla editor with Carbon Caret branding. This build adds substantial working functionality; **full standard Notepad++ coverage is not complete or certified**. All required behaviors remain in the ledger. No menu count or assertion count is a capability completion percentage.

Repository: https://github.com/funkymonkeyjam/TextTank

Unmerged PR: https://github.com/funkymonkeyjam/TextTank/pull/1

## Run

From the repository root:

```sh
./scripts/launch-review.sh
```

This launches `output/review/TextTank-review.zip` after extraction to a temporary directory outside synced storage. The package also contains `Launch-TextTank.command`, the application, source/dependency archives, licenses and hashes. `output/review/manifest.json` identifies the packaged commit/tree and archive; `validation.json` records observed tests and exact remote CI. Read those candidate-specific records instead of inferring results from an older run.

Rebuild and test on an arm64 Mac with Xcode:

```sh
./scripts/build.sh
./scripts/test.sh
./scripts/test-performance.sh
```

Launch a development build:

```sh
open build/DerivedData/Build/Products/Debug/TextTank.app
```

To package a committed clean source tree:

```sh
./scripts/package-review.sh
(cd output/review && shasum -a 256 -c SHA256SUMS)
```

The minimum deployment target remains macOS 14. Local testing used the current arm64 host; a deployment target is not macOS 14 runtime evidence. Ad-hoc signing is for local review and is not notarized public distribution. Initial pinned dependency downloads need network access; ordinary editing and deterministic automations do not need an account or paid service.

## Review walkthrough

Use synthetic scratch files, not personal documents.

1. **Editing and files:** paste `café · ½ cup · 👩🏽‍💻`, save, clone in split view, edit either pane and Undo from the other. Try line transforms, rectangular/multiple selections, Column Insert / Number, language-specific comments, and EOL conversion. Encoding conversion retains text; Reload As reinterprets disk bytes and confirms discarding dirty text. Read Only prevents mutation. The visible Close Tab X retains native Save/Discard/Cancel review.
2. **Search:** use Search → Find and Replace. Select Normal, Extended or Regular expression (Boost); test `([a-z]+)=(\d+)` → `$1:$2`, count/results, selection/current/all-open scopes and Undo. Folder search supports explicit saved workspace roots, include/exclude filters and skipped/partial outcomes. Disk replacement is separately confirmed, skips open documents, makes private recovery copies/reports, and reports each file; it is not atomic across files.
3. **Languages:** choose Python, paste a class with a function, open Function List and double-click the symbol. Try keyword completion, syntax font/color settings and synthetic UDL XML import/edit/export. A real ported LexUser handles tested keyword/comment/delimiter cases; complete language/UDL/API semantics are still open.
4. **Workspace:** open the document/folder/recent browser, save/reopen a session snapshot, and explicitly enable Monitor Current File. Monitoring reports changes without replacing editor text. Reload remains explicit and protects dirty buffers. Printing uses a detached representation rather than a second editable model.
5. **Macros and automations:** record a named editing/search macro, play it and Undo. Test repeat/Stop. Create or rename a workflow, edit/reorder processing steps, choose runtime parameters, and verify labels follow its saved name. Import/open/restore never executes a shell command or connector output.
6. **Recipe:** paste the complete ingredient section. Click the existing named cleanup button: it transforms the same editor and one Undo restores the original. The separate Add to Reminders action still requires choosing/reviewing a destination and explicit Send. **The user confirmed a successful live ingredient transfer.** Additional tests in this run use injected stores; they do not establish live revocation/deleted-list/partial-write behavior. Do not use a personal list for fault tests.
7. **Utilities and Run:** try Base64/URL/quoted-printable/hex/number conversions and styled HTML/RTF export. Add the sample text extension under Run, invoke it on synthetic text, inspect the preview and explicitly Apply. Argv stays separate unless intentional shell mode is configured. Run cancellation/output limits and stale preview guards have focused tests; see `EXTENSIONS-AND-RUN.md`.
8. **Settings and closing:** change a nonconflicting shortcut/font setting, restart and check persistence. Exercise dirty close and Quit Save/Discard/Cancel with scratch documents. Earlier Quit-crash repairs and detached-controller regression tests remain in place; the complete physical dialog matrix is not certified by automated tests alone.

## Evidence and repaired findings

The detailed records are in `harness/reviews/` and `docs/parity/implementation-evidence.json`. Observed suite results are bound to source hashes in ignored logs and the delivered validation record. The native walkthrough observed Unicode save, actual Boost replacement, Python rendering, symbol navigation and native step-editor controls.

Independent reviews found and repaired default shortcut collisions, canonical-Unicode duplicate-line loss, invalid-surrogate regex replacement, shared AppKit field-editor confusion, detached/stale extension application, an old preview applying a newer result, leading-FEFF output loss, corrupt workspace settings overwrite, and discarded folder-replacement outcomes. Additional scope/indicator changes require their own final results rather than inheriting those passes.

Synthetic native performance checks covered 1/10/100 MiB loading, literal find, a replacement and Undo, a 10 MiB long line, and creation of 100 independent buffers. They do not establish physical scroll responsiveness, 100 actual tabs, every search mode, disk/recovery budgets or sustained memory behavior. The observed peak memory includes fixture construction and text verification copies.

## Required gaps and external validation limits

- Reference normalization retains every seed plus discovered dialog/language surfaces, but is not a fully verified behavioral denominator. Official release metadata/hash is recorded; downloaded binary bytes and source/release differences remain unresolved. The same version label covers different source commits.
- Complete encoding/code-page choices, coordinated save fault/race coverage, metadata/recovery/dirty-clone lifetime combinations, monitoring/tail-follow and every tab/window/session variant remain open.
- Search still needs full Windows reference differential tests, uncommon wildcard/locale/word-boundary behavior, true project-file membership, every history/mark/dialog option and broad pathological/performance coverage. A noncooperating external writer can race a final per-file compare/rename; recovery reports do not constitute an automatic recovery UI.
- Advanced editor command variants, full macro command coverage, document-map behavior, all preference/shortcut/context/toolbar customization and localization remain incomplete.
- Imported language configurations are not full semantic tests. Objective-C and internal SearchResult-specific patched lexer factories are not supplied by stock Lexilla. Complex embedded/substyle/UDL nesting/folding/number/lifetime behavior, API-signature completion/call tips and upstream function-list XML semantics remain incomplete or unverified.
- The version 1 text-extension interface is a tested Mac equivalent for explicit text transforms, not the entire Notepad++ plugin event/message ecosystem. Utility reference malformed/binary/options semantics have documented differences in `docs/research/utility-audit.md`.
- Live connector failure/retry verification needs a designated scratch Reminders list. User-confirmed success closes only that observed happy path. IME/dead keys, VoiceOver, complete keyboard/light/dark/high-contrast checks and actual macOS 14/Intel runtimes remain unverified.

No merge, tagged release, public-release certification or full-parity claim is implied.
