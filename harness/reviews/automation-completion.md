# Automation completion work record

Owner: automation worker. Scope: Sources/Automations, Sources/Connectors, Sources/Macros and their tests. Shared App/bridge/build files remain integrator-owned.

Active work: native ordered step editing and runtime parameters; safe file input; connector cancellation/progress and fault matrix; macro repeat/cancel and interchange.

Regression contract: legacy definitions decode unchanged; recipe cleanup remains direct same-editor with one Undo and a separate explicit Reminders action; renamed workflows keep IDs/bindings. File input must reject FIFO without blocking. Cancellation leaves editor unchanged before apply and never resends uncertain reminders. Import never executes.

User-confirmed live Reminders success is existing happy-path evidence. New connector tests use injected stores, never personal lists. Full parity remains open until integrated evidence and independent review.

## Implemented checkpoint

- Native create/delete, step add/edit/remove/reorder, shortcut/preview/toolbar settings; optional find/replacement runtime prompts preserve saved defaults and cancel before mutation.
- Pure transform cancellation checkpoints and native large-input progress; small recipe inputs retain immediate behavior. All editor mutation remains on main thread and checks captured revision/selections.
- Multiple selections transform independently through atomic bridge replacement with one Undo. Later selection failure preserves all original text.
- File inputs reject FIFO/device/symlink, malformed UTF-8 and inputs above 32 MiB.
- Reminders progress/Stop Sending; pending resume under original batch; private journal regular-file/nonblocking reads and validated lock file. Uncertain entries remain non-retryable. User-confirmed happy path remains distinct from injected failure tests.
- Recorded macros gain incremental modal playback, Stop, repeat-until-end with no-progress/100000-step limits, import/export and typed search capture adapter. Macro search adapter requires integrator wiring to SearchController.

Observed checks: AutomationChecks 59; AutomationControllerChecks 34; Macro native 31; ReminderChecks 43. Existing recipe exact 28-row same-editor/one-Undo assertions remain passing. Native builder dialog and progress visual/keyboard interaction still need UI observation; functional core/action tests do not certify those interactions. Generic transforms retain bounded but not instantaneous cancellation during Foundation sort/split operations.

## Independent search review (in progress)

Reviewer: automation worker, not search author. Found: SearchController.apply lacked read-only/closed-window guards; TTSearchEngine accepted full match `(.).` over an emoji then expanded `$1` to an unpaired surrogate, losing content as `�`. Independent compiled probe reproduced the second finding. Search worker notified for repair/retest. This is not search parity certification.

## Independent review repairs

Search worker identified a P1 multi-selection routing defect: a document-input/external-output automation could enter the multiple-selection editor path. Restricted it to selection-input/editor-output, added native document-to-newDocument regression proving original editor preservation. Also added explicit read-only rejection and limited macro interactive chunks to ~20ms between steps (a single bounded search can still take ~100ms). Current native automation36 and macro31 pass after repairs. Full timer/Stop physical interaction and all prompt/preview cancellation combinations remain unverified.

## Language package checkpoint

Added 96 source-derived language profiles with provenance, keyword/lexer mapping, style semantics, detection, completion, basic function navigation and native profile editing/import/export. Added strict UDL2.x XML import/export/editor, property and15-list conversion, and a separately audited LexUser port. Native language106 assertions include94 profile configuration/text-integrity checks and actual synthetic UDL keyword/comment/delimiter styling. Pure language23 pass on current XML validation. This is not96-language lexical certification. `objc` and `searchResult` reference engines remain absent in clean Lexilla; complex embedded language/substyle semantics, all UDL nesting/folding/number/multipart/incremental/lifetime cases, full reference function-list XML, API completion/signatures, and exact UDL font/colorStyle behavior remain open. Native uses dynamic semantic syntax colors, retaining imported RGB as source/configuration data.

LexUser provenance and exact upstream file licenses/hashes: Sources/Languages/LexUserPort/PROVENANCE.json. Search worker has been requested to review the port independently. No reference third-party preinstalled Markdown UDL was bundled.
