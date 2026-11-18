# Architecture

Scintilla owns authoritative UTF-8 bytes and undo. TTEditor bridges Cocoa through Objective-C++; Swift never keeps a second mutable buffer. NSDocument owns file identity, encoding metadata, safe save coordination and window lifecycle. Clones share the Scintilla document, not independent string snapshots: text, read-only, tab settings, line-ending mode, lexer and keyword lists, bookmarks, highlights, undo and the save point are document state, while wrap, zoom, selection, syntax styles, margins and whitespace visibility are per view (TTEditor.h lists both). A clone copies view state from the pane it was made from and never rewrites document state; a language or style change installs the lexer once and copies styles to the other pane. The current editor has one definition, `AppDelegate.currentEditor`: the active presentation in the single workspace host, including its last-focused Clone. Auxiliary panels do not change that target. Each document retains a windowless EditorWindowController adapter and its presentation; WorkspaceWindowController alone owns the native window and shared toolbar. Native document-action entry points reveal their captured document for review; TextDocument.windowForSheet only returns its host and has no focus side effect. EditorLifetime separates open document, detached view and visible tab facts, retaining closed/retired markers independently of native-window presence. See [the tab model](tab-model.md) for invariants, empty workspace and codec-only layout state. Getters remain pure; focus changes are explicit, and captured operations retain revision and selection guards. Main-thread editor access only. Capture revision for transforms; reject stale output. No side effects on open/import/restore.

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

`EditorCommand` in `Sources/Documents/EditorCommandCatalog.swift` owns stable Swift identifiers, display names, fixed menu keys, assignable defaults and explicit recordable/view-only/assignable subsets. Menu placement stays literal. The bridge derives dispatch, replay and canonical recording maps from one numeric table; replay-only `indent`/`unindent` aliases never compete with `tab`/`backTab` in recordings. The frozen pre-refactor contract retains all 84 supported identifiers, 62 replayable names, 60 canonical recording messages and the exact text-changing subset. A routed unknown identifier returns failure before text, selection-generation or notification changes. Custom menu validation disables unavailable/text-changing commands when necessary and reads actual per-view toggle states; status menus use the same command names and current keys.

Editor Settings keeps version 1 and `shortcuts: [String: String]`. Missing required keys, wrong JSON types, unsupported schema/minimum-reader metadata and unsafe/unreadable files still fail closed. Shortcut-only problems are handled separately on load: unknown, unsupported, reserved or duplicate string bindings are ignored individually, valid shortcuts and unrelated settings remain usable, and the ignored entries are reported. The original file is unchanged until an explicit Save. That repair save validates strictly, keeps the original as a unique sibling and retains the existing rollback behavior. This is not automatic repair or universal detection of later external rewrites.

The historical pre-menu reserved fallback remains available. Effective protection additionally includes Command-E/window cycling and fixed Command/Command-Shift keys from the built menu, preserving modifier distinctions; Command-Option keys do not reserve unrelated Command keys. Startup reconciles again after menus exist, so a new fixed menu key does not discard unrelated editor settings. This deliberately changes shortcut-only load rejection, while save validation remains strict. Clearing a custom binding removes its override; clearing Duplicate Line restores Command-D. Empty strings are never a new stored unbinding vocabulary, and visiting/saving the default does not add a redundant override. The Settings working copy commits each row before popup changes, preserving earlier edits and invalid drafts. Shared shortcut validation also returns the stable offending command identity while strict saves retain their existing error cases. A rejected earlier row is selected again, its exact draft is shown and marked/focused, and every other row remains in the working copy. Conflicts with implicit defaults identify an editable conflicting override. All drafts are validated before recovery can move saved data aside.

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

The visible-only 0.2-second polling timer remains under DB-R8. In the native check,
a real Language menu action changes the document's profile but queued editor events
do not update the field; an actual polling tick does. This is evidence from the
owned fixture, not a claim about every running-app/OS event sequence. Existing
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

