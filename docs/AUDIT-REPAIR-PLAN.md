# Audit repair execution plan — 2026-11-15

Scope: F01-F14 in harness/reviews/audit-2026-11-15/README.md. Preserve all remaining full-parity requirements; this plan closes audit findings, not the complete product contract.

## Ownership and sequence

1. Integrator: F01 shared dialog dependency and screen-backed frame handling; F03 exact saved-byte baseline; F06 keyboard/document navigation; F09 visible-only status work; F11 ordered background recovery with maximum checkpoint interval; F12 stable status controls; F14 candidate validation and checkpoint records.
2. Automation worker: F02 bounded production transforms; F05 consistent Reminders journal limits; F13 bounded regular-file configuration IO.
3. Search/workspace worker: F07 session profile restore; F08 filename detection ordering; F10 linear, cancellable bookmark computation.
4. Run worker: F04 aggregate configuration bounds, then independent review of integrator changes.

Each worker owns its subsystem and regression tests, without changing shared build/scripts/document lifecycle. Integrator alone commits, packages and publishes. At most three workers.

## Gates

- Reproduce or encode a regression for each defect; never reproduce OOM or mutate personal documents/lists.
- Run focused tests, exchange independent reviews, repair findings, then run full scripts/test.sh and observe exact-tree CI.
- Package a clean committed candidate with validation.json recording actual local/remote source identities, results and skips. Install and verify the app through native UI.
- Keep outstanding runtime/VoiceOver/connector fault verification explicit. Do not merge, tag, force push, or claim full parity.

## Progress

Started from clean local f3384b4 (audit record); prior application source bcee103. F01-F14 repairs and regression tests implemented; independent findings repaired. Exact-candidate full local acceptance, CI and installation are the final gates. Individual worker records and final repair assessment live beside the audit report.
