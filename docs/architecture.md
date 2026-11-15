# Architecture

Scintilla owns authoritative UTF-8 bytes and undo. TTEditor bridges Cocoa through Objective-C++; Swift never keeps a second mutable buffer. NSDocument owns file identity, encoding metadata, safe save coordination and window lifecycle. Clones share the Scintilla document, not independent string snapshots. Main-thread editor access only. Capture revision for transforms; reject stale output. No side effects on open/import/restore.

Pinned clean engines precede explicit audit/port of Notepad++ UDL and Boost regex deltas. Native app target in TextTank.xcodeproj; scripts build exact dependencies before xcodebuild.

## Persisted formats

Every file and defaults value the app writes is a versioned Codable value type: editor settings, Find options, Find-in-Folder settings, the workspace browser state, the Run library, session snapshots, recovery snapshots, the Reminders journal, the macro library, the language catalog and the automation library. Their decoders are the synthesized ones, so every non-optional property is a required key, including properties that have a default value.

A field added to a version-1 type must therefore be one of two things. Either it is Optional, as the later fields of `AutomationDefinition` and `RecordedMacro.Step` are, or it is decoded with `decodeIfPresent(...) ?? default` in an `init(from:)` written in an extension for that field only. An `init(from:)` in the struct body removes the memberwise and default initializers that the sources and checks use. Never default a missing `version` or `schemaVersion`, a document's text, format, selection, dirty flag or revision, or a Run item's `shellMode` or `extensionMode`: those stay required. A change in what an existing field means needs a new `version` or `schemaVersion` and an explicit migration.

`Tests/Fixtures/persistence/` holds one file per format as written by the build of 15 November 2026. The "persisted format golden fixtures" section of document-checks decodes each one through the production reader and compares every value, so a field added without a decoder for old files fails acceptance. Do not rewrite those files to make a check pass; add a new fixture beside them when a format gains a version.

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