An inline request captures the editor/window, revision, every selection range and the primary anchor/caret. Only snapshot strings reach the worker. Before applying on the main actor, it checks those values and the caller's active pane, query/options and generation again. Field edits, another action, Done/Escape and close cancel the pending request; stale/cancelled/truncated results never edit, select or record. Deferred selection notifications alone do not invalidate unchanged ranges. Known input/selection/read-only/busy preconditions disable the appropriate inline button using bounded field prefixes and existing editor/field/focus events, without capturing document text or adding polling. Next remains usable in read-only documents. Return/Shift-Return keep the Find field editor; menu and button actions commit field editing and return typing to the captured document. The two Find surfaces exchange their query with the system Find pasteboard through injected callbacks (in-memory in native checks), without executing another search or bypassing private preference persistence/recovery.

New bar recordings contain only version-1 `search` actions (`next`, `previous`, `replaceOne`). Replace Selection requires one nonempty selected match, carries the starting selection through the edit and is one Undo action. A missed, refused, stale or cancelled action adds no macro action. Legacy `findLiteral` remains readable and uses the shared literal engine with wrap; legacy `replaceSelection` retains captured-text caret insertion/replacement because its wire payload contains no query. All symbolic command allow-lists, unsupported-action capture failures and grouped playback Undo remain unchanged.

Consolidation deliberately applies the existing engine limits to inline and legacy literal playback: 64 Mi UTF-16 document units, 65,536 query units, 1 Mi replacement units, 100,000 results, 64 Mi expanded output units and the default two-second search budget. Inline and recorded playback refuse truncated results. The prior native literal primitive had no such limits: an executed 65,537-unit legacy query succeeded before consolidation and now reports the shared limit without changing bytes/revision/selection or recording a completed action. This is a compatibility restriction, not universal equivalence with the former Scintilla search; sampled non-ASCII/astral cases agree, while full Unicode/reference differential behavior remains unverified.

`TTEditor.find` is retained for native bridge/Undo control checks and the unchanged PerformanceChecks primitive benchmark, including its 100 MiB manual tier. No product UI or macro path calls it. Retiring that API is deferred rather than weakening the real primitive benchmark or adding an uncapped product fallback. Those timings measure Scintilla's primitive, not the new end-to-end asynchronous Find latency; no equivalent speed claim is made for the shared path.

## Find and Replace window

`SearchController` searches text snapshots off the main thread and applies results only after re-checking them. The editor's `revision` is the staleness authority: every insert and delete moves it, in every view of a shared document (bridge-checks proves each path), so the controller compares revisions and does not re-copy and compare the whole text. A split clone takes its revision from the primary when it is created and before it can be searched; a new way of changing text must move the revision too.

- Results hold each searched editor weakly, keep one text snapshot per document with rows that refer to it by index, and are dropped when the Find window closes. Find Next from the menu with the window closed holds results again until the next search.
- Next and Previous reuse the held results while the editors, their revisions, the options and the scope are unchanged; anything else searches again.
- Selection scope: the first Next or Previous takes the selection as the scope and later presses keep that scope, until an edit, a manual selection change or an action in another scope. Every other action reads the live selection.
- All open documents: Next and Previous first look in the document they are in, then move through the other documents in open order (the order of `openEditors`), wrapping across documents when Wrap is on. The document last navigated to stays the starting point while its selection is still that match, because the application's current editor can lag behind a cross-document move. It stops being the starting point when the current editor is another listed document, or when the document navigated from is on screen and the one navigated to is not (only the selected tab's window is visible).
- Replace edits only the document it was pressed in. In All open documents that document is found by the same rule as the starting point of Next, so Next into another document and then Replace replaces the match just selected; a current editor outside the open list (a split view) needs a match selected by Next first, and a document Next moved to stops being that document once it is hidden while the current editor is on screen, whether that editor is listed or not. In the current document, Replace with no match selected selects the next one (recorded as `next`), and a successful Replace then selects the following match (recorded as `replaceOne` then `next`). Cancel while that following match is being looked for keeps the replacement's status and outcome. Macro playback of `replaceOne` stays strict: it replaces a selected match and never moves, so saved macros play as before. A habit of Replace, Next, Replace now skips a match.
- Replace and Replace All apply one `replaceRanges:withTexts:expectedRevision:` call per document: all ranges are validated before the first edit, the edit is one undo action, and the selection the command began with is then carried through the replacements (the bridge call itself leaves the caret just after the first replacement), so Undo returns to it. `ReplaceOutcome` says why a document was skipped (read-only, multiple selections, closed or changed).
- Find in Folder validates once before any file is read: filters are parsed and the expression is compiled on empty text, so an invalid one is a single error. After that a failure in one file skips that file only. `FolderSearchReport.skipped` lists the entries that could not be searched (unreadable, not valid text, too large); what filters and settings left out is counted per reason in `excludedCounts` and listed only when a request sets `listsPolicyExclusions`. Filename globs match as precomposed Unicode scalars or as UTF-16 units; path scoping compares UTF-8 bytes.
- Folder replacement's own files (`.texttank-backup-`, `.texttank-replacement-`, `.texttank-report-`) are never search results or replacement targets. A file that was not changed (conflict, cancellation, or a failure before the rename is attempted) keeps no recovery copy and no journal. While a replacement runs, the window refuses a new search and refuses to open a result.
- Find Next and Find Previous call `onFailureSignal` (the system alert sound) whenever they select nothing, since both work from the menu while the window and its status line are closed.

