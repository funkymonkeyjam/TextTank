# Independent foundation review — continuation run

Reviewer: reference/utilities worker. Independence applies to the integrator's editor bridge, document reload/external-change, settings and editor transforms. Utilities were authored by this reviewer and are excluded from independent certification.

## Findings

1. **P2 repaired and rechecked: effective shortcut collisions.** Settings validation originally checked only explicit overrides, allowing `upper = d` to collide with default Duplicate Line and comma to collide with Settings. The integrator now validates an effective map including the default and reserves comma. Independent runtime cases reject both and accept moving Duplicate Line to `u`, then assigning `d` to Uppercase. Automation bindings use Command-Option while these editor bindings use Command; matching letters across those modifier sets are not collisions.
2. **P2 repaired and independently rechecked: duplicate removal treats canonical-equivalent strings as identical.** `EditorTransform.uniqueLines` used `Set<String>`, which can merge composed `é` and decomposed `e + U+0301`. Those are distinct document bytes. The integrator changed the set to `Set<Data>` and added a regression retaining both rows. Source re-review confirms literal UTF-8 equality.
3. **Hardening repaired: exported font-name buffer.** `attributedTextForSelection` initially used a fixed 256-byte buffer for `SCI_STYLEGETFONT`. The integrator now queries the byte length and allocates that length plus the NUL terminator before filling the font buffer. Source re-review confirms the change. Existing built-in style names did not reproduce an overflow.

## Observed runtime evidence

An independent scratch extension of the current DocumentChecks compiled all app sources against actual AppKit/Scintilla and passed **88 assertions**. Additions exercise missing-file classification, default/comma shortcut conflicts and a valid default-key reassignment. Existing cases exercise failed reinterpretation preserving dirty bytes, explicit Latin-1 reload, unchanged/changed disk state, reload while read-only, save failure, shared clone edits/Undo, recovery and detached-controller close repair. Log: ignored `harness/logs/reference-document-checks.log`; scratch test and script: `build/tests/ReferenceDocumentChecks.swift`, `build/tests/run-reference-documents.sh`.

The native process reports no physical NSScreen. This verifies native object behavior, not physical UI, VoiceOver, IME, Save/Discard/Cancel panels or macOS 14 runtime. Deployment target is macOS 14; the host runtime is separate.

## Source-review conclusions and limits

- Multi-selection replacement validates revision, read-only state, count, numeric bounds, UTF-8 boundaries and nonoverlap before the first edit; descending target order prevents earlier replacements from shifting pending targets. It groups replacements in the shared Scintilla undo history. Additional native bridge tests are integrator-owned.
- Reload decodes before changing editor bytes. Its temporary read-only unlock is restored after replacing the authoritative model and resetting the savepoint. Failed decode preserves the model. File reads use nonblocking regular-file validation, avoiding the prior FIFO hang.
- External-change checking compares current regular-file bytes against the saved baseline. It is a manual check; continuous monitoring and unavoidable read/save races remain open.
- Settings persist through private atomic replacement and reject unknown versions. Current UI remains a subset of reference preferences; shortcut modifiers and per-command availability need broader coverage.
- Line transforms have a 16 MiB limit and preserve mixed separators according to their documented policy. Swift grapheme length, localized title case and String comparison are not assumed reference-equivalent; reference differential cases remain required.

Source identities inspected at the first completed native review:

- `TTEditor.mm`: `bf800771e71b71e946d0436aba4d8dbe0a6a1637ae3b821f059a745361476f6f`
- `EditorSettings.swift`: `ce9f6b60a4bad0bb81a356103cfd570a64492bd94b59abdb4d14357bc3638be8`
- `App.swift`: `5d97e516437ae70922c2333a822a06d124487c7f3be0c0e4a7eb2f8f2d9b2842`

No claim of complete parity or an independently reviewed final candidate is made.

## Repair recheck

The independent native document runner passed 89 assertions after the literal-byte duplicate repair, including the composed/decomposed two-line case. The dynamic font buffer was source-reviewed. No open blocking finding remains in this bounded foundation review; broad parity/runtime limitations above remain.
