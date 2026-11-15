# Automation and connector audit repairs

Scope: F02/F05/F13 at baseline bcee103. Worker owns automation/connector production and their checks; TTAlert extraction and shared build scripts belong to integrator. No live EventKit access or personal document changes.

## Changes

- Production transforms accept at most 32 MiB input/intermediate/output. Literal replacement builds checked segments, rejects before appending a segment beyond the ceiling, and observes cancellation during matching/appending. This applies to actual execution, not just sample previews. Native failure leaves original editor bytes, revision, savepoint and Undo untouched.
- Independent search reviewer found quadratic rescanning of nested malformed Markdown brackets. Invalid/nonlink groups now remain intact and the scanner skips the whole inspected group; unmatched remainders remain literal. Scanner cancellation uses a monotonically advancing threshold at most 4096 scanned positions apart, including escaped pairs that skip exact multiples. This deliberately preserves an inner apparent link inside an invalid outer group rather than interpreting it independently.
- Reminder journals enforce the same 32 MiB ceiling on writes and reads. Aggregate encoded row sizes are bounded before encoding the complete batch. Every persistence validates bytes before touching the destination; failed transitions retain the previous journal (including the uncertainty barrier preceding an external write).
- Automation startup/import uses bounded, nonfollowing, nonblocking regular-file reads. Startup lstat recognizes dangling symlinks as existing invalid evidence rather than seeding over them. Library encode/decode share a 32 MiB limit; rejected existing configurations remain on disk and loadError prevents replacement.

## Observed checks

- AutomationChecks: 132 passing assertions. New checks cover production expansion/input limits, Unicode replacement, cancellation, oversized decode, 20,000 nested malformed/balanced nonlink brackets, odd-offset escaped malformed text, and cancellation during an active transformation.
- ReminderChecks: 47 passing assertions with injected stores only. A valid-per-row 33 MiB aggregate batch rejects before any external save or JSON journal; a following ordinary export succeeds.
- AutomationControllerChecks: 70 passing native assertions. New checks exercise a saved 7 MiB replacement applied to five input characters, proving unchanged native document state on size rejection; FIFO startup rejects promptly; symlink target remains untouched; oversized configuration is preserved. Existing recipe same-editor/one-Undo and modal keyboard checks remain passing.

Commands: direct swiftc core invocations corresponding to scripts/test.sh; scripts/test-automation-ui.sh. Native evidence is in harness/logs/automation-controller-checks.log; temporary core outputs were captured during the session. Full integrated suite is the integrator's responsibility after source freeze.

## Independent Run repair review

F04 now encodes/decodes through one 1 MiB ceiling, checks raw aggregate parameters before encoding and actual bytes after escaping, and prepares bytes before persistence. Existing configuration/menu remain untouched on failure. No new blocking defect found in the reviewed diff. No configured process executed during review.

## Limits

The 32 MiB limits are intentional supported-operation limits, not full standard Notepad++ parity. Cancellation checkpoints do not establish a hard real-time bound inside each Foundation regex/sort primitive. Power-loss directory durability and adversarial ancestor-directory substitution remain unverified. User-confirmed Reminders happy-path evidence is preserved separately; these checks do not certify live permission revocation or account failure behavior.
