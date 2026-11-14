# Independent folder filter and workspace-scope review

Reviewer: reference/workspace worker; author of WorkspaceBrowser, independent of FolderSearchFilters, searchAcross and FolderSearchController.

## Finding and reproduction

**P2: overlapping recursive roots can omit explicitly selected files.** The initial scope code discarded a child root whenever a parent root was recursive. That implication fails with root-relative folder exclusions and hidden-folder policy. With roots `parent` and `parent/tests`, `!\tests` excludes the child during parent traversal, but the explicit child should still search its own contents. Initial code discarded the child and returned an apparently complete report. The same issue affects an explicitly chosen hidden child while hidden entries are excluded in parent traversal. An independent scratch extension of SearchScopeChecks reproduced the exclusion case with an assertion failure (exit 133). Repair and final disposition are recorded below when tested.

## Source review

- Parser bounds input, token count and token length, rejects NUL/path separators/unterminated quotes, and treats exclusion-only input as implicit `*.*` inclusion.
- Pinned reference `Common.cpp::matchInList`, `matchInExcludeDirList`, and `FindReplaceDlg::getAndValidatePatterns` confirm the inclusion/exclusion categories and first-level versus recursive folder exclusions. Native quoted-token support is an extension. The native lowercase UTF-16 wildcard algorithm is not a certified reproduction of all Windows PathMatchSpec Unicode behavior.
- Search snapshots saved workspace roots when the action starts. Per-match canonical `sourceRoot` supports replacement grouping under each validated root. Global entry/file/byte/result budgets are reduced across roots; cancellation is cooperative. Failed roots are visible and make report completeness false.
- Settings load is inert, versioned and bounded. Invalid stored bytes are preserved; controller suppresses persistence while the initial settings error exists. Search may still be used with controls in that state.
- Saved folder roots are not three Notepad++ project panels or explicit project-file membership. Physical UI, accessibility, wildcard differential corpora and filesystem-race coverage remain separate requirements. This review does not certify complete capability parity.

## Repair and final disposition

The search worker removed parent-child scope collapsing. Every explicit root retains its own root-relative traversal policy. Successfully searched canonical file paths are unioned across roots and excluded from later reads/results, while traversal, file, byte and result budgets remain global. Independent recompilation and execution of the repaired **23-assertion SearchScopeChecks passed** (exit 0), including explicit excluded child, root-relative policy union with no duplicate reads, explicit hidden child, shared result cap, unavailable root reporting and settings roundtrip/corrupt preservation. Log: `harness/logs/reference-search-scope-checks.log`. The initial defect is repaired; no remaining concrete blocking introduced defect was found in this bounded review. The author's native controller suite is separately reported as 16 passes; this review independently reran the pure scope suite, not physical GUI interaction.

SHA-256 identities at completed review:

- `Sources/Search/FolderSearchFilters.swift`: `58fd7dde2db9af7225a67fe9b16da4d49d5c96a20f1ec80e8ecc785e2dcfe101`
- `Sources/Search/FolderSearch.swift`: `35e27591688ccdffa555bd8b9b0e7cff7fb48d5b2edd17c2d65ca5c16e7b4303`
- `Sources/Search/FolderSearchController.swift`: `1ed271e646d8602a5f0ac0dbac8f768d98847d616253825209330a6179e354eb`
- `Tests/SearchScopeChecks.swift`: `5f8d63f8e5cad70ea403465f264aebae8215caaea442b3dc08f5ba2e8711582c`
