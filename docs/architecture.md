# Architecture

Scintilla owns authoritative UTF-8 bytes and undo. TTEditor bridges Cocoa through Objective-C++; Swift never keeps a second mutable buffer. NSDocument owns file identity, encoding metadata, safe save coordination and window lifecycle. Clones share the Scintilla document, not independent string snapshots. Main-thread editor access only. Capture revision for transforms; reject stale output. No side effects on open/import/restore.

Pinned clean engines precede explicit audit/port of Notepad++ UDL and Boost regex deltas. Native app target in TextTank.xcodeproj; scripts build exact dependencies before xcodebuild.

## Persisted formats

Every file and defaults value the app writes is a versioned Codable value type: editor settings, Find options, Find-in-Folder settings, the workspace browser state, the Run library, session snapshots, recovery snapshots, the Reminders journal, the macro library, the language catalog and the automation library. Their decoders are the synthesized ones, so every non-optional property is a required key, including properties that have a default value.

A field added to a version-1 type must therefore be one of two things. Either it is Optional, as the later fields of `AutomationDefinition` and `RecordedMacro.Step` are, or it is decoded with `decodeIfPresent(...) ?? default` in an `init(from:)` written in an extension for that field only. An `init(from:)` in the struct body removes the memberwise and default initializers that the sources and checks use. Never default a missing `version` or `schemaVersion`, a document's text, format, selection, dirty flag or revision, or a Run item's `shellMode` or `extensionMode`: those stay required. A change in what an existing field means needs a new `version` or `schemaVersion` and an explicit migration.

`Tests/Fixtures/persistence/` holds one file per format as written by the build of 15 November 2026. The "persisted format golden fixtures" section of document-checks decodes each one through the production reader and compares every value, so a field added without a decoder for old files fails acceptance. Do not rewrite those files to make a check pass; add a new fixture beside them when a format gains a version.
