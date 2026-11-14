# Independent folder replacement review

Reviewer: reference/utilities/workspace worker. Folder replacement and search controller were authored by the search worker; this review is independent of their implementation.

## Finding repaired

**P2 — closing the search window discarded committed-file outcomes.** The original completion callback gated all results on the active window/query generation. Closing canceled work and changed that generation, so already-committed file replacements could lose their visible changed-file and recovery-copy report. The repair retains replacement outcomes before the generation gate and exposes a Replacement Report action. Each changed file also receives a private JSON sidecar, synchronized before rename, containing original/replacement hashes and the backup filename. A prepared journal explicitly does not prove whether rename committed. After rename, the state is atomically changed to replaced; a failed completion-journal write retains uncertain recovery evidence and reports it.

## Independent observed checks

- `SearchReplacementChecks`: **13 assertions passed**, rerun by this reviewer against current source. Includes two-file replacement, UTF-16/BOM/Unicode/CRLF preservation, byte-exact backup, permission and extended-attribute preservation, open-document exclusion, stale fingerprint conflicts, injected external write before commit, partial independent success, cancellation, symlink rejection and a real committed JSON journal.
- `FolderSearchControllerChecks`: **12 assertions passed**, independently compiled with the complete native app. Includes native result revalidation/dirty buffer preservation and report retention after closing the controller. That report test injects a completed outcome after close; it is not a scheduler-level simulation of every close/rename ordering.
- Logs are ignored: `harness/logs/reference-replacement-checks.log`, `harness/logs/reference-folder-controller-checks.log`.

## Source review

Parent/leaf traversal uses directory descriptors and O_NOFOLLOW; leaf opens are nonblocking and require a single-link regular file owned by the current user. Source bytes must match the completed search fingerprint. The replacement is encoded with the original file format. Prepared output gets source metadata through fcopyfile. The original byte backup and report are private and synchronized before the final source check. The final check compares inode/device, size/timestamps/link count, mode/ownership/flags and bytes before same-directory rename. Per-file outcomes are honest about independent successes and failures; this is **not an atomic multi-file transaction**.

No additional concrete blocking issue was found in this bounded review. There remains a documented noncooperating-writer race between final comparison and rename. Metadata fault injection, process termination at every write boundary, report restoration UX, newly opened documents during an active replacement, large-file cancellation bounds and physical UI walkthrough remain incomplete. A prepared journal must be reconciled by hashes, never blindly replayed as a committed result.

Reviewed hashes:

- `Sources/Search/FolderReplacement.swift`: `f1940347b8761498320cebde1735655ae7d95c68dd23b89361d153aea3566429`
- `Sources/Search/FolderSearchController.swift`: `b9d0aa951db455c331b45e214bb93b73b5ad69432aa7d47c4720fb239af44700`
