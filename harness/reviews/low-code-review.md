# Independent low-code automation review

Reviewer: automation worker. Production author: integrator. This reviewer edited only AutomationChecks.swift and this report in this work item. Review covers literal-rule core additions and the replacement native rule builder, not complete editor capability parity.

## Resolved finding

**P1 — sample preview expansion could exhaust memory.** The initial builder bounded sample input to64 KiB but called unrestricted `transform` synchronously. Repeated literal `a → aa` steps can expand a small sample exponentially; an input limit alone does not bound intermediate allocations. Integrator added pure `testSample`, a64 KiB input ceiling, conservative replacement preallocation checks,1 MiB intermediate ceiling, cancellation checkpoints and a between-step2-second budget. The UI now evaluates snapshots on a worker queue and publishes only when its generation still matches. Tests independently verify repeated and single-step expansion rejection before oversized allocation, ordinary expansion, input boundaries and cancellation.

## Observed validation

Compiled current AutomationCore.swift with AutomationChecks.swift at the macOS14 arm64 target and ran it: **113 assertions passed**. Added coverage includes:

- Three literal line-clearing kinds: exact case-sensitive text, regex punctuation treated as ordinary data, nonempty find validation, rejection of replacement fields, ask-at-run defaults/cancellation and unchanged stored defaults.
- Quantities, fractions, Unicode, duplicate ingredient rows, CRLF and mixed separators. Matching content becomes empty while separators remain; explicit Remove empty lines compacts output.
- Trimming preserves interior spaces, NUL and each original separator.
- New step kinds round-trip through the existing versioned library and retain workflow identity.
- Sample testing uses only supplied text even when the definition declares file input and Reminders output; it does not invoke either boundary.
-64 KiB boundary, oversized source/replacement, multiplicative growth, ordinary growth, pre-cancellation and cancellation between steps.

These are core tests, not observation of the physical native builder. No personal documents, clipboard contents or reminders were changed in this review.

## Native source inspection

- Builder edits a value-copy draft. Outer Cancel/close returns no definition; Use These Rules validates then returns the draft. Persistence remains with the existing outer automation settings Save action.
- Add/Edit use nested modal rule fields. Field-editor contents are committed before distinct find/replacement values are read. Unsupported fields are disabled and omitted when constructing a step; all returned steps pass core validation.
- Add/duplicate enforce100-step limits; edit/remove/move guard the selected index. Preview invalidates after every rule mutation and sample text edit.
- Testing captures the draft and sample text; it calls only the pure transform helper. The result view is read-only. Generation changes cancel the current control and prevent an obsolete completion from repopulating a changed or closed builder. Weak captures avoid keeping the builder alive solely for worker completion.
- Loading the recipe preset explicitly confirms draft replacement and preserves workflow input/output/name/UUID until the user saves.

No further concrete blocking defect found in these inspected paths. Nested modal focus, keyboard-only operation, physical layout and rapid overlapping preview interactions still require integrated native/UI observations. The timer is checked between transform steps; individual Foundation operations are not continuously interruptible, so this does not establish a hard2-second wall-clock guarantee. Conservative preallocation may reject a safe no-match/shrinking replacement at large intermediate sizes; this is a boundedness/usability tradeoff, not a claim of exact output-size prediction.

## Reviewed source identities

Initial reviewed low-code core SHA-256: `49f38b8ef326b506d88db9bd1bbc1be5b5e53839424c9f4981b039f221f3f90d`.
Native builder SHA-256: `11bab4d883be7865f0bf04a00d4af4d38942a945ac0a28e428e583f609a86bc1`.
These identities precede any subsequent recipe-specific production edits; those require their own fixture evidence.

## Integrator physical verification

Native rule table and side-by-side sample/result areas visually inspected. Selected literal heading rule showed friendly fields and disabled irrelevant replacement controls. Loaded recipe rules into existing Clean up text draft, tested full sample4 to expected13 rows, saved via Use These Rules then Save. Actual toolbar run produced exact visible expected rows in the same editor; Cmd-Z restored original. Existing Add to Reminders action remained separate and unused. Initial direct development-app observation timed out; copied signed app launched successfully outside synced storage. Final label wording changed to general-purpose “paste text to test”; no behavior change.
