# Independent folder-search review — 2026-11-14

Scope: bounded read-only review of the new literal folder-search core. This is not full reference search parity, Boost regex, replacement, result-navigation or native UI certification.

## Findings and disposition

1. **P2 repaired: platform directory aliases rejected valid descendants.** A real temporary directory rooted under `/var/folders` remained there after Foundation resolvingSymlinksInPath, while its enumerator returned `/private/var/folders` URLs. Prefix validation skipped every regular file as outside scope. Reviewer reproduced filesSearched0. The author now derives the canonical root path using F_GETPATH on the opened directory descriptor. Reviewer reran a temporary-directory probe after repair: filesSearched1, matches1, skipped0.
2. **Completion semantics clarified.** Initial isComplete treated intentional hidden/extension/nonrecursive exclusions as incomplete. The author now distinguishes policy exclusions from unreadable/invalid/oversized inputs and actual cancellation/limits. Source inspected.
3. **Cancellation latency limitation, not immediate cancellation.** Detached execution keeps the caller off the search worker. At default32MiB maximum file size, reviewer requested cancellation50ms after start. UTF8 emoji fixture returned about1.87–1.92seconds later; UTF16LE ASCII fixture about1.05seconds later. Both returned wasCancelledtrue with filesSearched0, consistent with noninterruptible FileCodec decode. These were unoptimized local probe builds, not cross-device performance guarantees. The author added token checks every4096 scalars to position conversion. Foundation decoding/literal range calls remain coarse cancellation boundaries; document this and avoid claims of instantaneous cancellation.

## Safety/correctness inspected

- Root and each relative directory component use descriptor-based O_NOFOLLOW scope traversal. Final regular-file reads use O_NONBLOCK before fstat, avoiding FIFO-open hangs; symlink entries are skipped.
- File/entry/result/byte limits are explicit; actual read chunks count toward the total even when a later decode/read check fails. Size/mtime checks identify ordinary in-read modifications. This is not an immutable filesystem snapshot.
- Matches carry decoded UTF8 byte offsets and UTF16 ranges; the scalar cursor preserves non-BMP boundaries and CRLF line counting. Preview edges avoid splitting UTF16 surrogate pairs, but are not grapheme-cluster-aware.
- Case-insensitive literal search is explicitly Foundation behavior, not Notepad++/Boost semantics. Decoder does not silently guess legacy encodings.
- Result navigation must still verify current document contents before applying stored offsets: files can change after search. This review does not certify a future navigation controller.

## Reviewed tracked source hashes

- `Sources/Search/FolderSearch.swift`: `2e6f4c05ff7e1ca69315a9a39c8302ee060a58dacc8d2ebb0eedc18d9a5d7015`
- `Tests/FolderSearchChecks.swift`: `a0f983c3614051bc8304b04fd8c3dc9668faf8b7124359307aba7ed76184f50b`

## Bounded native controller review

Read `FolderSearchController.swift` and its native tests after integration. No additional concrete blocking defect found in the reviewed code paths.

- Search work awaits the detached core without retaining the controller across that await. Worker progress is coalesced and dispatched to MainActor; progress and completion both gate on generation. Closing invalidates generation and cancels both the token and wrapper task, so an obsolete completion cannot repopulate the closed controller. A newer valid search similarly invalidates older work.
- Cancellation preserves partial results and labels cancellation/limit truncation. Decode cancellation remains coarse as measured above; the UI does not promise immediate completion.
- Result navigation uses the query/case settings of the completed search, validates stored UTF8 and UTF16 positions against the current buffer, and selects only a current literal match. Validation failure leaves selection unchanged. It never replaces text or reverts a dirty document. Validation confirms the current substring/offset, not an immutable identity of the originally searched file.
- The native tests cover Unicode selection, case-insensitive matching, changed/short buffers, exact selected text and preserved dirty revision/content, unchanged stale selection, and basic controller construction. They do not simulate overlapping asynchronous searches, progress-after-close races, cancellation status timing or an external file mutation between click and open. Those race properties were source-reviewed only.
- Integrator reports native CUA search returned5 matches across5 files with1 filtered entry, and double-click selected the exact panko text. This reviewer did not independently operate that UI flow.

Controller review hashes:
- `Sources/Search/FolderSearchController.swift`: `f487bed9289cccb9bfeefe98c09cd4ff999ae8000c616ad0b11e2fb78585d43e`
- `Tests/FolderSearchControllerChecks.swift`: `5df55ecb106a73e02400dcf8b9fd55464eb1e33560a5c71c3a9660af55a5b615`
