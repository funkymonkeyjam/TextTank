# Architecture

Scintilla owns authoritative UTF-8 bytes and undo. TTEditor bridges Cocoa through Objective-C++; Swift never keeps a second mutable buffer. NSDocument owns file identity, encoding metadata, safe save coordination and window lifecycle. Clones share the Scintilla document, not independent string snapshots: text, read-only, tab settings, line-ending mode, lexer and keyword lists, bookmarks, highlights, undo and the save point are document state, while wrap, zoom, selection, syntax styles, margins and whitespace visibility are per view (TTEditor.h lists both). Line numbers, whitespace marks and line-ending marks are view state that Editor Settings sets alike on every document view; a pane's own zoom is kept in its tab's session record. A view's horizontal scroll range starts at nothing and tracks the widest line laid out, so an empty or narrow document has none; comparison panes keep one fixed range because they scroll together. A clone copies view state from the pane it was made from and never rewrites document state; a language or style change installs the lexer once and copies styles to the other pane. The current editor has one definition, `AppDelegate.currentEditor`: the active presentation in the single workspace host, including its last-focused Clone. Ordinary auxiliary panels do not change that target. A key D1 comparison or source picker blocks workspace editing dispatch and current-editor providers until workspace focus returns. Each document retains a windowless EditorWindowController adapter and its presentation; WorkspaceWindowController alone owns the native window and shared toolbar. Native document-action entry points reveal their captured document for review; TextDocument.windowForSheet only returns its host and has no focus side effect. EditorLifetime separates open document, detached view and visible tab facts, retaining closed/retired markers independently of native-window presence. See [the tab model](tab-model.md) for invariants, empty workspace and codec-only layout state. Getters remain pure; focus changes are explicit, and captured operations retain revision and selection guards. Main-thread editor access only. Capture revision for transforms; reject stale output. No side effects on open/import/restore.

For very long lines of single-style printable ASCII, the default editor face can use fixed cell positions after Scintilla verifies its advance. The editor draws the cells near the viewport and still uses its normal shaping path for tabs, custom representations, proportional type and bidirectional text.


Native macro recording/playback carries immutable `TTMacroAction` values for insertion, symbolic commands or a named unsupported action. Numeric messages are diagnostic only and never dispatch. The persisted associated-value `RecordedMacro.Step` codec and bytes remain unchanged; actual JSON decoding, not a second native dictionary adapter, checks malformed/unknown fields. Unencodable insertions are rejected before selection generation changes, using the same single encoding and Scintilla Undo path.

All exported snapshot/value classes deny KVC direct-ivar writes as well as exposing no setters. Native field-by-field checks retain their complete values, equality and hashes after rejected mutation, including typed search results. Cancellation remains explicitly mutable and atomic.

Snapshot search takes `TTSearchMode`, mapped exhaustively from unchanged persisted `SearchOptions.Mode` integers. Typed `TTSearchMatch`/`TTSearchResult` remain the only result interface; the test-only dictionary selector is retired, while its full-text/range/replacement behavior is checked through the typed API.

Native commands use `TTEditorCommandIdentifier`, a distinct Swift-imported typed identifier over the existing on-disk strings. Product dispatch maps the validated `EditorCommand` catalog; unknown or non-string foreign values are rejected before state/notification changes. The numeric table, replay-only aliases and canonical recording choices are unchanged; map membership checks test pointer presence, never an NSNumber Boolean value.

Native EOL changes use `TTLineEndingMode`; its codes retain Scintilla CRLF=0/CR=1/LF=2. Both conversion and insertion-mode setters report rejection for unknown codes. The pure `LineEnding` string vocabulary remains unchanged; the runtime adapter maps it exhaustively, and insertion mode still changes no text, save point or Undo history.

`TTTextEdit` pairs an immutable byte span with copied replacement text. The public edit API accepts no dictionaries; it validates every typed edit and every encoded string before opening the single Scintilla Undo group. Comment application constructs those values directly from its pure edit plan.

Editor replacement/highlight spans are `TTByteRange` values, distinct from the UTF-16 `NSRange` carried by snapshot search results. Negative lengths, overflow, wrong foreign object types, scalar splits and all batch bounds are rejected before engine mutation. Search applies its existing validated UTF-16-to-byte conversion before constructing byte spans.

Selections cross the native boundary as immutable `TTSelectionRange` byte-position values. Every position, overlap and UTF-8 boundary is validated before any selection changes; a foreign object is rejected. Pure comment planning uses its own Foundation-only `EditorSelection` value and converts at the AppKit application adapter. No selection dictionaries remain in the product interface.

`TTEditor.statusInfo` returns immutable `TTEditorStatus` metadata with required typed fields, including zero-valued line-ending modes and false indentation flags; there is no status dictionary fallback. It captures no editor reference and querying it never mutates the engine.

The Swift composition header explicitly imports the editor and snapshot-search interfaces. `TTEditor.h` is independently compilable without the Search tree; its public interface has no search dependency.

Pinned clean engines precede explicit audit/port of Notepad++ UDL and Boost regex deltas. Native app target in TextTank.xcodeproj; scripts build exact dependencies before xcodebuild.

## Ownership and enforcing files

| Invariant | Owner and focused evidence |
| --- | --- |
| One authoritative UTF-8 document/Undo history; main-thread bridge access | `Sources/EditorBridge/TTEditor.h/.mm`; bridge and split-view document checks |
| Captured/revalidated save payload, disk identity and recovery lifecycle | `TextDocument` in `Sources/TextTankApp/TextDocument.swift`; `DocumentOpenSaveChecks` and file/recovery checks |
| Strict bytes and private atomic recovery writes | `FileCodec`, `RecoveryStore`, `RecoveryWriter` in `Sources/Documents/`; `FileChecks` |
| Snapshot search, revision guards and descriptor/fingerprint-gated folder replacement | `SearchController`, `FolderSearch`, `FolderReplacement` in `Sources/Search/`; search/controller/replacement checks |
| Named, versioned automations and inert imports | `AutomationCore`/`AutomationController`; automation and controller checks |
| Explicit bounded process execution and stale-result refusal | `Sources/Run/`; Run/core/controller checks |
| Uncertain Reminders barrier and explicit destination | `RemindersConnector`; injected-store checks, with live fault limits stated separately |
| Current build/source/log identity | `Dependencies.lock.json`, `scripts/env.sh`, `record-validation.py`, `suite-lib.sh` and `package_review.py`; isolated pipeline/runner fault checks |

Recovery reads now use the shared descriptor-anchored, no-follow regular-file reader, closing the earlier check-then-use gap. They retain `Int.max` capacity to preserve existing large-snapshot compatibility and still materialize the complete JSON snapshot. This is not a practical memory ceiling; private atomic writes do not imply bounded memory use.

This table names ownership rather than asserting full parity. Dated per-capability source/check mappings and unassessed requirements are in [the matrix guide](parity/README.md). Temporary strings for I/O/immutable background work are not a second mutable document model. Generated `TextTank.xcodeproj` is derived by `scripts/generate-project.py`; explicit narrow suite source lists continue to enforce core layering.

## Editor commands and shortcut repair

`EditorCommand` in `Sources/Documents/EditorCommandCatalog.swift` owns stable Swift identifiers, display names, fixed menu keys, assignable defaults and explicit recordable/view-only/assignable subsets. Menu placement stays literal, in one function per top-level menu in `Sources/TextTankApp/MainMenu.swift`; each controller builds its own items and the menu bar only decides where they are listed (DS-D4). The bridge derives dispatch, replay and canonical recording maps from one numeric table; replay-only `indent`/`unindent` aliases never compete with `tab`/`backTab` in recordings. The frozen pre-refactor contract retains all 84 supported identifiers, 62 replayable names, 60 canonical recording messages and the exact text-changing subset. A routed unknown identifier returns failure before text, selection-generation or notification changes. Custom menu validation disables unavailable/text-changing commands when necessary and reads actual per-view toggle states; status menus use the same command names and current keys.

Editor Settings keeps `shortcuts: [String: String]` and is version 1 or 2 (see "A shortcut for any command" below). The optional Boolean `autoIndent` controls indentation on Return in all editor views. The optional Boolean `braceHighlight` controls live brace feedback at each view’s primary caret. Automatic feedback examines up to 4,096 bytes in each candidate’s search direction and clears its cue when the result is indeterminate. Matching Brace and Select to Matching Brace search the full document. The optional Booleans `currentLineHighlight` and `indentGuides` control a frame around the focused editor's caret line and native dotted indentation guides. Existing files without these four keys default to enabled. The optional Booleans `lineNumbers`, `showWhitespace` and `showLineEndings` hold View → Show Line Numbers, Show Whitespace and Show Line Endings for every document view: line numbers default to shown and both kinds of mark to hidden, so a file without them loads as before. Those three stay catalog commands in the View menu; the active tab routes them to the settings store, one write applies the choice to every open view (both panes of a split and every editor group) and to tabs opened later, and the menu checkmark shows the stored value. Comparison panes suppress both the frame and guides. The guides use the current profile's indentation-guide style, including explicit style 37 colors. Optional fontName, fontSize (6–72 fractional points) and defaultZoom (−10 through 60) default to Menlo, 14 and zero. An unavailable saved face uses Menlo and preserves the preference. Base metrics apply to all document views; a pane already zoomed away from the previous default retains its zoom. Language style face and size inherit independently. Comparison snapshot panes share effective metrics and retain their local zoom adjustment within their existing 6–96 point display range. Missing required keys, wrong JSON types, unsupported schema/minimum-reader metadata and unsafe/unreadable files still fail closed. Shortcut-only problems are handled separately on load: unknown, unsupported, reserved or duplicate string bindings are ignored individually, valid shortcuts and unrelated settings remain usable, and the ignored entries are reported. The original file is unchanged until explicit repair. That repair validates strictly, keeps the original as a unique sibling and retains the existing rollback behavior. This is not automatic repair or universal detection of later external rewrites.

The historical pre-menu reserved fallback remains available. Effective protection additionally includes Command-E/window cycling and fixed Command/Command-Shift keys from the built menu, preserving modifier distinctions; Command-Option keys do not reserve unrelated Command keys. Startup reconciles again after menus exist, so a new fixed menu key does not discard unrelated editor settings. This deliberately changes shortcut-only load rejection, while save validation remains strict. Clearing a custom binding removes its override; clearing Duplicate Line restores Command-D. Empty strings are never a new stored unbinding vocabulary, and visiting/saving the default does not add a redundant override. Shared shortcut validation returns the stable offending command identity while strict saves retain their existing error cases, and a conflict with an implicit default identifies the entry to correct. The pop-up with its working copy of drafts was replaced by the Shortcuts pane, where each assignment is saved when it is recorded.

### A shortcut for any command

