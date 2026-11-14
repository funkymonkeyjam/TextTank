# Research inputs used by TextTank

This index is curated from the accumulated investigation. It publishes requirements, provenance and limitations, not proprietary application code, machine profiles or personal documents. Source findings are not Windows runtime observations. The implementation evidence belongs in the candidate's test/review records.

| Record | Use and limit |
|---|---|
| [Reference profile](../parity/reference-profile.json) | Frozen Notepad++ source commit, 96 language definitions and hashes for standard configuration/packaging inputs. Actual released distribution artifact/version/hash remain unresolved. |
| [Working capability inventory](../parity/capabilities.json) | Required command surfaces and separately identified high-risk behavior interactions. All initially unassessed/not-run. Semantic deduplication and dialog/dynamic/preferences expansion remain open, so the row count is not a completeness denominator. |
| [Every seed disposition](../parity/seed-dispositions.json) | All 531 original command/range definitions retained; explicit alias/group dispositions. 531 is not a feature count. |
| [Inventory builder](../parity/build_inventory.py) | Reproducible source-only extraction; takes a frozen checkout and seed JSON as explicit arguments. Never marks implementation or tests complete. |
| [Research digest](findings.md) | Decisions, previous evidence types and regression risks carried into implementation. |
| [Source links](sources.json) | Pinned primary source URLs from the earlier source investigation. |
| [Automation acceptance](../parity/automation-acceptance.json) | User-named workflow and connector behaviors required in addition to editor parity. |

## Reference identity

[Official source](https://github.com/notepad-plus-plus/notepad-plus-plus/tree/61246e5741fd7c59352f3feb5ccc7e33e4594d15): source version 8.9.8.1, vendored Scintilla 5.6.7 and Lexilla 5.5.4. These are reference facts, not TextTank dependency pins. The standard package recipe includes mimeTools, NppConverter and NppExport; their functions cannot be dropped as optional third-party plugins. Detailed plugin versions and exact error/option semantics still need official package/source evidence.

The verified [REA workflow](https://github.com/morluto/rea/blob/8c857ce56c68ca46d202db0c9571277974c9e167/.agents/skills/reverse-engineer-anything/SKILL.md) routes complete source-repository analysis to ordinary tools. No new binary or Windows runtime observation is claimed by this inventory.

## Local provenance check

All 91 entries in the execution handoff's local source-input manifest matched their expected SHA-256 on 14 November 2026. The per-entry hash audit is `harness/reference-inputs.json`; it contains relative input names and hashes only. The local raw evidence is not needed to run TextTank and is not copied wholesale into the public repository.
