# Independent session review — 2026-11-14

Scope: independent review of snapshot storage, restore lifecycle and application menu/document wiring; parent subsequently authorized the isolated FIFO repair.

## Finding repaired and verified

**P2: named-pipe referenced files hang the main thread.** `WorkspaceStore.readRegularFile` calls `openat` with `O_RDONLY | O_NOFOLLOW` before checking `fstat` for a regular file. Opening a FIFO with no writer blocks at that call. `openSession` invokes `inspectReferencedFiles` synchronously before its restore confirmation, so a valid session whose originalURL points to a FIFO makes the UI unresponsive. The same helper can hang when directly loading a FIFO.

Observed reproduction: compiled the current FileCodec + WorkspaceCore with a minimal readRegularFile caller; created a temporary FIFO via os.mkfifo; a bounded subprocess did not return within two seconds and was killed. No original files were changed. Suggested repair: add O_NONBLOCK when opening, then retain the existing regular-file fstat gate; add both direct FIFO loading and referenced FIFO inspection regressions. Parent notified.

## Other reviewed behavior

- Restore validates the whole decoded session before creating documents, restores into fresh unsaved document instances, and does not assign originalURL as fileURL. Original-file inspection is read-only.
- Session persistence uses private0600 temporary creation, synchronization and same-directory rename; invalid snapshots are validated before a destination replacement.
- Capture uses authoritative shared document text and active-pane selection; restore retains modified state for recovery and flushes recovery after text/metadata restoration.
- Menu wiring retains one WorkspaceController and targets its explicit save/open methods.

Limits: this review did not exercise native session panels, quit dialogs or recovery relaunch. Native integration tests are owned by root. Full workspace/tab/split-view persistence parity remains outside these snapshot APIs.

## Reviewed source SHA256

- `Sources/Workspace/WorkspaceCore.swift`: `0f776f8be248a384574de79c67f24c91bf416dc8d06d5df99b224a7cd34257fa`
- `Sources/Workspace/WorkspaceController.swift`: `98aafb55ee85f387cbd0d260e0b8a718744a084c0b54c404bd1f54668c2b0cd9`
- `Sources/TextTankApp/App.swift`: `995b41706bc8ff889cefc3f5ecd938854b5bcaf9358cd4be31fdc33bf45d7997`
- `Tests/WorkspaceChecks.swift`: `98a689ebccc72f1fbb5875f802ad6287d3b1bd4d78935ba9b075714e2fde0b49`

## Repair disposition

Added O_NONBLOCK to the file descriptor open while retaining O_NOFOLLOW and the regular-file fstat check. Added direct FIFO load rejection, referenced FIFO unreadable classification and a less-than-two-second bound. `scripts/test-workspace.sh` passed39 assertions after repair. These tests create only temporary FIFO and document fixtures. The source freezes below supersede the reviewed hashes above for the changed files.

Read current native DocumentChecks session assertions: they cover exact FEFF/NUL snapshot text, unsaved fileURL detachment, original byte preservation, reversed UTF8 selection, bookmarks, format/language, durable recovery, and capture text/selection. No additional concrete blocking UI defect found by source review. This is not a claim of manual panel/quit verification.

- `Sources/Workspace/WorkspaceCore.swift`: `7d1a60f01e78821c8d195bb1e4734b67b073c769351f567f2bf7c168b6bcb73c`
- `Tests/WorkspaceChecks.swift`: `238ce173f13c09d83ec4f1f71662cd2e351687964440af9d55d5edd766f94cde`
