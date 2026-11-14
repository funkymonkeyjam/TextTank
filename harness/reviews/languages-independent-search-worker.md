# Scoped independent LexUser and workspace review

Reviewer: search worker; not author of these features.

## LexUser/UDL source inspection

Read UserDefinedLanguage.swift, LanguageCore.swift and port-specific portions of LexUser.cxx. The 15 owned lists match the mapper ordering: Operators2, six folder groups, eight keyword groups. Temporary facade pointers refer to WordList storage owned for the Lex call. Cache identities are private per lexer and removed in Release; pointer-to-int Windows document identities are not reused. Property overrides prevent imported data from choosing private cache IDs. Global cache access depends on the application's main-thread-only editor contract.

UDL import rejects DTD/entity declarations, disables external entity resolution, bounds input/depth/count, and validates supported keyword/style names and generated profiles. No concrete blocking memory defect was found in the inspected additions. This is not an exhaustive review of the inherited 2,400-line lexer or malformed-input fuzzing. Imported extra attributes and some unrecognized boolean spellings remain permissive; background/font/nesting/style semantics and all keyword corner cases require broader differential coverage. Author native styled-fixture results are separate from this source inspection.

## Workspace browser inspection

Read WorkspaceBrowserCore/Controller and associated tests. Directory enumeration uses an owned descriptor, skips symbolic links/special files and reports bounded listings. Open reads once through the regular-file helper and preserves existing dirty NSDocument instances. Stored paths remain inert on loading.

P2 repaired by author: corrupt/unsupported saved workspace data initially set loadError but noteRecent/add/remove could overwrite it with empty defaults. Save now refuses mutations while loadError exists. Re-read the guard after repair; author added corrupt-state preservation tests. No broad monitoring, path-alias or full workspace parity claim follows from this scoped review.

## Subsequent scoped comments/styles and monitoring review

Read CommentCommands.swift: UTF-8 boundaries and overlapping edits are rejected before mutation, line selections exclude an end positioned at the next line start, CRLF is retained, and block wrapping rejects embedded closing markers. Native application validates editor/revision/selection and groups Undo. No concrete new defect was identified in this inspection; author-owned native tests cover actual editing.

P2 style settings repaired: separate font/size fields initially read the shared AppKit field editor via each control, the same class of bug observed in search. Production readStyle now commits editing before reading distinct stringValue values; author reports a real focused-size field regression with distinct preserved font name. Re-read repaired helper and its invocation.

Read DocumentMonitor.swift: background byte-bounded snapshots do not access the editor; generation, document identity, URL, revision, baseline fingerprint and attachment gates reject stale results. Reload is explicit and refuses dirty/stale/closed documents. No concrete blocking finding in the reviewed source. The 32 MiB byte cap does not establish an I/O time deadline; a pending read briefly retains its document until completion. The timer callback is weak and no persistent cycle was found.
