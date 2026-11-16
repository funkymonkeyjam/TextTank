# TextTank — incomplete review build

Native Swift/AppKit, Scintilla Cocoa and Lexilla editor with Carbon Caret branding. This build adds substantial working functionality; **full standard Notepad++ coverage is not complete or certified**. All required behaviors remain in the ledger. No menu count or assertion count is a capability completion percentage.

Repository: https://github.com/funkymonkeyjam/TextTank

Identify the candidate by its source commit/tree and validation record, rather than by a branch or an older review. A work-branch checkout may include changes not yet merged to `main`.

Interface rules: [DESIGN-STANDARDS.md](DESIGN-STANDARDS.md).

## Run

First create a clean, committed review package with `scripts/build.sh`, `scripts/test.sh` and `scripts/package-review.sh` (the commands below). Then, from the repository root:

```sh
./scripts/launch-review.sh
```

This verifies the archive against `SHA256SUMS`, then launches `output/review/TextTank-review.zip` after extraction to a temporary directory outside synced storage. The launch command waits for the application to exit and removes that temporary copy afterward; if its wait is interrupted, it keeps the potentially running copy and prints its location. The package also contains `Launch-TextTank.command`, the application, source/dependency archives, licenses and hashes. `output/review/manifest.json` identifies the packaged commit/tree and archive; `validation.json` records observed tests and labels any manually supplied CI metadata as self-reported; it never treats that metadata as verified remote CI. Read those candidate-specific records instead of inferring results from an older run.

From an arm64 source checkout with Xcode and Python 3.9 or newer, build before running native suites:

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

Build identity is shared by `scripts/env.sh`, the dependency lock and the generator. `CONFIGURATION=Debug` is the default; set `CONFIGURATION=Release` for **each** build, test, performance and package command to exercise the independent optimized engine/app outputs. Only arm64 is supported by this build workflow. Debug and Release Lexilla sources/objects and Scintilla outputs are isolated under `build/vendor/<configuration>/`; changing the configuration cannot reuse the other configuration's objects.

The minimum deployment target remains macOS 14. Local testing used the current arm64 host; a deployment target is not macOS 14 runtime evidence. Ad-hoc signing is for local review and is not notarized public distribution. Initial pinned dependency downloads need network access; ordinary editing and deterministic automations do not need an account or paid service.

## Low-code automation rules

Open Automations → Manage Automations → Edit → Edit Rules & Test. The native builder shows an ordered rule list, plain-language rule choices, editable parameters and isolated sample/result panes. Add, duplicate, move and remove rules; use Test Rules before saving. Load Rules offers saved automations, general templates and portable import/export. Its recipe template loads editable rules for the four supplied samples while preserving earlier browser/Markdown cleanup. It changes only the draft until Use These Rules and Save. See [automation guide](AUTOMATION-RULES.md).

## Review walkthrough

Use synthetic scratch files, not personal documents.