The paragraph above describes version 1, which is still what an older file means and what is written while it suffices: twelve editor commands, one printable character each, Command, uppercase for Shift. `ShortcutCore.swift` (Core) widens that without a second store. `MenuShortcut` has one stored form (`init(storedText:)`, `storedText`: the version-1 character, or modifier names and a key name joined by plus signs, as in `ctrl+opt+k`, `shift+f9`, `ctrl+cmd+up`), one comparison (`identity`, under which Shift-Command-K and uppercase K with Command, or Command-Plus and Shift-Command-Equals, are one key press) and one display (`displayText`, `spokenText`), used by Settings, the Command Palette and every message (DS-20). `ShortcutPolicy.refusal(for:)` refuses a key that would type or edit text (no Command or Control, unless it is a function key) and the system shortcuts of DS-25, with the standard editing keys and a few that macOS owns, each with whole-sentence reasons. There are no chords and no conditional bindings.

`ShortcutContext` is what saved shortcuts are checked against: the commands that can be given a key with their defaults, whether a default yields, and the keys of commands that cannot change. `ShortcutCatalog` (Runtime) builds it from the menu bar. A command's identifier is its action, its explicit target's type and its represented object (`SearchController.showSearch:`, `performTabCommand:/reopen`); an editor command or transform keeps its catalogue identifier (`upper`, `transform.sortAscending`). It never depends on a title or a place in the menus, and it is a storage contract. An item's default is the key it was built with, recorded the first time the catalogue reads it. A `DefaultShortcutItem` is a yielding default: it gives way without a question to the same key assigned elsewhere, and a hidden second key of a command gives way the same way. Commands in menus their owner rebuilds (Macros, Automations, Syntax Highlighting, Editor Groups) and Save All are listed read-only with the reason, and their keys cannot be taken. `ShortcutCatalog.apply` is the one place a key is put on a menu item; a default is restored exactly as built. `SettingsController` reapplies after a rebuilt menu (Run Commands) adds items.

`EditorSettings.version` is 2 exactly while `requiredVersion` says an entry needs it: a command outside the twelve, a key outside the version-1 form, or an empty value, which records that a default was taken away. `SettingsStore.save` sets it, so a file an older TextTank can read stays one it can read, the first such shortcut is the upgrade, and removing the last one returns the file to version 1. Nothing else in the file changes at the upgrade. An older TextTank accepts only `version == 1`: it reports a version-2 file as unsupported, uses defaults and leaves the file as it is, which is the existing version policy. A version-1 file is held to the version-1 rules, so it means what it meant. Tolerant loading is unchanged in kind: an entry for a command that is not there, a key that cannot be used, a reserved key or a second command on one key is ignored and reported, by the command's menu path and never its identifier (DS-82), and the file is unchanged until Repair. Two things are deliberately not errors: before the menu bar exists a version-2 entry for an unknown command is kept and judged at `reconcileShortcuts`, and an entry for a saved Run command that is not there now (`transientPrefixes`) is kept and does nothing.

In the Shortcuts pane (`SettingsShortcutsPane.swift`) the list has every command the Command Palette has, searched by name, menu or key. `ShortcutRecorder` takes the next key press; while it records, a local event monitor sees keys before the menu bar does. A refused key shows its reason. A key another command holds shows that command and offers Replace, which leaves the other command with an empty entry, or Cancel. Use Default goes through the same question, because a default may by then belong to another command. Reset All Shortcuts… asks in a sheet. A key that was not saved leaves its reason on the recorder as accessibility help, the command that holds a key in question is marked in its Status column with help of its own, as is a command whose saved shortcut was ignored, and the question puts the keyboard on Cancel (DS-41, DS-45, DS-62). The list takes the height the window gives the pane; the other panes stay exactly their content. The pane's strings are in `Localizable.xcstrings` under `settings.shortcuts.`. `ShortcutPolicy.reserved` is the whole list of refused keys: the twelve of DS-25, the six standard editing keys, which every text field takes from the Edit menu, and five that macOS acts on first. Every change is saved and applied to the menu bar when it is made. `Tests/Fixtures/persistence/Settings-v2.json` is the golden version-2 file.

DS-27 remains an explicit limitation: the catalog supplies action names, but Undo/Redo still have generic native labels. Scintilla's undo metadata describes primitive edits/coalescing and exposes container tokens, not command captions; native responder Undo/Redo bypass the app dispatcher. No parallel history, container-token changes or `NSUndoManager` were added to guess captions. Precise labels need a separately validated provenance/lifecycle design that preserves Scintilla's authoritative grouped history, clones, coalescing and history branches. Settings now uses the modeless form described below; the Undo/Redo limitation is unchanged.

## Standard document toolbar

`EditorToolbarCommand` owns the five UI command titles/selectors shared by the menu bar and standard New, Open, Save, Find and Clone toolbar items. Their nil targets retain the existing responder-chain routes. Save continues to use NSDocument validation; Clone toggles the second view through the existing shared-document creation and retirement paths. It stays enabled in both states, with a menu/overflow checkmark and a checked toolbar symbol while split; its tooltip and scoped accessibility name describe returning to a single view. Close Split View remains available. This follows DS-20, DS-21, DS-22, DS-30, DS-70 and DS-91. Clone uses the same window-controller validation as the menu. The Foundation editor-command catalog and its bridge allow-lists are unchanged. The toolbar defaults to icons and labels, uses SF Symbols, allows customization and exposes the standard View visibility/customization actions. The redundant tab-strip New button is removed: File > New and Command-N remain available even when the toolbar is hidden or customized. Tab selection, per-tab close and the red close button retain their existing routes.

Automations use one `NSMenuToolbarItem` drop-down. Individual automation buttons are neither allowed nor created, and legacy saved item identifiers are removed without resetting the remaining arrangement, display mode or visibility (DS-D6). Favorites still sort first in the drop-down and editor context menu; every action remains UUID-bound through rename and reload. Library changes refresh the drop-down in place. Windows from one composition share AppKit configuration synchronization; isolated independent compositions have separate identifiers, so their different libraries cannot corrupt one synchronization family.

Native configuration autosave is enabled only for the bundled application without an absolute support override or explicitly injected isolated defaults. Isolated checks use unique composition identifiers, disable native autosave and exercise arrangement capture/restoration through an explicit owned defaults domain. They do not inspect the person's configuration. Scoped accessibility names are assigned to the actual standard toolbar's native accessibility elements, retaining the system controls and drawing; metadata updates traverse only that toolbar, never the editor text or tab/status trees.

## One-row document status

The status area uses one Auto Layout row. Its leading label preserves the full
save, transient or recovery message; trailing native borderless `NSPopUpButton`
controls show position, selection, language, indentation, encoding and line endings.
The native pull-down cells expose AppKit's menu-button role. Both their real host
and cell names state the field, value and “Show options”; native menu tracking and
keyboard focus remain system behavior. The former custom badge drawing is removed.

At the 800-point minimum content width, fields collapse in this order: language,
indentation, line endings, encoding, selection count, selected characters. Position
and the essential save/failure words remain. Fields return when width permits, with
existing controls reused. Position's menu retains character and line totals,
bookmark count/actions, text size and wrap; it also offers the options of collapsed
fields. The filename remains in the title bar and tab. No command's action,
read-only validation, shortcut or checkmark changes.

An unbounded path, error or transient cannot fit in a finite row. The full message
stays in `statusText`, the actual native accessibility name and the tooltip. Only
when necessary, the visible leading label retains the action/result prefix, a
caller-provided semantic summary, “Recovered copy — Save As to keep”, or
“⚠︎ Recovery copy not written”. A long transient never becomes the document's save
state. Search failure and confirmed Reminder results provide explicit short whole
messages; the fallback is a bounded whole-word prefix, without English keyword
classification. An unbounded first token uses “Message details are available.”,
so no universal essence-preservation claim is made for unspecified future callers. This
is an explicit DB-R1 presentation departure for path/diagnostic overflow, preserving
essential state without a giant minimum window width. Recovery failure remains
latched above transient messages until the document reports successful recovery.
The original full recovered-copy and error wording is retained in the model.

The visible-only 0.2-second polling timer remains under DB-R8. A lexer change now
schedules a coalesced editor-state notification so that brace feedback and Language
status reflect the new profile. The native check observes the first language menu
action with the timer disabled, then invokes a second action and runs one real
polling tick before that action’s queued notification. Both paths update the field.
Existing
checks still require no recurring work in hidden/minimized tabs, no whole-text
capture during continuous edits in either event/tick order, one capture after an
idle interval, one in-flight worker and exact revision checks before publication.
Metrics still scan an immutable UTF-8 copy off the main thread. Moving totals to a
menu does not turn menu construction or editor events into full-text captures.

## Search semantics

`TTSearchEngine` searches immutable text snapshots and reports UTF-16 ranges. Regular expressions run over Unicode code points, not UTF-16 units, so `.`, classes and quantifiers take a whole astral character and a match never splits a surrogate pair; this departs on purpose from the Windows reference, which walks UTF-16 units. The regex carries its own UTF-8 locale (the process locale is never changed), so case folding, `\w`, `\b` and `\s` follow Unicode as literal mode and Whole word do; `\d` and `[[:digit:]]` stay `0-9`. Replacement output that would contain half a surrogate pair is refused.

Selection scope searches a range of the whole document rather than an extracted substring. Whole word, `^`, `\b`, `\A` and lookbehind see the text before the range, and `$` matches at the range end only where a line really ends. Known limit: Boost cannot read past the range end, so lookahead, `\b` and `\z` there are relative to the range, and a match is cut off at the range end. Whole word in regex mode filters finished matches and does not retry a rejected one. A regex search decodes the document up to the end of the range, so its memory follows the document, not the selection.

## Shared Find and recorded searches

The inline bar, Find and Replace window and macro search playback all use `SearchCore.search` / `TTSearchEngine` over immutable snapshots. The bar is a scheduling/feedback front end to `SearchController.performInline`; it does not search or replace through `TTEditor.find`. Inline actions and synchronous bounded macro playback share single-document report application, navigation eligibility and strict selected-match replacement. The advanced window retains its existing scopes, rows, cache and asynchronous workflow. Navigation/strict-single-replacement reports enumerate overlapping literal and extended matches by advancing one Unicode scalar from each match start; Find All, Replace All, highlights and bookmarks retain nonoverlapping reports. Cache identity includes report purpose, so those lists cannot be substituted. Literal wrap candidates stay wholly on the other side of the starting boundary, matching native interior-caret and forward/backward behavior; regex navigation retains its prior zero-width rules. A single replacement filters for the exact selected match, never applies the overlapping list. Its cache key compares query and replacement UTF-8 bytes exactly: Swift's canonical String equality is broader than Boost pattern semantics and exact replacement output.

An inline request captures the editor/window, revision, every selection range and the primary anchor/caret. Only snapshot strings reach the worker. Before applying on the main actor, it checks those values and the caller's active pane, query/options and generation again. Field edits, another action, Done/Escape and close cancel the pending request; stale/cancelled/truncated results never edit, select or record. Deferred selection notifications alone do not invalidate unchanged ranges. Known input/selection/read-only/busy preconditions disable the appropriate inline button using bounded field prefixes and existing editor/field/focus events, without capturing document text or adding polling. Next remains usable in read-only documents. Return/Shift-Return keep the Find field editor; menu and button actions commit field editing and return typing to the captured document. The two Find surfaces exchange their query with the system Find pasteboard through injected callbacks (in-memory in native checks), without executing another search or bypassing private preference persistence/recovery. Between themselves they do not go through the pasteboard: see One Find state below.