## Persisted formats

Find and Find in Folder now save versioned JSON files under `AppStorage.supportDirectory` on action or close. They import a legacy preference only when their private file is absent; legacy values are never written or removed. An absolute support override suppresses implicit legacy access entirely, including obtaining `UserDefaults.standard`. Window frames retain bundled-application-only production behavior and explicit fixture overrides, but suppress implicit shared preferences under that isolation override. Native checks use a protected test-owned provider and sentinel; they never inspect the owner's preferences. The prior source path had an isolation gap; which defaults domain earlier command-line runs actually accessed was not established, and no owner-domain cleanup or inference is made.

Search preferences use `JSONFileStore` and the common `StoreLoadState`: an unreadable file remains intact and blocks direct saves. The search continues with visible feedback when preferences cannot be saved. An explicit Reset Saved Settings action renames the previous entry beside its original path and saves defaults; a failed replacement attempts an exclusive rollback and retains any backup. A healthy no-op compares stable encoded bytes, preserving Unicode byte differences. Both preference readers allow 8 MiB, enough for the existing validated UTF-16 field limits even with JSON escaping. DS-40, DS-41, DS-43, DS-52, DS-53, DS-72 and DS-83: the persistent notice names the failure without blocking a search; reset is explicitly confirmed, destructive Return is guarded, the alert identifies affected data, and documents remain untouched.

Every file and defaults value the app writes is a versioned Codable value type: editor settings, Find options, Find-in-Folder settings, the workspace browser state, the Run library, session snapshots, recovery snapshots, the Reminders journal, the macro library, the language catalog and the automation library. Most decoders are synthesized, so every non-optional property is a required key, including properties that have a default value. `RecordedMacro.Step` is an associated-value enum with custom Codable retaining the existing `kind` and payload keys: irrelevant nil payloads stay omitted, null optionals and unknown extra keys remain readable, and malformed or incompatible known payloads are rejected. Its encoder still reproduces the golden version-1 bytes.

A field added to a version-1 type must therefore be one of two things. Either it is Optional, as the later fields of `AutomationDefinition` are, or it is decoded with `decodeIfPresent(...) ?? default` in an `init(from:)` written in an extension for that field only. An `init(from:)` in the struct body removes the memberwise and default initializers that the sources and checks use. Never default a missing `version` or `schemaVersion`, a document's text, format, selection, dirty flag or revision, or a Run item's `shellMode` or `extensionMode`: those stay required. A change in what an existing field means needs a new `version` or `schemaVersion` and an explicit migration.

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

Settings uses an owned, resizable `FormPanel`, opened by Command-comma and titled
“Settings”. Save explicitly applies its working copy; Cancel, Escape and Close abandon
pending changes. Reset Defaults remains a destructive, explicitly confirmed action.
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
Save persists it. New macros contain a validated nonempty Insert Text action.
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
exactly once. Go to Line is an owned modeless panel; closing its captured document
closes the panel, and a changed or retired target cannot navigate a stale editor.

