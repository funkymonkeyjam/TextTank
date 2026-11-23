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
| Delimited rows | 100,000 | later rows are left out; `limitsReached` has `.tooManyRows` |
| Delimited columns | 512 | later cells of a row are left out; `.tooManyColumns` |
| JSON values | 500,000 | the tree so far is returned with `.tooManyValues` |
| JSON nesting | 512 levels | the tree so far is returned with `.nestedTooDeeply` |
| Local file served to a page | 8 MiB | the file is refused (`.tooLarge`) |

Further fixed caps keep adversarial Markdown linear: 32 open brackets per paragraph, 2,048 bytes
for a link destination or title, 999 bytes for a reference label, 32 nested parentheses in a
destination. At most 1,000 external references and 100 delimited-text diagnostics are listed;
the totals are still counted.

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

### Deliberate differences from CommonMark

These are decisions, not gaps:

1. **Raw HTML is escaped, never passed through.** HTML blocks and inline HTML appear as the text
   that was typed (`<b>` shows as `<b>`). The output therefore contains only the tags this renderer
   writes: `p`, `h1`–`h6`, `em`, `strong`, `code`, `pre`, `blockquote`, `ul`, `ol`, `li`, `a`,
   `img`, `br`, `hr`, `table`, `thead`, `tbody`, `tr`, `th`, `td`, `input`.
2. **Link and image addresses are restricted.** Only `http:`, `https:`, `mailto:` and relative
   addresses are written. For any other scheme (`javascript:`, `data:`, `file:`, `ftp:`, …), or
   an address containing a control character, no tag is written: a link keeps its text and an
   image keeps its description. An autolink with another scheme stays literal text.
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
blocks all network loads, and a handler for the `texttank-preview` scheme (`PreviewScheme.name`).

- `contentSecurityPolicy(scheme:)` is
  `default-src 'none'; img-src texttank-preview:; style-src texttank-preview: 'unsafe-inline'; font-src 'none'; script-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'`.
- `wrapFragment(_:title:stylesheet:)` builds a complete page around rendered Markdown or the SVG
  image tag: charset, the policy, an escaped title, and the stylesheet in a `<style>` element. The
  stylesheet is the bundled `Resources/Preview/preview.css`
  (`PreviewStylesheet.resourceName`/`resourceExtension`), which uses system colours and the system
  font and loads nothing.
- `prepare(html:)` takes the user's HTML document and inserts the policy `<meta>` as the first
  thing in `<head>`. Without a `<head>`, one is created after the `<html>` start tag, else after the
  doctype, else at the start. Nothing else is rewritten. It also returns a
  `PreviewContentReport`:
  - `externalReferences`: `http:`, `https:` and `//` addresses the page asks to load — `src`,
    `href`, `xlink:href`, `poster`, `data`, `background`, `srcset` and `imagesrcset` of `link`,
    `img`, `script`, `iframe`, `frame`, `source`, `video`, `audio`, `object`, `embed`, `track`,
    `input`, `image`, `use` and `feImage`, plus `url(…)` and `@import` in `<style>` elements and
    `style` attributes. Ordinary links (`<a href>`) and form targets are not loaded resources.
  - `scriptCount`: `<script>` elements, `on…` event-handler attributes, and `javascript:`
    addresses.
  - `hasBaseTag`: a `<base>` tag exists (the policy ignores it).

The scan uses a tolerant tokenizer, not a parser: it reads tags and attributes in any case, quoted
or not, and skips comments, CDATA sections and the text of script and style elements. It reports
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
- the path, after percent-decoding and removing `.` and `..`, is inside the folder that contains
  the document, subfolders included (otherwise `.outsideDocumentFolder`). A leading slash does not
  make a path absolute;
- the same is true of the file's real location after symbolic links are followed;
- the extension, of the name and of the real file, is one of `css`, `png`, `jpg`, `jpeg`, `gif`,
  `webp`, `svg`, `bmp`, `ico`, `avif`, `heic` (otherwise `.typeNotAllowed`);
- it is a regular file (otherwise `.missing`) of at most 8 MiB (otherwise `.tooLarge`).

A null byte or malformed percent-encoding is `.missing`. Symbolic-link resolution and file size are
injected closures with real defaults, so the rules are tested without touching the disk. SVG is
served only as `image/svg+xml` for use in `<img>`; the policy's `frame-src` and `object-src`
refuse it anywhere it could act as a document.

## Delimited text

`DelimitedTable.parse(_:delimiter:)` reads comma- or tab-separated text in the style of RFC 4180:
values may be wrapped in double quotes; inside quotes a doubled quote is one quote, and
delimiters and line breaks (LF, CRLF, CR) are text. A byte order mark is skipped. A line break at
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
- a quote inside an unquoted value, or text after a closing quote, is kept literally
  (`.strayQuote`).

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
  column and a message such as "Expected a comma or closing brace at line 12, column 5.";
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
with a divider that can be dragged. The View menu has the three commands, with a checkmark on the
one that is showing (DS-22). They have no shortcut. They are disabled for a document that
`PreviewKind.kind` gives no preview (DS-21). When a document stops having one, because its
language was changed or it was saved under another extension, its tab returns to Source and the
status line says "This kind of document has no preview. The tab shows Source again."

