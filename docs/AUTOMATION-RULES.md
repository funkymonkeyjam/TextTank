# Configuring automation rules

Use the single Automations dropdown to run any saved workflow. Favorites appear first; keyboard shortcuts remain optional. New workflows do not create separate toolbar buttons. Existing saved pin flags are displayed as favorites.

Automations → Manage Automations → Create Automation opens one builder with an editable name. To change an existing workflow, select it → Edit → Edit Rules & Test.

Load Rules copies processing steps from any saved workflow or a general template. Import File reads a portable JSON rule set; Export Rules writes one with version, name and steps. Loading only replaces draft steps after confirmation; it never adopts an imported connector destination, input/output, shortcut or identifier. Invalid or oversized files leave the draft unchanged. Recipes are one optional template.

The ordered list shows each rule in plain language. Add Rule opens a choice of actions. Text-match rules use case-sensitive literal text; special characters do not require escaping. Clear-lines rules leave an empty row; follow them with Remove empty lines for a compact list. Regular expressions remain an explicitly advanced option. Duplicate, Move Up, Move Down and Remove operate on the selected rule.

Paste test text into Sample input and press Test Rules. The result is read-only. Tests use saved parameter defaults, not runtime prompts, and never read a configured file/clipboard, change an editor or invoke a connector. Input is limited to64KiB; intermediate results are capped at1MiB with conservative replacement preflight. Testing runs off the UI thread; edits or closing invalidate/cancel pending results. Time is checked between steps, not a hard preemptive deadline for every operation.

Use These Rules returns the draft to workflow settings; Save persists it. Cancel discards draft changes. Workflow names, IDs, triggers, input/output and preview choice are retained. JSON remains available as an advanced interchange/configuration option.

## Supplied recipe examples

Load Rules → Template: Recipe ingredient cleanup replaces the draft with editable literal heading/note removals plus marker, Markdown and blank-line cleanup. It preserves unknown text rather than guessing whether an unmarked row is an ingredient. Four sample input/output pairs are retained in Tests/Fixtures/recipe-user-sample*; outputs contain32,7,13 and13 ingredient rows. The earlier browser/Markdown/plain-copy fixtures also match. The sample-specific notes are literal rules: arbitrary preparation prose is not inferred. Parenthetical quantities and substitution options remain unless an explicit matching rule removes them.

The native walkthrough loaded and saved these rules to the existing Clean up text workflow, tested sample4 in the preview, invoked the toolbar cleanup in the same editor and restored the exact original with one Undo. Add to Reminders stays a separate explicit action; this change did not send reminders.

This rule builder is a linear low-code pipeline, not a branching programming system. Full application parity remains incomplete.
