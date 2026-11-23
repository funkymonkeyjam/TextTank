# Automation rules reference

An automation is a saved, named workflow: one input, an ordered list of rules, and one output. This document describes the rules, the dialogs that edit them and the limits that apply. It describes the app as built; the checks named at the end pin the behaviour.

## Running and managing

The Automations menu and the Automations toolbar dropdown list every saved automation. Favorites come first in the dropdown and the context menu and are marked with a star. A keyboard shortcut is optional: one lowercase letter, bound to Command-Option, refused if an application command already uses it. Automations do not get toolbar buttons of their own from the dialogs; the `pinToToolbar` field of a saved automation is shown as its favorite status.

The management commands are in the Automations menu:

- **Manage Automations…** lists the saved automations. Two automations may share a name; both are listed, and each keeps its own identifier.
- **Choose Automation…** runs one from a list.
- **Review Reminder Export History…** shows recorded Reminders exports, newest first. A record file that cannot be read is named there and left unchanged; a new export then asks before sending, because the unreadable file may record the same items. **Clear Confirmed History…** in that dialog removes, after a confirmation, TextTank's record of exports whose every item was confirmed. Exports with unsent, failed or uncertain items are kept, Reminders itself is not changed, and a cleared list no longer triggers the already-sent warning. Nothing is removed automatically.
- **Restore Default Automations…** adds a fresh copy of the automation a new installation starts with (Add to Reminders), under a new identifier. Nothing already saved is replaced, including an edited copy of the same automation.

### Creating an automation

Manage Automations → Create Automation opens the rule builder with the name My Automation. Use These Rules then opens the settings dialog, titled New Automation, with the name from the builder. There you choose input, output, shortcut, preview and favorite status. Nothing is saved until Save in that dialog; Cancel there, or in the builder, discards the new automation. Saving a new automation with no rules asks for confirmation first.

### Editing an automation

Manage Automations → Edit opens the settings dialog for the selected automation. Edit Rules & Test opens the rule builder on a draft; Use These Rules returns the draft's rules and name to the settings dialog, and Cancel in the builder discards them. Save writes the automation. If Save fails (an empty or over-long name, a shortcut that is not one lowercase letter or is already taken, a write error) the error is shown and the settings dialog opens again with every field and the rule edits intact. A blank Shortcut field stores no shortcut.

The identifier, the Reminders destination and the rules of other automations are never changed by editing.

## The rule builder

The builder shows the automation name, the ordered rule list, a sample input pane, a read-only result pane and a status line. The window can be resized; the rule list and the two panes share the extra space.

Each row shows the rule, its text to match, its replacement, and whether it asks for a value when run, for example `Find and replace text · “x” → “y” · asks for the replacement when run`. Add Rule and Edit open the Configure Rule dialog. Duplicate, Move Up, Move Down and Remove act on the selected rule. An automation holds at most 100 rules; Add Rule and Duplicate are unavailable at the limit.

In Configure Rule the text field is called Text to match, or Pattern for the pattern rule. A rule that takes no text has both fields disabled. Ask for this text when running stores a default and prompts on every run; such a rule may be saved with its text left empty. A rule that is opened and saved unchanged is stored exactly as it was.

### Rule kinds

