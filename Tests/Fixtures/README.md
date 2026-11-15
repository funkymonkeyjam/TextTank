# Recipe regression fixtures

Every file here is input or expected output for a check. No check edits a fixture at run time. Expected files marked *supplied* were provided or captured independently of the code; files marked *derived* were produced from another fixture and reviewed.

## Which rules each fixture is checked against

| Input | Expected output | Checked against | Origin of the expected file |
| --- | --- | --- | --- |
| `recipe-markdown-input.txt` | `recipe-cleaned-expected.txt` | The first-run automation, `AutomationDefinition.example` (Clean up recipe list) | Supplied |
| `recipe-browser-plain-input.txt` | `recipe-browser-cleaned-expected.txt` | `AutomationDefinition.example`, in the core and through a toolbar button in the app | Supplied |
| `recipe-plain-copy-derived.txt` | `recipe-plain-copy-expected.txt` | `AutomationDefinition.example` | Derived from the Markdown pair |
| `recipe-user-sample1-input.txt` to `recipe-user-sample4-input.txt` | `recipe-user-sample1-expected.txt` to `recipe-user-sample4-expected.txt` | `recipe-user-samples.rules.json` | Supplied |

`Tests/AutomationChecks.swift` runs the first three pairs. `Tests/UserRecipeChecks.swift` and `Tests/AutomationControllerChecks.swift` run the four user samples, the second through a saved automation in a real editor with Undo.

## The first-run automation pairs

The supplied Markdown recipe contains 28 marked ingredient rows; its expected output preserves the trailing chat quote, quantities, options and duplicates. The browser plain input was captured from the native TextTank accessibility text after a Chrome copy and paste; its expected output preserves copied spacing, quantities and options.

The plain-copy input is an approximation made from the Markdown input, not an observed clipboard: delimiters, bullets and the trailing chat quote were removed, link labels retained and delimiter spaces before commas normalized. Its expected output is the Markdown expected output without the trailing chat quote.

`AutomationDefinition.example` starts with a user-editable `removeMatchingLines` pattern for the whole-line recipe controls Ingredients, Cups, Metric and Garnish (optional), followed by the strict `keepMarkedListRows` rule. Behaviour is selected by typed rules and saved parameters, never by the automation's name. In a list that has marked rows, any other non-blank row must be a Markdown heading or a colon label; anything else stops the run before the document is edited, which protects unmarked ingredients and continuations. A list with no marked rows is kept whole.

## The user sample pairs

The four `recipe-user-sample*` pairs are literal examples supplied by the user; the expected outputs contain 32, 7, 13 and 13 ingredient rows. Samples 1 and 4 mix marked rows with unmarked ones, so the strict first-run automation refuses them and they are not checked against it.

`recipe-user-samples.rules.json` is the rule set that turns the four inputs into their expected outputs: the bundled Recipe ingredient cleanup template (`Resources/AutomationTemplates/recipe-ingredient-cleanup.rules.json`) plus eight literal rules for headings and note suffixes found only in those samples. It is test data in the format Export Rules writes; the app ships the template without the literals.

## Other folders

`persistence/` holds golden files for the persisted formats; see `Tests/DocumentPinningChecks.swift`.
