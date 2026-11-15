# Compact document tabs — 2026-11-15

User-requested presentation: content-sized tabs at the left, active tab tinted with an accent underline, and New Tab (+) immediately after the last tab. Each tab has a close control and dirty dot. Overflow scrolls horizontally. Each file retains its NSDocument, native window, authoritative Scintilla buffer and undo history; only the selected document window is shown. Native full-width tabbing is disabled.

Observed UI: Command-N and + create tabs; switching returns to the selected document. Closing an inactive dirty tab visibly presents its native save sheet. Cancel retains the exact synthetic text. Undo restored the clean draft; tab close and clean Quit succeeded. Active highlight and adjacent + visually inspected.

Independent review findings repaired: actions bind weakly to document-window identity rather than unstable indices; closing the active tab transfers its frame; inactive documents are selected before presenting their close/save prompt.

Regression coverage added to DocumentChecks: visible selection, frame preservation on switch and close, compact plus placement, disabled system tabs, stale close action safety. The test process reports no screens; geometry assertions are explicitly skipped there because AppKit constrains frames against an absent display. Native document suite results are recorded in harness/logs/compact-tabs-documents.log.

Limitations: tab dragging/reordering and separate document-window groups are not implemented by this custom strip. Full Notepad++ parity remains incomplete. Overflow layout is implemented but not exhaustively exercised visually.
