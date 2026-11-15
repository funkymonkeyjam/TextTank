# Architecture

Scintilla owns authoritative UTF-8 bytes and undo. TTEditor bridges Cocoa through Objective-C++; Swift never keeps a second mutable buffer. NSDocument owns file identity, encoding metadata, safe save coordination and window lifecycle. Clones share the Scintilla document, not independent string snapshots. Main-thread editor access only. Capture revision for transforms; reject stale output. No side effects on open/import/restore.

Pinned clean engines precede explicit audit/port of Notepad++ UDL and Boost regex deltas. Native app target in TextTank.xcodeproj; scripts build exact dependencies before xcodebuild.

## Search semantics

`TTSearchEngine` searches immutable text snapshots and reports UTF-16 ranges. Regular expressions run over Unicode code points, not UTF-16 units, so `.`, classes and quantifiers take a whole astral character and a match never splits a surrogate pair; this departs on purpose from the Windows reference, which walks UTF-16 units. The regex carries its own UTF-8 locale (the process locale is never changed), so case folding, `\w`, `\b` and `\s` follow Unicode as literal mode and Whole word do; `\d` and `[[:digit:]]` stay `0-9`. Replacement output that would contain half a surrogate pair is refused.

Selection scope searches a range of the whole document rather than an extracted substring. Whole word, `^`, `\b`, `\A` and lookbehind see the text before the range, and `$` matches at the range end only where a line really ends. Known limit: Boost cannot read past the range end, so lookahead, `\b` and `\z` there are relative to the range, and a match is cut off at the range end. Whole word in regex mode filters finished matches and does not retry a rejected one. A regex search decodes the document up to the end of the range, so its memory follows the document, not the selection.

## Find and Replace window

`SearchController` searches text snapshots off the main thread and applies results only after re-checking them. The editor's `revision` is the staleness authority: every insert and delete moves it, in every view of a shared document (bridge-checks proves each path), so the controller compares revisions and does not re-copy and compare the whole text. A split clone takes its revision from the primary when it is created and before it can be searched; a new way of changing text must move the revision too.

- Results hold each searched editor weakly, keep one text snapshot per document with rows that refer to it by index, and are dropped when the Find window closes. Find Next from the menu with the window closed holds results again until the next search.
- Next and Previous reuse the held results while the editors, their revisions, the options and the scope are unchanged; anything else searches again.
- Selection scope: the first Next or Previous takes the selection as the scope and later presses keep that scope, until an edit or a manual selection change. Every other action reads the live selection.
- All open documents: Next and Previous first look in the document they are in, then move through the other documents in open order (the order of `openEditors`), wrapping across documents when Wrap is on. The document last navigated to stays the starting point while its selection is still that match, because the application's current editor can lag behind a cross-document move.
- Replace edits only the document it was pressed in. In the current document, Replace with no match selected selects the next one (recorded as `next`), and a successful Replace then selects the following match (recorded as `replaceOne` then `next`). Macro playback of `replaceOne` stays strict: it replaces a selected match and never moves, so saved macros play as before. A habit of Replace, Next, Replace now skips a match.
- Replace and Replace All apply one `replaceRanges:withTexts:expectedRevision:` call per document: all ranges are validated before the first edit, the edit is one undo action, and the caret ends just after the first replacement. `ReplaceOutcome` says why a document was skipped (read-only, multiple selections, closed or changed).
- Find Next and Find Previous call `onFailureSignal` (the system alert sound) whenever they select nothing, since both work from the menu while the window and its status line are closed.

## Persisted formats

Every file and defaults value the app writes is a versioned Codable value type: editor settings, Find options, Find-in-Folder settings, the workspace browser state, the Run library, session snapshots, recovery snapshots, the Reminders journal, the macro library, the language catalog and the automation library. Their decoders are the synthesized ones, so every non-optional property is a required key, including properties that have a default value.

A field added to a version-1 type must therefore be one of two things. Either it is Optional, as the later fields of `AutomationDefinition` and `RecordedMacro.Step` are, or it is decoded with `decodeIfPresent(...) ?? default` in an `init(from:)` written in an extension for that field only. An `init(from:)` in the struct body removes the memberwise and default initializers that the sources and checks use. Never default a missing `version` or `schemaVersion`, a document's text, format, selection, dirty flag or revision, or a Run item's `shellMode` or `extensionMode`: those stay required. A change in what an existing field means needs a new `version` or `schemaVersion` and an explicit migration.

`Tests/Fixtures/persistence/` holds one file per format as written by the build of 15 November 2026. The "persisted format golden fixtures" section of document-checks decodes each one through the production reader and compares every value, so a field added without a decoder for old files fails acceptance. Do not rewrite those files to make a check pass; add a new fixture beside them when a format gains a version.

## Source layout

First-party Swift under `Sources/` and `Tests/` is laid out by the `swift-format` that ships with the toolchain, using the committed `.swift-format`. That configuration enables layout only (line breaks, indentation, spacing, 120 columns, one statement per line); every rule that rewrites tokens is off, so formatting never changes what the code says. `Sources/Search/Boost` and `Vendor` are never formatted, and neither are the Objective-C++ bridge files, the Python scripts or the shell scripts.

- `scripts/swift-format.sh format` rewrites the files; run it before committing Swift changes. `scripts/swift-format.sh lint` reports any difference and exits non-zero.
- CI runs the lint as an advisory step. `swift-format` output differs between versions (the sources were formatted with 6.4.4), so the step must not block until the CI image's Xcode is pinned to the same version.
- `scripts/check-layout-only.py <before> <after>` proves that a formatting commit changed layout only: for every changed Swift file the code tokens, string literals and comments are unchanged and in the same order, and the compiler's parse tree is the same. Its self-test runs in acceptance as `layout-proof-selftest`. Use it whenever the formatter version or configuration changes and the tree is reformatted.
- A line the formatter cannot break, such as a long string literal, stays long; the lint does not report it.
- A commit that only reformats is listed in `.git-blame-ignore-revs`; `git config blame.ignoreRevsFile .git-blame-ignore-revs` makes blame skip it.
