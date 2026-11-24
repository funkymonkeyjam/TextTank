# TextTank design standards

These are the rules every change to TextTank's interface is held to. They come from a five-perspective
review of the app against Apple's public design guidance (15 November 2026) and from the owner's decisions
since. They sit beside `product-spec.md` (what the app must do) and `architecture.md` (how it is built):
this file says how it must behave and read on a Mac.

Read this before adding or changing a window, menu, toolbar item, alert, status text, colour, shortcut or
any user-facing string. Cite rules by their id (for example DS-31) in commit messages, briefs and reviews.

## How to use this file

- **A rule is a requirement.** A change that breaks one is not done.
- **A departure needs a reason on record.** If a rule does not fit, say which rule, what the person gains,
  and what evidence supports it, in the commit message and in the unit result. Keeping a familiar
  Notepad++ capability is a valid reason; "it was easier" is not.
- **`scripts/check-design-standards.py` enforces the countable part** (section 6). It runs as the
  `design-standards` suite in `scripts/test-suites.sh`. Never raise a budget to get green.
- **The rest is checked by review**, using the checklist in section 4 and the rubric in section 5.
- Apple's guidance is the source for the principle; the text here is TextTank's own rule. Following it
  does not imply Apple's endorsement.

## 1. Commitments

1. One clear purpose: a general-purpose plain-text and code editor. Automations extend it; they are not
   its main workflow.
2. Organise around the person's objects (document, tab, automation) with one name for each.
3. Use the system's familiar interaction for ordinary operations; spend invention on what is distinctive.
4. Keep primary actions discoverable and secondary depth available when relevant.
5. Preserve control: cancellation, truthful feedback, meaningful recovery.
6. Fit the Mac: resizable windows, the menu bar, keyboard shortcuts, pointer precision.
7. Accessibility, durability and responsiveness are requirements from the start, not a finishing pass.
8. Judge real workflows, including interruption and failure, not screenshots.

## 2. Decisions on record

| Id | Decision | Date |
|---|---|---|
| DS-D1 | **Tab model: one workspace window that hosts the compact tab strip** (and, later, editor groups). Native `NSWindow` tabbing is rejected: pinned tabs, multi-select, groups and two views of one document cannot be built on it. Stage 0 replaces the hidden document windows with a shared native host; later stages extend its model. | 15 Nov 2026 |
| DS-D2 | **The window's red close button quits TextTank**, after the usual review of unsaved documents. One tab closes from its own close button, File > Close or Command-W. Amended by DS-D9 (23 Nov 2026): at quit the review covers files with unsaved edits; an untitled document's unsaved text is kept and is not asked about. | 15 Nov 2026 |
| DS-D3 | **No Close Tab button in the toolbar.** Each tab has its own. | 15 Nov 2026 |
| DS-D4 | **The menu bar has nine menus, in this order: TextTank, File, Edit, Find, View, Compare, Tools, Window, Help.** File opens, saves and re-encodes documents and holds the workspace files. Edit holds everything that changes the text or the selection. Find holds finding, Go to Line, bookmarks and the Function List. View holds how the document is shown: the Preview submenu, Split Tab View, Wrap Lines, the Show submenu, Centered Text Column, zoom, Folding, Syntax Highlighting, the Workspace Browser, Editor Groups and the toolbar, fourteen items in all (DS-D13). Compare holds starting, reading, merging and exporting a comparison. Tools holds Macros, Automations, Run Commands and the utilities that leave the text as it is. Help holds the guides, the Command Palette and keyword help. TextTank is a close approximation of Notepad++, not a copy of its menu bar: a command sits where a person on a Mac would look first, and the Command Palette still finds it by its former menu. Group inside menus; do not add top-level menus without the owner. This replaces the frozen fourteen-menu order. | 23 Nov 2026 |
| DS-D5 | **Distribution** (Developer ID signing and notarisation) is undecided. Do not add signing identities, entitlements or release scripts without the owner asking. | open |

Owner follow-up, 16 November 2026:

- DS-D6. The toolbar has one Automations drop-down, with no individual automation buttons,
  including in restored configurations. Favorites prioritize the drop-down and editor context menu.