Typing in the bar runs a cancellable preview with a separate indicator and never records a macro step. Escape restores the opening selections while the preview still owns them. The bar and the Find window share match case, whole word, search mode, dot-newline and wrap settings. Inline recordings use the existing version-1 `next`, `previous`, `replaceOne` and `replaceAll` search actions. Replace requires one selected nonempty match. It records the accepted edit as `replaceOne` and appends `next` only if the follow-up selects a match. Replace All applies to the current document, reports its count and is one Undo action. Refused gestures record nothing. Legacy `findLiteral` remains readable and uses the shared literal engine with wrap; legacy `replaceSelection` retains captured-text caret insertion/replacement because its wire payload contains no query. All symbolic command allow-lists, unsupported-action capture failures and grouped playback Undo remain unchanged.

Consolidation deliberately applies the existing engine limits to inline and legacy literal playback: 64 Mi UTF-16 document units (a longer document takes the windowed path described under Find in documents above the engine limit), 65,536 query units, 1 Mi replacement units, 100,000 results, 64 Mi expanded output units and the default two-second search budget. Inline and recorded playback refuse truncated results. The prior native literal primitive had no such limits: an executed 65,537-unit legacy query succeeded before consolidation and now reports the shared limit without changing bytes/revision/selection or recording a completed action. This is a compatibility restriction, not universal equivalence with the former Scintilla search; sampled non-ASCII/astral cases agree, while full Unicode/reference differential behavior remains unverified.

`TTEditor.find` is retained for native bridge/Undo control checks and the unchanged PerformanceChecks primitive benchmark, including its 100 MiB manual tier. No product UI or macro path calls it. Retiring that API is deferred rather than weakening the real primitive benchmark or adding an uncapped product fallback. Those timings measure Scintilla's primitive, not the new end-to-end asynchronous Find latency; no equivalent speed claim is made for the shared path.

## One Find state

DS-35. `SearchController` holds one text to find and one replacement (`sharedQuery`, `sharedReplacement`). The Find and Replace window and every tab's find bar show those two values as they are typed. A surface reports its own typing with `setSharedQuery` / `setSharedReplacement`, naming itself as the source; `sharedTextChanged` then tells the other surfaces, never the source, so the field being typed in is not set and keeps its caret and selection. Sharing text schedules no search: the bar being typed in runs its own live count exactly as before, and a surface that receives text only shows it. A find bar also reconciles when it is shown and before it acts, so a field changed by something other than typing is shared and an untouched field takes the shared text.

History is `FindHistory`: the last ten distinct searches and the last ten distinct replacements, newest first, compared by UTF-8 bytes as the engine compares search text. A search enters it once it has run (Next, Previous, Find All, Replace, Replace All, Mark, Bookmark; Return or a button in the bar), not while it is typed and not when it was refused, failed to compile, went stale or was cancelled; a replacement enters it when a Replace action uses it. An entry over 1,000 UTF-16 units is not remembered. The window's two fields are combo boxes (arrow button, Down Arrow). The bar's Find field shows the history from its magnifying glass and on Down Arrow, with the replacements in a submenu; Down Arrow in the bar's Replace field shows the replacements. Each menu can clear its own list.

The private `FindPreferences.json` keeps the option flags and, in two optional arrays (`queryHistory`, `replacementHistory`), the history. The format version stays 1 and an older file loads unchanged. A new launch always starts in Normal mode with both fields empty: `startingOptions` drops the saved text and mode whatever the file holds, and a file from before the history existed offers the text it would have restored as its first history entries. Saves write empty text and Normal mode. Text already on the system find pasteboard at launch is not taken in (`adoptFindPasteboard`); a search made in another application afterwards is, once, when a Find surface opens.

DS-21: the window disables Replace All while the fields, options, scope and documents are still exactly those of a search that found nothing (`EmptySearch`, re-evaluated on typing, option and scope changes and `windowDidUpdate`, without reading document text). The bar disables its Replace All while its live count reports no matches. DS-45: a regular expression that does not compile is reported by the engine with `TTSearchEngine.invalidPattern`; the window shows the whole message under the Find field beside a warning symbol and as the field's help, and the bar's count label reads "Expression not valid" with the whole message in the status line and as the field's help. The window's status line wraps to three lines so a message is not cut off.

## Find in documents above the engine limit

The snapshot engine searches one `NSString` of at most 64 Mi UTF-16 units. A longer document is searched as its UTF-8 bytes by `TTSearchEngine.searchUTF8` (`SearchCore.searchBytes`), for Normal mode and for Extended mode, which is a literal once its escapes are decoded.

- **Windows.** The bytes are read in windows of 4 MiB (`SearchCore.largeChunkBytes`). A window takes the matches whose first byte lies in it and reads past its end by the longest possible match, so a match that straddles two windows is found once, by the window it starts in. Window ends are moved to character boundaries. With Match case the search is a byte comparison and nothing is decoded. Without it each window is decoded and compared with the same Unicode case folding as below the limit; a folded match may be longer in bytes than the search text, so the overlap allows twelve bytes per UTF-16 unit. Whole word reads the characters around a match from the bytes, across window and range edges.
- **Memory.** One immutable copy of the document's bytes (as the live count and recovery already take) and one window of working memory, whatever the document's size. Nothing is decoded whole. Whether a document is above the limit is decided without decoding: under 64 Mi bytes it cannot be, and above three times that it must be, and between the two its UTF-16 length is counted in one pass over one copy and remembered for that revision of that document, so later presses and the All open documents refusal copy nothing.
- **Navigation.** `SearchSession.planBytes` asks for the one nearest match, forwards or backwards from the selection, and for the wrapped one only when that finds nothing. Matches are not enumerated to move, so Find Next and Find Previous do not meet the result cap and cost the distance to the next match: the engine is asked to stop at its first match (`stopAtLimit`), reads no window after it, and so cannot lose it to a later deadline. The candidate rules are those of `plan`; core checks compare the two planners position by position.
- **Budget and cap.** Large-file variant of the time budget: the interactive two seconds for every started 64 MiB of the range searched (`SearchCore.largeTimeLimit`), one deadline per action. Cancel and the deadline are looked at after every mebibyte of comparison work, inside a window too: exact matching counts the bytes it compares, and folded matching is searched in slices sized by the search text's length, or position by position with an anchored comparison when the search text is long for the window. Position by position, a character is tried only if its case fold begins with the unit the search text's fold begins with (one table read per character, in any script); a 3,000-unit search text in CJK text went from about 5 MiB/s to about 80 MiB/s in a Debug build, against the 32 MiB/s the budget assumes (`swift-foldcjk-checks`). The result cap is unchanged at 100,000: a count at the cap says the limit was reached, and Replace All refuses a truncated result.
- **Off the main thread.** The Find window shows `Searching, N%…` (real bytes covered; the trailing ellipsis keeps `AnnouncingLabel` from announcing each step, DS-51 and DS-72) and Cancel Search cancels. The bar shows the same text in its count label; typing, Escape, Done or another action cancels. Before selecting or replacing, the revision, the current editor and the selection are checked again; a stale result changes nothing and is not recorded.
- **What works.** Current document and Selection scope: Next, Previous, Find All / Count (a count; matches are not listed), Replace (the selected match, then the next match in the new text) and Replace All. Replace All is supported, not refused: it applies at most 100,000 byte ranges through the same single `replaceSearchRanges` call, so it is one Undo step whose size follows the matches, not the document. The find bar's four actions and its live count use the same planner.
- **Macros.** Playback of a recorded search step is synchronous, and a large search must never hold the window, so `playRecorded` and `playLegacyFind` refuse the step in words before the document is read (the refusal says that the search changed nothing and that prior edits remain undoable, which is true whether or not earlier steps of the macro edited the document), and a search made in a large document is not recorded (the recording is told why).
- **What is refused, in words.** A regular expression in the whole document: the message says to select part of the document and choose Selection, or to change the mode to Normal. Selection scope then decodes only the selected bytes and runs the snapshot engine on them, so the expression sees the selection as the whole text (anchors, lookbehind and Whole word do not see the document around it); a selection above the limit is refused. Mark Matches and Bookmark Matches. All open documents when one of them is above the limit, naming it.

## Find and Replace window

`SearchController` searches text snapshots off the main thread and applies results only after re-checking them. The editor's `revision` is the staleness authority: every insert and delete moves it, in every view of a shared document (bridge-checks proves each path), so the controller compares revisions and does not re-copy and compare the whole text. A split clone takes its revision from the primary when it is created and before it can be searched; a new way of changing text must move the revision too.

- Results hold each searched editor weakly, keep one text snapshot per document with rows that refer to it by index, and are dropped when the Find window closes. Find Next from the menu with the window closed holds results again until the next search.
- Next and Previous reuse the held results while the editors, their revisions, the options and the scope are unchanged; anything else searches again.
- Selection scope: the first Next or Previous takes the selection as the scope and later presses keep that scope, until an edit, a manual selection change or an action in another scope. Every other action reads the live selection.
- All open documents: Next and Previous first look in the document they are in, then move through the other documents in open order (the order of `openEditors`), wrapping across documents when Wrap is on. The document last navigated to stays the starting point while its selection is still that match, because the application's current editor can lag behind a cross-document move. It stops being the starting point when the current editor is another listed document, or when the document navigated from is on screen and the one navigated to is not (only the selected tab's window is visible).
- Replace edits only the document it was pressed in. In All open documents that document is found by the same rule as the starting point of Next, so Next into another document and then Replace replaces the match just selected; a current editor outside the open list (a split view) needs a match selected by Next first, and a document Next moved to stops being that document once it is hidden while the current editor is on screen, whether that editor is listed or not. In the current document, Replace with no match selected selects the next one (recorded as `next`), and a successful Replace then selects the following match (recorded as `replaceOne` then `next`). Cancel while that following match is being looked for keeps the replacement's status and outcome. Macro playback of `replaceOne` stays strict: it replaces a selected match and never moves, so saved macros play as before. A habit of Replace, Next, Replace now skips a match.
- Replace and Replace All apply one `replaceRanges:withTexts:expectedRevision:` call per document: all ranges are validated before the first edit, the edit is one undo action, and the selection the command began with is then carried through the replacements (the bridge call itself leaves the caret just after the first replacement), so Undo returns to it. `ReplaceOutcome` says why a document was skipped (read-only, multiple selections, closed or changed).
- Find in Folder validates once before any file is read: filters are parsed and the expression is compiled on empty text, so an invalid one is a single error. After that a failure in one file skips that file only. `FolderSearchReport.skipped` lists the entries that could not be searched (unreadable, not valid text, too large); what filters and settings left out is counted per reason in `excludedCounts` and listed only when a request sets `listsPolicyExclusions`. Filename globs match as precomposed Unicode scalars or as UTF-16 units; path scoping compares UTF-8 bytes.
- A confirmed folder replacement keeps one versioned append-only manifest and private originals under Application Support/TextTank/FolderReplacements. The original mode is recorded in the manifest and each private original carries its extended attributes. Replacement uses a system-selected staging directory on the same volume and keeps the final descriptor, metadata and content checks. Undo Last Folder Replace opens the newest private batch and obtains an exclusive lock. It restores only a file matching the recorded replacement fingerprint, verifies the saved original and rechecks the current file before the rename. Open files, later edits and missing originals remain untouched and appear in the per-file report. A repeated Undo only retries remaining entries in that batch. Review Backups lists each private batch and its per-file states. A confirmed deletion checks the reviewed manifest again, locks the batch, retires its directory and removes only its recorded files. Retention defaults to keeping backups until manual deletion. Selecting an age runs cleanup immediately, at startup and daily while the application runs. Active, unrecognized and interrupted replacements are retained. The private store and legacy folder replacement files (`.texttank-backup-`, `.texttank-replacement-`, `.texttank-report-`) are never search results or replacement targets. A file that was not changed (conflict, cancellation, or a failure before the rename is attempted) keeps no recovery copy and no journal. While a replacement runs, the window refuses a new search and refuses to open a result.
- Find Next and Find Previous call `onFailureSignal` (the system alert sound) whenever they select nothing, since both work from the menu while the window and its status line are closed.

