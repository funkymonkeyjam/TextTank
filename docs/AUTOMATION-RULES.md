# Configuring automation rules

Use the single Automations dropdown to run any saved workflow. Favorites appear first; keyboard shortcuts remain optional. New workflows do not create separate toolbar buttons. Existing saved pin flags are displayed as favorites.

Automations → Manage Automations → Create Automation opens one builder with an editable name. To change an existing workflow, select it → Edit → Edit Rules & Test.

Load Rules copies processing steps from any saved workflow or a general template. Import File reads a portable JSON rule set; Export Rules writes one with version, name and steps. Loading only replaces draft steps after confirmation; it never adopts an imported connector destination, input/output, shortcut or identifier. Invalid or oversized files leave the draft unchanged. Recipes are one optional template.

The ordered list shows each rule in plain language. Add Rule opens a choice of actions. Text-match rules use case-sensitive literal text; special characters do not require escaping. Clear-lines rules leave an empty row; follow them with Remove empty lines for a compact list. Regular expressions remain an explicitly advanced option. Duplicate, Move Up, Move Down and Remove operate on the selected rule.

## What the rules match

- Literal text means the same characters, as in Find. The clear-lines rules and Find and replace do not treat a precomposed letter (é as one character) and its decomposed spelling (e followed by a combining accent) as equal, and they find text inside a joined emoji sequence. Remove duplicate lines compares bytes, exactly as Remove Duplicate Lines in the Edit menu does, so those two spellings are different rows.
- Trim spaces at line edges removes Unicode spaces and tabs, including the no-break spaces common in text copied from web pages. The Edit menu's Trim Leading and Trailing Whitespace removes only the space and tab characters.
- Clear lines matching a pattern clears a line only when the pattern can match the whole line. Every alternative is tried, so `Cups|Cups Metric` clears the line `Cups Metric`.
- Pattern rules share one time budget of a tenth of a second per run, counted over every pattern rule and every line. Test Rules applies the same budget to the sample. A sample is at most 64 KiB, so a large document can still exceed the budget when its sample passed; the run then stops with nothing changed.
- Remove numbered note references tidies the gap a removed reference leaves, on that line only. It does not trim other lines; add Trim spaces at line edges for that.
- Remove Markdown formatting removes the padding before an opening emphasis mark whose text starts with a comma or semicolon (`each) *, halved*` becomes `each), halved`). It changes no other spacing.
- Sort lines alphabetically orders by character code: capitals before lowercase, accented letters after z. Sort lines in locale order (`sortLinesLocalized` in JSON) orders as Finder does in your language: case and accents come second and numbers inside a line sort by value. The Edit menu has the same pair, Sort Lines Ascending and Sort Lines in Locale Order.
- A rule set to ask for its text when running may be saved with the text left empty. Running or testing it without a value stops with a message that names the rule.
- Line filtering and sorting rules need one kind of line ending in the text. Mixed endings are refused and nothing is changed.

Every run happens off the main thread. A run that takes longer than a fifth of a second shows a progress panel whose Cancel button (or Escape) ends the run at once with nothing changed, whatever the size of the input.

Clipboard input reads plain text first, then rich text. A clipboard that offers only HTML is converted locally to text: tags are removed, list items, paragraphs and line breaks become lines, and scripts, styles and images are dropped. Nothing in the markup is rendered, run or fetched.

### Changes for automations saved by earlier builds

Saved automations are never rewritten. Three corrections change what an existing one does:

- An automation that uses Remove numbered note references without Trim spaces at line edges no longer trims lines that hold no note reference.
- A pattern with a shorter alternative first, or a lazy quantifier, now clears every line it can match entirely. It may clear lines it used to leave.
- A literal rule typed with a precomposed letter no longer matches the decomposed spelling, and the reverse.

Paste test text into Sample input and press Test Rules. The result is read-only. Tests use saved parameter defaults, not runtime prompts, and never read a configured file/clipboard, change an editor or invoke a connector. Input is limited to64KiB; intermediate results are capped at1MiB with conservative replacement preflight. Testing runs off the UI thread; edits or closing invalidate/cancel pending results. Time is checked between steps, not a hard preemptive deadline for every operation.

Use These Rules returns the draft to workflow settings; Save persists it. Cancel discards draft changes. Workflow names, IDs, triggers, input/output and preview choice are retained. JSON remains available as an advanced interchange/configuration option.

## Supplied recipe examples

The templates in Load Rules are rule files bundled with the app (`Resources/AutomationTemplates/*.rules.json`), in the same format Export Rules writes.

Load Rules → Template: Recipe ingredient cleanup replaces the draft with general rules only: the recipe control words and colon labels are cleared, then markers, Markdown, checkbox marks and numbered note references are removed, line edges are trimmed and empty lines dropped. It preserves unknown text rather than guessing whether an unmarked row is an ingredient or a heading: a heading without a colon stays, and so does preparation prose after an ingredient. Add your own Clear lines equal to text or Find and replace rules for those.

The four supplied sample input/output pairs are retained in Tests/Fixtures/recipe-user-sample*; outputs contain 32, 7, 13 and 13 ingredient rows. They are matched byte for byte by Tests/Fixtures/recipe-user-samples.rules.json, which is the template plus eight literal rules for the headings and note suffixes that only those samples contain. That rule file is test data and is not part of the app; it can be imported with Load Rules → Import File. The earlier browser/Markdown/plain-copy fixtures also match. Parenthetical quantities and substitution options remain unless an explicit matching rule removes them.

The automation installed on first run is named Clean up recipe list. It is a strict, marker-based cleanup: when a list has bullets or checkboxes, every other non-blank line must be a Markdown heading or a colon label, or the run stops with nothing changed. Samples 1 and 4 mix marked rows with unmarked ones, so that preset refuses them; they need the rules above. Add to Reminders stays a separate explicit action.

This rule builder is a linear low-code pipeline, not a branching programming system. Full application parity remains incomplete.