`VersionedLibrary` in `Sources/Documents/` shares their Foundation-only codec with
`AutomationRuleSet`. Each model retains its required version, optional minimum-reader
gate, validation, byte capacity and diagnostic vocabulary. Encoding validates and
checks the same capacity used by decoding. The three libraries retain pretty,
sorted, unescaped-slash JSON; portable rule files retain their escaped-slash
format. No stored keys or version-1 fixture bytes change.

## Reminders export journal

Each export batch is one version-1 JSON file in `ReminderExports`. A row is recorded as uncertain, and that record is synced, before the row is handed to Reminders; it becomes confirmed or failed only afterwards, and an uncertain row is never resent automatically.

- The first write of an export replaces the file atomically (private temporary file, fsync, rename) in a slotted layout: one row per line, each ending in a space-padded slot for its status, reminder identifier and message. JSON permits that whitespace, so the file decodes like the compact form earlier builds wrote, which still loads.
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

Session snapshot (`WorkspaceSession`, written by File > Save Session Snapshot; proposed extension `.texttanksession`, exported as `app.texttank.session`). A snapshot loads under any file name. Opening a `.texttanksession` file from Finder or File > Open goes to the restore prompt instead of showing the JSON as an editable document.

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

Recovery snapshot (`RecoverySnapshot`, one `<id>.json` per unsaved document in the app's private `Recovery` folder, mode 0600):

| Key | Type | Required | Meaning |
| --- | --- | --- | --- |
| `schemaVersion` | integer | yes | Always 1. |
| `id` | UUID string | yes | Must equal the file name. |
| `text` | string | yes | The whole editor text. It may hold characters `format` cannot encode; those are kept. |
| `format` | object | yes | As for a session document. |
| `originalURL` | file URL string | no | The file the draft belongs to, absent for an untitled one. Note that this is a string here and a URL in a session document; both hold the same absolute `file://` form. Shown in the recovery prompt, in the recovered window's title and status line, and nowhere else: recovery never opens or writes that path. |
| `revision` | integer | yes | Monotonic per `id`, at most 2^63 - 1. A snapshot is never replaced by a lower revision, and never by an equal revision with different content. |
| `savedAt` | date | yes | When the snapshot was written. Shown in the recovery prompt and the recovered window's status line. |

The Recovery folder may also hold `<UUID>.pending` files: the temporary file of a write in progress. One left by a process that died during a write is deleted by the next launch's scan. A `.json` entry is never deleted except by saving, closing or explicitly discarding the document it belongs to.

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

The Reminders journal uses the shared strict bounded reader and private atomic replacement tail, transferring the committed descriptor back to its journal actor. Its slotted layout, per-row `pwrite`/`fsync`, pre-commit identity guard, compact fallback at capacity, uncertain-before-EventKit barrier and no automatic resend of uncertain rows remain journal-owned. Shared replacement restores exact 0600 using `fchmod` before `fsync` and rename, including a restrictive process umask. Malformed journals retain the reader's concrete `DecodingError`; minimum-reader gating occurs before the decoded batch can be accepted. Fake-store native checks make no EventKit calls.

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
Unicode decimal digits emitted by the formatter are accepted. Go to Line retains signed integer
recognition and its existing out-of-range feedback. Editable point sizes use a lossless Double
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
the declarations, menu tree and lifecycle; subsequent changes have their own focused checks.
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

`SettingsCore.swift` contains Foundation-only values, validation, drafts and `SettingsStore`.
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

TextTankCore owns the30 Foundation model/codec/storage/search-planning sources listed once
in scripts/core_sources.py. It depends on NativeSearch and system Foundation/Darwin/CryptoKit/
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

The shared group command owner supplies View, context and trailing picker definitions (DS-20-24,62,70-74).
Menus capture the complete move set; a vanished member invalidates the entire move. Organization
deduplication does not create history. Explicit tab closes capture exact view offsets and group slot;
Reopen resolves a live document identity before fingerprint waits or disk reads, then restores a shared
view or focuses the existing destination. Chooser rows use TabID/group identity. Session and recovery
remain once per document with focused or per-document MRU selection. No layout persistence or automatic
restore is connected; that is Stage 4. Group shortcuts are unassigned pending a complete system conflict
check; the reference combinations are not assumed safe on an arbitrary Mac.
