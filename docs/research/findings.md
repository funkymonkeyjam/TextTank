# Retained findings and decisions

TextTank is an independent Mac-only, free and offline-capable general editor. Swift/AppKit owns native windows and document lifecycle; a narrow Objective-C++ bridge exposes Scintilla Cocoa and Lexilla. Scintilla owns authoritative text and undo. A temporary string used for I/O or a captured transform is not a second mutable document model.

The selected identity is Carbon Caret: original TT/negative-space caret, Space Grotesk 650 wordmark, Inter support, carbon `#15201F`, paper `#F4F6F0`, citrus `#C7F45B`. Light-mode action text uses `#3A5B00`; native controls retain system fonts. “Plain text. Sharp tools.” is the primary line. Selection of a name is not a claim of legal clearance.

## Evidence already gathered

* Official Notepad++ architecture was investigated from the frozen source. No Windows build or runtime comparison was performed.
* The separately installed notePad++++ 2.0.0 (37) was observed through UI, plist/Mach-O metadata, limited REA JavaScript analysis and ordinary static package inspection. UI entry points existed for search, layouts and other editor functions; full functional tests were not run. Static JavaScript called Monaco and a WebKit bridge. The larger semantic pass timed out. Native-side persistence and full behavior remain unknown. Its code and assets are not implementation sources.
* PadPlus was reviewed at commit `f477aa7f5c02092f94e6e3d59f4f72994ca90a44`. The user rejected it as a foundation; no code from that Mac implementation is adopted. Its report identifies regression hypotheses worth testing independently.
* Handoff architecture, validation, orchestration, parity and adversarial reviews are planning evidence. Acceptance of the handoff did not establish an application build, feature pass or runtime support.

## Regression risks carried forward

1. Dirty cloned views must be treated as one document when quitting. A per-view “other clone exists” shortcut can skip every save prompt. Test close-one, close-last, cancel, write failure and quit.
2. Session filenames do not recover unsaved or untitled content. Test forced crash and corrupt/partial snapshots without overwriting original files.
3. ANSI cannot silently mean UTF-8. Preserve actual code-page bytes, BOM and EOL; reject unrepresentable conversions without replacement.
4. Folder search must not silently use a different regex engine, omit zero-width matches, skip large files or change multiline semantics. Match the frozen Boost search contract, with explicit failures and cancellation.
5. Recorded macros must include Find/Replace parameters, not just text insertion. Configurable automations extend rather than replace macros.
6. Native AppKit hosting does not itself verify Scintilla IME, keyboard focus or accessibility. Exercise composed text, dead keys, UTF-16/UTF-8 mapping and VoiceOver.
7. A clean Lexilla build does not provide Notepad++'s GPL LexUser additions or Boost.Regex integration. Audit and port the required deltas separately.
8. Import/open/restore are data operations. Shell commands and executable extensions require explicit configuration and invocation; paths, names and document text never implicitly become code.

## Dependency candidate provenance

The prior architecture work downloaded official Scintilla 5.6.9 (`scintilla569.tgz`, SHA-256 `1622546ce1d3804b589292f1adae98ad1d87fa8c43bb401edc098adae12dcacb`) and Lexilla 5.5.5 (`lexilla555.tgz`, SHA-256 `fa4093ad5c48acf49a6f3eca1b75143a5c824ef1a6f5b0ee59e8c3d6a970f229`). Those records established downloaded bytes only. Accepted implementation pins and actual builds are recorded separately by the integration owner.

## Product completion rule

Full standard capability parity remains required. No missing behavior is waived by this digest, no alias/range count is a feature denominator, and no helper test or screenshot proves integrated behavior. Windows DLL binary compatibility is not claimed; required extension functions need documented, tested Mac equivalents. Real Reminders testing remains subject to explicit consent and a designated writable scratch list; fake outcomes never imply live EventKit export.
