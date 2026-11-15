# Automation presentation and input review

The user reported inability to rename a new workflow or enter sample text. Before changes, real keypresses typed both fields and Command-A/C/V worked in the tested copy; the failure was not reproduced as a noneditable control. Canceling the diagnostic builder exposed an already open user builder underneath it. Existing draft preserved. Inspection identified createAutomation lacking a busy guard across its modal sequence. This is a concrete reentrancy defect, not proof of every cause of the reported symptom.

Changed creation to a single builder with explicit editable/selectable name and initial focus. The entire creation and palette lifecycle now holds the busy guard. Native editing fallback prefers the modal window's responder. User settings remain untouched by cancellation.

Independent worker ran54 native assertions, including real NSEvent keyDown in name/sample and a watchdog proving reentrant management does not open another dialog; cancellation preserves exact saved definitions. Core121 assertions include portable rules roundtrip, exclusion of connector/identity fields, validation and size bounds. Source review found no additional blocking defect in generic load/export paths.

Physical new-build walkthrough: one labeled Automations dropdown, starred saved favorites followed by other workflows; no per-workflow toolbar buttons. Created a draft, typed name 'rule' with individual keypresses, typed b/newline/a in Sample Input, used actual Command-A/C/V to produce b/a/b/a. Loaded Sort unique lines from generic Load Rules; name and sample retained. Test Rules displayed a/b. Canceled draft; main editor returned and no diagnostic workflow was saved. Layout screenshot inspected; user draft in the older app copy was not canceled. Recovery snapshot left intact. No Reminders writes.

Portable file import/export schema and validation are tested; complete physical save/open-panel matrices and full accessibility certification are not claimed. Full application parity remains incomplete.

Follow-up: full suite surfaced a Swift warning that the temporary RuleFields controller's weak action targets could outlive it. Retained it explicitly with withExtendedLifetime for the entire modal run. Independent native regression switches an actual rule picker to literal replacement, verifies both fields enable, enters values and saves;57 native assertions pass after repair. Core remains121. Final candidate is rebuilt and the full suite rerun for source-bound delivery.