1. **Editing and files:** paste `café · ½ cup · 👩🏽‍💻`, save, clone in split view, edit either pane and Undo from the other. Try line transforms, rectangular/multiple selections, Column Insert / Number, language-specific comments, and EOL conversion. Encoding conversion retains text; Reload As reinterprets disk bytes and confirms discarding dirty text. Read Only prevents mutation. Each tab's own close button (and ⌘W) retains native Save/Discard/Cancel review; the toolbar has no separate Close Tab button.
2. **Search:** use Search → Find and Replace. Select Normal, Extended or Regular expression (Boost); test `([a-z]+)=(\d+)` → `$1:$2`, count/results, selection/current/all-open scopes and Undo. Folder search supports explicit saved workspace roots, include/exclude filters and skipped/partial outcomes. Disk replacement is separately confirmed, skips open documents, makes private recovery copies/reports, and reports each file; it is not atomic across files.
3. **Languages:** choose Python, paste a class with a function, open Function List and double-click the symbol. Try keyword completion, syntax font/color settings and synthetic UDL XML import/edit/export. A real ported LexUser handles tested keyword/comment/delimiter cases; complete language/UDL/API semantics are still open.
4. **Workspace:** open the document/folder/recent browser, save/reopen a session snapshot, and explicitly enable Monitor Current File. Monitoring reports changes without replacing editor text. Reload remains explicit and protects dirty buffers. Printing uses a detached representation rather than a second editable model.
5. **Macros and automations:** record a named editing/search macro, play it and Undo. Test repeat/Stop. Create or rename an automation, edit/reorder its rules, choose runtime parameters, and verify labels follow its saved name. Import/open/restore never executes a shell command or connector output.
6. **Recipe:** paste the complete ingredient section. Choose the saved cleanup automation from the Automations menu or toolbar dropdown: editor output transforms the same document and one Undo restores the original. Favorites are ordered first in the toolbar dropdown and editor context menu; the menu bar uses stored order. The separate Add to Reminders action still requires choosing/reviewing a destination and explicit Send. **The user confirmed a successful live ingredient transfer.** Additional tests in this run use injected stores; they do not establish live revocation/deleted-list/partial-write behavior. Do not use a personal list for fault tests.
7. **Utilities and Run:** try Base64/URL/quoted-printable/hex/number conversions and styled HTML/RTF export. Add the sample text extension under Run, invoke it on synthetic text, inspect the preview and explicitly Apply. Argv stays separate unless intentional shell mode is configured. Run cancellation/output limits and stale preview guards have focused tests; see `EXTENSIONS-AND-RUN.md`.
8. **Settings and closing:** change a nonconflicting shortcut or indentation setting in Settings, restart and check persistence. The shortcut picker shows the selected command’s current key, keeps edits when switching commands, and Clear Custom Shortcut removes that override. Clearing Duplicate Line restores Command-D; Reset Defaults resets all settings. Invalid saved shortcut entries are listed separately while other settings remain usable; only an explicit Save repairs them and retains the original settings file beside the repaired one. Per-language font name/size are edited in Language Profiles. Status-bar text size is per-view zoom and is not persisted. Exercise dirty close and Quit Save/Discard/Cancel with scratch documents. Earlier Quit-crash repairs and detached-controller regression tests remain in place; the complete physical dialog matrix is not certified by automated tests alone.

## Where things are

A short inventory of features that the walkthrough above does not name, and of where two commands moved.

- **Status bar.** Every field at the bottom of a document window is a button that opens options: document (Save, Save As, Read Only), bookmarks, language, position (Go to Line…), selection, text size, indentation (tabs or spaces and width, for this document), encoding (re-read or convert), line endings and wrap.
- **Go to Line.** Search → Go to Line… (⌘L), and the position field of the status bar.
- **Closing.** The red close button of the window quits TextTank, reviewing unsaved documents first. One tab closes from its own × button, File → Close or ⌘W.
- **Tabs.** Window → Next Tab (⌃⇥), Previous Tab (⌃⇧⇥) and Open Documents…. Closing a tab shows the tab beside it; closing a background tab from its × returns to the tab that was active. Document windows do not enter full screen, because each tab is its own window.
- **Find bar and Find window.** Search → Find… (⌘F) opens the find bar above the text; it is hidden until then. Return finds the next match, ⇧Return the previous one, Escape or Done closes it. Find Next (⌘G), Find Previous (⇧⌘G) and Use Selection for Find (⌘E) share its text with the system find pasteboard, and act on the Find and Replace window instead while that window is open. A failed find says “No matches” in the status line. Search → Find and Replace… (⌥⌘F) is a panel: the document's own commands (Save, Encoding, Close Split View) keep working while it has the keyboard, Return in its Find field is Find Next, Escape closes it, and Return on a selected result opens it. Its Mark Matches, Clear Marks and Bookmark Matches buttons highlight or bookmark matches without editing.
- **Find in Folder and Function List.** Return on a selected row opens it, as a double-click does. Escape closes Find in Folder while it is idle.
- **Automations.** Automations → Automation Palette… (⇧⌘P) is the one entry for the palette. A right-click in the text shows the edit commands followed by the saved automations. Automations → Review Reminder Export History… lists earlier exports and offers Request Access and Resume Unsent.
- **Language.** Language → Show Keyword Help and Edit Language Profiles….
- **Workspace.** Workspace → Reload Monitored File… is the explicit reload after a reported change.
- **Text Utilities.** Includes SAML Decode.
- **Settings.** TextTank → Settings… includes the appearance override (system, light or dark). ⌘H, ⌥⌘H and ⌘L are application shortcuts and cannot be assigned to an editor command.
- **Edit menu.** Commands are grouped into Lines, Indentation and Whitespace, Convert Case, Comment, Selection, Delete and Line Endings.
- **Open Recent and dropped files.** File → Open Recent lists recent documents, with Clear Menu. A file dragged from Finder onto the text opens as a document.
- **Save state.** The status line reads Edited from the moment a document changes, then “Edited — recovery copy kept” once the crash-recovery copy is written. It reads Saved only for an unchanged saved document.
- **Confirmations.** Where the first button deletes or replaces something on disk, Return is Cancel and the action needs a click. Settings → Reset Defaults asks first. Saving Settings leaves indentation or wrapping chosen for one document in the status bar as it was.
- **Standard menus.** TextTank → Services, Hide TextTank, Hide Others and Show All; Window → Bring All to Front; Help, whose search field finds any menu command.
- **Window positions.** The document window and each tool window reopen where they were left.