| Rule in the builder | JSON `kind` | Parameters | Effect |
| --- | --- | --- | --- |
| Remove bullet markers | `removeListMarkers` | none | Removes a leading `-`, `*` or `•` and the spaces after it. Leading numbers stay, because `2 eggs` is a quantity. |
| Remove empty lines | `removeBlankLines` | none | Drops lines that are empty or hold only spaces and tabs. Needs uniform line endings. |
| Sort lines (case-sensitive) | `sortLines` | none | Sorts by character code: capitals before lowercase, accented letters after z. Needs uniform line endings. |
| Remove duplicate lines | `deduplicateLines` | none | Keeps the first of each byte-identical line. Needs uniform line endings. |
| Find and replace text | `replaceLiteral` | `find`, `replacement`, `askForFind`, `askForReplacement` | Replaces every occurrence of the literal, case-sensitive text. An empty replacement removes it. |
| Replace regular expression | `replaceRegex` | `find`, `replacement`, `askForFind`, `askForReplacement` | Uses the Find bar’s case-sensitive Boost regular expressions and capture replacements such as `$1`. All regex rules share the workflow time budget. |
| Clear lines equal to text | `removeLinesEqualTo` | `find`, `askForFind` | Empties each line that is exactly the literal text. The line ending stays. |
| Clear lines containing text | `removeLinesContaining` | `find`, `askForFind` | Empties each line that contains the literal text. The line ending stays. |
| Clear lines starting with text | `removeLinesStartingWith` | `find`, `askForFind` | Empties each line that starts with the literal text. The line ending stays. |
| Trim spaces at line edges | `trimWhitespace` | none | Removes Unicode spaces and tabs, including no-break spaces, from both ends of every line. |
| Clear lines matching a pattern (advanced) | `removeMatchingLines` | `find` (regular expression, 1–500 characters), `askForFind` | Empties each line that the pattern matches from start to end. The line ending stays. |
| Clear Markdown headings | `removeMarkdownHeadings` | none | Empties lines that start with one to six `#` marks and a space. The line ending stays. |
| Remove Markdown formatting | `removeMarkdownFormatting` | none | Removes emphasis marks and code ticks and replaces an inline link with its label. A mark with no partner is left as typed. |
| Remove checkbox markers | `removeCheckboxMarkers` | none | Removes a leading `☐`, `☑`, `☒`, `▢`, `□`, `[ ]` or `[x]`. |
| Remove numbered note references | `removeNoteReferences` | none | Removes references such as `(Note 2)` or `see Notes 1 and 3`, and tidies the gap on that line only. |
| Keep marked list rows (strict) | `keepMarkedListRows` | none | Keeps only rows that start with a bullet or checkbox. Any other non-blank row must be a `#` heading or a label ending in a colon, or the run stops with nothing changed. A list with no marked rows is left as it is. |
| Sort lines in locale order | `sortLinesLocalized` | none | Sorts as Finder does in your language: case and accents come second and numbers inside a line sort by value. Needs uniform line endings. |

The five Clear rules empty a line and keep its line ending, so the number of lines does not change. Follow them with Remove empty lines to drop the emptied lines. Their JSON names say `remove` for compatibility with saved files.

### What the rules match

- Literal text means the same characters, as in Find. The clear-lines rules and Find and replace do not treat a precomposed letter (é as one character) and its decomposed spelling (e followed by a combining accent) as equal, and they find text inside a joined emoji sequence. Remove duplicate lines compares bytes, exactly as Remove Duplicate Lines in the Edit menu does, so those two spellings are different rows.
- Trim spaces at line edges removes Unicode spaces and tabs, including the no-break spaces common in text copied from web pages. The Edit menu's Trim Leading and Trailing Whitespace removes only the space and tab characters.
- Clear lines matching a pattern empties a line only when the pattern can match the whole line. Every alternative is tried, so `Cups|Cups Metric` empties the line `Cups Metric`.
- Pattern rules share one time budget of a tenth of a second per run, counted over every pattern rule and every line. Test Rules applies the same budget to the sample. A sample is at most 64 KiB, so a large document can still exceed the budget when its sample passed; the run then stops with nothing changed.
- Remove numbered note references tidies the gap a removed reference leaves, on that line only. It does not trim other lines; add Trim spaces at line edges for that.
- Remove Markdown formatting removes the padding before an opening emphasis mark whose text starts with a comma or semicolon (`each) *, halved*` becomes `each), halved`). It changes no other spacing.
- Sort lines (case-sensitive) orders by character code. Sort lines in locale order orders as Finder does in your language. The Edit menu has the same pair, Sort Lines Ascending and Sort Lines in Locale Order.
- Remove empty lines, the two sort rules, Remove duplicate lines and Keep marked list rows need one kind of line ending in the text. Mixed endings are refused and nothing is changed. Every other rule keeps each line's own ending.
- A rule set to ask for its text when running may be saved with the text left empty. Running or testing it without a value stops with a message that names the rule.

