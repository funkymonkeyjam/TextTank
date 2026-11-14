# Independent utilities review

Reviewer: search worker, not utility author. Source inspected: UtilityCore.swift, UtilityController.swift and UtilityChecks.swift. This is a scoped review, not full utility-reference certification.

P2 repaired: modal hex/number conversion could retain and mutate an editor detached while native modal UI processed events. Author added window attachment guards before mutation, consistently applied to ordinary utility/export access. The reviewer re-read those guards. Author suite reports 84 assertions including detached-editor rejection; reviewer did not independently rerun all 84.

Core inspection: strict UTF-8 round-trip validation preserves FEFF/NUL and rejects decoded binary/invalid sequences. Hex and percent decoding reject malformed input. SAML raw inflate uses a fixed 16 MiB output buffer plus one sentinel byte, checks complete stream and rejects trailing input. XML detection is a prefix check, not XML validation; no content is executed. Styled export captures a stable attributed snapshot before the save panel. Transform application uses a grouped Scintilla replacement.

Performance limitation: an independent Debug probe measured 1 MiB URL-full encoding at approximately 0.88 seconds and permissive Base64 decoding at 0.15 seconds on this host. Current utility application allows up to 16 MiB and executes synchronously; this review does not certify responsiveness/cancellation for that maximum. Probe is ignored at build/tests/UtilityReviewProbe.swift. Complete reference-option semantics remain governed by docs/research/utility-audit.md rather than inferred from menu presence.
