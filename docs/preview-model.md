# Preview model

This document describes the preview in two parts. The first is the Foundation-only preview core
in `Sources/Preview/`. It is part of TextTankCore: it has no AppKit or WebKit dependency, reads no
files and opens no network connection. The second, [Presentation](#presentation), is the
per-tab Source, Preview and Both views built on it: a web view with page JavaScript disabled for
Markdown, HTML and SVG, a table view for delimited text and an outline view for JSON. The
presentation files are in the same folder and belong to TextTankRuntime.

Every entry point is a pure function of its input. Each one

- takes the document as `String` or UTF-8 `Data`;
- enforces the limits in `PreviewLimits` and reports a typed `PreviewLimit` whose `message` is a
  whole sentence for the user (DS-81 to DS-84);
- takes `isCancelled: () -> Bool`, polled about every 4 KiB of input, and returns a `.cancelled`
  case. The default is `{ Task.isCancelled }`, which reads the task that calls the function and so
  works from `Task.detached`. Run these functions off the main thread (DS-100).

`Tests/PreviewCoreChecks.swift` (run by `scripts/test-preview.sh`) checks everything stated here.
Timings printed by that suite are from the unoptimized Debug build and are not a speed claim
(DS-101).

## Which documents have a preview

`PreviewKind.kind(languageID:fileExtension:)` decides, in this order:

1. extension `csv` → comma-delimited; `tsv` or `tab` → tab-delimited; `svg` → SVG. These win over
   the language.
2. language `markdown`, `html` or `json` → that preview.
3. language `json5` or `jsonc` → no preview, whatever the extension. Only strict JSON has a tree.
4. extension `md`, `markdown`, `mdown`, `mkd`, `mkdn` → Markdown; `html`, `htm`, `xhtml` → HTML;
   `json` → JSON.
5. otherwise no preview.

Extensions are compared without regard to case. An untitled document has no extension, so it is
decided by its language alone. No language identifier selects SVG or delimited text: **an SVG,
CSV or TSV document must be saved with its extension before it can be previewed.**

## Limits

| Limit | Value | Result when reached |
| --- | --- | --- |
| Source size, every kind | 8 MiB | nothing is parsed; `.limited(.sourceTooLarge)` |
| Markdown output | 16 MiB of HTML | nothing is returned; `.limited(.outputTooLarge)` |
| Markdown block quote and list nesting | 32 levels | deeper markers are shown as text |
| Markdown table columns | 4,096 | a wider header is not a table; its lines are shown as text |
| Markdown table cells, empty ones included, in a document | 1,000,000 | nothing is returned; `.limited(.tooManyTableCells)` |
| Delimited rows | 100,000 | later rows are left out; `limitsReached` has `.tooManyRows` |
| Delimited columns | 512 | later cells of a row are left out; `.tooManyColumns` |
| JSON values | 500,000 | the tree so far is returned with `.tooManyValues` |
| JSON nesting | 512 levels | the tree so far is returned with `.nestedTooDeeply` |
| Local file served to a page | 8 MiB | the file is refused (`.tooLarge`) |

Further fixed caps keep adversarial Markdown linear: 32 open brackets per paragraph, 2,048 bytes
for a link destination or title, 999 bytes for a reference label, 32 nested parentheses in a
destination, and 131,072 bytes read per paragraph by attempts to read `(destination "title")`
that found no link (after that the paragraph has no more inline links; reference links still
work). At most 1,000 external references and 100 delimited-text diagnostics are listed; the
totals are still counted.

A table row is stored with the cells it has. A row shorter than its header is padded with empty
cells only as it is written, under the output limit, so a wide header with many short rows
cannot ask for more memory than the limits allow.

## Markdown

`MarkdownRenderer.render` turns Markdown into an HTML fragment (the content of `<body>`). The
dialect is **the CommonMark core with GitHub tables and task lists, without raw HTML**. No
third-party code is used.

### Supported

Blocks:

- ATX headings (`#` to `######`, optional closing `#`s) and setext headings (`===`, `---`).
- Paragraphs. A line ending with two or more spaces, or with a backslash, is a hard break
  (`<br />`).
- Fenced code blocks with backticks or tildes; the first word of the info string becomes
  `class="language-…"`. A fence that is never closed runs to the end of its container.
- Indented code blocks (four or more columns).
- Block quotes, nested, with lazy continuation lines.
- Bullet lists (`-`, `+`, `*`) and ordered lists (`1.` or `1)`, start number kept), nested by
  indentation, tight or loose as in CommonMark, with lazy continuation lines.
- Task-list items: an item starting `[ ] ` or `[x] ` gets a disabled checkbox.
- GitHub pipe tables with a delimiter row and `:--`, `:-:`, `--:` alignment. Rows are padded or cut
  to the header's column count; `\|` is a literal pipe.
- Thematic breaks (`***`, `---`, `___`).
- Link reference definitions, `[label]: destination "title"`, anywhere in the document, including
  inside quotes and lists. The first definition of a label wins.

Inlines:

- Emphasis and strong emphasis with `*` and `_`, using the CommonMark delimiter rules: flanking,
  no intraword `_`, and the "multiple of three" rule.
- Code spans with any number of backticks.
- Inline links, `[text]` followed by `(destination "title")`, including `<destination with spaces>` and balanced
  parentheses; full, collapsed and shortcut reference links; images with the same forms.
- Autolinks `<https://…>` and `<name@example.com>`.
- Backslash escapes of ASCII punctuation.
- Entity references (`&amp;`, `&#169;`, `&#xA9;`) are passed through unchanged, so the reader sees
  the character.

Output follows the CommonMark reference renderer's layout: one block per line, `<p>` omitted in
tight lists, `<hr />`, `<br />`, `<img … />`.

### Which lines a block came from

`MarkdownRenderer.renderWithScrollMap` returns the same fragment and, beside it, a
`PreviewScrollMap`: one entry for each top-level block, in order, with the zero-based source line
it starts on, the number of lines it was made from, and a fingerprint (a hash of those lines).
The renderer writes exactly one element at the top level for each entry, so entry *n* is the
*n*th child of the page's `<body>`. The HTML carries no mark for this and is byte for byte what
`render` returns. Blank lines and link reference definitions belong to no entry. Lines end at LF,
CRLF or CR, as the editor counts them. A block inside a quote or a list item has no entry of its
own; its place is a fraction of the top-level block that holds it.

- `position(forLine:)` gives a block and a fraction from 0 to 1 through it; `line(for:)` gives
  one of the block's own lines back. Both cost a binary search or less.
- `counterpart(of:in:)` finds a block in the map of a later rendering. An edit below a block
  leaves its number alone and an edit above it moves it by the change in the number of blocks;
  the block's fingerprint decides between the two, and the eight blocks after it decide when its
  own text was edited or repeats. The cost does not depend on the size of the document.

### Deliberate differences from CommonMark

These are decisions, not gaps:

1. **Raw HTML is escaped, never passed through.** HTML blocks and inline HTML appear as the text
   that was typed (`<b>` shows as `<b>`). The output therefore contains only the tags this renderer
   writes: `p`, `h1`–`h6`, `em`, `strong`, `code`, `pre`, `blockquote`, `ul`, `ol`, `li`, `a`,
   `img`, `br`, `hr`, `table`, `thead`, `tbody`, `tr`, `th`, `td`, `input`.
2. **Link and image addresses are restricted.** Only `http:`, `https:`, `mailto:` and relative
   addresses are written. For any other scheme (`javascript:`, `data:`, `file:`, `ftp:`, …), an
   address that starts with `//` (another computer, with no scheme named), or an address
   containing a control character, no tag is written: a link keeps its text and an image keeps
   its description. An autolink with another scheme stays literal text.
3. **Entities are not decoded.** A well-formed entity reference is copied to the output rather
   than replaced by its character, and its name is not checked against the HTML list. Entities are
   never recognized inside a link destination (`&amp;` there is the five characters), so that an
   address cannot change after it has been checked.
4. **Addresses are not percent-encoded.** They are written as typed, HTML-escaped.

### Simplifications

Places where rare input renders differently from CommonMark:

- A link reference definition must fit on one line, title included.
- A lazy continuation line is recognized from the previous line of the quote or item alone: it is
  accepted after any non-blank line that is not inside a fenced block and is not a heading or
  thematic break. After an indented code line inside a quote or item, an unindented line therefore
  continues the code instead of ending the container.
- Tab stops are counted from the start of each container's content, not from the start of the
  source line. Text indented with tabs inside nested containers can be read one level differently.
- A table needs a pipe in both its header line and its delimiter line. Pipes inside code spans
  split cells unless escaped, as on GitHub.
- When a setext underline follows a paragraph that consists only of reference definitions, the
  underline is shown as text.
- Block quotes and lists stop nesting at 32 levels, and brackets at 32 per paragraph; beyond that
  the markers are literal text.
- Not supported: hard-wrapped multi-line link titles in definitions, footnotes, strikethrough,
  extended autolinks without angle brackets, heading anchors, and HTML blocks (see above).

## HTML

`StaticHTMLPolicy` supplies the text-level half of a static, offline page. The web view supplies
the other half and must not rely on this half alone: JavaScript disabled, a content rule list that
blocks all network loads, and a handler for the `texttank-preview` scheme (`PreviewScheme.name`)
that sends the content security policy as a response header.

**Which layer enforces the policy.** The policy in force is the `Content-Security-Policy`
response header (see [The web view](#the-web-view-markdown-html-svg)). The `<meta>` tag that
`prepare` and `wrapFragment` write is a second copy and is not relied on, because markup in a
user's document can defeat a `<meta>`: a browser honours one only inside the real head, and the
scan below is a tokenizer, not an HTML parser. It takes for the head a `<head>` written after the
body has begun, inside a title, a text area, a template, a comment in a script or an `svg`
element, or one that is never finished, and it adds a head after an `<html>` tag that follows
content. A `<base>` written before the tag is also out of the tag's reach. The checks load each
of these documents and observe the header's policy refusing what it should.

- `contentSecurityPolicy(scheme:)` is
  `default-src 'none'; img-src texttank-preview:; style-src texttank-preview: 'unsafe-inline'; font-src 'none'; script-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'`.
- `wrapFragment(_:title:stylesheet:)` builds a complete page around rendered Markdown or the SVG
  image tag: charset, the policy, an escaped title, and the stylesheet in a `<style>` element. The
  stylesheet is the bundled `Resources/Preview/preview.css`
  (`PreviewStylesheet.resourceName`/`resourceExtension`), which uses system colours and the system
  font and loads nothing.
- `prepare(html:)` takes the user's HTML document and inserts the policy `<meta>` after the first
  `<head>` tag the scan finds. Without one, a head is created after the `<html>` start tag, else
  after the doctype, else at the start. Nothing else is rewritten. It also returns a
  `PreviewContentReport`:
  - `externalReferences`: `http:`, `https:` and `//` addresses the page asks to load — `src`,
    `href`, `xlink:href`, `poster`, `data`, `background`, `srcset` and `imagesrcset` of `link`,
    `img`, `script`, `iframe`, `frame`, `source`, `video`, `audio`, `object`, `embed`, `track`,
    `input`, `image`, `use` and `feImage`, plus `url(…)` and `@import` in `<style>` elements and
    `style` attributes. Ordinary links (`<a href>`) and form targets are not loaded resources.
  - `scriptCount`: `<script>` elements, `on…` event-handler attributes, and `javascript:`
    addresses.
  - `hasBaseTag`: a `<base>` tag exists. The header's `base-uri 'none'` makes the browser ignore
    it wherever it is written; the `<meta>` copy alone would not stop one written before it.

The scan uses a tolerant tokenizer, not a parser: it reads tags and attributes in any case, quoted
or not, and skips comments, CDATA sections and the text of script and style elements. A script or
style element ends at its end tag's name followed by a space, a slash or `>`; `</scriptx` does
not end a script. It reports
what the *source* asks for; the web view's own rules are what actually block it. Serve the
prepared document as `text/html; charset=utf-8`.

`PreviewSummary.text(blockedExternalResources:scriptsNotRun:missingLocalFiles:)` gives the status
line, for example "1 external resource was blocked. 2 scripts were not run. 1 local file could
not be found." It returns nil when there is nothing to say.

### Local files

`PreviewResourceResolver` decides what the scheme handler may serve. Given the saved document's
URL and the path of a requested preview URL (still percent-encoded), it answers
`.allowed(fileURL, mimeType:)` only when all of these hold:

- the document is a saved local file (otherwise `.untitledDocument`);
- the document is not saved directly in the person's home folder or at the top of the disk
  (otherwise `.documentFolderTooBroad`): "the document's folder" would then be everything the
  person owns, or the whole disk. A subfolder of the home folder is an ordinary folder;
- the path, after percent-decoding and removing `.` and `..`, is inside the folder that contains
  the document, subfolders included (otherwise `.outsideDocumentFolder`). A leading slash does not
  make a path absolute;
- the same is true of the file's real location after symbolic links are followed;
- the extension, of the name and of the real file, is one of `css`, `png`, `jpg`, `jpeg`, `gif`,
  `webp`, `svg`, `bmp`, `ico`, `avif`, `heic` (otherwise `.typeNotAllowed`);
- it is a regular file (otherwise `.missing`) of at most 8 MiB (otherwise `.tooLarge`).

A null byte or malformed percent-encoding is `.missing`. Symbolic-link resolution, file size and
the home folder are injected with real defaults, so the rules are tested without touching the
disk. SVG is served only as `image/svg+xml` for use in `<img>`. Anywhere it could act as a
document it is refused twice: by `frame-src 'none'` and `object-src 'none'` of the policy in the
response header, and by the navigation rule, which cancels every load into a frame.

## Delimited text

`DelimitedTable.parse(_:delimiter:)` reads comma- or tab-separated text in the style of RFC 4180:
values may be wrapped in double quotes; inside quotes a doubled quote is one quote, and
delimiters and line breaks (LF, CRLF, CR) are text. The delimiter must be an ASCII character;
any other is a programming error and stops the program (`PreviewKind` only ever gives a comma or
a tab). A byte order mark is skipped. A line break at
the very end does not start another row; an empty line elsewhere is a row with one empty cell.

**Every value stays text exactly as written.** Nothing is trimmed, converted or evaluated:
`007`, `=SUM(A1)`, `+1`, `1e5` and ` padded ` are shown as typed.

The table reports `rowCount`, `columnCount` (the widest row), `rowLines` (the 1-based source line
each row starts on), `cell(row:column:)` (empty text where a row is shorter), `row(_:)`,
`diagnostics` and `limitsReached`. Cells are stored as one byte buffer with an offset per cell
rather than as a `String` each, so a table view should ask for the cells it shows.

Malformed quoting is tolerated and reported with 1-based row numbers:

- a quoted value that is never closed takes the rest of the document as one value
  (`.unterminatedQuote`);
- a quote inside an unquoted value is kept literally (`.strayQuote`);
- a value with text after its closing quote is every byte between its delimiters, quotes
  included (`.strayQuote`): `"a"b` is shown as `"a"b`, not `ab`. The sentence for it says "It
  is shown as written", and that is what is done.

Bytes that are not valid UTF-8 are shown as the replacement character. The first row is data;
there is no header detection.

## JSON

`JSONTree.parse` reads strict JSON (RFC 8259) into a flat array of `JSONNode` in document order,
iteratively, so depth is bounded by the limit and not by the stack. It **preserves the source**:

- members keep their order, and duplicate names are all kept;
- numbers are never converted — `displayValue` is the literal as written (`1.0`, `1e400`,
  `123456789012345678901234567890`);
- strings are decoded for display (escapes, surrogate pairs; a lone escaped surrogate becomes
  U+FFFD) and `rawText` returns the literal as written;
- each node has its kind, name range, position in its parent, parent, child count, byte range in
  the source, and 1-based line and column (columns count Unicode scalars).

Outcomes:

- `.empty` — the document is empty or only whitespace;
- `.parsed(tree)`;
- `.invalid(partial:error:)` — the tree of everything read before the error, with containers that
  were still open closed at the error, and a `JSONSyntaxError` with kind, byte offset, line,
  column and a message such as "Expected a comma or closing brace at line 12, column 5.". The
  offset is that of the offending byte, or the length of the document when the text ends too
  soon (`unexpectedEnd`), which is where Go to Error then puts the caret;
- `.limited(partial:limit:)`;
- `.cancelled`.

The parser is strict: comments, trailing commas, single quotes, unquoted names, leading zeros
(`00012…`), `NaN`, raw control characters in strings and invalid UTF-8 are errors, each with its
location. A byte order mark is skipped.

A node is 100 bytes or so; a tree at the 500,000-value limit uses about 50 MB while it is shown.

## SVG

SVG is shown as an image: `SVGPolicy.wrapper(imageURL:title:stylesheet:)` builds a page whose only
content is `<img src="…">` pointing at a preview-scheme URL that serves the document's current
text. An SVG loaded by `<img>` runs no scripts and loads nothing it refers to.

`SVGPolicy.scan` tells the user what the image contains that an image cannot do, using the same
report and summary as HTML: script elements and event handlers, and external `href`/`xlink:href`
of `image`, `use`, `script` and `feImage`, `@import` and `url(…)` in styles. `isSVG` is true when
the first element is `svg` (or a prefixed `…:svg`); when it is false, show
`SVGPolicy.notSVGMessage` ("This document is not an SVG image.").

## Presentation

`Tests/PreviewNativeChecks.swift` (run by `scripts/test-preview-ui.sh`) checks what this section
states, unless the section says it is not verified. The checks drive the real tab adapter,
coordinator, presenters and web view against the signed frameworks, and pass with the screen
locked.

### Source, Preview and Both

Every tab shows one of three modes of its document. **Source** is the editor, and the default.
**Preview** is the read-only preview alone. **Both** is the editor and the preview side by side
with a divider that can be dragged. View > Preview has the three commands, with a checkmark on the
one that is showing (DS-22). They have no shortcut. They are disabled for a document that
`PreviewKind.kind` gives no preview (DS-21). The other ways to change the mode are described
under "Switching the mode" below; all of them end in the same `chooseViewMode` (DS-20). When a document stops having one, because its
language was changed or it was saved under another extension, its tab returns to Source and the
status line says "This kind of document has no preview. The tab shows Source again."

A mode change only rearranges views (`DocumentViewContainer`). The tab's own split view, which
holds the editor and its clone, is the container's first pane and is never removed or rebuilt:
Preview hides it. Nothing is saved, reloaded or shared again and Undo is not touched, so the
bytes, revision, selection, scroll position, clone split, Undo history and file are the same
after any number of changes. In Both each pane keeps at least 120 points while there is room for
two; below that the width is shared equally, so nothing overlaps (DS-67). The divider's position
is a fraction of the width and changes only when it is dragged. In a preview narrower than 320
points the Go to Error button goes under its sentence instead of beside it, so the sentence
keeps the width of the pane and may use six lines instead of three.

Keyboard: showing Preview moves the keyboard to the preview. In Both, choosing View → Both
again moves it from the source to the preview or back; Tab from the table or the tree goes to
the source. While only the preview shows, Find, Find and Replace, Go to Line and Go to Error
first put the source beside it, and so does anything else that puts the keyboard in a source
pane. Making the tab active through its own chrome, such as a status-row menu opened while
another editor group has the keyboard, is not one of those: the keyboard then goes to the
preview and the tab keeps showing Preview. Commands that change text still act on the document,
and Undo and Redo chosen from the preview go to the document. The pane and each presenter are
labelled "Preview of <name>" (DS-70, DS-71). The message row announces its changes, and so does
every sentence shown in place of the content: an empty document, a limit, "not ready yet",
"cannot be shown" and "stopped twice" (DS-72).

The mode is part of a tab's session record (see [tab-model](tab-model.md)). A restored mode is
applied only to a document that still has a preview. When a whole layout is restored, the keyboard
goes to the pane the session recorded as the one in use (the clone pane when that was it), or to
the preview of a tab that shows Preview alone.

### Switching the mode

Besides the three View commands there are four routes. None of them changes what a preview may
load or run.

**Toggle Preview** (View > Preview, directly under Both; Control-Command-V since 24 November 2026, when the owner moved it from Shift-Command-V, which another application can hold system-wide). From Source it shows the
rendered mode the person chose last, Preview or Both, and from either of those it returns to
Source. Until one has been chosen it shows Both. It is disabled for a document with no preview
(DS-21) and carries no checkmark: the three items above it show the mode (DS-22). The shortcut is
a default of the kind Save All and Actual Size have (`DefaultShortcutItem`): a shortcut the person
assigned to the same key in Settings keeps the key, and the menu item then has none. The Command
Palette lists the command because it is a menu item. Like the three mode commands it is a view
change that a macro recording neither records nor is discarded by. Since DS-D13 the mode
commands are in View > Preview, and View's top level lists fourteen items (DS-23).

**The tab's context menu.** A tab whose document has a preview has a section with Source,
Preview and Both, titled as in the View menu, with a checkmark on what that tab shows
(identifiers `tabs.command.viewMode.source`, `.preview`, `.both`). A tab with no preview has no
such section. For the active tab an item behaves as the View command does. For any other tab it
changes that tab where it is: the tab is not selected, the keyboard does not move, and the change
is announced ("notes.md now shows Preview.", DS-72); if that tab's find bar is open, Preview
closes it without giving the keyboard to the editor it hides, and the tab strip does not scroll.
The items are disabled while a comparison
window is in front, while a tab operation or a sheet is in progress, and for a tab that has
closed, as the other tab commands are.

**The mark on the tab.** A tab in Preview or Both shows an eye (`eye.fill`) between its title and
its close button; pressing it returns the tab to Source. A tab in Source whose document has a
preview shows an outlined eye only while the pointer is over the tab; pressing it shows Both. A
tab with no preview has no mark and its title keeps the full width. The mark is a 28 by 28 point
button with four points between it and the title and between it and the close button
(DS-14, DS-74); the title gives up 32 points and truncates at its tail. A press on it never
reaches the tab's own button, so it cannot select the tab or start a reorder. A Control-click or
secondary click on it opens the tab's menu instead. The hovered tab is worked out again when the
tabs move under a still pointer (a tab closes, tabs are reordered) and is
dropped when the window stops being key or TextTank stops being active. A tab narrower
than 162 points does not show the mark that only appears under the pointer, so its title never
has less than the 82 points a tab at the 130-point minimum width has always had; the mark of a
tab in Preview or Both is state and is shown at every width, leaving 50 points of title at the
minimum. The mark's label and tooltip name the document and the result ("Show source for
notes.md", "Show preview beside source for notes.md", DS-70), and while it is shown it is one of
the strip's accessibility children, between the tab and its close button. The tab's own label
ends ", showing Preview" or ", showing Source and Preview", as one whole label for each
combination with pinned and edited (DS-84). Without a pointer the same step is
the tab's accessibility action "Show Preview Beside Source" or "Show Source", and the context
menu (DS-73). The strip brings the mark up to date whenever a mode changes, by any route, and
whenever a document gains or loses its preview.

**The remembered mode.** `lastRenderedPreviewMode` in the settings file is `preview` or `both`.
It is written, as one member, only when the person chooses Preview or Both by hand (the View
commands, the tab's menu, the mark, the accessibility action) and the choice differs from the one
stored. A mode the app sets itself is not remembered: a restored session, a format's Open in
setting, or Find putting the source beside a preview. If the settings file cannot be written the
choice is kept until TextTank quits and no alert is shown (DS-40).

### Opening in Preview or Both

Settings has one choice for each of the five formats (Markdown, HTML, CSV and TSV, SVG, JSON):
Open in Source, Preview or Both. It is a pair of pop-ups, Preview format and Open in, as the
shortcut rows are a pair, because five more rows would not fit a small screen. Every format
starts at Source, so nothing changes until the person changes it. The choice is
`previewOpenModes` in the settings file, a `PreviewFormat` raw value to a `DocumentViewMode` raw
value, with Source recorded by leaving the format out. A file without the member, a format
without an entry and a value this build does not know all read as Source; an entry for a format
this build does not know is kept when another is changed. Both members are Optional additions to
the version-1 settings format (see "Persisted formats" in [architecture](architecture.md)) and
are written atomically like the other settings.

The rule is applied once, by `TextDocument.makeWindowControllers`, when a document that has a
file gets its first tab: File → Open, Quick Open and the Workspace Browser, a file dropped in,
a file named on the command line or opened by URL, and Reopen Closed Tab, whose history records
no mode. It is not applied:

- to a tab reopened from the last session. `AutomaticSession.reopen` suspends the rule
  (`PreviewOpenDefault.suspended`) and the tab's own record decides, including a record of Source;
- to a tab that is already open when the setting changes, or that the person has switched by hand:
  nothing looks at the setting after the tab exists;
- to an untitled document, including a recovery copy, a restored session snapshot and the bundled
  guides. Setting its language to a previewable one later does not switch it;
- on Save As to a previewable extension. The tab stays as it is and gains the mark under the
  pointer;
- to a second view of a document opened in another editor group, which starts in Source as before.

The keyboard goes to what the new tab shows when it is activated: the preview for Preview, the
source for Both. A jump into the source of a tab that shows Preview alone puts the source beside
it first and gives the editor the keyboard: a file opened with a line (the command line or a
`texttank://open` address), and a Find in Folder or Find and Replace result
(`EditorLifetime.activate`), as Find and Go to Line already did. A search action that selects a
match or replaces text without activating the editor (Find Next, Find Previous, Replace and
Replace All from the Find and Replace window, a recorded search) also shows the source first,
through `EditorLifetime.revealSource(of:)`, and leaves the keyboard in the Find window.
Bookmark Matches and Mark do not move the selection and leave the tab as it is.

A value of the wrong JSON type for either member (a number, a list, an entry that is not text)
is not tolerated: like any other member it fails the whole settings file, which is left
unchanged behind the usual notice. Only text is read leniently.

### When the preview is rendered

`PreviewCoordinator`, one per tab, exists only while the tab shows Preview or Both.

- It works only while the tab is open, on screen and not in Source. A hidden tab does nothing,
  even when its document changes through another view; when it is shown again and is stale it
  renders once.
- After an edit it waits for typing to pause: 0.2 s for a small document, growing in proportion
  to the document's size up to 1 s at the 8 MiB limit (`PreviewRenderer.debounceInterval`). Twenty
  edits inside the interval cause one render, of the final text.
- A render takes one immutable copy of the unsaved text on the main actor and runs the core in a
  detached task, at most one per tab. A newer request cancels the older one through the core's
  `isCancelled` hook. The result is applied only if the tab is still live and the document's
  revision, preview kind and saved location are the ones it was started for; otherwise it is
  dropped and, if the tab is still live, rendered again. The location matters because it decides
  which local files a page may load: a page rendered before Save As is not shown with the
  folder the document had then.
- When the web content process ends, the page is rendered again, once. If the process ends a
  second time while showing the same text, the pane says "The preview stopped twice while showing
  this document, so it is not shown. The document is not changed. Edit the document to try the
  preview again." and nothing more is rendered until the text changes.
- The last good rendering stays in place until the next is ready. Nothing says "updating".
- A document over 8 MiB is not copied or parsed; the pane shows the core's limit sentence.
- Returning to Source, closing the tab or closing the document cancels the work and releases the
  pane, the presenters and the web view.

### The web view (Markdown, HTML, SVG)

One `WKWebView` per tab, made on first use.

| Rule | How it is enforced |
| --- | --- |
| No page script runs | `allowsContentJavaScript = false`, and the content security policy in the response header has `script-src 'none'`. |
| No network request | A compiled `WKContentRuleList` blocks every load and exempts only the `texttank-preview:` scheme. The content security policy in the response header allows images and stylesheets from that scheme only. |
| The policy cannot be written around | `PreviewSchemeHandler` sends `Content-Security-Policy` as a response header with every response: the page, the SVG image and each local file. WebKit enforces a header policy on this scheme; the checks observe it refusing a `data:` image, a frame, an object and a `<base>` in documents whose markup defeats the `<meta>` copy. |
| Nothing is kept | A non-persistent `WKWebsiteDataStore`; responses are served `no-store`. |
| No inspector, no link preview, no back/forward gestures | Web view settings. |
| No load before the rules exist | The rule list is compiled once for the application, asynchronously, into the application's private folder. The web view is created only after it is ready. While it is compiling the pane says the preview is not ready and loads nothing; if it cannot be compiled the pane says so, says to quit and reopen the application, and never loads anything. |

`PreviewSchemeHandler` answers the scheme. It never looks at the URL's host. It serves:

1. the prepared page, from memory, at a path that contains a fresh random token for every render;
2. for SVG, the document's current text as `image/svg+xml` at its own random path, which the page
   shows through `<img>`;
3. a local file below the page's path, when `PreviewResourceResolver` allows it: a stylesheet or
   an image, inside the saved document's own folder or a subfolder, at most 8 MiB, after symbolic
   links are followed. The file is read off the main thread, opened without following a link at
   its final name and measured again through the open descriptor. An untitled document is served
   no local file. An address above the page, such as `../file.png`, is refused before the
   resolver is asked.

Local files are allowed so that a page's own stylesheet and pictures appear as they will in a
browser; the folder rule keeps a page from reading anything else on the Mac.

The message row above the preview is one sentence list: the core's summary of external resources
and scripts (`PreviewSummary`), the number of local files that were missing, the number that
were refused ("3 local files were not loaded. Only stylesheets and images in the document's
folder are loaded."), and the number not loaded because the document is saved directly in the
home folder or at the top of the disk, with what to do about it. A file read that finishes after
its page was replaced is not counted against the new page. For Markdown the rendered fragment is
scanned only to count remote images.

Navigation is decided by `PreviewNavigationPolicy`: the presenter's own load of the page and
moves to an anchor inside it are allowed; everything else is cancelled, including reloads, meta
refresh, `file:`, `javascript:`, `data:`, relative page links, frames and new windows. Forms are
stopped twice: by `form-action 'none'` of the policy in the response header, and by the
navigation rule.

An `http`, `https` or `mailto` link is opened in the person's browser or mail application only
by a pointer press and release on that link (an explicit action, DS-97). The application's own
script, in its own script world, catches every activation of such a link before the web view
starts a navigation, and reports it only when a press on the same link came first and the click
has a click count. **Return on a focused link opens nothing.** A page can give a link the
keyboard focus by itself (`autofocus`), so an activation from the keyboard cannot be told from
one the page arranged; it is stopped and not reported. The navigation delegate opens nothing
either: a link activation that reaches it is cancelled. Without a pointer, the address is still
available through Copy Link. The context menu keeps only Copy and Copy Link.

The application's own scripts (reading and restoring the place across a new rendering, the
link catcher and the scroll reporter described under
[Scroll sync in Both](#scroll-sync-in-both)) run in `WKContentWorld.defaultClient`. Page scripts
being off does not affect them; the checks rely on this and would fail if it changed. The page's
own world has none of their objects or message handlers, and a check observes that.

**The reader's place across a new rendering.** For rendered Markdown the page before a new one
is asked which top-level block is at the top of the window and how far through it the top is.
When the new page has loaded, `PreviewScrollMap.counterpart` finds that block in the new map and
it is scrolled back to the same fraction. An edit above what is being read therefore does not
move it, however many blocks the edit added or removed. A page still at its very top stays at
the top. HTML, SVG, and a Markdown page whose map is missing keep their offset in points, as
before.

### The table (CSV, TSV)

An `NSTableView` whose data source asks `DelimitedTable.cell(row:column:)` for the cells that
are on screen; `rows` is never built. The first column, Line, is the source line each row starts
on. The other columns are lettered A, B, …; the first row is data. A cell is drawn as written, on
one line, cut for display at 1,000 characters; a line break inside a cell is drawn as ⏎, and the
tooltip gives the value. Rows can be selected, and Copy copies the selected rows as tab-separated
text, quoting a value that contains a tab, a line break or a quotation mark. The message row
gives any limit reached and the first quoting problem, with a count of the rest. A new parse
keeps the selection where the rows still exist.

### The tree (JSON)

An `NSOutlineView` with Name and Value columns over `JSONTree`. Rows are made when their parent
is opened. The outermost value is the row "Document", open at first. An array item is named by
its position; a container's value is its count ("3 items"); other values are `displayValue`, and
the tooltip is the literal as written. The first tree that has a value starts with its
outermost row open, also when the text before it was not JSON at all. When the document is
parsed again, the rows that were open (at most 2,000) and the selected row are found again in
the new tree: an array item at the same position, an object member at the same position when
that one has the same name. A member whose position changed is found by name, counting earlier
members of that name where names repeat; that reads every name of the object, so it is limited
to 100,000 names for one new parse, and rows beyond that are left closed. Invalid JSON shows the tree read before the
error, the error sentence with its line and column in the message row, and Go to Error, which
shows the source and puts the caret on the byte where the text stopped being valid.

### Scroll sync in Both

While a tab shows Both, scrolling the source scrolls the preview to the matching place and
scrolling the preview scrolls the source to the matching line (`PreviewScrollSync`, one per
tab, owned by the coordinator).

| Format | What is matched |
| --- | --- |
| Markdown | A source line and a top-level block of the page, through the page's `PreviewScrollMap`, with the fraction of the block the line is at. From the preview, the source goes to one of the block's own lines. |
| CSV, TSV | A source line and the row that starts on or before it, so a line inside a quoted value with line breaks is the row that value is in. From the table, the source goes to the line the top row starts on. |
| JSON | A source line and the last row showing whose value starts on or before it; a value inside a closed row is that row. From the tree, the source goes to the line the top row's value starts on. |
| HTML, SVG | Not followed. Nothing ties a place in the rendered page to a source line: the HTML scan is a tokenizer, a page can lay its content out in any order, and an SVG is one image. |

The source pane that leads or follows is the tab's own: scrolling either the editor or its clone
scrolls the preview, and the preview scrolls the pane used last.

**The switch.** `syncPreviewScrolling` in the settings file is a Boolean; sync is on unless it
is `false`, so a file without the member behaves as on. It is an Optional addition to the
version-1 format, written as one member by `SettingsStore.updateViewPreference(.syncPreviewScrolling)`.
There is nothing to apply when it changes: it is read at every scroll of a tab that shows Both.
Two controls set it, and each shows a change made by the other at once: the "Sync scrolling in
Both" row under Previews in Settings, and View > Preview > Sync Scrolling in Both (DS-D13), a
toggle with a checkmark that is disabled, like the rest of that submenu, for a document with no
preview. The Command Palette lists the menu item.

**What it may not do.** The security rules of the web view are unchanged: page JavaScript is
off, the response header carries the same policy, the rule list blocks the same loads, and no
file or network access was added. The scroll reporter is one more of the application's own
scripts in `WKContentWorld.defaultClient`. It reads the positions of the body's children and
calls `window.scrollTo`; it changes nothing in the page and loads nothing. It reports through a
message handler registered in that world only, and a report is three numbers: the number the page
was armed with, a block and a fraction. The application drops a report that is not exactly
three finite numbers (a Boolean is not a number), whose first number is not the one given to the
page that is showing, whose block the map does not have, or whose fraction is outside 0 to 1.
The page is armed only if it has as many top-level elements as its map has entries, and again
for every page, so a report from a page that has left is dropped. The map itself never enters
the page.

**No echo, no jump.**

- A scroll the application made is not answered. The script remembers the offset it set and
  ignores a scroll event that leaves the page there; the source and the table remember the line
  or row they were put at. No timer or delay is involved.
- Nothing is animated, with Reduce Motion on or off: the page is scrolled with
  `behavior: 'instant'` and the views with `NSClipView.scroll(to:)`.
- A scroll of the source is looked at in the next turn of the main queue, never inside the
  editor's own callback: Scintilla moves its top line while it is still applying an edit made
  above it, before the document's revision changes. Several scrolls before that turn count as
  one.
- The preview is scrolled only while it shows the text as it is now. Between an edit and its
  rendering the map's lines are not the text's lines, so a scroll of the source in that time is
  remembered and followed when the new rendering is showing, and then only if the place kept
  for the reader is not already the source's line. An edit by itself never moves the preview.
  An edit that takes the caret elsewhere (typing at the bottom of the pane, Undo of a change
  far away) scrolls the source, and the preview follows that once the edit is rendered.
- While a pane is being resized nothing is followed: lines wrapping again are not scrolling.
- A preview that has just been made, and one loaded again after its content was lost, starts
  where the source is.

**When it works.** Only while the tab is on screen, shows Both and has a followed format. A
hidden tab, a tab in Preview alone and a tab in Source hold no observer, and the page's script
reports nothing; Source releases everything with the pane. One scroll costs a binary search
(over the map's entries, the rows' starting lines, or the rows showing) and one scroll of the
other side; nothing is read or measured for the whole document. A document over the 8 MiB limit
has no page, so nothing is followed. Sync only scrolls: it never moves the selection or the
caret, takes the keyboard, edits, or touches Undo or the file.

**Limits of the match.**

- Inside one top-level block the match is proportional. In a long list, table or quote whose
  items differ much in height, the source line and the preview can be a few items apart.
- Between an edit and its rendering, a scroll of the preview is matched with the lines of the
  rendering that is showing. After an edit above the place, the source can land off by the
  number of lines the edit added or removed until the next scroll.
- Folded or wrapped source lines are matched by document line; the fraction of a wrapped line
  is not used.
- The table and the tree keep their offset in points across a new parse, as before. In Both
  with sync on, an edit above that moves the source's lines moves the table to the same rows.

### Measurements

From `scripts/test-preview-ui.sh` on the unoptimized Debug build, in Both, one arm64 Mac,
23 November 2026. They are observations, not budgets (DS-101).

| Document | Render, off the main thread | Applying the result, main thread | Applying again after an edit | Longest main-thread gap while rendering | One keystroke |
| --- | --- | --- | --- | --- | --- |
| Markdown, 5 MiB | 1.9–2.0 s | 0.1–0.2 ms | 0.1–0.2 ms | 12 ms | 0.4–0.9 ms |
| CSV, 5 MiB | 0.42–0.44 s | 0.5–0.6 ms | under 0.1 ms | 12 ms | 0.3 ms |
| JSON, 5 MiB: an array of about 71,000 objects, 50 of them open | 0.40 s | 22–23 ms | 23–25 ms | 12 ms | 0.3–0.5 ms |
| JSON, 3.8 MiB: one object of 200,000 members, 50 of them open | 0.33 s | 55–56 ms | 59–61 ms | 12 ms | 0.3 ms |
| JSON, 0.4 MiB: one object of 24,000 members, 50 of them open; the edit adds a member at the top | 0.04 s | 7 ms | 42 ms | 12 ms | 0.7 ms |

"Applying" is handing the result to the presenter. For the web view the page then loads and is
laid out in WebKit's own process, which is not included. For the table, rows are asked for as
they are drawn. For the tree the figure includes making a row for every item of each open value
and opening the rows that were open before; drawing them is not included. The JSON documents
are measured with the outermost row open, which is how a tree is first shown. The last row is
the costliest edit for the tree: every member moves down one place, so each open row is looked
for by name until the allowance of 100,000 names is spent; two of the fifty rows are found and
the others are left closed.

### Not verified

- Anything that needs an unlocked screen and a person: dragging the divider, physical Tab and
  arrow keys, VoiceOver speech, the look in light appearance, and the context menu as WebKit
  builds it (the check removes items from a menu it builds itself).
- A physical click on a link. The checks make the press and the click with the application's
  own script (a `mousedown` and a `click` with a click count), and observe that this opens the
  link through the opener, that the web view makes no connection, and that an activation with
  no press opens nothing. A real pointer click, a middle click and a drag are not exercised, and
  neither is Return typed on a focused link.
- A load started through the web view's own API with an `http` address is cancelled by the
  navigation rule, but WebKit opens a connection to the server before it asks. Nothing in the
  application makes such a load.
- The mark on the tab under a real pointer: the tracking area's enter, move and exit events, a
  physical click, and how the eye looks beside a truncated title. The checks tell the strip
  where the pointer is and press the button through `performClick`. Pressing Control-Command-V on
  a keyboard is not exercised either; the checks send the menu item's action.
- The tab menu's Source, Preview and Both while a sheet or a comparison window blocks them. They
  share one test (`blockedReason`) with the tab commands, and a check observes it for a tab
  operation in progress; no check opens a sheet or a comparison window for it, because a check
  must not put a dialog on the desktop and this check process never holds the key window.
- Control-Command-V pressed with the keyboard in a preview. From the table, the tree and the find
  field no view takes the key equivalent and the action's responder chain reaches the tab. The
  web view (Markdown, HTML, SVG) answers every key equivalent itself and passes on what the
  page does not use, as it does for Command-F; that hand-back needs a key window and was not
  observed.
- `NSDocumentController.openDocument` itself with a format set to Preview or Both. The check
  process has no document types, so it performs the same three steps (read, register, show).
- Scroll sync under a person's hand: a trackpad or wheel scroll with momentum, the scroll bar,
  dragging the divider or resizing the window while both sides show, and scrolling the clone
  pane. The checks scroll the editor through its bridge, the page through the application's own
  script and the table and tree through their clip views, and observe the other side.
- Reduce Motion itself. Nothing in sync animates in either setting, which a check reads from
  the script; the system setting was not switched.
- What a scroll costs on the main thread. It is a binary search by construction; no time was
  measured for it.
- Release-build timings.