### Testing

Paste text into Sample input and press Test Rules. The result pane is read-only. A test:

- runs the rules in the list as they are now, with the saved defaults of any rule that asks when run; it shows no prompts;
- never reads the automation's configured file or clipboard, never changes a document and never invokes an output or connector;
- does not depend on the automation's name, which is checked only by Use These Rules and Save;
- accepts a sample of at most 64 KiB and stops if a result would exceed 1 MiB, with a conservative check before a replacement that could grow the text;
- runs off the main thread and stops after two seconds, checked between rules.

A freshly opened builder shows the instruction to paste sample text. After a test, editing the sample or the rules clears the result and says it is stale; a test still running is cancelled and its late result is discarded. Closing the builder cancels a running test.

### Load Rules and Export Rules

Load Rules copies rules into the draft from a saved automation, a built-in template, or a file. Only the rules are taken: the draft keeps its name, input, output, shortcut and destination. The draft's rules are replaced only after a confirmation that names the source and the number of rules.

Import File reads a JSON file of at most 1 MiB. It is not followed if it is a symbolic link. It accepts:

- a rule file written by Export Rules (`version`, `name`, `steps`). The name is only a label, so a blank or over-long name does not refuse the file;
- an automation library exported from Advanced JSON. Its automations are listed by name and the rules of the one you choose are loaded.

Any other file is reported as not a rule file, and the draft is unchanged. Export Rules writes the current rule list with the name in the name field, which must be 1–120 characters.

The templates are rule files bundled with the app (`Resources/AutomationTemplates/*.rules.json`), in the format Export Rules writes: Trim and remove empty lines, Sort unique lines, and Recipe ingredient cleanup.

## Advanced JSON

Manage Automations → Advanced JSON edits the whole library as JSON. The dialog lists every rule kind with its builder label and parameters; the list is generated from the same definitions the app validates against. An empty library is shown as an empty library. Insert Example adds a small general automation (Trim and remove empty lines, under a new identifier each time) to the JSON in the editor; nothing is saved until Save. Import and Export read and write a library file of at most 32 MiB.

A library holds at most 200 automations. Each has `version` 1, a unique `id`, a `name` of 1–120 characters, an `input` (`selection`, `document`, `clipboard`, `file`), `steps`, an `output` (`editor`, `clipboard`, `newDocument`, `file`, `reminders`), and optionally `shortcut`, `previewBeforeApply`, `pinToToolbar` and `destinationID`. A step has a `kind` and only the parameters that kind takes; a stray `find` or `replacement` is refused. Validation messages name a rule by its builder label and its JSON kind. No automation runs when it is saved or imported.

## Running

Every run happens off the main thread on a copy of the text; input and result are each limited to 32 MiB. A run that takes longer than a fifth of a second shows a progress panel whose Cancel button (or Escape) ends the run at once with nothing changed, whatever the size of the input. Editor output is applied only if the document, its revision and its selection are still what they were when the run started.

File input reads a regular UTF-8 file. A missing file, a symbolic link, a folder or device, and a file over the limit are each reported as what they are.

Clipboard input reads plain text first, then rich text. A clipboard that offers only HTML is converted locally to text: tags are removed, list items, paragraphs and line breaks become lines, and scripts, styles and images are dropped. Nothing in the markup is rendered, run or fetched.

## First run and storage

Automations are stored in `Automations.json` in the app's support folder, written atomically with private permissions. When no file exists, the one starting automation, Add to Reminders, is installed. It has its own explicit destination and Send. If that first write fails, it stays available for the session, the failure is reported once, and the next save writes it. An existing file that cannot be read is never overwritten: saving is refused until it is repaired or removed outside the app. An existing library is never topped up: an empty library stays empty.