### Automatic recovery timing

The recovery timer scales with the Scintilla document's UTF-8 byte count. Up to 8 MiB its idle and continuous-typing deadlines are 0.5 and 5 seconds. Above 8, 32 and 128 MiB the respective delays are multiplied by 2, 4 and 8. An uninterrupted burst retains its original start time when it crosses bands. Above 256 MiB automatic recovery pauses and the status line identifies the cutoff. Save remains available, and a previously protected draft stays on disk until save or close. Reducing the text to 256 MiB or less resumes automatic capture.

## Persisted formats

Find and Find in Folder now save versioned JSON files under `AppStorage.supportDirectory` on action or close. They import a legacy preference only when their private file is absent; legacy values are never written or removed. An absolute support override suppresses implicit legacy access entirely, including obtaining `UserDefaults.standard`. Window frames retain bundled-application-only production behavior and explicit fixture overrides, but suppress implicit shared preferences under that isolation override. Native checks use a protected test-owned provider and sentinel; they never inspect the owner's preferences. The prior source path had an isolation gap; which defaults domain earlier command-line runs actually accessed was not established, and no owner-domain cleanup or inference is made.

Search preferences use `JSONFileStore` and the common `StoreLoadState`: an unreadable file remains intact and blocks direct saves. The search continues with visible feedback when preferences cannot be saved. An explicit Reset Saved Settings action renames the previous entry beside its original path and saves defaults; a failed replacement attempts an exclusive rollback and retains any backup. A healthy no-op compares stable encoded bytes, preserving Unicode byte differences. Both preference readers allow 8 MiB, enough for the existing validated UTF-16 field limits even with JSON escaping. DS-40, DS-41, DS-43, DS-52, DS-53, DS-72 and DS-83: the persistent notice names the failure without blocking a search; reset is explicitly confirmed, destructive Return is guarded, the alert identifies affected data, and documents remain untouched.

Every file and defaults value the app writes is a versioned Codable value type: editor settings, Find options, Find-in-Folder settings, the workspace browser state, the Run library, session snapshots, recovery snapshots, the Reminders journal, the macro library, the language catalog and the automation library. Most decoders are synthesized, so every non-optional property is a required key, including properties that have a default value. `RecordedMacro.Step` is an associated-value enum with custom Codable retaining the existing `kind` and payload keys: irrelevant nil payloads stay omitted, null optionals and unknown extra keys remain readable, and malformed or incompatible known payloads are rejected. Its encoder still reproduces the golden version-1 bytes.

A field added to a version-1 type must therefore be one of two things. Either it is Optional, as the later fields of `AutomationDefinition` are, or it is decoded with `decodeIfPresent(...) ?? default` in an `init(from:)` written in an extension for that field only. An `init(from:)` in the struct body removes the memberwise and default initializers that the sources and checks use. Never default a missing `version` or `schemaVersion`, a document's text, format, selection, dirty flag or revision, or a Run item's `shellMode` or `extensionMode`: those stay required. A change in what an existing field means needs a new `version` or `schemaVersion` and an explicit migration.

The automation library has one content migration, applied by `AutomationController` when it starts and has read an existing `Automations.json`: `AutomationLibrary.removingRetiredFactoryItems()` drops the recipe automation earlier builds installed, only while it still equals one of the definitions in `RetiredFactoryAutomation`. It keeps format version 1, records no marker, is not part of decoding, and is never applied by the read-only Services and App Intents reader. A failed rewrite leaves the file as it was. The matching rule and failure behaviour are in [AUTOMATION-RULES](AUTOMATION-RULES.md).

Editor settings gained two Optional members this way for the preview: `previewOpenModes` (what each of the five preview formats opens in) and `lastRenderedPreviewMode` (what Toggle Preview returns to). Both hold text, not enums, so that an unknown value reads as Source or Both instead of failing the whole file; [preview-model](preview-model.md) gives the rules. The session tab record (`WorkspaceLayoutState.Tab`) gained two Optional fields this way, `viewMode` and `previewSourceFraction`, for the per-tab Source, Preview and Both views. They are omitted for a tab that shows Source. The preview itself (`Sources/Preview/`: a pure Core that parses and renders, and Runtime files for the coordinator, the presenters and the tab adapter's mode logic) is described in [preview-model](preview-model.md). It persists nothing else; its compiled content rule list is a cache under `AppStorage.supportDirectory/PreviewRules`.

`PersistedFormat` additionally checks optional envelope metadata `minimumReaderVersion` before model decoding. Absent means reader 1; present must be a positive integer no greater than this build's reader version (1). Null, a string, zero and a newer reader requirement are failures, and app-owned stores retain their original bytes behind the load latch. The Run format is still an array: this gate applies to each command object. Other formats gate their envelope, never arbitrary nested user dictionaries. Current unchanged version-1 writers omit the metadata, so their schema and the committed golden fixtures remain unchanged. Existing older builds cannot retroactively honor this gate: a future incompatible meaning or schema must also bump its existing required version and supply an explicit migration; setting this optional key alone cannot make it safe for an older build. No format migration is performed by this audit.

Bundled syntax profiles retain the 96 Notepad++ source definitions, style IDs, category names,
keyword lists and pinned source hashes. The additional Markdown profile is TextTank-authored
against the existing pinned Lexilla Markdown lexer; its provenance is separate from the
Notepad++ import and is stated in the catalog limitations. It detects `.md`, `.markdown`,
`.mdown`, `.mkd` and `.mkdn` through the same case-insensitive extension path as other languages.
Headings, bold/italic emphasis, lists, quotes, links, inline/fenced code and front matter use
the lexer categories. Code fences are colored as code; they do not embed another language lexer
or render a preview. Explicit saved profile deletions and user-defined extension priority remain.

Built-in presentation maps the source categories to paired colors for comments, strings,
keywords, types, functions, numbers/constants, properties, tags, attributes, variables, operators,
directives/decorators, escapes and errors. More specific category names take precedence over
shared words; uncommon chromatic source styles retain their hue family rather than falling
back to ordinary text. Neutral ordinary-text categories remain native text colors. Each view
resolves its own appearance; saved fixed RGB choices and imported UDL behavior are unchanged.
Native checks read every linked built-in style's actual foreground/background in light and
dark mode (minimum 4.5:1), exercise category separation on Python/HTML/JSON and check real
Markdown lexer IDs/fonts without changing text, revision or the save point (DS-D8).

The user's `LanguageProfiles.json` is the one store that is not a whole value: it is a `LanguageOverrides` (`overridesVersion` 1) holding only what differs from the bundled catalog, namely changed fields of bundled profiles, added profiles such as imported UDLs, deleted bundled identifiers, and the order when it was changed. `LanguageCatalog.load(stored:over:)` merges it over the bundled catalog at launch, so a later bundled catalog reaches every field the user left alone. A file written before overrides existed is a full `LanguageCatalog`; it is still read, as the differences it makes to today's bundled catalog, and is rewritten as overrides at the next save. If the stored file cannot be read, the bundled catalog is used, the file is never overwritten, and the Language dialogs offer to rename it aside (`quarantineDamagedStorage`) before anything is saved.

`Tests/Fixtures/persistence/` holds one file per format as written by the build of 15 November 2026. The "persisted format golden fixtures" section of document-checks decodes each one through the production reader and compares every value, so a field added without a decoder for old files fails acceptance. Do not rewrite those files to make a check pass; add a new fixture beside them when a format gains a version.

## Library codecs and advanced JSON editing

Settings uses an owned `FormPanel`, opened by Command-comma and titled “Settings”. A
preference-style `NSToolbar` switches five panes (Editing, Appearance, Files, Previews,
Shortcuts); every pane stays in the window and only the chosen one is shown, so the window is
as tall as that pane and a control is found by its identifier whichever pane is showing. Each
setting is a `SettingRow`: its pane, visible label, synonyms, whether its value differs from
`EditorSettings()` and how to return it to that default. The search field lists the matching
rows of every pane under their pane's name, Changed from default lists the rows that differ,
and a row that differs has a Use Default button. A stored `Bool?` member gets its row from
`toggleRow` and a command from `actionRow` (marked `SETTINGS-ROW-EXTENSION` in
`SettingsController.swift`). The Shortcuts pane is one row; under Changed from default its list
shows only the commands whose shortcut was changed. Reveal Settings File in Finder goes through `StoreRecovery.reveal`. Committed controls validate and persist their own fields before applying them. A pending text draft retains its original field value for conflict detection, while unrelated preferences merge from the current store. A changed file on disk requires reopening Settings. External file changes defaults to Ask. Reload if unmodified refreshes a clean document after verifying its disk contents. Ignore suppresses notices while in-place saves still check for conflicting bytes. Close and Escape end the session. Accepted changes persist across close. The Reset Defaults and Repair Settings actions each require confirmation.

The Font button owns a session on the shared AppKit Font panel. A fixed-pitch descriptor collection is visible only in this process. The modern panel opens this collection through its native collection picker. Older layouts use the panel's family filter. The user can choose all fonts. Closing the session releases its collection and restores the prior panel target, delegate, selection and accessory.
Frames use the existing `WindowFrames` policy, including isolated test defaults.
Input purpose labels name both the host and AppKit's exposed native cell, with
caption relationships attached to the caption cell. Dynamic rule and inline
rename labels follow their current purpose. Native checks traverse actual window
children and table accessibility edges, retain native roles/values, and type into
focused fields; they do not certify physical VoiceOver interaction.
The document test script always runs the full document checks and these input checks
as separate required processes of one compiled executable, preserving both native
completion gates and every assertion.

Automation, Macro and Run managers use `LibraryManager` with native tables, inline
rename, Add, Duplicate and confirmed Delete. Automation Favorite shows its pending
checked state. Automation settings and Rules open as owned sheets; the Rules editor and its
rule configuration use completion callbacks, without application-modal manager loops.
Children use “Use Changes” to update the manager's working copy. Only the outer
Save persists it. Closing an edited manager offers Save, Keep Editing and Discard Changes.
An unchanged manager closes immediately, and explicit Cancel discards its working copy.
A failed Save keeps the manager open. These rules apply to Automation, Macro and Run
library windows (DS-40 through DS-45). Application termination follows its existing lifecycle.
New macros contain a validated nonempty Insert Text action.
Management never starts a macro, process, automation or external export. Busy state
follows actual execution or recording, not the lifetime of an open manager.

The advanced Automation, Macro and Language JSON editors share `JSONLibraryEditor`
in `Sources/UI/`. Import, export and examples retain their common codec, capacity,
recovery and file policies. Language uses an owned modeless editor and still writes
overrides before reapplying profiles. Automation and Macro use advanced sheets over
the manager's working copy. Run retains its existing JSON array format in an advanced
sheet. Invalid values stay beside the marked field with exact pending text retained;
errors carrying native recovery metadata retain native error presentation.

Before recovery can move data aside or a Save can persist it, the controller checks
a captured stable encoded-byte baseline against its current saved model. Intervening
controller writes, including recording completion and canonically equivalent NFC/NFD
text changes, keep the pending form open with an explanation. The recording-name
form checks both the saved library and the last completed recording. This is an
in-process stale-working-copy guard, not universal compare-and-swap protection
against late writes by another process.

Run Automation and Open Documents use `ChoicePanel` with live filtering and stable
identities independent of displayed names. Typing, focus changes and Cancel never
invoke an action. Return, table activation or the explicit action button chooses
exactly once. Go to Line is one inline field in the find bar's place, owned by its tab
(`EditorGoToLineBar`, `LineJumpPreview`): the two bars replace each other and the shared Find
state is untouched. A valid entry (`line` or `line:column`, read by `GoToLineEntry`) shows the
line without a jump being made; Return makes the jump through `goTo(line:column:in:macros:)`,
the one place a macro recording learns of it, and the only thing that makes the jump. Showing
a line uses the bridge's `preview(line:column:)`, which never unfolds: a line hidden in a fold
is stood in for by its fold header and the field says so. Everything else that closes the
field (Escape, Cancel, Tab or Move Focus out of it, another tab, Find, Preview alone) puts the
caret, the exact selection state (`selectionSnapshot`: every range, the main one, rectangular
mode), the scroll position and so the folding back. The editor holds that place (`holdPlace`)
and moves it with every edit, so a change from another view or an automation never turns the
previewed line into the place to go back to; if the edit deleted the caret's own text, Escape
goes to where that text began and the field says so. A click closes the field: one that
places a caret in the previewing pane's text stands, and any other (the other pane of a
split, a margin, another group) first puts the previewing pane back. Return on the line the field opened with
changes nothing. Closing the document closes the
field, and a changed or retired target cannot navigate a stale editor.

