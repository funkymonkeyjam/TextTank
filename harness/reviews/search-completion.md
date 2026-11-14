# Search implementation and scoped verification

This remains partial standard capability coverage. Search worker owns Sources/Search and associated tests; integration owns command/menu/build wiring. No Windows reference-runtime differential certificate is implied.

## Implemented

- Normal, extended and actual Boost 1.90 regex snapshot engine. Unmodified headers came from official Notepad++ commit `61246e5741fd7c59352f3feb5ccc7e33e4594d15`, with per-file hashes/license in `Sources/Search/Boost/PROVENANCE.json`. The reference build also defines BOOST_REGEX_STANDALONE. No PadPlus source was imported.
- ECMAScript search flags, dot-newline option, format_all replacement expansion, named/numbered capture fixtures, `\K`, lookbehind, zero-length progression, strict Unicode boundaries and extended numeric escapes. Regex uses UTF-16 units to match the Windows iterator representation; matches/replacements splitting surrogate pairs reject safely rather than replacing invalid Unicode.
- Checked iterator cancellation/deadline and result/output caps. Snapshot work runs off-main. Large literal Foundation calls/decoding and regex compilation have coarser boundaries; no universal instantaneous cancellation claim. A 10,000-level nested-pattern compile probe rejected promptly with Boost's nested-brace limit.
- Native current/selection/all-open scopes; count/results, next/previous/wrap, selected/all replacements, bookmarks and option persistence. Editor mutation uses validated linear UTF-16→UTF-8 mapping, revision/read-only/attachment guards and one Undo per document. Shared AppKit field editing is committed before reading separate query/replacement controls.
- Folder normal/extended/Boost search retains bounded descriptor-based traversal, Unicode positions, explicit skipped files, asynchronous result revalidation and unchanged dirty buffers on stale results.
- Explicit folder disk replacement: source-byte fingerprints, open-document exclusion, scoped O_NOFOLLOW descriptors, nonblocking regular-file reads, size/permission/single-link checks, per-file backups, metadata copying, final exact-byte/inode/metadata conflict check and atomic per-file rename. Each backup has a durable prepared/replaced JSON recovery report with original/replacement hashes. Closing the window cancels pending work but retains committed outcomes for Replacement Report. No cross-file atomicity is claimed. A noncooperating writer can still race the final compare/rename interval.
- Recorded search callback/playback contract includes all options and current-document actions; unsupported scope recording explicitly invalidates rather than silently truncating a macro.

## Observed regression results before integrator's final exact-candidate run

- SearchChecks: 28 assertions passed; subsequent deeply nested compilation regression added after a separate successful probe (final suite result owned by integrator).
- SearchControllerChecks: 16 native assertions passed, including actual focused replacement field/editor and NSApp action dispatch, exact two captures replaced, and one Undo.
- FolderSearchChecks: 42 assertions passed.
- FolderSearchControllerChecks: 12 native assertions passed, including retained replacement report after close.
- SearchReplacementChecks: 13 assertions passed (independently rerun by reference worker): UTF-16/BOM/CRLF, byte-exact backup, durable report, permissions/xattrs, open-document exclusion, stale snapshot, injected external modification, independent partial success, cancellation and symlink rejection.

An overlapping worker build temporarily caused Swift to reject a changed UserLexer.o input. The native focused-field regression was rerun successfully with isolated object copies; this was not an application-source compile defect.

## Independent findings repaired

Automation reviewer reproduced invalid surrogate replacement capture (`(.).` / `$1` on an emoji) and found missing read-only/detached guards. Both repaired and regression-tested. Reference reviewer found completion outcomes discarded on window-close generation changes; outcomes now retained and durable recovery journals written. Integrator observed the shared AppKit field-editor query/replacement bug through actual CUA; native focused-field regression now passes.

## Remaining required search coverage

Full frozen-reference differential fixtures and locale/word-boundary equivalence remain unverified. Folder filename globs/exclusions and project search scopes remain missing. Mark indicators and every reference mark/navigation/dialog semantic are not complete. Search history, every persisted folder option and complete keyboard routing need coverage. Native all-open/selection search actions have implementation but not comprehensive integrated UI tests. Detailed large-file performance budgets, every pathological regex shape, cross-file crash/recovery UI and concurrent noncooperating writer races remain open. Folder backups require user-directed recovery; no automatic restore command is implemented. The implementation must not be counted as full search parity.
