# Integrated audit repairs

F01: real TTAlert moved to Sources/UI; native test compilation explicitly includes shared UI. Tab activation settles content layout before copying the prior visible frame; real-screen regression retained with diagnostic frames.
F03: data supplied to NSDocument saving is an immutable encoded snapshot. Successful saves retain those exact bytes as conflict baseline, with revision/format guard before clearing dirty state. Injected external post-write replacement test verifies a later save refuses to overwrite it.
F06: Control-Tab / Control-Shift-Tab commands and Open Documents chooser expose hidden files and restore editor focus.
F09: hidden windows skip recurring status work. Active statistics use one in-flight immutable snapshot with scalar/EOL scans off-main; Scintilla capture remains on main by contract. UI-scale latency remains a measurement obligation, not certified by this repair.
F11: ordinary recovery checkpoints use serial background IO with at most one pending snapshot, plus a five-second maximum interval alongside half-second debounce. Explicit Save/discard boundaries synchronously order cleanup after prior writes to prevent snapshot resurrection. Tests cover coalescing, continuous-edit checkpoints and close cleanup. Explicit boundary IO and main-thread snapshot capture remain synchronous; no full power-loss/slow-disk UI certification is implied.
F12: stable semantic badge identities preserve unchanged control objects across value updates.
F14: full acceptance records start/end source identity, tracked-file hashes, dirty state and actual exit result. Packaging rejects mismatched/failed/dirty evidence and includes validation.json, app hash and tree-matched observed CI state in ZIP. No inferred CI passes.

Independent reviews: Run worker found a queue-boundary Scintilla read in close and a validation end-tree-only identity hole; both repaired. Reviewer verified recovery coalescing/order, exact save baseline, stable controls, visibility gating and shared UI extraction. Session test fixture now retains the actual language controller dependency rather than asserting only metadata.

Final local/CI outcomes are recorded in the candidate's validation.json. Full Notepad++ parity, VoiceOver matrix, macOS14/Intel runtime and live Reminders fault verification remain separate open requirements.
