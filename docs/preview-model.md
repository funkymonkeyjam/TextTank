# Preview model

This document describes the Foundation-only preview core in `Sources/Preview/`. It is part of
TextTankCore: it has no AppKit or WebKit dependency, reads no files and opens no network
connection. The presentation layer (a web view with JavaScript disabled for Markdown, HTML and
SVG; a table view for delimited text; an outline view for JSON) calls it with the text of the
current document and shows what it returns.

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
- Inline links `[text](destination "title")`, including `<destination with spaces>` and balanced
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
