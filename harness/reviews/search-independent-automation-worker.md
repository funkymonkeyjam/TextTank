# Independent search and disk replacement review

Reviewer: automation worker, who did not author the search implementation. This is a bounded review of this implementation wave, not full Notepad++ search parity certification.

## Findings repaired

- P1: Boost replacement captures could split a surrogate pair even when the full match covered the whole character. Independent compiled probe on `🥑`, pattern `(.).`, replacement `$1` returned `�` and would lose original scalar content. Search worker added validation of expanded UTF-16 and a regression. Independent rerun observes `replacement capture splitting surrogate rejected` passing.
- P2: native replacement lacked read-only and detached-window guards; read-only actions could be reported as success despite no edit, and retained closed editors could be mutated. Search worker added guards and native regressions. Independent rerun passed both preservation checks.

## Observed verification

Independently executed `scripts/test-search.sh`: 28 core and 16 native assertions. These include malformed patterns, active/pre-cancellation, pathological regex, capture expansion, extended escapes, surrogate boundaries, zero-width navigation/replacement, stale/read-only/detached editors, one Undo, and native shared-field-editor dispatch.

Independently executed `scripts/test-folder-search.sh`: 42 core and 12 native assertions. Independently compiled current `FolderReplacement.swift` with `SearchReplacementChecks.swift`: 13 assertions passed, including two independent outcomes, UTF-16 BOM/CRLF exactness, byte-exact backup, durable report, mode/xattr retention, open-file exclusion, old fingerprint rejection, injected external modification preservation, cancellation, and symlink rejection. Only synthetic temporary files were mutated.

## Disk mutation inspection

Reviewed descriptor traversal, nonblocking regular-file reads, snapshot fingerprinting, per-file backup, durable prepared report, metadata copying, immediate identity/content recheck and rename. No additional concrete blocking defect found in this bounded inspection. The implementation explicitly does not claim an atomic multi-file transaction. A noncooperating external writer can race the final comparison/rename interval; locks/coordinated-file behavior against every external application and power-failure recovery remain unverified. Existing source must not be described as eliminating that race. Backup/report access requires explicit recovery handling; tests prove artifacts exist, not every user recovery journey.

Reviewed SHA-256:

- FolderReplacement.swift: `f1940347b8761498320cebde1735655ae7d95c68dd23b89361d153aea3566429`
- TTSearchEngine.mm: `143fa5a955f7279a42fe8e41f29b52a543e22f138078a1ef58ffeb93f7a2602b`
- SearchController.swift: `1752f035446e1ba654852d905a6790dc47b19a4d73db9c4bc0635e2752f9baae`
