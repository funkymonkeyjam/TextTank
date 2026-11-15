# F04 Run configuration persistence repair

Author: reference worker. This is author validation, not an independent review of this repair.

Run libraries now use one 1 MiB encoded byte limit for saving and restart. `ConfiguredRun.encodeLibrary` checks semantic validity and a raw-field lower bound before JSON allocation, then checks actual encoded bytes including escaping and metadata. `decodeLibrary` rejects oversized bytes before parsing and validates decoded commands. Controller persistence obtains validated data before creating directories or replacing the file; rejected configurations preserve both the file and active menu/library. Existing oversized files are not rewritten on startup.

Observed validation:

- **RunChecks: 17 passed**, including exact 1 MiB encoding/decoding, one byte over, escaping expansion, two individually valid 600,000-byte arguments, aggregation across multiple commands, and oversized reader rejection. Existing process execution cases also passed.
- **RunControllerChecks: 10 passed** in a scratch runner using the real RunController, AppKit and TTEditor with a minimal native editor owner instead of TextDocument to isolate concurrent integrator changes. It verifies rejected save preserves exact old file bytes and command identity, ordinary restart, actual exact-1-MiB file restart, old/stale/detached preview rejection, FEFF/NUL preservation and one Undo. Log: `harness/logs/repair-run-controller-checks.log`. The committed test uses TextDocument and still needs the integrator's full-source suite run.
- All persistence tests use an isolated temporary support directory. New aggregate tests do not execute configured commands or access personal documents. No scripts/shared source were changed by this worker.

Source identities:

- `Sources/Run/RunCore.swift`: `a7c6ccf019fca774200d4aa46194645bbfc2148a185bf8fd5c656612016abee1`
- `Sources/Run/RunController.swift`: `ea11eebd4e588106561ad966234da1855fb68b4172544b3a2212fb793df5e570`
- `Tests/RunChecks.swift`: `f156b03b328fd0593f21245fdd8ee6d864096cdcf5d7544c0b0413f105491f64`
- `Tests/RunControllerChecks.swift`: `173706e7676e96e19eff8169fc6083d9f4ad85afe90ad5f17b80e55184dda340`