## Evidence and repaired findings

Use the exact candidate's `validation.json` and `Evidence/full-acceptance.log` when reviewing a package. In a source checkout the current local records are ignored under `harness/logs/`. Clean start/end source trees and the acceptance-log SHA-256 bind the record; native exit-zero runs without their completion summary are failures. Exported diagnostics normalize known local paths while retaining original/public log hashes. Packaging refuses dirty, mismatched or unrooted source evidence and invalid signed artifacts. A successful build's signature check is immediate; later file-provider metadata or analysis tools can change the on-disk bundle, so package-time verification is required.

The [compact requirement matrix and dated source/check mappings](parity/README.md) replace the stale incremental evidence ledger. [Historical provenance](research/README.md) distinguishes source observations, earlier user-reported runtime observations and current candidate acceptance. Earlier walkthroughs do not certify this candidate's GUI behavior.

Independent reviews found and repaired default shortcut collisions, canonical-Unicode duplicate-line loss, invalid-surrogate regex replacement, shared AppKit field-editor confusion, detached/stale extension application, an old preview applying a newer result, leading-FEFF output loss, corrupt workspace settings overwrite, and discarded folder-replacement outcomes. Additional scope/indicator changes require their own final results rather than inheriting those passes.

Synthetic native performance checks covered 1/10/100 MiB loading, literal find, a replacement and Undo, a 10 MiB long line, and creation of 100 independent buffers. They do not establish physical scroll responsiveness, 100 actual tabs, every search mode, disk/recovery budgets or sustained memory behavior. The observed peak memory includes fixture construction and text verification copies.

## Required gaps and external validation limits

- Reference normalization retains every seed plus discovered dialog/language surfaces, but is not a fully verified behavioral denominator. Official release metadata/hash is recorded; downloaded binary bytes and source/release differences remain unresolved. The same version label covers different source commits.
- Complete encoding/code-page choices, coordinated save fault/race coverage, metadata/recovery/dirty-clone lifetime combinations, monitoring/tail-follow and every tab/window/session variant remain open.
- Search still needs full Windows reference differential tests, uncommon wildcard/locale/word-boundary behavior, true project-file membership, every history/mark/dialog option and broad pathological/performance coverage. A noncooperating external writer can race a final per-file compare/rename; recovery reports do not constitute an automatic recovery UI.
- Advanced editor command variants, full macro command coverage, document-map behavior, all preference/shortcut/context/toolbar customization and localization remain incomplete.
- Imported language configurations are not full semantic tests. Objective-C and internal SearchResult-specific patched lexer factories are not supplied by stock Lexilla. Complex embedded/substyle/UDL nesting/folding/number/lifetime behavior, API-signature completion/call tips and upstream function-list XML semantics remain incomplete or unverified.
- The version 1 text-extension interface is a tested Mac equivalent for explicit text transforms, not the entire Notepad++ plugin event/message ecosystem. Utility reference malformed/binary/options semantics have documented differences in [the utility notes](research/utility-audit.md).
- Live connector failure/retry verification needs a designated scratch Reminders list. User-confirmed success closes only that observed happy path. IME/dead keys, VoiceOver, complete keyboard/light/dark/high-contrast checks and actual macOS 14/Intel runtimes remain unverified.

This walkthrough and local checks do not imply a merge, tagged release, public-release certification or full-parity claim. Running-app GUI, VoiceOver and real connector failure scenarios still need explicitly authorized observation.
