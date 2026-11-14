# Final files review — 2026-11-14

Reviewed working tree based on `0e79401506aae00134b64d129eb5e8e78d1d0bdd`. This is an exact-file review, not a claim that the uncommitted tree already has a candidate commit. Hashes below identify the final reviewed versions.

Scope: independent review of application lifecycle, automation/macro integration and bridge text boundaries. The reviewer previously authored the codec/recovery components; checks of those components are therefore **self-review**, not an independent audit. Root owns final integrated candidate/CI verification.

## Findings and repairs

1. **P1 — leading U+FEFF content lost through bridge getters. Repaired.**
   `TTEditor.text` and `selectedText` decoded UTF-8 using NSString constructors, which consume an initial EF BB BF marker. A UTF-8 file containing a file BOM plus an intentional leading U+FEFF decoded correctly in FileCodec but lost the content scalar when read back from the editor for saving. A native pre-fix probe observed `allLength=1 first=61 selectedLength=1 first=61` after setting U+FEFF + `a`. The bridge now prefixes a temporary ASCII sentinel during decoding and removes only the sentinel; the same conversion protects recorded insert text. Three new bridge checks and two actual NSDocument codec→editor→serialization checks preserve the exact leading content and double-BOM bytes.

2. **P2 — malformed recovery revision could trap during restore arithmetic. Repaired.**
   A syntactically valid snapshot with `revision=UInt64.max` passed schema validation and reached `snapshot.revision+1` during Recover. RecoveryStore now rejects revisions above Int64.max, preserving offending evidence; the application additionally checks addition overflow. Three FileChecks verify save/read rejection and preservation. Runtime revisions remain bounded by realistic edit counts; this is not a power-loss durability certification.

3. **P2 — automation parameter storage inherited broad default permissions. Repaired.**
   Saved literal find/replacement parameters in Automations.json used ordinary atomic Data writes. On a traversable custom support directory this could expose configuration text. Both workflow management and selected-destination persistence now share a private writer: support directory0700, new0600 temporary file, fsync and atomic rename. Native tests check initial and replacement modes, exact saved definitions and symlink rejection without altering the external target. A first regression exposed cached URL resource values accepting a replaced symlink; authorization now uses fresh FileManager file attributes.

4. **Earlier native lifecycle findings verified repaired.**
   Assigning NSWindowController.document before addWindowController left NSDocument with zero owned controllers. Root removed that assignment. Minimum/content-frame constraints now keep actual Scintilla viewports nonzero through full controller cloning. These defects were discovered through native integration checks, not inferred from screenshots.

## Observed checks

- FileChecks: **642 assertions passed**, compiled for arm64-apple-macos14.0. Covers byte/BOM/EOL round trips, strict rejection, recovery corruption/stale revisions, private modes and actual SIGKILL snapshot persistence.
- BridgeChecks after BOM repair: **45 assertions passed**. The other bridge reviewer subsequently added native Undo/Redo recording safeguards; root must record that final integrated run independently.
- DocumentChecks: **49 assertions passed** through `scripts/test-documents.sh` after all above repairs and latest App.swift integration. Includes private automation storage, double-BOM document bytes, window/controller ownership, full controller split geometry, file conflicts/failures, Save/Save As/Save Copy, metadata, shared undo, actual revert, recovery and clean termination.
- Native headless bitmap `build/tests/document-clone.png` was inspected and shows source and clone text. Shell test process reports `NSScreen.screens=[]`; its `window.isVisible` assertion is native AppKit state, not proof of physical onscreen display. Root reports separate CUA visual/input verification; this reviewer did not independently repeat it.
- Log: `harness/logs/document-checks.log` (also `document-review-final.log`). Scratch probes remain ignored under build/tests.

## Remaining limits

No additional confirmed blocking defect remains in the reviewed scopes at these exact hashes. This is not full parity certification. IME/dead-key and VoiceOver behavior, older OS/Intel runtime, live EventKit permission/export, native macro UI capture across all actions, macro cancellation and the unimplemented parity matrix remain unverified/open as recorded by their owners. No live Reminders access was requested by this reviewer.

## File identities

| File | SHA256 |
|---|---|
| `Sources/TextTankApp/App.swift` | `1fd44b1b5f9641cd6e2feab5ca519af4ab11901d53c57f1f9fd50100a0e68525` |
| `Sources/EditorBridge/TTEditor.mm` | `7e02b69418b33ccd3ec9d487c0b80e365e1a2e4e95310acce2a1989e7868a833` |
| `Sources/Automations/AutomationController.swift` | `fac0f7da87b72a5e586009d67555d1986693fe23ef3da8f803cdd8602e3780d9` |
| `Sources/Macros/MacroController.swift` | `4600bae686da8f043e42af5e0eca71633c438e35ca9fcff044f7ec5a5e7d8b26` |
| `Sources/Documents/RecoveryStore.swift` | `44ea8c0afac95dcbd85b458da695b3d074240c9b07ccb691a29885feee93b1da` |
| `Tests/DocumentChecks.swift` | `af9702036d2e0bc40f23d26568eb39c8b5a92837973bd6e0c24747693472ed40` |
| `Tests/BridgeChecks.mm` | `7dcc399169e7d778afb735a8debfdbe12f5b69381d13ea4a22b88a01a068cf36` |
| `Tests/FileChecks.swift` | `4072af7ebf2c56b56bf723e70249102c9249a748b702f24d2daaa5b8257341e7` |
