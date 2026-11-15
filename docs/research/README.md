# Research provenance and limits

This index publishes requirements, provenance and limitations, not proprietary application code, machine profiles or personal documents. Ordinary source observations are distinct from actual REA Evidence, user-reported runtime observations and design proposals. None is a current candidate certificate.

- [Capability matrix](../parity/README.md): all reference requirements, source links, seed dispositions, automation requirements and a small dated implementation/check map. Static rows and aliases are not a behavioral denominator.
- [Research digest](findings.md) and [pinned source links](sources.json): architectural decisions and reference limits.
- [Utility differences](utility-audit.md) and [workspace notes](workspace-browser.md): scoped implementation/reference observations.
- [User-reported Reminders observation](../parity/user-validation-2026-11-14.json): one reported happy path. The exact binary, destination and permission state were not independently inspected; fault/retry behavior is not established by it.

## Reference identity

The [frozen official source](https://github.com/notepad-plus-plus/notepad-plus-plus/tree/61246e5741fd7c59352f3feb5ccc7e33e4594d15) reports Notepad++ 8.9.8.1 with reference Scintilla 5.6.7/Lexilla 5.5.4. TextTank's separate implementation pins are recorded in `Dependencies.lock.json`. The reference package recipe includes MIME Tools, NppConverter and NppExport; required equivalent functionality cannot be waived as optional plugins. Released binary bytes and source/release differences remain unresolved; matching version labels do not prove matching code.

The verified [REA workflow](https://github.com/morluto/rea/blob/8c857ce56c68ca46d202db0c9571277974c9e167/.agents/skills/reverse-engineer-anything/SKILL.md) routes complete source-repository analysis to normal source tools. This matrix adds no Windows binary/runtime observations.

## Historical material

Historical run state, orchestration prompts, agent reports, large generator intermediates and the one-off language importer were removed from the current product tree and retained byte-for-byte with a hash/blob manifest in the surrounding investigation. They are also recoverable from [product source commit `cb66cfd24cb40f9764d6079018532667d6003342`](https://github.com/funkymonkeyjam/TextTank/tree/cb66cfd24cb40f9764d6079018532667d6003342). These dated records include the former `harness/reviews/`, `harness/reference-inputs.json` and original parity inputs; use Git history when reproducing that research. They are not copied into current review documentation.

The former 91-input local handoff audit records what was checked on 14 November 2026, not a current source-tree result. The old importer was a one-off research tool with unverified regeneration assumptions; it is no longer a production source utility. Bundled `Resources/LanguageProfiles.json` was retained unchanged, with its original input hashes and explicit semantic limitations. Future regeneration needs a maintained, input-verified procedure.

For a current candidate, use `validation.json` and its source tree/log hashes. Current UI appearance, physical keyboard paths, VoiceOver, actual macOS 14/15/Intel behavior and live connector fault scenarios remain unverified unless the specific candidate record says otherwise.