No recipe automation is installed. Recipe cleanup is available as rules: the Recipe ingredient cleanup template below, and the Keep marked list rows (strict) rule for a marker-based cleanup that stops with nothing changed when a list mixes marked rows with other text.

### The retired recipe automation

Earlier builds installed a second starting automation, a recipe cleanup named Clean up text and later Clean up recipe list. When the app starts and reads an existing library, it removes that automation only if it is still exactly what a build installed (`RetiredFactoryAutomation` in `Sources/Automations/AutomationCore.swift`). All of these must hold:

- the identifier is the one those builds used;
- the name and the rule list are together one of the two installed definitions, with no rule edited, added, removed, reordered or set to ask when run;
- the input is the document and the output is the captured document;
- there is no shortcut (a stored empty shortcut counts as none) and no destination;
- preview is stored as off and favorite is stored as on.

Anything else is the user's and is kept: a renamed or edited copy, one with a shortcut, one removed from the favorites, a duplicate under another identifier, and any other automation that happens to use the same name. An automation is never removed by its name alone.

The removal is decided from the content each time, with no marker that it has run, so repeating it is harmless and a library with nothing to remove is not rewritten. Every other automation keeps its content and position. A library that held only that automation becomes an empty library; the starting automation is not installed again. A library that cannot be read is not examined and not written.

If the rewritten library cannot be saved, the file stays exactly as it was. The automation is still left out for that session and nothing is reported. Opening Manage Automations, the next save and the next start each try again. A remembered Paste Through choice that named the removed automation simply shows no check mark.

Services and Shortcuts read the library without changing it. Until the app has started once and saved the library, they can still find the old automation in the file by its name. With no file they offer only Add to Reminders, which they refuse because it sends to Reminders.

## Recipe template and fixtures

Load Rules → Template: Recipe ingredient cleanup replaces the draft with general rules only: the recipe control words and colon labels are cleared, then markers, Markdown, checkbox marks and numbered note references are removed, line edges are trimmed and empty lines dropped. It preserves unknown text rather than guessing whether an unmarked row is an ingredient or a heading: a heading without a colon stays, and so does preparation prose after an ingredient. Add your own Clear lines equal to text or Find and replace rules for those.

The four supplied sample input and output pairs are `Tests/Fixtures/recipe-user-sample*`; the outputs contain 32, 7, 13 and 13 ingredient rows. They are matched byte for byte by `Tests/Fixtures/recipe-user-samples.rules.json`, which is the template plus eight literal rules for the headings and note suffixes that only those samples contain. That rule file is test data and is not part of the app; it can be imported with Load Rules → Import File. Samples 1 and 4 mix marked rows with unmarked ones, so a strict cleanup built on Keep marked list rows refuses them; they need the rules above. `Tests/Fixtures/README.md` says which rules each fixture is checked against.

## Changes for automations saved by earlier builds

Saved automations are never rewritten, apart from the removal of the untouched retired recipe automation described under First run and storage. Three corrections change what an existing one does:

- An automation that uses Remove numbered note references without Trim spaces at line edges no longer trims lines that hold no note reference.
- A pattern with a shorter alternative first, or a lazy quantifier, now clears every line it can match entirely. It may clear lines it used to leave.
- A literal rule typed with a precomposed letter no longer matches the decomposed spelling, and the reverse.

The rule labelled Sort lines alphabetically in earlier builds is now labelled Sort lines (case-sensitive). Its JSON kind and its behaviour are unchanged.

## Scope

The rule builder is a linear pipeline, not a branching programming system. The behaviour described here is checked by `Tests/AutomationChecks.swift` (rules, limits, files) and `Tests/AutomationControllerChecks.swift` (the dialogs, driven headless). Full application parity remains incomplete.
