# Audit finding IDs

These titles identify findings cited by first-party source and checks. They describe the 14 November 2026 audit snapshot. The corresponding checks establish current behavior.

The titles come from the confirmed entries in the *TextTank code audit, 14 November 2026*. The source JSON has SHA-256 `cdf5fc230643939d6ce46f9e45f47d6bae4e31f9c916f1d0283496e54a4c8c75`.

Some test labels use the same letters for other purposes. F0 identifies the Review foundation phase in the Review and Compare checks. F000 is the HarnessChecks demonstration ID. G2, G3 and G4 identify editor groups in the T3 checks. The Swift Unicode escape F702 represents the left arrow function-key character. F9 labels the recording function key when present. These names have no numbered audit finding.

| ID | Historical title |
| --- | --- |
| F3 | Line-comment commands do nothing when the caret is at the end of an unterminated last line |
| F4 | Comment commands rewrite the entire buffer, destroying bookmarks and moving the viewport |
| F6 | A document whose file was deleted externally can never be saved back to its own path |
| F7 | Revert to Saved leaves the discarded edits in the recovery store |
| F10 | Save Copy can desynchronise the external-change baseline and always suggests a .txt name |
| F11 | Remove Duplicate Lines appends a line ending that was not in the input |
| F12 | Go to Line recomputes line offsets with a regex over a full copy of the document |
| F16 | TTAlert assigns key equivalents by English button title, and Settings treats any unexpected response as Save |
| F17 | Inline find bar drops keyboard focus, and Replace Selection acts without a match |
| F18 | Minor sloppiness in document commands and settings |
| F19 | Regex search aborts on any document with astral characters when the pattern can consume one code unit or match empty |
| F20 | Unchecked nil from dataUsingEncoding turns an unencodable string into a silent deletion |
| F21 | setLanguage replaces the document-level lexer but only restyles the receiving view, so split views desynchronise |
| F22 | setLanguage hard-codes a C-like keyword list and C-lexer style numbers for every lexer |
| F23 | Regex mode is ASCII-only for case folding and word classes while literal mode and whole-word are Unicode-aware |
| F24 | TTStringFromUTF8 returns an empty string on decode failure and triple-copies the document on every read |
| F27 | Whole-word filtering discards overlapping candidates after a rejected match |
| F28 | Line-number margin is a fixed 48 px and never tracks line count or zoom |
| F29 | Bridge headers are stringly typed and most rejections are silent |
| F32 | Rich-text export queries Scintilla per byte and exports only the main selection |
| F33 | Change callback fires once per modification step with no coalescing inside undo groups |
| F34 | Replace (single) does an O(document) UTF-16 array copy per hit on the main thread |
| F35 | Next/Previous in "Selection" scope cannot navigate: it finds nothing or sticks on the first match |
| F36 | Replace (single) with "All open documents" scope edits every document whose selection happens to be a match |
| F37 | Selection-scope search runs on an extracted substring, so word boundaries, anchors and lookarounds ignore the surrounding document |
| F39 | Folder replacement leaves permanent hidden backup/journal files that later searches match and rewrite; aborted files keep a stale "prepared" journal |
| F40 | SearchCore.replacing edits an NSMutableString in place once per hit |
| F42 | Folder search records every policy-filtered entry as "skipped" and dumps the list into the details view |
| F43 | Macro playback of search steps has a hard 0.1 s budget, so replay success depends on machine speed and document size |
| F44 | apply() conflates read-only, multi-selection, closed and stale documents, and can return false after partially editing |
| F45 | Replace (single) is a silent no-op unless the selection already equals a match, and never advances |
| F46 | Bookmark line calculation puts a match that starts on the LF of a CRLF pair on the following line |
| F47 | One invalid match range aborts the whole folder root instead of skipping the file |
| F48 | "All open documents" navigation never leaves the current document |
| F52 | Dead production code and write-only state in FolderSearchController |
| F55 | removeMatchingLines uses one 0.1 s wall-clock budget for the whole run, so large inputs fail with a false 'pattern exceeded its time limit' |
| F58 | keepMarkedListRows is quadratic and cannot be cancelled |
| F59 | Macro recording silently omits mouse caret/selection changes and drag-and-drop edits |
| F62 | removeNoteReferences strips leading and trailing whitespace from every line, including lines with no note reference |
| F63 | removeMatchingLines whole-line test only examines the first match, so alternations can miss a line the pattern fully matches |
| F65 | RunResult flags conflate output-limit, timeout/cancel and 'descendant still holds the pipe' |
| F67 | Invalidated recordings keep 'recording' with no feedback, and discard reasons are opaque |
| F68 | A find that did not match is still recorded as a macro step |
| F70 | Edit dialog stores an empty string instead of nil for 'no shortcut' |
| F71 | 'Ask when running' steps still require a non-empty saved default |
| F72 | AutomationFileInput reports wrong errors |
| F75 | First-run preset install happens in the controller initialiser, and a failure there blocks automation editing for the session |
| F76 | A bad stored LanguageProfiles.json disables all language support with no in-app recovery |
| F77 | First profile edit forks the whole bundled catalog; later bundled updates are never seen |
| F80 | Function List line counting is quadratic and trips its own 0.1 s limit on ordinary files |
| F81 | Imported UDLs can never win extension detection over a built-in profile |
| F82 | UDL styles are forced to fixed foreground colours while background is discarded |
| F83 | Profile and style changes are applied only to the focused editor view |
| F84 | Saving any style edit pins that style to an explicit font name and size |
| F86 | DocumentMonitor re-reads and hashes the whole file every 2 s and hashes the baseline twice per tick on the main thread |
| F87 | Monitor status is republished every tick and overwrites other Workspace panel messages |
| F89 | Quoted-printable decode rejects LF soft line breaks; encoder hard-codes CRLF and leaves trailing whitespace raw |
| F91 | Workspace 'Open Documents' list is a stale strong snapshot |
| F92 | WorkspaceBrowserController.open hand-builds documents instead of going through NSDocumentController |
| F93 | Workspace store compares URLs two different ways |
| F94 | Shared WorkspaceError messages are wrong for most callers |
| F95 | Language detection table has a dead entry and matches shebangs by substring |
| F96 | Two different 'no language' sentinels |
| F97 | Style picker indexes by NSPopUpButton position but addItem(withTitle:) removes duplicate titles |
| F98 | UDL import rejects valid Notepad++ files on minor fields with a generic error |
| F99 | Edit Current UDL / re-import regenerates the profile and drops profile-level customisations |
| F100 | SAML decode only accepts XML starting with '<?xml' or '<saml' and allocates 16 MiB per call |
| F101 | Byte-wise encoders build output with one String(format:) per byte |
| F102 | Hex-with-options and Number Conversion rough edges |
| F109 | Directory listing truncates before sorting |
| F110 | Automation progress panel cannot be cancelled: Cancel only sets a flag, and several steps never check it |
| F111 | Pressing Return in the Find in Folder query field silently cancels an in-flight multi-file replacement |
| F114 | Save, close, reload and encoding conversion block the main thread on the recovery queue, and close writes a snapshot only to delete it |
| F116 | Quitting does not cancel a running Run command; the child process group is orphaned with no timeout |
| F117 | Background closures hold strong references to main-thread-only objects, so the last release can happen off the main thread |
| F118 | Modal run loops are started from inside main-queue blocks and main-actor Tasks, and one modal depends on main-queue delivery to end |
| F119 | Recovery and status timers run only in the default run-loop mode, so the 0.5 s / 5 s recovery guarantees pause during modals and tracking |
| F122 | Find and Replace results keep closed documents' editors and full text snapshots alive indefinitely |
| F124 | No check exercises the large-input automation worker path, its cancellation, or folder-search re-entrancy |
| F125 | Undo in a recovered (or session-restored) document empties it, marks it clean, and deletes its crash-recovery snapshot |
| F126 | Scintilla EOL mode is never set from the loaded file, so editing a CRLF or CR file inserts bare LF and silently produces mixed line endings |
| F127 | Files in a legacy encoding cannot be opened at all; the error tells the user to choose an encoding but no such path exists |
| F128 | Folder replace preserves the original modification time on rewritten files, hiding the change from mtime-based tools |
| F133 | Recovery prompt offers no discard option and recovered documents do not show which file they came from |
| F135 | RecoveryStore hygiene: test-only loadAll duplicates scan, and crash-orphaned .pending files are never cleaned |
| F137 | Saved Run commands cannot be inspected, edited or deleted; the menu shows only a free-text name for what will be executed |
| F138 | Opening a session file reads every path it references before the user confirms anything |
| F140 | Test-only TEXTTANK_SUPPORT_DIRECTORY override is honoured by the production app for all persistent state, including Run commands |
| F141 | Clipboard automation input parses attacker-controlled HTML/RTF with NSAttributedString's importer |
| F142 | Run children inherit the app's whole environment and an unspecified working directory |
| F143 | `{selection}` is substituted as a bare argv element, so document text can be read as an option; over-limit or NUL selections give a misleading error |
| F144 | UDL import blocks DTDs with a UTF-8 substring denylist that the XML parser's own encoding detection can bypass |
| F146 | Run cleanup signals the process group after the leader has been reaped, and a waitpid failure is reported as a clean exit |
| F148 | Production code falls back to a cwd-relative Resources/LanguageProfiles.json when the bundle resource is missing |
| F149 | Private atomic-write and bounded regular-file read are re-implemented 6-7 times, and the copies have drifted |
| F155 | The 'edit library as JSON with Save / Cancel / Import… / Export…' modal and its versioned library type are copy-pasted for automations, macros and languages |
| F162 | Search stack repeats offset conversion, surrogate checks, canonical-root resolution, hashing and cancellation state |
| F180 | Encoding choices are defined four times as string tables; the main menu shows raw enum names |
| F181 | Errors are a mix of numbered NSErrors and per-module enums; some reach the user with no message, and one condition is tested three different ways |
| F182 | Popup and segment positions are used as magic integers, and popup order is coupled to enum raw values |
| F186 | Access control is largely absent on controller state; internal mutable properties are written across types |
| F188 | Automation step kinds named `remove…Lines` blank the line instead of removing it |
| F191 | Menu construction order does not match menu-bar order and relies on positional helper arguments |
| F192 | Save, external-change check and monitoring fail with ELOOP for any document reached through a symlink |
| F198 | Unreadable configuration stores are a dead end, and are handled differently in every controller |
| F199 | Settings save overwrites an unreadable settings file while the error says existing settings were not replaced |
| F200 | Invalid regex in Find in Folder is reported as thousands of skipped files instead of one up-front error |
| F202 | Recovery-store failures are swallowed on close and otherwise shown only in the status label |
| F203 | Editing an automation discards all changes, including rule edits, when final validation fails |
| F204 | Catch-all error cases produce messages that describe the wrong problem |
| F206 | System errno is discarded and replaced with generic EIO / CocoaError codes |
| F207 | User actions that cannot proceed return silently or only beep |
| F210 | Search bridge result is an untyped dictionary unpacked with force casts; some errors carry no message |
| F212 | Preference persistence errors are swallowed and unreadable search settings permanently stop saving |
| F213 | Validation failures do not identify the offending item |
| F214 | Dialogs validate after dismissal, so a typo throws away everything the user entered |
| F218 | Status bar polls 5x/second and copies the whole document on the main thread after every edit burst |
| F220 | Applying a language re-lexes the entire document dozens of times |
| F221 | TTEditor.text makes four full-size copies per read and is used as a general-purpose accessor |
| F222 | Macro 'repeat until end of document' copies the whole document every iteration |
| F223 | Every Find Next / Previous re-snapshots the document and recomputes all matches; stale checks re-copy and compare the full buffer |
| F224 | Replace All drives the selection per hit and fires per-edit change callbacks that recreate timers |
| F227 | Each open document retains a second full copy of its on-disk bytes, re-reads the file synchronously on save, and re-hashes it on every monitor poll |
| F228 | Regex engine input is copied one UTF-16 unit at a time into a 4-byte wstring and the pattern is recompiled for every file |
| F229 | File open/save path makes many full-size copies and builds UTF-16/Latin text one scalar at a time |
| F231 | Line transforms allocate per character and contain quadratic trims/sort comparators |
| F234 | Every Scintilla notification (including SCN_PAINTED) invalidates the line-number overlay, which rebuilds fonts on each draw |
| F241 | Launch decodes the 1.2 MB language catalog twice and rebuilds lexer lists/menus on demand |
| F243 | Crash-recovery restore at launch and the dirty-quit path have no test at all |
| F248 | Lexer-profile loop asserts nothing about how many profiles load |
| F251 | Menu and command wiring in App.swift is untested, so renamed selectors produce dead menu items silently |
| F252 | Most EditorTransform cases and about 28 TTEditor commands are never executed by any check |
| F253 | Controller-level user flows that mutate files or external state are untested |
| F255 | Search controller checks read and write the real UserDefaults.standard domain |
| F269 | Tests compile a specially flagged copy of the sources, not the built app; production code carries TESTING conditionals |
| F274 | App.swift is a god file: 9 types and roughly 20 unrelated responsibilities in 871 lines |
| F275 | Four different definitions of the current editor; Macros and Automations stop working when an auxiliary window is main |
| F276 | Features reach each other through `NSApp.delegate as? AppDelegate`; the document model depends on the app delegate |
| F277 | Macro-recording safety is a scattered opt-in convention; Go to Line and Clear Selection slip through it |
| F278 | Editor-provider getters have side effects: merely asking for the editor discards a macro recording |
| F281 | No command catalog: command identifiers are bare strings duplicated across seven tables, and unknown ids are silently ignored |
| F285 | The Core/Controller split is not applied in Documents, and controllers mix UI, persistence and domain logic |
| F287 | Status bar and tabs are driven by a 200 ms polling timer per window because the bridge exposes only single-slot callbacks |
| F293 | Auxiliary tool windows are main-capable NSWindows: document menu commands die and each Find Next click sends the Find window behind the document |
| F294 | No menu validation anywhere; the Read Only checkmark is global state that goes stale across documents |
| F295 | Automation context menu is assigned to TTEditor.menu, which Scintilla's content view never consults |
| F297 | Hide-other-windows tab model breaks under full screen and is not guarded |
| F298 | Closing a tab always jumps to the first document, and quitting re-shows each remaining window in turn |
| F299 | Dynamic syntax colours are flattened to RGB without the view's appearance, so a light/dark switch can keep the old palette |
| F301 | Five hand-rolled document creation paths bypass NSDocumentController and leave fileType nil |
| F302 | Getters and provider closures with side effects, plus a window-update observer that exists only to trigger one (the old crash site) |
| F304 | TTAlert guts NSAlert and is used as the app's general-purpose dialog framework |
| F305 | Every Command-key press rebuilds the Language, Macros, Automations and Workspace menus |
| F306 | Programmatic main menu omits standard macOS items |
| F308 | Find Next/Previous gives no feedback when the Find window is closed |
| F310 | No window frame persistence, no secure restorable-state opt-in, deprecated activation call |
| F313 | AutomationStepEditor uses hard-coded frames in a fixed 940x700 non-resizable window and rebuilds cells without reuse |
| F316 | Main-thread-only invariant is not compiler-enforced: 1,262 strict-concurrency warnings, and the UI controllers have no @MainActor |
| F325 | Two alert styles are mixed: 40 plain NSAlert constructions alongside 39 TTAlert, despite TTAlert being the documented shared modal |
| G328 | UDLWordList sort comparator is not a strict weak ordering (undefined behaviour), and the reorder is implemented twice with different results |
| G329 | All 15 keyword-list facades are rebuilt and re-sorted on every Lex call, and StartAt is a linear scan where upstream uses a 256-entry table |
| G330 | No check exercises the TextTank-authored lexer deltas: multi-part keywords, incremental lexing, nesting keys, folding, live keyword updates, multiple lexers |
| G332 | `_itoa` replacement hard-codes a 3-byte bound that is wrong for the +20 call sites and ignores its radix argument |
| G333 | Swift re-implementation of upstream keyword quoting diverges from ScintillaEditView::setUserLexer |
| G334 | Wrapper keeps dead upstream scaffolding and misleading descriptions around the UDL lexer |
| G335 | Cloning a view resets the document's tab width and tabs/spaces choice to the global setting |
| G336 | "All open documents" search always targets the primary view, so it misbehaves when the clone has focus |
| G337 | A macro recording started in the clone is not invalidated by reload, revert or close |
| G338 | A TTEditor instance is used as the document's identity, so results captured from the clone die on Close Split View |
| G339 | Clone does not copy the source view's state, and re-applies the language to the shared document |
| G340 | Read-only is copied between views in three places although it is a document property |
| G341 | clone(_:) is one 700-character statement chain that duplicates the primary's wiring; closeSplit acts when there is no split |
| G342 | Split-view checks cover shared bytes and undo only; focus tracking, per-view state and every consumer are unpinned |
| G343 | Extended-mode \uXXXX escapes can inject lone surrogates: matches are deleted in the editor and U+FFFD is written to files by folder replace |
| G344 | Find-in-Folder filename globs compare raw UTF-16 units: NFD file names never match NFC patterns and `?` does not match one character |
| G345 | Automation line rules use Swift canonical-equivalence and grapheme semantics while the editor commands and search are byte-exact, so the same operation gives different results in different menus |
| G346 | Positions and lengths are reported in three different units (UTF-16, Unicode scalars, graphemes) across status bar, search results and sort |
| G347 | Line sorting is raw Unicode-scalar order in both the editor and automations: capitals before lowercase, accented letters after 'z', no numeric or locale option |
| G348 | Invert Case and Title Case use full case mappings per grapheme, so they change text length and are not reversible |
| G349 | Whole-word test classifies by single UTF-16 unit, so astral letters and digits count as word boundaries |
| G350 | Comment commands mix normalising/grapheme-aware string matching with byte arithmetic, which can cut a UTF-8 sequence or miss a delimiter |
| G351 | Uniform-line-ending detection for sort/dedupe/blank-line automations uses grapheme-based contains, so some mixed-ending inputs slip through and are reordered |
| G352 | Files whose name begins with a combining mark are reported unreadable/unsafe because path scoping uses grapheme-aware hasPrefix and dropFirst |
| G353 | The app can save a UTF-16 file that it then refuses to open, or reopens as NUL-filled UTF-8 |
| G354 | Unicode edge cases are tested in codecs and offsets but not in case commands, sort, glob filters, whole-word, extended escapes or automation matching |
| G355 | Every persisted struct uses strict synthesized Codable, so adding any non-optional field makes all existing user files undecodable |
| G356 | `version` fields are decorative: never bumped, no migration path, and an older build silently strips newer fields while leaving version 1 |
| G358 | Several stores can write a value they will refuse to read back (limits and file-type rules differ between save and load) |
| G360 | Application Support location is derived independently in seven places, and two stores bypass it via UserDefaults |
| G361 | Find and Find-in-Folder preferences live in UserDefaults with no schema, opposite failure policies, and are rewritten on every search action |
| G362 | Settings shortcut schema is coupled to hand-maintained tables, so a later menu change invalidates existing Settings.json wholesale |
| G363 | Session and recovery formats carry write-only fields, unreachable checks and inconsistent representations of the same concepts |
| G364 | First-run automation presets are keyed on file absence, are re-offered by the JSON editor after deletion, and can never be refreshed |
| G365 | Language catalog 'migration' is an in-memory backfill on every launch, and the user store carries required upstream provenance fields that become false after the first edit |
| G366 | Recorded Find-window search steps never stop a macro on no-match, so later steps edit the wrong text (repeat / until-end keeps going) |
| G367 | Ordinary Mac editing keys (Home, Cmd-Left, Page Up/Down, Escape, Option/Cmd-Backspace) silently discard the whole macro recording |
| G368 | Whole-buffer setText is used for reload, document-input automations and no-selection line transforms, wiping every bookmark, fold state and the caret position |
| G369 | Read-only is enforced differently on every mutating path: some check up front, some after long dialogs with a misleading message, some rely on Scintilla dropping the edit and still report or record success |
| G370 | Folder replace snapshots the open-document exclusion set once, while its result list stays live and opens files during the run |
| G371 | Completion acceptance and Overtype typing are recorded as different operations than the ones performed, so playback silently diverges |
| G372 | Find-window search steps are recorded when the async search finishes, regardless of whether navigation happened and after anything typed meanwhile |
| G373 | Reload/Revert re-runs language detection and overrides the user's manual language; UDL import switches the current document's language |
| G374 | Undo restores text but never the selection or scroll position for any grouped command; Scintilla's selection-history undo is available but not enabled |
| G375 | Rule-set and automation pickers index by popup position, but addItem(withTitle:) drops duplicate titles |
| G376 | The shipped first-run "Clean up text" default is recipe-specific and rejects two of the user's own four samples |
| G377 | RecipeRulePreset compiles one user's sample data into the app as a generically named template |
| G378 | removeMarkdownFormatting strips spaces before commas only on lines where Markdown was found |
| G379 | The rule editor's list, preview and accept logic has no test and is not testable as written |
| G380 | Recipe checks are tautological or adjust their own expectations |
| G381 | Advanced JSON help omits four step kinds, and validation messages are stale and use raw identifiers |
| G382 | "Test passed" does not predict a real run: the preview gives each regex step its own 0.1 s budget |
| G383 | Test Rules validates a stale draft name instead of the name field |
| G384 | Create Automation persists straight from "Use These Rules" with no settings step, contrary to the docs |
| G385 | The editor's opening instruction is overwritten before the window is shown |
| G386 | Rule rows hide the replacement and prompt flags; label and default guidance misdescribe some kinds |
| G387 | Find-accepting kinds are listed twice, and the rule dialog writes `false` where presets use `nil` |
| G388 | Load Rules import re-encodes the file and does not recognise a library export |
| G389 | AUTOMATION-RULES.md and the fixtures README are part session log and out of date |
| G390 | Behaviour is selected by comparing or round-tripping English display strings |
| G391 | Search, folder-search and Function List results can only be opened with a mouse double-click |
| G392 | Most input controls have no accessibility label: placeholder-only fields, unlabelled popups, and alert accessory fields with detached captions |
| G394 | Counts are interpolated into fixed plural nouns, producing '1 matches', '1 Bookmarks', '1 files' throughout |
| G396 | Settings dialog can assign a shortcut but cannot show existing shortcuts or remove one |
| G397 | One 'selection required' error is shown for read-only, stale, multi-selection and no-editor conditions |
| G398 | The same concept is worded differently across menus, dialogs and status text |
| G399 | Numbers and sizes are formatted and parsed with interpolation, String(format:) and Int()/Double() instead of formatters |
| G400 | Auxiliary windows have no default or cancel key, inconsistent initial focus, and one hand-framed window has no explicit key-view loop |
| G401 | Status bar badges and the window status label expose terse values with no description |
| G402 | About panel hard-codes a version string that already disagrees with Info.plist |
| G403 | Info.plist claims Editor for every file on the system and omits type declarations and standard bundle keys |
| G404 | Checks locate controls and assert outcomes through English UI strings, so any wording or localization change breaks tests instead of behaviour |
| G407 | "Clear Additional Selections" discards the main selection and jumps the caret to the start of the document |
| G408 | "Stream Selection" and "Rectangular Selection" menu items toggle Scintilla's sticky move-extends mode instead of choosing a selection type |
| G409 | F02 repair is incomplete: automation runs on inputs up to 256 KiB still execute synchronously on the main thread with no cancellation |
| G416 | REVIEW-ME, README, AUTOMATION-RULES, in-app help and utility-audit make behavioural claims the code does not honour |
| G418 | User-visible features that no document mentions, two of them reachable only from unexpected places |