- DS-D7. New, Open and Close must not animate the document window. The temporary tab-window
  arrangement positions the incoming window before showing it; the workspace-host decision is unchanged.

Owner follow-up, 17 November 2026:

- DS-D8. Syntax highlighting retains the original Notepad++ lexer style categories. Built-in
  categories use distinguishable light/dark colors, with at least 4.5:1 text/background contrast.
  Explicit user colors remain overrides. Markdown is a selectable language and is detected for
  `.md` and `.markdown` files. Its headings, emphasis, lists, links and code are highlighted.

Owner decision, 23 November 2026:

- DS-D9. **Unsaved untitled text survives quit.** Quitting (Command-Q, the red close button, logout
  or restart) does not ask about an edited untitled document. Its text is first written to its
  recovery copy, confirmed on storage and read back; only then may TextTank quit without asking. At
  the next launch those tabs reopen without a question, in their saved order, group and pin state,
  with their text, caret and selection, language, encoding and line endings, still untitled and still
  marked edited, and a status message says how many were restored. Undo history is not kept: a
  recovery copy holds text only. This applies to untitled documents only. A file with unsaved edits
  keeps the Save / Don't Save / Cancel review at quit, and closing one untitled tab (its close
  button, File > Close, Command-W) still asks. A document whose copy cannot be verified, that is
  larger than 256 MiB, or that falls beyond 256 documents or 512 MiB of kept text in one quit, is
  reviewed as before: text is never dropped to meet a bound. After a crash the same silent reopening
  applies to untitled recovery copies; a recovery copy that belongs to a file keeps the Recover
  question. The stored setting "Keep unsaved untitled documents when quitting" (`keepUntitledOnQuit`,
  on unless stored off) turns all of this off and restores the earlier behaviour exactly.

- DS-D10. **Local history on save.** Each successful Save or Save As of a file keeps a private
  **earlier version**: the bytes just written, and before them the bytes that save replaced when
  history does not already end with those, so the version before the newest is exactly what the
  file held before that save. TextTank keeps the last 20 versions of a file, for at most 30 days,
  and at most 200 MB in all, removing the oldest first; a save larger than 32 MiB is not kept, and
  identical consecutive versions are kept once. The copies are in TextTank's private support
  folder, never beside the document, and never leave the Mac. Nothing is kept for an untitled
  document or for Save Copy. Compare > Compare with Earlier Version… lists a file's versions by
  date and size and opens the existing comparison on the one chosen against the current text;
  the earlier side is read-only, and restoring is that comparison's Apply Selected Changes: one
  Undo step in the document, which is written only when the person saves. Compare > Clear Local
  History… deletes the versions of the current file or of every file after a confirmation sheet
  (DS-41, DS-43, DS-44) and changes no file. The stored setting "Keep earlier versions when
  saving" (`keepLocalHistory`, on unless stored off) stops new versions from being kept.

- DS-D11. The Workspace Browser is a sidebar docked at the leading edge of the workspace window, beside
  the editor groups. The floating Workspace panel is retired and nothing opens a second presentation.
  View > Workspace Browser is a toggle with a checkmark (DS-22). The sidebar draws on the window's own
  background, with no material or translucency (DS-11). Its width is between 260 and 480 points and is
  remembered with whether it was shown. While it is shown the window's minimum width grows by the
  sidebar's minimum and its divider, so the editor groups keep the minimum their layout always had; a
  narrowing window takes width from the sidebar first, and hiding it restores the usual minimum (DS-67).
  Showing it moves the keyboard only when the person chose the command; Escape or the same command
  returns the keyboard to the text (DS-73). `docs/tab-model.md` has the contract.