`VersionedLibrary` in `Sources/Documents/` shares their Foundation-only codec with
`AutomationRuleSet`. Each model retains its required version, optional minimum-reader
gate, validation, byte capacity and diagnostic vocabulary. Encoding validates and
checks the same capacity used by decoding. The three libraries retain pretty,
sorted, unescaped-slash JSON; portable rule files retain their escaped-slash
format. No stored keys or version-1 fixture bytes change.

## Reminders export journal

Each export batch is one JSON file in `ReminderExports`. A row is recorded as uncertain, and that record is synced, before the row is handed to Reminders; it becomes confirmed or failed only afterwards, and an uncertain row is never resent automatically.

- The first write of an export replaces the file atomically (private temporary file, device flush, rename, containing-directory flush) in a slotted layout: one row per line, each ending in a space-padded slot for its status, reminder identifier and message. JSON permits that whitespace, so the file decodes like the compact form earlier builds wrote, which still loads.
- Before a nontransactional send, the journal actor publishes a version 2 intent naming a bounded run of eligible rows, and requires a successful device flush. It also verifies directory links on the journal volume. Existing v1 readers reject the active file. The actor flushes outcomes before advancing intent and writes a v1 record on normal completion or cancellation. A cold reader treats unresolved rows inside the armed range as uncertain, and permits the pending suffix outside it to resume. An unsupported device barrier stops the export before sending. Groups have at most 32 rows, with one-row groups for exports of 32 rows or fewer.
- After that a row's barrier and outcome are each one in-place write into its slot followed by fsync, so the cost of a row does not grow with the batch. A slot never crosses a 4096-byte boundary, so an update touches one storage block. An in-place write is not an atomic replacement: if a block were torn by a power failure the file would no longer decode, and an undecodable journal is preserved, reported by name and never resent. An outcome too long for its slot is written by another atomic replacement.
- Before every write the journal path must still name the file that was validated or written by this export. A journal folder that was moved or replaced fails the write instead of redirecting it.
- Journal reads and writes of an export run on `ReminderJournalFile`, an actor, off the main thread. Calls into the reminder store stay on the main actor.
- A journal failure after an item was sent throws `ReminderConnectorError.journalFailed` carrying the in-memory batch; the write is not retried and the file is not touched again.
- `storedBatches()` is strict and fails on any unreadable file. `scanBatches()` returns the readable batches and one issue per unreadable file, as `RecoveryStore.scan()` does. `deleteConfirmedBatches(ids:)` holds the export lock, revalidates each named batch and removes only fully confirmed ones. Nothing is pruned automatically.

## Source layout

First-party Swift under `Sources/` and `Tests/` is laid out by the `swift-format` that ships with the toolchain, using the committed `.swift-format`. That configuration enables layout only (line breaks, indentation, spacing, 120 columns, one statement per line); every rule that rewrites tokens is off, so formatting never changes what the code says. `Sources/Search/Boost` and `Vendor` are never formatted, and neither are the Objective-C++ bridge files, the Python scripts or the shell scripts.

- `scripts/swift-format.sh format` rewrites the files; run it before committing Swift changes. `scripts/swift-format.sh lint` reports any difference and exits non-zero.
- CI runs the lint as an advisory step. `swift-format` output differs between versions (the sources were formatted with 6.4.4), so the step must not block until the CI image's Xcode is pinned to the same version.
- `scripts/check-layout-only.py <before> <after>` proves that a formatting commit changed layout only: for every changed Swift file the code tokens, string literals and comments are unchanged and in the same order, and the compiler's parse tree is the same. Its self-test runs in acceptance as `layout-proof-selftest`. Use it whenever the formatter version or configuration changes and the tree is reformatted.
- A line the formatter cannot break, such as a long string literal, stays long; the lint does not report it.
- A commit that only reformats is listed in `.git-blame-ignore-revs`; `git config blame.ignoreRevsFile .git-blame-ignore-revs` makes blame skip it.

## Session and recovery snapshot fields

Both formats are JSON written by `JSONEncoder` with its default date strategy, so a date is a number of seconds since 1 January 2001 00:00 UTC (`784000000` is 5 November 2025). Key names and the date encoding are fixed for version 1; a new format should use ISO 8601 dates and `schemaVersion`. "Required" means the decoder rejects a file without the key.

Session snapshot (`WorkspaceSession`, written by File > Workspace > Save Session Snapshot…; proposed extension `.texttanksession`, exported as `app.texttank.session`). A snapshot loads under any file name. Opening a `.texttanksession` file from Finder or File > Open goes to the restore prompt instead of showing the JSON as an editable document.

| Key | Type | Required | Meaning |
| --- | --- | --- | --- |
| `schemaVersion` | integer | yes | Always 1. Any other value is rejected. |
| `id` | UUID string | yes | Identity of this snapshot file. Not used on restore. |
| `name` | string | yes | Shown in the restore prompt. 1 to 200 characters, no NUL. |
| `documents` | array | yes | At most 1000 entries with distinct `id`s. |
| `activeDocumentID` | UUID string | no | The document to bring forward after restore; must be one of `documents`. |
| `savedAt` | date | yes | When the snapshot was captured. Shown in the restore prompt; nothing else depends on it. |

Each entry of `documents` (`SessionDocument`):

| Key | Type | Required | Meaning |
| --- | --- | --- | --- |
| `id` | UUID string | yes | The document's recovery identity when captured. Matches `activeDocumentID`. |
| `originalURL` | file URL string | no | Where the document was saved, absent for an untitled one. Used to show the name and to compare the file with `originalSHA256`. Restore never opens it for editing and never writes it. |
| `text` | string | yes | The whole editor text, including unsaved edits. |
| `format` | object | yes | `encoding` (`utf8`, `utf16LE`, `utf16BE`, `windows1252`, `latin1`) and `bom` (boolean). A BOM with a legacy encoding is rejected. |
| `isDirty` | boolean | yes | Whether the document had unsaved edits when captured. Shown in the restore prompt only: every restored document opens as a new unsaved document whatever this says. |
| `selection` | object | yes | `anchorByte` and `caretByte`, UTF-8 byte offsets into `text` on character boundaries. |
| `bookmarks` | array of integers | yes | Zero-based line numbers, distinct and inside the text. |
| `language` | string | no | Language profile identifier; an unknown one falls back to plain text with a notice. |
| `originalSHA256` | string | no | Lower-case hex SHA-256 of the original file's bytes at capture, not of `text`. Requires `originalURL`. |

Legacy recovery snapshot v1, stored as `<id>.json` in the private Recovery folder:

| Key | Type | Required | Meaning |
| --- | --- | --- | --- |
| `schemaVersion` | integer | yes | Always 1. |
| `id` | UUID string | yes | Must equal the file name. |
| `text` | string | yes | The whole editor text. It may hold characters `format` cannot encode; those are kept. |
| `format` | object | yes | As for a session document. |
| `originalURL` | file URL string | no | The file the draft belongs to, absent for an untitled one. Note that this is a string here and a URL in a session document; both hold the same absolute `file://` form. Shown in the recovery prompt and recovered window. If that original has already reopened, recovery associates the reviewed draft with its group. Recovery never opens or writes that path. |
| `revision` | integer | yes | Monotonic per `id`, at most 2^63 - 1. A snapshot is never replaced by a lower revision, and never by an equal revision with different content. |
| `savedAt` | date | yes | When the snapshot was written. Shown in the recovery prompt and the recovered window's status line. |

Current recovery writes publish a private `<id>.<generation>.utf8` containing exact UTF-8 editor bytes, followed by a small `<id>.json` commit record. The header uses schemaVersion 2 and minimumReaderVersion 2. It carries the same id, format, originalURL, revision and savedAt, plus the generation UUID, UTF-8 byteCount, lowercase SHA-256 and optional previousGeneration. Raw content can include U+FEFF, NULs or characters that the selected disk encoding cannot represent. Both files have mode 0600.

The writer confirms the new body before atomically replacing the header, then retires the previous payload after the header's file and directory barriers. A visible-but-unconfirmed replacement retains its predecessor. An equal-revision retry validates and confirms both files. Removing the header confirms its directory before deleting the referenced body. A detached body is retained and reported in recovery review. Saving or discarding a damaged pair is refused.

Launch enumerates on a utility queue. For v2 it inspects header metadata and the body descriptor's type and exact length. Recover verifies the selected generation, digest and UTF-8 when reading text. Discard also validates the listed generation and existing bytes. Old v1 files still need one full JSON read at inventory, and convert when a later revision is saved. A version 1 reader refuses a version 2 record. Exact size validation does not detect same-length damage during the initial header-only scan.

