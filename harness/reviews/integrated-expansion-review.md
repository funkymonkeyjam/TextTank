# Independent integrated expansion review

Reviewer: reference/workspace worker. Independence applies to integrator-authored App.swift, editor bridge, settings, Run and new command wiring. This reviewer authored Utilities and WorkspaceBrowser/DocumentMonitor; those implementations are explicitly excluded from independent certification here. Their independent review is in search-worker reports. This is a bounded integration review, not full capability/parity certification.

## Findings

- **P2, repaired and independently retested: modal column insertion could target changed selections or a detached editor.** Original handler captured only editor revision before the dialog. Caret/selection changes do not increment text revision, and the handler used current selections after the modal returned. Integrator added captured selection ranges and a shared applyColumn guard requiring attachment and unchanged ranges before atomic bridge revision/read-only validation. Source recheck resolves this path; runtime disposition follows below.
- **P2, repaired and independently retested: newly cloned views omitted editor settings.** Clone construction shared the Scintilla document and applied language/read-only state, but omitted configured wrap/appearance/tab settings even though settings promise application to new views. Document sharing does not share all view configuration. The integrator now applies settings before language styling and assigns the automation context menu. The native clone regression passes.

## Source review conclusions

The saved-workspace provider weakly captures AppDelegate and reads current saved root identities when folder search captures its action snapshot. It does not imply project-file membership. Language-specific comment menu commands obtain the document profile and explicitly invalidate unsupported macro recording. Comment application checks open/writable state, revision and selections before grouped replacement. Inline find/replace now commits the shared AppKit field editor before reading values.

Bridge syntax fonts validate index, font availability, finite bounded sizes and embedded NUL, persist per-view overrides and replay them after palette rebuild. Search highlights validate all UTF-8 ranges before clearing/filling indicator 20; they do not alter document bytes or Undo. Complete theme/print/Unicode parity is not established by these guards.

Close preserves native Save/Discard/Cancel review, prepares controllers by clearing callbacks/observers and making views read-only, and retains visible native and toolbar close controls. Quit closes clean documents or waits for the asynchronous unsaved-document review callback. Previous close-crash runtime evidence remains in DocumentChecks; this review does not substitute for physical modal testing.

Save performs an external-byte comparison and sets the savepoint only after successful native save. A noncooperating filesystem writer can still race the check/write sequence; post-save reread is not a filesystem transaction. This known limitation is not claimed repaired. Clone shares document data/Undo while view configuration is separate.

Run keeps argv separate from text except explicit intentional shell mode, validates unique configured identities, previews output and requires explicit Apply. Apply checks result-button identity, revision, attachment, writability and selection identity. Exact UTF-8 output decoding preserves FEFF/NUL; the independent six-case RunController repair retest is recorded in foundation review. Child-process lifecycle has a separate search-worker review; this report does not claim unrestricted in-process plugin parity.

## Test evidence and source identities

The candidate suite manifest initially covered 267 source/test/script files. App.swift and DocumentChecks changed during its run for these repairs, so that manifest must not be presented as covering the final repaired files without a fresh run or explicit supplementary evidence.

### Final repair validation

Independent recompilation against current full app sources and actual AppKit/Scintilla passed **88 DocumentChecks assertions**, exit 0. Included regressions reject modal column selection changes without altering original bytes and confirm a new clone inherits configured wrap and an automation context menu. Existing checks cover shared Undo after closing a clone, dirty-state tracking, settings validation/persistence, native save/reload/recovery and clean Quit. Log: `harness/logs/integrated-review-documents.log`. Host sandbox-extension warnings occur around synthetic temporary files; the process completed its assertions. Native object tests are not physical GUI or macOS 14 runtime certification.

Candidate broad-suite log reaches WorkspaceBrowserChecks 35 and inventory check PASS (1375 surfaces retained, behavioral coverage explicitly unverified). Its original manifest differs on exactly App.swift and DocumentChecks; the supplementary independent 88-case run covers those repaired files and compiled all current app sources. No broad-suite final-file rerun is inferred from that older manifest.

No remaining concrete blocking introduced defect was found within the reviewed integration scope after these repairs. Scope limits above remain; this disposition is not full standard Notepad++ capability certification.

SHA-256 identities at completed review:

- `Sources/TextTankApp/App.swift`: `287dbad8e4031cff480374747cb216774a22b6d1acea68d2556388786751cbdb`
- `Sources/EditorBridge/TTEditor.h`: `31487a12b67453494293a30a5eb5f0adb30ecb32acf4268d06af64bf5e47810c`
- `Sources/EditorBridge/TTEditor.mm`: `f7d06edf84ebc48ded503ecebb7cbd87511bb18ef0274d0993cc4ce92c503153`
- `Sources/Documents/EditorSettings.swift`: `ce9f6b60a4bad0bb81a356103cfd570a64492bd94b59abdb4d14357bc3638be8`
- `Sources/Documents/CommentCommands.swift`: `0cc7bdb550dbf49b0b07f7ffc64deef92088e3417f2843a9abe7e933a5cf04c4`
- `Sources/Run/RunCore.swift`: `fa4d26a9aa5a24fb0b9efe7d84f68fa4e2c20124b31e9a5ac8bc969111145dad`
- `Sources/Run/RunController.swift`: `0f88315794ca2a09f34841ef176c74ee3d7c6191ab6f434ec5cb09e207d1df7e`
- `Tests/DocumentChecks.swift`: `21cc4d7cb89b8b9e17296a4b0eb07be725b70f63ae2c667a8dc1b96170a87b1e`