- DS-D13. **The View menu is regrouped, and gains change bars and a centered text column.** (DS-D12
  is recorded by another change of the same day.) View's top level lists fourteen items: Preview ▸ |
  Split Tab View | Wrap Lines, Show ▸, Centered Text Column | Zoom In, Zoom Out, Actual Size |
  Folding ▸, Syntax Highlighting ▸ | Workspace Browser, Editor Groups ▸ | Show Toolbar, Customize
  Toolbar…. **Preview** holds Source, Preview, Both and Toggle Preview, then Sync Scrolling in Both,
  a checkmark for the stored `syncPreviewScrolling` setting that the Settings row also shows; all
  of it is disabled for a document with no preview (DS-21). **Split Tab View** is one toggle with a
  checkmark (DS-22): it splits the tab and closes the split. Close Split View has no row; its
  action remains, and a shortcut saved for it is read as Split Tab View's unless that command has
  a saved shortcut of its own. **Show** holds Line Numbers, Whitespace, Line Endings | Indentation
  Guides, Current Line Highlight, Matching Braces | Change Bars. An item there is titled by what
  it shows (DS-24); the Command Palette and Settings name the command in full ("Show Line
  Numbers"). Guides and Highlights is no longer a submenu. Every moved command keeps its identity,
  shortcut, validation and macro behaviour, and the Command Palette finds it by its former path
  and name as well as its new one.
  **Change Bars** (stored `changeBars`, off unless stored on, for every editor view): a narrow
  margin beside the text marks the lines changed since the document was opened, from Scintilla's
  change history. A change that is not saved is a wide amber bar; a saved one is a narrow green
  bar at the left; a line undone to its original text after a save is a hollow amber bar in the
  middle, so no state is carried by colour alone (DS-61, DS-62). The record starts only while a
  document has no Undo history, and Undo is never cleared to start it: a document edited before
  the toggle shows the margin with no bars, its tab says so, and its record starts when it is
  reverted or reopened. Turning the toggle off hides the margin and keeps the record. There are
  no change bars in large-file mode or in a comparison.
  **Centered Text Column** (stored `centeredColumn`, off unless stored on, and
  `centeredColumnWidth`, 90 characters, 40 to 240): the text is laid out between equal margins
  around a column that wide in the editor font, recomputed when the pane, the zoom or the font
  changes. The line-number gutter stays at the pane's leading edge. It changes no text and
  implies nothing about wrapping; a pane narrower than the column, and a comparison, keep the
  ordinary layout.

## 3. Rules

### Windows and tabs

- DS-10. The text is the principal surface. Chrome that is not in use is hidden (the find bar is hidden
  until Find is chosen).
- DS-11. Standard window chrome: a real `NSToolbar`, the system title bar, no custom materials, no
  `NSVisualEffectView`, no transparent title bar, no hand-drawn buttons that imitate system ones.
- DS-12. Closing one tab, closing the window and quitting are three separately specified behaviours
  (DS-D2). Each keeps the Save / Discard / Cancel review, and Cancel leaves everything as it was.
  The one exception is DS-D9: at quit an untitled document's unsaved text is kept, after its recovery
  copy is verified, instead of being reviewed. Closing a single untitled tab still asks.
- DS-13. Full screen must work in the workspace window. Native transitions remain system behavior.
- DS-14. A tab is a tab to assistive technology: tab role, a label of the form "name, edited", an
  in-place update rather than a rebuild, and a close target of at least 28 by 28 points that does not
  abut the tab's own target. Tabs shrink before the strip scrolls.
- DS-15. Auxiliary windows are `ToolPanel`s: they cannot become main, Escape closes them, and their frames
  are remembered. A command started from a panel acts on the document captured before any prompt and is
  rechecked by revision before it applies.

### Commands, menus and shortcuts

- DS-20. One definition per command. Its title, shortcut, enabled state, checkmark and Undo name are the
  same in the menu bar, toolbar, context menu, palette and macros.
- DS-21. A command that cannot run is disabled by validation. It is not offered and then refused with an
  alert after the click.
- DS-22. A toggle shows a checkmark. An item that opens a dialog for more input ends with an ellipsis.
- DS-23. No menu level lists more than about twenty items. Group with submenus and separators by what the
  command acts on.
- DS-24. Menu and button titles are words a person would say. Never show a stored identifier, enum raw
  value, UUID or file-format key (for example "UTF-8 with BOM", never "utf8bom").
- DS-25. System shortcuts keep their meaning and cannot be reassigned: Command-Q, W, H, M, comma, backtick,
  Option-Command-H, and the Find set (Command-F, G, Shift-Command-G, E).
- DS-26. File has New, Open, Open Recent (with Clear Menu), Close, Save, Save As, Revert, Page Setup and
  Print. Help has at least one item of its own.
- DS-27. Undo and Redo name the action once the command catalogue exists ("Undo Sort Lines").

### Toolbar

- DS-30. Toolbar items are standard `NSToolbarItem`s with an SF Symbol and a label, for the actions used
  most. The toolbar is customisable and remembers its arrangement.
- DS-31. The toolbar does not repeat a control the tab strip or title bar already provides (DS-D3).

### Find

- DS-35. There is one Find. Command-F opens and focuses the find bar; Return finds the next match,
  Shift-Return the previous one, Escape or Done closes it. Find Next, Find Previous and Use Selection for
  Find share its text with the system find pasteboard. The Find and Replace window (Option-Command-F) adds
  scopes, modes and results; while it is open, Find Next and Find Previous act on it. The bar and the
  window show one Find text and one replacement, live, and offer one history of the last ten of each. A
  new launch starts in Normal mode with an empty Find field.
- DS-36. A search that finds nothing says so in words, visibly, and is announced (DS-62).

### Alerts, sheets and dialogs

- DS-40. An alert is for a decision that cannot be handled in place. Never use one to report routine
  success; show a quiet status message instead.
- DS-41. Return never triggers a destructive action. A button that deletes, discards, removes or replaces
  something that Undo cannot bring back is marked `hasDestructiveAction`; when it is the first button,
  Return and Escape both cancel.
- DS-42. Every alert has a way out that Escape reaches. Buttons are verbs that name the outcome
  ("Replace Files", "Send 12 Items"), not "OK" or "Yes" where a verb fits.
- DS-43. A confirmation states what will change, how much, and whether it can be undone, in the person's
  terms: the text, the counts, the destination.
- DS-44. Settings, managers and editors are windows or sheets, not alerts with accessory views. Do not add
  a new app-modal management screen; the count of `runModal` call sites may only go down (section 6).
- DS-45. A dialog that rejects input keeps what was typed and marks the field. It does not close and make
  the person start again.

### Status and truthfulness

- DS-50. A save indicator never overstates durability. An edited document reads "Edited", never "Saved".
- DS-51. Progress is real or indeterminate. No invented percentages.
- DS-52. An action with an effect outside the app (Reminders, files on disk, a shell command) reports what
  actually happened per item, never implies a failed hand-off succeeded, and never retries an uncertain
  result on its own.
- DS-53. Editor Undo is never described as reversing an external effect.

### Colour, contrast and appearance

- DS-60. Chrome uses semantic `NSColor`s. Editor colours come in light and dark pairs, applied when the
  appearance changes. No new literal colour in chrome.
- DS-61. Text is at least 4.5:1 against its background; marks, indicators and other non-text cues are at
  least 3:1, in light and in dark. Selection uses the system selection colours.
- DS-62. State is never carried by colour alone or by sound alone. A beep comes with words in the status
  line and an announcement.
- DS-63. Honour Increase Contrast, Reduce Transparency and Reduce Motion. Do not add custom animation
  without a sentence saying what it communicates.

### Typography and layout

- DS-65. Controls use system fonts by role. Brand typefaces are for the identity only, never for native
  controls. The count of literal font sizes may only go down (section 6).
- DS-66. macOS has no Dynamic Type. The editor provides its own text size control.
- DS-67. Layout is Auto Layout. Nothing wraps, truncates essential text or overlaps at the minimum window
  size. The status bar is one row that collapses by priority.

### Accessibility

- DS-70. Every control has an accessibility label that states the action and its scope ("Find in
  document", "Close notes.txt"). Image-only buttons always have one.
- DS-71. The text area is named after its document, and after its pane in a split view.
- DS-72. A result that only changes a label is announced: use `Announce.say` for one-off messages and
  `AnnouncingLabel` for a tool window's status label. Do not announce progress ticks.
- DS-73. Every task can be completed from the keyboard, including leaving any dialog.
- DS-74. Mac control sizes: 28 by 28 points by default, 20 by 20 at the least.

### Writing

- DS-80. One noun per object, everywhere: **document**, **tab**, **window**, **automation**, **rule** (a
  step of an automation), **favorite** (an automation listed first in the Automations drop-down and editor context menu), **macro**, **Run command**,
  **workspace**, **session**, **recovery copy**, **earlier version** (a copy local history kept at a
  save, DS-D10). Do not introduce synonyms (workflow, step, snapshot,
  draft, batch, root).
- DS-81. Plain, active sentences. An error says what happened, what was not changed, and what to do next.
- DS-82. No developer vocabulary in user text: no identifiers, UUIDs, "transaction", "root(s)", "id".
- DS-83. Counts read correctly: "1 file", "3 matches". Do not write "file(s)". The number of "(s)"
  plurals may only go down (section 6).
- DS-84. Do not build a sentence by joining fragments. New strings are whole sentences so that they can be
  moved to a string catalogue without rewriting.
- DS-85. Empty states and tooltips say what the thing is for and what to do next.

### Recovery and Undo

- DS-90. A text transformation acts on the focused document, preserves the original, is one Undo step, and
  leaves the text untouched if it fails or is cancelled.
- DS-91. Prefer a reversible action to a confirmation. Confirm only what cannot be cheaply recovered.
- DS-92. Reopening should resume the work: unsaved text is kept as a recovery copy, and the same
  documents reopen at the same place. Files reopen from the last session. Untitled documents with
  unsaved text reopen from their recovery copies, without a question, after a quit or a crash
  (DS-D9); a quiet status message says so (DS-40). A recovery copy that belongs to a file is offered
  through the Recover question, and the file itself is never changed by recovery.

### Permissions and privacy

- DS-95. Ask for a permission at the moment the feature that needs it is invoked, never at first launch.
- DS-96. Declined, restricted and revoked are ordinary states: explain them, offer the way to System
  Settings, and keep everything unrelated working.
- DS-97. Nothing leaves the Mac without an explicit choice for that action. No implicit execution, upload
  or download.

### Responsiveness

- DS-100. Work that can take longer than about 100 ms after a discrete action runs off the main thread,
  can be cancelled, and has its result dropped if the document changed meanwhile.
- DS-101. A claim about speed needs a measurement on a representative large file.

### Belonging to the system

- DS-105. A file dropped on the text opens as a document. Recent documents are recorded with the system.
- DS-106. System integrations (Services, Share, Shortcuts) call the same validated command path as the
  interface. An integration never performs in the background what the interface would ask about first.

## 4. Checklist for any change that touches the interface

Copy this into the unit result or pull request and answer each line.

- [ ] Which rules apply (ids), and does the change meet each?
- [ ] Any departure, with the rule id, the benefit and the evidence?
- [ ] Reachable from the menu bar and from the keyboard?
- [ ] Disabled, checked and enabled states correct in every surface that shows the command?
- [ ] New or changed controls have accessibility labels; results are announced?
- [ ] New or changed wording follows the glossary and reads as a whole sentence?
- [ ] Light and dark both considered; contrast of any new colour stated?
- [ ] Cancel, failure and interruption each leave the document as it was?
- [ ] A check exists that fails without the change?
- [ ] `scripts/check-design-standards.py` passes without raising a budget?
- [ ] What was not verified in the running app?

## 5. Review rubric and release gates

Score each category 0 (broken), 1 (needs substantial work), 2 (good with known gaps) or 3 (demonstrated in
representative tasks). A score of 3 needs an observed task, not a code reading. Do not use a total to
excuse a single failure.

| Category | Question | Score at the 15 Nov 2026 review |
|---|---|---|
| Purpose | Can a new user identify and complete the primary job? | 2 |
| Structure | Are location, selection, scope and next action clear? | 1 |
| Platform fit | Do familiar controls, commands and windows behave as expected? | 1 |
| Legibility | Does hierarchy survive appearance, content and window changes? | 1 |
| Accessibility | Can the task be completed through assistive inputs? | 1 |
| Recovery | Can a mistake or interruption be resolved without avoidable loss? | 2 |
| Responsiveness | Does feedback track the current action accurately? | 2 |
| Trust | Are permissions, external effects and save states truthful? | 2 |

The fixes made on 15 November 2026 addressed the status line, destructive defaults, mark contrast, editor
naming and announcements, Find, the Edit menu, Open Recent and file drops, per-document settings, and the
Reminders declined path. They have not been observed in the running app, so the scores above stand until
someone does.

**Release-blocking:** data loss; a primary task that cannot be reached through an intended input; an
external action falsely reported as complete; an essential control that cannot be read; a save indicator
that overstates durability. Fix these before any polish.

## 6. The automated guard

`scripts/check-design-standards.py` reads `docs/design-budget.json` and fails when a count rises above its
budget or a hard rule is broken.

| Key | What is counted in `Sources/` | Rule |
|---|---|---|
| `app_modal_calls` | `runModal(` call sites | DS-44 |
| `literal_font_sizes` | `ofSize:` followed by a number | DS-65 |
| `literal_colours` | `NSColor(` built from component values | DS-60 |
| `lazy_plurals` | string literals containing `(s)` | DS-83 |
| `beeps` | `NSSound.beep()` | DS-62 |
| `custom_materials` | `NSVisualEffectView`, transparent title bars | DS-11 |

Hard rules, with no budget:

- A button whose title begins with Delete, Remove, Discard, Erase or Reset is marked
  `hasDestructiveAction` within the next three lines, unless its title ends with an ellipsis (it leads to
  a confirmation) or the line carries a `// design-ok: <reason>` comment (DS-41).
- `tabbingMode` is never set to `.preferred` or `.automatic` (DS-D1).

A budget may be lowered whenever the count drops; the script prints a reminder when it can be. Raising a
budget is a departure and needs the owner's agreement.

## 7. Known gaps, in the order they should close

These are the remaining actions from the review. Each names the work that owns it.

1. The typed command catalogue, current-key and toggle validation are implemented by audit 25. Precise Undo/Redo action labels remain an explicit DS-27 gap; Scintilla history provenance has not been replaced or guessed. App declarations and typed service/application boundaries are split by audit 29; the product remains one Swift target.
2. The workspace-window host, full screen and tab accessibility (DS-D1, DS-13, DS-14): tab stage 0.
3. Session restore and recovered copies that keep their file (DS-92): tab stage 4 and package 23.
4. Physical toolbar customization and VoiceOver interaction remain unverified. Standard items, favorites, native accessibility names and isolated configuration round trips have native check coverage (DS-30, DS-70).
5. Physical keyboard and VoiceOver interaction with Settings and the automation, macro and Run managers remain unverified. Modeless windows, owned Rules/JSON sheets, explicit Save/Cancel working copies, retained invalid input, filtered pickers and scoped native accessibility names have native check coverage (DS-44, DS-45, DS-70).
6. Physical keyboard and VoiceOver interaction with the status row remain unverified. One-row native pop-ups, actual scoped accessibility names, minimum-width collapse/restoration, truthful save/recovery state and relocated options have native check coverage (DS-50, DS-67, DS-70).
7. Glossary, plurals and a string catalogue (DS-80 to DS-84); labels on every dialog field (DS-70):
   package 26.
8. Measured responsiveness on large files (DS-100, DS-101).
9. Services, Share and Shortcuts (DS-106). Distribution (DS-D5). Bundled help (DS-26).

## 8. Sources

Apple Human Interface Guidelines: Designing for macOS, Toolbars, Sidebars, Menus, Keyboards, File
management, Alerts, Undo and redo, Accessibility, VoiceOver, Color, Typography, Layout, Motion, Materials,
SF Symbols, Writing, Onboarding, Privacy (developer.apple.com/design/human-interface-guidelines). Apple
developer documentation: Improving app responsiveness; Testing system accessibility features in your app;
Sufficient contrast evaluation criteria. The numeric contrast and control-size figures are the
conservative gates this project adopted from that guidance, not Apple certification criteria.