The Recovery folder may also hold `<UUID>.pending` files: the temporary file of a write in progress. One left by a process that died during a write is deleted by the next launch's scan. A `.json` entry is never deleted except by saving, closing or explicitly discarding the document it belongs to.

## Local history (DS-D10)

`LocalHistoryStore` in `Sources/Documents/PrivateFileStore.swift` keeps earlier versions of saved files under `LocalHistory` in the support folder (`AppStorage.Location.localHistory`), never inside or beside a document's own folder. Nothing in it is sent anywhere.

Layout. One folder per file, named by the lowercase SHA-256 of the file's resolved absolute path (the document's `diskURL`, links resolved). It holds `manifest.json` and one `<version id>.bytes` per version. Folders are created 0700 and files 0600 through `PrivateFileStore.prepareDirectory` and `PrivateFileStore.write`: a temporary file in the same folder, a flush to storage, a rename, then a flush of the folder. A version's bytes are published before the manifest names them, and a manifest is rewritten before bytes it no longer names are deleted, so a manifest never names missing bytes; bytes no manifest names are removed by the next prune.

A folder is never a dead end. With no readable manifest (a stop between the first version's bytes and its manifest, or damage) its versions are the `.bytes` files present, dated by when each was written: they are listed, counted toward the limits, expired and cleared like any others, and the next save of that file writes a fresh manifest naming them. A manifest that states another path than the folder is named for is an interrupted move and is read as it is. A manifest that can be read but states a `version` other than 1, or a `minimumReaderVersion` above this build's, is not damage: it was written by a newer TextTank. That folder is left entirely alone. It is not listed, counted, pruned, cleared, moved into or written to, a save of that file keeps no version, and a newer build finds it as it left it.

`manifest.json`, version 1:

| Field | Type | Required | Meaning |
|---|---|---|---|
| `version` | integer | yes | 1. Any other value means a newer format: the folder is left entirely alone. |
| `path` | string | yes | The file's resolved absolute path. Must hash to the folder's name. |
| `versions` | array | yes | Oldest first. |
| `versions[].id` | UUID string | yes | Names `<id>.bytes`. |
| `versions[].savedAt` | date | yes | When the save happened. |
| `versions[].byteCount` | integer | yes | Exact length of the bytes. |
| `versions[].sha256` | string | yes | Lowercase SHA-256 of the bytes; checked whenever a version is read. |
| `versions[].kind` | string | yes | `saved`: what TextTank wrote. `replaced`: what the file held just before a save. |
| `versions[].format` | object | no | Encoding and byte-order mark when TextTank knew them; otherwise detected on reading. |

Which bytes. `TextDocument.writeSafely` records after a successful Save or Save As, never for Save Copy and never for an untitled document. It keeps the bytes it just wrote. Before the write it also reads the bytes about to be replaced, when history does not already end with them (the first save of a file TextTank has not recorded, or a file changed by something else), and keeps those first, as `replaced`. The version listed before the newest is therefore exactly what the file held before that save. The usual save reads nothing extra: the document's own digest of the bytes on disk is compared with what the store last reported as the newest version of that path. That memory is filled only from the store's replies (each `record`, `relocate` and `prune` reports the newest version of every file it changed, evictions included) and is unknown while a record is unanswered or after one failed; with it unknown the save reads the bytes it is about to replace and the store decides whether it already has them. That read is of the document's own file on the main thread, bounded by the 32 MiB version limit, once per path per launch and after a failed record; reading and hashing 32 MiB measured about 21 ms on the development Mac (Debug build, file in cache). The replaced bytes carry the document's format only when they are the bytes the document last read or wrote; bytes another program wrote are decoded by detection.

Limits (`LocalHistoryLimits`): 20 versions a file, 30 days, 200 MB (200,000,000 bytes) in all, oldest first; a save above 32 MiB (the large-file threshold) is not kept; bytes equal to the newest version are not stored again. The limits are applied on the store's serial utility queue after every save and once at launch. The save never calls a synchronous store entry point, so it never waits for the store's queue, and Clear Local History asks for its counts and deletes through completions for the same reason; a failure to keep a version never fails the save and is said in the status line.

Identity. When a document's `fileURL` changes and the earlier path no longer exists, or names the same file as the new one (a rename that changes only case on a volume that ignores case), the history moves to the new path's name. With nothing there, the folder is renamed in one step and its manifest rewritten after. With a history already there, the moving bytes are hard-linked into it, the joined manifest (date order) is published, and the old folder is removed last, so at every point each manifest names only bytes that exist. After Save As the earlier file still exists and keeps its history; the new file starts its own. A file that is renamed while it is not open in TextTank is a new path with a new history, and the old one expires. A path inside the store is never given a history.

Reading. Compare › Compare with Earlier Version… lists `versions(forPath:)` newest first by date and size in a `ChoicePanel`. The chosen version is decoded with its recorded format and handed to `CompareService.open` as a fixed `.snapshot` on the original side, with the open document on the modified side as the merge destination. A fixed value cannot be a destination, so the earlier side is read-only. Restoring is Merge's own Apply Selected Changes (docs/merge-model.md): one Undo group through the sole application path, with no write to the file or the history. The comparison's 8 MiB source limit applies; a larger version is kept but cannot be compared.

Clearing. Compare › Clear Local History… shows a sheet on the workspace window, never an app-modal alert (DS-44), stating the counts and sizes and that it cannot be undone (DS-43), with Cancel first and both clearing buttons marked destructive (DS-41). `clear(path:)` removes one file's folder; `clear()` removes every folder whose name is 64 hexadecimal digits and nothing else.

Switches. `keepLocalHistory` in Settings.json, on unless stored `false`; off keeps nothing new, and kept versions still expire by age and size (the launch prune runs with the switch off) or are cleared. When Settings.json cannot be read the choice is unknown: nothing new is kept and nothing is expired or deleted until it can be read. A process whose support folder is overridden (checks, the bundle smoke run) keeps no history unless a check sets `LocalHistory.allowsIsolatedSupport`.

## Macro storage hardening

Saved macro libraries and chosen macro imports are regular files bounded to32MiB,
matching the resource envelope of saved automations. The encoder and decoder use
the same ceiling, including JSON overhead. This deliberately replaces the older
unbounded, symlink-following Macro load policy (F149; conflicting G358 clause).
A failed load blocks saving; refusal leaves the original file or link and target
bytes untouched. `PrivateFileStore` supplies the bounded no-follow byte I/O and
private fsync-before-rename write mechanism; model validation stays in MacroCore.

`AppStorage` is the computed, side-effect-free source of support/store URLs. A
nonempty absolute `TEXTTANK_SUPPORT_DIRECTORY` remains supported in every build;
relative, empty or NUL-containing values fall back to the normal support path.
Selecting a URL does not create or read a store. An isolated root does not
implicitly import the person's shared search defaults. Controllers capture
their URL at construction; a later controller can follow a changed override.

WorkspaceStore is a compatibility facade over the same private byte helper;
its512MiB session ceiling, error identities, file signatures and cancellable
streamed hashing stay unchanged. Recovery reads now use a no-follow regular-file
descriptor rather than a check followed by Data(contentsOf:). Recovery retains
its addressable-Data ceiling (Int.max), not the session cap, and still materializes
the complete JSON snapshot in memory. Large-document memory behavior is not
certified by the small fixture checks. Equal-revision recovery content compares
UTF-8 text/identity bytes, not Swift's canonically equivalent String equality.

Audit 23's shared failed-load latch now protects Settings, Macro, Automation, Run, Language, Workspace Browser and search preference saves at their persistence boundary. Configuration actions share the explicit error/path, Reveal, Move Aside and Cancel presentation (`StoreRecovery`); passive recent-file updates never open a recovery dialog. Moving aside renames the entry itself under an exclusive unique sibling name. Settings keeps its earlier stricter direct replacement policy for symbolic links and restores its failure latch if replacement fails. A dangling Macro link is a refused entry, rather than a missing store. DS-40, DS-41, DS-42, DS-43, DS-52 and DS-53: recovery is requested by an editing action, identifies retained data and its location, and never executes a macro, command, automation or external export.

These are load-time failure latches, not universal detection of external rewrites after a healthy load. Language deliberately rereads its existing file before saving, so that reread validates the model and minimum-reader metadata and latches a newly observed failure. Other controllers do not all reread their models immediately before each write, and this audit does not add a multi-process compare-and-swap protocol. The Reminders journal retains its own identity checks around replacement and in-place outcome writes. Recovery retains its existing revision/cache behavior and whole-snapshot allocation; its shared I/O capacity remains `Int.max`, rather than silently adopting the session's 512 MiB ceiling. This is not a practical Recovery memory bound.

The Reminders journal uses the shared strict bounded reader and private atomic replacement tail, transferring the committed descriptor back to its journal actor. Its slotted layout, per-row `pwrite`/`fsync`, pre-commit identity guard, compact fallback at capacity, uncertain-before-EventKit barrier and no automatic resend of uncertain rows remain journal-owned. Shared replacement restores exact 0600 using `fchmod` before the file flush and rename, including a restrictive process umask. Recovery snapshots, saved sessions and atomic journal publications request `F_FULLFSYNC` on the file before rename and on the containing directory afterward, with `fsync` on filesystems that do not implement the device flush for recovery, session and initial pending-journal writes. Arming and advancing external-send intent and completing its results require the device operation. A directory flush failure is reported after publication and leaves the visible file in place. In-place reminder row updates retain their existing per-row `fsync` barrier. Malformed journals retain the reader's concrete `DecodingError`; minimum-reader gating occurs before the decoded batch can be accepted. Fake-store native checks make no EventKit calls.

## Presentation identity, numbers and positions

`Strings` is a Foundation-only namespace with explicit English fallback values and a bounded
English `Localizable.xcstrings` catalog for the shared audit26 messages, count labels and display
names. The native app compiles that catalog; raw check executables use the same English fallbacks.
This does not localize every existing UI/error literal or certify translations. Existing development
region `en` is retained. Persisted enum values, library envelopes, command IDs and search-mode
integers remain unchanged. Popups carry represented identifiers, including when display titles
are duplicated or renamed. Each automation launcher menu owns its stable menu identifier.

Encoding conversion/reload/status choices share typed `FileEncoding` names and `FileFormat`
targets. Unknown conversion identifiers fail before format/text mutation. A typed status item
array and exhaustive field dispatch replace parallel strings; legacy repeated badge identities
remain stable. Labels and help describe fields and scopes, including Unicode scalar character
counts. Operational save status no longer appends preview marketing copy; the incomplete-preview
qualification remains in About and product documentation. Precise Undo action captions remain
subject to the separately documented provenance limitation.

Numeric forms keep a real locale-aware formatter and the complete active raw draft. Parsing
requires the whole trimmed input, rejects fractions in integer fields, grouping/exponents/NaN/
infinity and inappropriate decimal separators, and validates bounds at the owning operation.
Unicode decimal digits emitted by the formatter are accepted. Go to Line reads ASCII digits
itself and says what is wrong beside its field, with the valid range. Editable point sizes use a lossless Double
spelling, distinct from concise one-decimal status presentation; an unchanged 12.125 remains
12.125 through Save. Explicit Cancel remains reachable with invalid active editing.

Result presentation uses one monotonic scalar/tab-stop pass over existing immutable captured
text, off the main thread, with cancellation/work limits. Find columns use each document's tab
width captured at search time; folder columns use the captured default tab width. Held result
columns retain that captured setting. CR/LF/CRLF lines, astral characters and combining scalars
agree with native Scintilla columns, including the position between CR and LF. Internal UTF-16
columns, byte ranges, stale-result checks and navigation remain unchanged. Character and selected
lengths count Unicode scalars; Sort Lines by Length now deliberately uses that same unit rather
than grapheme clusters, with stable equal-length ties and one native Undo. Visual glyph width,
grapheme count and Unicode normalization are not substituted for this documented unit.


## App composition and document boundaries

App entry, composition, documents, encoding recovery, tabs, recent documents, status items and
editor windows live in separate files under `Sources/TextTankApp/`. The first split preserves
the declarations and lifecycle; subsequent changes have their own focused checks. The menu tree
is the nine-menu map of DS-D4, pinned by `Tests/Fixtures/menu-tree.json`; the commands of the
earlier fourteen-menu bar are accounted for by `menu-command-identities-before-nine-menus.json`.
The Command Palette matches a command by its menu path or by its former one
(`CommandDiscovery.legacyLocations`, and `CommandDiscovery.formerPaths` for the View menu as it was
before DS-D13), lists the best name match first (`CommandDiscovery.rank`) and
shows each command's current key equivalent (`ControlPresentation.shortcut(of:)`). The five commands
run from it last are kept in `CommandPaletteRecents.json` in the private support folder
(`CommandRecentsStore`): row identities only, read when the palette is first used, never an alert
when the file cannot be read or written. Quick Open (`QuickOpenList`) lists open documents, then
recent files that still exist, then workspace files, one row a file by volume and file number; it
asks the file system off the main thread, to a count and a deadline, and reads no file's contents.
`TextDocumentController` is still constructed before `NSApplication.shared`, before constructing
the application delegate. The intended shared document controller must win that bootstrap order.
The Objective-C document name and Info.plist document class remain unchanged.

`EditorServices` is an optional, explicitly installed feature environment. Its weak providers
retain lazy controller creation and do not retain a discarded composition root. A missing owner,
provider or environment remains a no-op. AppKit creates documents normally; documents, tabs,
workspace restore and editor windows resolve typed services without casting the application
delegate. Checks install and restore that environment independently of `NSApplication.delegate`.
Focus changes call `noteActive`; current-editor getters remain pure.

`DocumentFactory` centralizes hand-built document registration, type and window setup. New,
automation, session and recovery documents have the plain-text type before their first edit.
Recovery identity and revision base are installed before window wiring and loading. Session and
recovery text still opens unsaved, and the original path is never opened by restore. Browser
open still short-circuits an existing document before reading and performs one bounded,
nonblocking no-follow descriptor read. Explicit encoding open retains its initial alias resolution
and prior addressable-data capacity. Captured bytes, digest and descriptor modification date are
handed to the factory together. A recent modification date is not a trusted settled signature;
later pathname replacements remain external changes, rather than becoming a new save baseline.

`SettingsCore.swift` contains Foundation-only values, validation and `SettingsStore`; `ShortcutCore.swift` holds the shortcut model.
The store retains the version-1 bytes, shortcut-only tolerant load, strict save validation, failed-load
latch, retained repair backup and private write/rollback policies. `SettingsController.swift` owns
its AppKit editor and publishes synchronous application/status callbacks. The composition root
supplies `EditorSettingsApplication`, which carries changed defaults to eligible open views and
menus exactly as before. Standalone controllers can supply their own effects; the store itself
never enumerates windows or changes appearance. Pure line transforms and comment plans are
separate from their AppKit editor-application extensions.

`SearchSession` is a Foundation-only immutable planning layer for the existing single-document
navigation, strict replacement and carried selection. It uses the same search reports and engine;
it holds no editor, window or mutable text model. `SearchController` retains scheduling, weak view
lifetimes, multi-document result state and guarded bridge application, with its existing forwarding
APIs. Cheap truncated/closed/stale rejection still happens before selection reads or position
conversion, and the pure planner also validates its input facts. Foundation-only compilation and
native checks enforce this boundary. TextTankCore is now a separate Foundation Swift module;
AppKit composition belongs to the separate Runtime module.

Document language intent applies a profile once and records its identifier only on success.
Language-controller notifications use the separate state-only `noteAppliedLanguage` method, so
menu and style callbacks never apply the lexer again. Lifecycle/focus state has private setters;
production status labels and utility providers are private while checks retain focused read access.
The authoritative read-only flag still belongs to the shared Scintilla document and covers both
panes. No second document buffer, search engine or Undo history was introduced.

The native bridge reports acceptance for indentation, syntax style/font, call tips and
completion requests. Bounds and installed-font rules remain unchanged; completion lists still
filter invalid words before requesting presentation. `setLanguage(keywordLists:properties:)`
retains its compound fallback, clamp and skip behavior rather than promising atomic refusal.

NativeSearch is now a separate Foundation Objective-C++ framework containing the snapshot
search engine and its typed public interface. The application depends on and embeds this
framework; EditorBridge has no dependency on it. Checks link the actual signed native
frameworks after input/artifact validation, with no implementation copies in check compilation.

EditorBridge is now a separate AppKit Objective-C++ framework owning TTEditor and the
ported user lexer. It links Scintilla and Lexilla; it has no dependency on NativeSearch
or the remaining Swift application target. The application embeds both native frameworks.

TextTankCore owns the Foundation model/codec/storage/search-planning sources listed once
in scripts/core_sources.py, including the preview core in `Sources/Preview/` (Markdown
rendering, the static HTML policy, the local resource resolver, delimited-text and JSON models and
the SVG scan; see `docs/preview-model.md`). It depends on NativeSearch and system Foundation/Darwin/CryptoKit/
zlib interfaces, with no EditorBridge, AppKit or executable dependency. Package access and
explicit value constructors form the cross-target API; fields retain setter restrictions,
version decoding requirements and existing defaults. UUID/Date defaults evaluate once per
construction. Native checks import the actual built Debug Core module and link/load its
signed application image rather than recompiling those sources. Core-only checks do not
import Runtime or UI modules.

TextTankRuntime now owns the AppKit/document/controller/service composition and depends on
Core, EditorBridge and NativeSearch. TextTankMain is only the executable bootstrap; Runtime
initializes the custom document controller before NSApplication and installs services in the
existing order. The stable Objective-C TextDocument name is retained. Checks compile only
Tests sources and consume the actual signed Runtime/Core/native images. Product TESTING
branches are replaced by explicit document timing/write/notice configuration and runtime
window/Find/announcement effects; production defaults remain unchanged. Isolated support
without explicit owner capabilities cannot obtain general clipboard or EventKit implicitly.

Runtime UI/controller/composition state is main-actor owned. Worker closures carry immutable
inputs and main-created Sendable deliveries; weak UI references are loaded only on that
actor. Pure Core models, Strings, saved configuration, metrics values and disk inspection
remain nonisolated. Recovery storage and run-control callback state use narrow complete
locks, with arbitrary callback invocation and displaced capture destruction after unlock.
Native search cancellation allows only its audited atomic cancel/read methods to mutate or
observe cancellation; direct ivar KVC is disabled.

Inherited synchronous NSDocument read/data/write entry points retain synchronous main
bridges and their complete super-call/payload/reentry lifetimes. The fileURL getter is a
separate contract: an off-main file presenter can immediately read the superclass URL while
main waits during a save. Only the canonical URL snapshot uses a narrow lock; no superclass
call or UI callback runs under it. Completion deliveries preserve direct main execution
and main-queue worker delivery; an absent controller also delivers on main. Automation
progress continues through the main common-mode CFRunLoop block and wakeup, publishing its
actor-owned result before stopping the nested modal loop in that same turn.

The workspace uses `.none` document transition animation (DS-D7). New, Open, switching and Close mount retained presentations inside the same window, with no sibling ordering or frame copying. One host frame is tracked. Full screen uses native transitions; physical keyboard, VoiceOver and full-screen interaction require separate observations. Explicit document lifecycle notifications keep the workspace browser independent of native-window creation and closing.


### Stage 1 tab commands

`TabCommandCore.swift` computes ordered close plans and final-view document decisions from a value snapshot. A bulk transaction collects every decision before saving, then completes every requested save before removing any view. Structure, dirty state, revision, format and URL are revalidated across asynchronous boundaries. Cancellation or save failure removes no tabs; earlier successful saves remain saved. Final close uses the existing document lifecycle and recovery cleanup.

`TabCommandController` captures TabID for context menus and shares dispatch and validation with Window, File Close and tab controls. Disabled items retain a reason; stale targets and reopen outcomes are visible and announced (DS-20–26, DS-62, DS-72–73). Review sheets name the document and tab count, default to Save, and mark Discard destructive (DS-40–43). No new shortcuts or toolbar controls are introduced.

The in-memory `ClosedTabHistory.capacity` is 20 and stores only URL, placement, view offsets and a disk fingerprint. `TabDiskIO` hashes captured regular-file descriptors off the main actor in cancellable chunks; record identity prevents late publication. Reopen reads current disk bytes through the standard captured document factory, revalidates identity, clamps UTF-8 offsets and placement, and consumes missing records with feedback. It neither persists history nor retains discarded draft text. Locate in Workspace is deferred: adding bounded navigation and ancestor expansion to the lazy browser exceeds a small select-by-URL change.

Reopen compares the captured canonical disk URL, including display aliases, with existing documents' pinned disk locations. Before publishing asynchronous bytes it revalidates the display path's canonical binding and the captured file signature, then repeats the existing-file lookup. The normal captured factory also checks its constructed document's pinned diskURL against the expected captured target before loading bytes, registration or window publication, closing the final alias-lookup race. An alias retarget or a Save As in another existing tab cannot produce a duplicate document or bind captured bytes to a different file. Tests hold the actual disk actor from the test client to make these races deterministic; production I/O and cancellation guards remain unchanged.


### Stage 2 tab organisation and selection

`TabOrganizationCore` changes pin/order values atomically while preserving active/focused identities and
the contiguous pinned prefix. The strip previews a local drag without changing model, text or pasteboard;
keyboard Move uses the same reorder mutation. Overflow reveals active plus moved tabs when both fit;
otherwise active visibility takes priority and the moved position is announced, per owner clarification.

`TabSelectionState` is transient per-group state, outside the saved layout/session/recovery codecs.
The active view is always selected; plain navigation collapses selection, Command toggles, Shift ranges
from active. Selected-inactive tabs have a semantic-color outline and actual AX selected state.
`TabTargetCapture` snapshots menu identities; vanished members are pruned and a vanished clicked target
invalidates the set. Selection changes cannot broaden an already-open menu. Context and Window Close/Pin
use that set, while File Close/Command-W/tab X remain single-tab actions (DS-D2). Close Other preserves
all captured selected tabs plus its clicked target, excluding pinned tabs from implicit close. Explicit
selected Close includes pins and reuses Stage 1 review/save/revalidate/commit. Abort restores selection
and focus; disappearance collapses selection. No group UI, cross-group drag, search or persistence is added.
See [tab-model](tab-model.md) for the settled interaction and DS rule mapping.


### Stage 3 editor groups

`TabGroupCore` plans all four layouts, remaps, moves, duplicate retirement and Close Group atomically.
The workspace registers strong presentations by TabID and weak documents by DocumentID. Each native
group surface has a transient generation: captured source membership and destination continuity are
revalidated before a whole move. Orientation changes preserve groups; removed/recreated slots do not.
The focused group supplies commands, including nil for an empty group; each group's active tab remains
visible independently. Native split dividers enforce total 320 by 200 pane bounds. Grid columns align.
Find uses the same native controls in a compact three-row arrangement at narrow widths.

Each tab has its own primary and optional Clone, sharing one Scintilla document and Undo with other
views. TextDocument's representative transfers to a surviving primary before retirement; its one
change/recovery observer moves without resetting bytes, revision or savepoint. Retiring a non-final
tab removes both editor views, forms, callbacks and adapter ownership, without a document close or
save review. The cold process drains an explicit setup autorelease pool before asserting weak release;
it performs no prior view removal. Final tabs retain the native document lifecycle.

The shared group command owner supplies the View, context and Editor Layout toolbar definitions (DS-20-24,62,70-74, DS-D12).
Menus capture the complete move set; a vanished member invalidates the entire move. Organization
deduplication does not create history. Explicit tab closes capture exact view offsets and group slot;
Reopen resolves a live document identity before fingerprint waits or disk reads, then restores a shared
view or focuses the existing destination. Chooser rows use TabID/group identity. Session and recovery
remain once per document with focused or per-document MRU selection. Explicit session snapshots now carry
optional layout state as described below; automatic launch recovery remains separate. Group shortcuts are unassigned pending a complete system conflict
check; the reference combinations are not assumed safe on an arbitrary Mac.


### Automatic last-session layout

`LastSession.json` in Application Support has a top-level version of 1. Its file list maps identifiers to absolute local paths and optional explicitly selected file encodings. Its layout uses the existing workspace layout format, including group order, active tabs, pins, byte selections and first visible lines. Document text stays in the recovery and explicit-session mechanisms; untitled tabs are named only as described under DS-D9 below. A periodic checkpoint publishes changed metadata. A committed quit captures the final layout before closing its presentations. Canceling quit resumes periodic capture.

#### Unsaved untitled documents across a quit (DS-D9)

With the stored setting `keepUntitledOnQuit` on, which it is unless stored `false`, `AppDelegate.applicationShouldTerminate` first asks each edited untitled document, in tab order, to hold itself for the quit. `TextDocument.holdForQuit()` captures the editor bytes on the main thread and, on the recovery writer's serial queue, saves them through `RecoveryStore.save` (file and directory `F_FULLFSYNC`) and then calls `RecoveryStore.confirm`, which reads the header and body back from the folder and requires the same revision, format, byte count, SHA-256 and bytes. Only then is the document held: it answers "not edited" to AppKit, so the quit review neither counts it nor asks about it, while its status line still says Edited. A failure leaves it edited and the ordinary review asks. Bounds, all falling back to the review rather than dropping text: 256 MiB per document (the automatic-recovery ceiling), and 256 documents and 512 MiB of text per quit (`SizePolicy.keptUntitledCount`, `keptUntitledTotal`). Cancelling the review releases every hold. Before the documents close, each hold is checked against the document's current revision and written and verified again if text changed during the review; if that fails the quit is refused. `TextDocument.close()` never removes a held copy, unless the document was saved under a name while held: it is then a file, the hold is dropped and its copy is removed like any saved document's.

Nothing closes before the quit is certain. AppKit's quit review (`closeAllDocuments`) closes each document as soon as it is clean, saved or discarded, while Cancel is still possible on a later document's review; a held untitled document counts as clean there. While that review is running, or a document is held, `TextDocument.close()` therefore only notes the close: the document leaves `NSDocumentController.documents` and nothing else changes, so the tab, text, selection and Undo history are untouched. `AppDelegate.closeAllForTermination` carries the noted closes out once the quit is certain. While its close is only noted a file is still found by `TextDocumentController.document(for:)`, so opening it again selects its tab instead of making a second document. If AppKit's own review was accepted and a held document's text then changed and cannot be written and verified again, `applicationShouldTerminate` refuses the quit (`.terminateCancel`), registers everything again and leaves the earlier verified copy on disk; a failed newer hold never releases the earlier one. The same refusal applies when a held document no longer fits a bound at the second hold. When the delegate's own review reports that everything was reviewed, the holds are taken again first, and an edited untitled document that is still registered and not held is never closed: that quit is refused too. AppKit completes each review exactly once; there is no timer or activation-based reset of a pending review. A cancelled review registers every such document again and releases the holds, refreshing the tab, title bar and status row that asked while a held document answered "not edited".

The automatic session then names those documents. `LastSession.json` gains an optional `untitled` array of `{id, language?, lineEnding?}` records and has `version` 2 exactly when the array is present; with no kept untitled document the file is byte for byte the version-1 file, and an earlier build refuses a version-2 file and preserves it. The record holds no text: the text, encoding and byte-order mark are the recovery copy whose id it names, and the caret, selection, first visible line, pin state and group are the layout's existing tab fields. Periodic checkpoints name every edited untitled document, so a crash can restore them in place; a committed quit names only held ones.

At launch `restoreLaunchDocuments` receives the recovery scan. Each untitled record with a readable copy reopens through `TextDocument.openKeptUntitled` before the layout is applied: same recovery identity, a later revision base, still untitled and edited, Undo history empty. Untitled copies that no session names (a crash, or a session file that could not be written) reopen as tabs after the session's own, oldest first. With "At launch: New document" the files are skipped and the kept untitled tabs still reopen. One status message reports the count (DS-40). A copy that cannot be read is neither opened nor deleted and reaches the Recover question, as does any recovery copy that names a file. With the setting off, none of this runs: the quit review, the version-1 session and the Recover question are as they were.

The default launch setting opens existing originals from disk and reports skipped paths together. A file already open retains its current buffer. Startup with existing documents preserves their layout and focus. Recovery then offers its usual decision. Choosing Recover opens a separate unsaved draft in its reopened original’s group. The draft keeps the informational origin for a subsequent interrupted session. Older settings default to reopening the last session. An unknown or unreadable automatic-session version is preserved.

### Stage 4 document targets and explicit session layout

Foundation `DocumentTarget` records runtime document identity, modification revision, reload epoch and
oriented UTF-8 selections. `AutomationDocumentTarget` captures immutable input on the main actor and
holds weak document/origin references. All automation entry points choose at invocation (palette Run).
Results revalidate their source identity/revision/epoch before any output (and after a file Save panel).
Whole-document external output ignores caret-only changes and permits read-only sources; selection input
checks live-origin drift. Independent clipboard/file inputs remain independent. Editor writes check
read-only state before the atomic bridge edit;
a surviving sibling can receive captured ranges after origin retirement. Live-origin selection drift
still rejects. Whole-document output keeps the minimal-span bookmark/caret behavior and one Undo.

`WorkspaceSession` schemaVersion 1 adds Optional `layoutState` with saved SessionDocument IDs, never
runtime IDs. Text occurs once/document. A malformed/unknown optional layout is classified separately
from strict document/envelope corruption. Explicit restore validates policy before opening anything,
creates fresh unsaved documents and recovery identities, then reconstructs shared Scintilla views,
ordered tabs, pins, group actives/focus and clamped UTF-8 view positions. Empty workspaces apply a fitting
valid layout or fall back to Single. Nonempty workspaces keep their layout and merge into the captured
focused group. Confirmations revalidate after modal work; visible summaries are announced. Legacy absent
layout retains its previous focused-group restore behavior. Recovery stays one snapshot/document/view
and never consumes session layouts. Closed-tab history remains transient. No automatic last-session
restore, extra window, collection, comparison engine or AI provider is introduced. See
[tab-model](tab-model.md#stage-4-document-targets-and-explicit-session-layouts) for the contract and DS rules.

## Wave 5 Foundation

[review-model](review-model.md) defines the shared immutable snapshot/change/preflight contract. The five Sources/Review Core files are explicitly registered in core_sources.py; SnapshotCapture and ProposalApplier remain Runtime. No new UI or consumer migration is included. ReviewDiffing is the replaceable Sendable engine protocol; Runtime accepts an injected engine. The first-party ReviewDiffEngine always detaches worker computation. Both linear-space Myers and exact-anchor/LIS strategies share bounded accounting, with independently bounded grapheme refinement and complete/cancelled/budgetStopped results. A weak exact document capture composes existing DocumentTarget and reload epochs; one internally issued shared apply ticket revalidates all exact bytes before the existing atomic bridge transaction, without staging selections or nesting Undo. Empty/rejected attempts consume the ticket without native state changes. Actual behavior and two-strategy measurements belong to exact-candidate validation evidence.

## Read-only comparison (D1)

[compare-model](compare-model.md) defines the snapshot/source bindings, bounded Core projection and typed bridge contract. CompareService captures explicit inputs and schedules one diff pipeline with at most two result windows. CompareController owns independent locked snapshot renderers and a virtual native unified table; no source document, Undo stack, saved layout or recovery record is created. A failed Refresh retains the previous complete generation. Explicit file encodings use FileCodec; Tab and Saved File binds the captured document and its pinned saved location. ToolPanel key-window scope blocks background document commands. DS-20–25, DS-30–31, DS-50–53, DS-70–74 and DS-90–92 govern the native controls, truthful feedback and accessibility.


## Selective merge and patch export (D2)

[merge-model](merge-model.md) binds whole-block selection to a comparison generation and an explicit
open destination, including parent-relative selection slices. MergeCore plans exact selected-only
coalesced edits off MainActor; strict destination encoding admission precedes the sole Foundation
ReviewRequest/atomic applier. No comparison renderer becomes editable and no alternate Undo authority
is introduced. Known own-commit rebinding preserves a Tab/Saved captured disk value without rereading.
Fresh destination recomputation invalidates all old coordinates; failure keeps applied text and a
visibly stale capture. Show Destination activates the exact bound document for ordinary Undo/Redo.

CompareService serializes merge/patch auxiliary jobs with comparison computation. Native virtualized
checkbox sheets and menu/toolbar definitions share validation. UnifiedPatch uses an explicit LF-only
first-party solver entry; ordinary F0/D1 CR/CRLF/LF defaults remain unchanged. File publication stages
a bounded0600 temp on a worker, then MainActor revalidates live sources/job/protected URL-inode identity
and performs a short single-use prepared-ticket rename without await. Legacy PrivateFileStore.write
is unchanged. No patch execution/import, implicit clipboard read/save, filter, provider or dependency.
