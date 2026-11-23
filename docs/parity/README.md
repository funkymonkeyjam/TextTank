# Capability requirements and dated implementation map

[capabilities.json](capabilities.json) retains all 1,375 reference source surfaces, all 531 seed expressions/dispositions, the specialized parameters/aliases/acceptance cases and 28 additional automation requirements. `completion_claim` remains **false**. The reference surface count is not a deduplicated feature denominator or a completion percentage.

The matrix is the reference, not an exact-parity contract. By the owner's decision of 23 November 2026, TextTank is a close approximation of Notepad++ for familiar editing tasks: a row may be met by a Mac equivalent that is clearer on a Mac, such as a command listed in a different menu (the nine-menu map is DS-D4 in [DESIGN-STANDARDS](../DESIGN-STANDARDS.md)). A difference is recorded in the row; it never removes a working command and never marks an unassessed row complete.

The matrix stores repeated defaults and acceptance templates once. Each requirement row retains its identifier, behavior, source evidence and differences. `scripts/capability_matrix.py` expands a row losslessly: expected behavior defaults to behavior, owner to family, command identifier to row id, and each acceptance case combines its template with its identifier suffix and optional action text. Expanded legacy command-contract and acceptance defaults describe outstanding reference assessment work, not the runtime command allow-list or an instruction to disable existing behavior. Original research inputs and generators remain available in the dated history described in [research provenance](../research/README.md).

The separate `assessments` map lists only reviewed source/check connections. Unmapped requirements remain unassessed. Mapped entries are **partial**, with a source/check-presence scope and a dated source commit/tree; they do not claim every case, Windows equivalence, current GUI behavior or full command coverage. Actual test outcomes belong to the exact candidate's acceptance log/validation record. Update mappings when owning symbols or paths move.

From a source checkout:

```sh
python3 scripts/capability_matrix.py
python3 scripts/capability_matrix.py --expand
python3 scripts/check-docs.py
```

These commands check metadata, actual mapped paths/symbols and local documentation links. They do not execute editor behavior and are deliberately outside the native acceptance suite. The former constant-only parity inventory gate was removed; no native check was removed with it.

## Current dated examples

The map connects external-save conflict and untitled recovery to document/file checks; empty-line removal, EOL conversion, folder search and macro recording to their native mechanisms/checks; and automation rename/Undo to their controller checks. These examples document existing implementation evidence without marking the remaining catalog complete. Read each entry's limits and the snapshot identity before using it.