A mode change only rearranges views (`DocumentViewContainer`). The tab's own split view, which
holds the editor and its clone, is the container's first pane and is never removed or rebuilt:
Preview hides it. Nothing is saved, reloaded or shared again and Undo is not touched, so the
bytes, revision, selection, scroll position, clone split, Undo history and file are the same
after any number of changes. In Both each pane keeps at least 120 points while there is room for
two; below that the width is shared equally, so nothing overlaps (DS-67). The divider's position
is a fraction of the width and changes only when it is dragged.

Keyboard: showing Preview moves the keyboard to the preview. In Both, choosing View → Both
again moves it from the source to the preview or back; Tab from the table or the tree goes to
the source. While only the preview shows, Find, Find and Replace, Go to Line and Go to Error
first put the source beside it, and so does anything else that puts the keyboard in a source
pane. Commands that change text still act on the document, and Undo and Redo chosen from the
preview go to the document. The pane and each presenter are labelled "Preview of <name>"
(DS-70, DS-71), and the message row announces its changes (DS-72).

The mode is part of a tab's session record (see [tab-model](tab-model.md)). A restored mode is
applied only to a document that still has a preview.

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
  revision and preview kind are the ones it was started for; otherwise it is dropped.
- The last good rendering stays in place until the next is ready. Nothing says "updating".
- A document over 8 MiB is not copied or parsed; the pane shows the core's limit sentence.
- Returning to Source, closing the tab or closing the document cancels the work and releases the
  pane, the presenters and the web view.

### The web view (Markdown, HTML, SVG)

One `WKWebView` per tab, made on first use.

| Rule | How it is enforced |
| --- | --- |
| No page script runs | `allowsContentJavaScript = false`, and the page's content security policy has `script-src 'none'`. |
| No network request | A compiled `WKContentRuleList` blocks every load and exempts only the `texttank-preview:` scheme. The content security policy allows images and stylesheets from that scheme only. |
| Nothing is kept | A non-persistent `WKWebsiteDataStore`; responses are served `no-store`. |
| No inspector, no link preview, no back/forward gestures | Web view settings. |
| No load before the rules exist | The rule list is compiled once for the application, asynchronously, into the application's private folder. The web view is created only after it is ready. While it is compiling the pane says the preview is not ready and loads nothing; if it cannot be compiled the pane says so and never loads anything. |

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
and scripts (`PreviewSummary`), the number of local files that were missing, and the number that
were refused ("3 local files were not loaded. Only stylesheets and images in the document's
folder are loaded."). For Markdown the rendered fragment is scanned only to count remote images.

Navigation is decided by `PreviewNavigationPolicy`: the presenter's own load of the page and
moves to an anchor inside it are allowed; everything else is cancelled, including reloads, meta
refresh, `file:`, `javascript:`, `data:`, relative page links, frames and new windows. Forms are
stopped by the policy's `form-action 'none'`. A click on an `http`, `https` or `mailto` link is
caught by the application's own script, in its own script world, before the web view starts a
navigation, and is opened in the person's browser or mail application (an explicit action,
DS-97). The context menu keeps only Copy and Copy Link.

The application's own scripts (reading and restoring the scroll position across a new
rendering, and the link catcher) run in `WKContentWorld.defaultClient`. Page scripts being off
does not affect them; the checks rely on this and would fail if it changed.

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
the tooltip is the literal as written. When the document is parsed again, open rows and the
selected row are found by their path of names and positions (at most 2,000 rows and 200,000 name
comparisons; beyond that rows are left closed). Invalid JSON shows the tree read before the
error, the error sentence with its line and column in the message row, and Go to Error, which
shows the source and puts the caret on the byte where the text stopped being valid.

### Measurements

From `scripts/test-preview-ui.sh` on the unoptimized Debug build, 5 MiB documents in Both, one
arm64 Mac, 23 November 2026. They are observations, not budgets (DS-101).

| Document | Render, off the main thread | Applying the result, main thread | Longest main-thread gap while rendering | One keystroke |
| --- | --- | --- | --- | --- |
| Markdown | 1.9–2.1 s | 0.1 ms | 12 ms | 0.7 ms |
| CSV | 0.42–0.48 s | 0.5 ms | 12 ms | 0.3 ms |
| JSON | 0.41–0.47 s | 0.1 ms | 12 ms | 0.3 ms |

"Applying" is handing the result to the presenter. For the web view the page then loads and is
laid out in WebKit's own process, which is not included.

### Not verified

- Anything that needs an unlocked screen and a person: dragging the divider, physical Tab and
  arrow keys, VoiceOver speech, the look in light appearance, and the context menu as WebKit
  builds it (the check removes items from a menu it builds itself).
- That WebKit makes no connection for a link the person clicks is checked for an ordinary click
  only, not for a middle click or a drag.
- A load started through the web view's own API with an `http` address is cancelled by the
  navigation rule, but WebKit opens a connection to the server before it asks. Nothing in the
  application makes such a load.
- Release-build timings.
