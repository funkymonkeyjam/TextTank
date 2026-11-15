# Architecture

Scintilla owns authoritative UTF-8 bytes and undo. TTEditor bridges Cocoa through Objective-C++; Swift never keeps a second mutable buffer. NSDocument owns file identity, encoding metadata, safe save coordination and window lifecycle. Clones share the Scintilla document, not independent string snapshots: text, read-only, tab settings, line-ending mode, lexer and keyword lists, bookmarks, highlights, undo and the save point are document state, while wrap, zoom, selection, syntax styles, margins and whitespace visibility are per view (TTEditor.h lists both). A clone copies view state from the pane it was made from and never rewrites document state; a language or style change installs the lexer once and copies styles to the other pane. The current editor has one definition, `AppDelegate.currentEditor`: the main window when it is a document window, otherwise the document window focused last. Getters and editor providers are pure; focus is tracked where it changes, and a macro recording is invalidated where an unrecorded action is committed. Main-thread editor access only. Capture revision for transforms; reject stale output. No side effects on open/import/restore.

Pinned clean engines precede explicit audit/port of Notepad++ UDL and Boost regex deltas. Native app target in TextTank.xcodeproj; scripts build exact dependencies before xcodebuild.

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
