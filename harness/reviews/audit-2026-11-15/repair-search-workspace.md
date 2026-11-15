# F07/F08/F10 repair — search/workspace worker

2026-11-15. Changes confined to search core/controller, workspace session/browser controllers and their owned tests. No shared App.swift, bridge, build scripts, DocumentChecks or commits.

## Repairs

- Session restoration calls the application LanguageController profile mapper rather than passing the profile identifier directly to Lexilla. This restores mapped lexer, keyword lists, properties and styles, including the existing UDL profile path. Missing profiles explicitly fall back to Plain Text without changing restored content; a status notice identifies the fallback.
- Workspace/recent file opening assigns the new document URL before decode, so the existing load-time detector receives the filename. Read failure still occurs before adding the document to NSDocumentController.
- Bookmark Matches computes line indices in its detached task with one forward UTF-16 traversal. CR, LF and CRLF semantics match the previous algorithm; only unique line indices are retained. Up to 100,000 ordered offsets, a two-second budget and cancellation checked every 4,096 scanned units bound this phase. Main-thread completion only merges prepared lines into current bookmarks after attachment/revision/text and selection-scope guards. Truncation, cancellation and stale results preserve existing bookmarks.

## Observed verification

- `./scripts/test-search.sh`: exit 0; SearchChecks 34, native SearchControllerChecks 22, SearchReplacementChecks 13, SearchScopeChecks 23.
- New pure checks cover CRLF/CR/LF and astral offsets, empty results, pre-cancel, invalid ordering and 100,000 dense offsets within the budget.
- New native checks cover actual asynchronous bookmark action preserving save point and existing markers, immediate cancellation, and stale-content rejection.
- `./scripts/test-workspace-browser.sh`: exit 0; 40 assertions. New tests open an extension-only Python file, restore JavaScript and compare actual keyword styling to the mapped LanguageController output, preserve unsaved text, and fall back for an unknown language profile.
- Native processes emitted sandbox-extension/AppKit service diagnostics; assertions completed successfully. No user files were used.

A small final presentation-only ordering change places the missing-profile notice after synchronous recovery status updates; language and search behavior were already covered by the above runs. This repair does not claim full language/UDL differential parity, global all-document search memory budgets, or universal I/O cancellation.
