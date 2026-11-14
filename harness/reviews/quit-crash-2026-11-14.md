# Quit crash diagnosis and repair review

Date: 2026-11-14. Reviewer: bridge worker; repair authored by integrator.

## Confirmed failure

Two local diagnostic reports for TextTank 0.1.0 (build 1), captured at 14:29:26 and 14:38:16 local time, identify the same main-thread Swift assertion trap:

`EditorWindowController.textDocument.getter → activeEditor.getter → window-update observer → NSApplication window update → application termination`

The observer ran after NSDocument.close detached its window controller. The computed `textDocument` property force-cast the now-nil controller.document. This was an application teardown defect, not merely stale UI-tool inventory. An earlier 10:03 report aborting during OS application registration is a separate sandbox-launch observation.

Diagnostic identities (raw reports deliberately not copied into the repository):

- First quit report SHA256: `9e3aa7946cfc80da03e0d31aa4fa5719e6b892767805c2726809a411f710110e`
- Second quit report SHA256: `061a87e34892d376b840408f2d458fb7fa6d19d2546b8445b3ae5e6a7f5697ea`

## Repair reviewed

- Controller owns its primary TTEditor directly; activeEditor no longer force-casts a detached NSDocument.
- TextDocument.close invokes prepareForClose before super.close.
- Idempotent prepareForClose removes both focus and automation observers and clears primary/clone focus callbacks.
- Close Tab uses native window.performClose, preserving unsaved-document review rather than forcibly dropping document state.
- Native close control is visible and an explicit toolbar Close Tab button is available.

No further blocking finding in this repair. The editor reference does not create a document ownership cycle: its change callback captures the document weakly.

Reviewed App.swift SHA256: `f0b04472fe7b3015509dc8c0c479cd38224fcbb3ba2b1cab5fd603d99ea3b4aa`
Reviewed DocumentChecks.swift SHA256: `a286ad9735b2449eb605505adc611c36fbae966c05a6c3999396134b202a33c3`

## Observed verification

The native document suite log reports 53 passing assertions. The new regression retains the controller/window, closes the document, posts NSWindow.didUpdateNotification, calls app.updateWindows, and accesses activeEditor after detach. It confirms observer removal and no assertion trap. This reproduces the lifecycle ordering missing from the earlier test suite.

The integrator separately reports CUA closed one of two tabs, then invoked menu Quit, and observed no new TextTank crash report afterward. This reviewer independently reviewed the source and native test log, not those CUA actions. Absence of a new report is recorded as such; it is not a substitute for process-exit observation or complete dirty-quit coverage.

Disposition: confirmed crash repaired and regression-tested; no full-product/parity claim.
