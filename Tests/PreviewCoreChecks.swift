// SPDX-License-Identifier: GPL-3.0-or-later
// Checks for the Foundation-only preview core (Sources/Preview): kind selection, limits, the
// Markdown renderer, the static HTML policy, the resource resolver, delimited text, the JSON
// tree and the SVG scan. Fixtures are in Tests/Fixtures/preview; see its README.
import Foundation
@testable import TextTankCore

/// A cancellation closure that never cancels. The default reads `Task.isCancelled`, which is
/// also false here, but an explicit closure keeps each check independent of task state.
private let never: @Sendable () -> Bool = { false }

/// Counts how often a parser asks whether it is cancelled, and can answer yes from a given call on.
private final class CancellationProbe {
    private(set) var polls = 0
    private let cancelAtPoll: Int?
    init(cancelAtPoll: Int? = nil) { self.cancelAtPoll = cancelAtPoll }
    func isCancelled() -> Bool {
        polls += 1
        if let cancelAtPoll { return polls >= cancelAtPoll }
        return false
    }
}

private enum PreviewFixtures {
    static let root = TestPaths.fixtures.appendingPathComponent("preview", isDirectory: true)

    static func data(_ path: String) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(path))
    }

    static func text(_ path: String) throws -> String {
        String(decoding: try data(path), as: UTF8.self)
    }

    static func names(in folder: String, withExtension fileExtension: String) throws -> [String] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent(folder, isDirectory: true), includingPropertiesForKeys: nil)
        return urls.filter { $0.pathExtension == fileExtension }.map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }
}

private func rendered(_ markdown: String, limits: PreviewLimits = .standard) -> String? {
    if case .rendered(let html) = MarkdownRenderer.render(markdown, limits: limits, isCancelled: never) { return html }
    return nil
}

/// The structural safety property of rendered Markdown: the output consists only of tags the
/// renderer writes, with known attributes and permitted addresses, properly nested, and all
/// other text has its `<`, `>` and `"` escaped. Returns a description of the first violation.
private func markdownOutputViolation(_ html: String) -> String? {
    let allowedTags: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6", "em", "strong", "code", "pre", "blockquote", "ul", "ol", "li", "a",
        "img", "br", "hr", "table", "thead", "tbody", "tr", "th", "td", "input"
    ]
    let voidTags: Set<String> = ["img", "br", "hr", "input"]
    let allowedAttributes: Set<String> = [
        "href", "title", "src", "alt", "class", "align", "start", "type", "disabled", "checked"
    ]
    let forbiddenSchemes = ["javascript:", "data:", "vbscript:", "file:"]
    let tagPattern = #"<(/?)([a-z][a-z0-9]*)((?:\s+[a-z]+(?:="[^"<>]*")?)*)\s*/?>"#
    let attributePattern = #"([a-z]+)(?:="([^"]*)")?"#
    guard let tagExpression = try? NSRegularExpression(pattern: tagPattern),
        let attributeExpression = try? NSRegularExpression(pattern: attributePattern)
    else { return "the check's own patterns did not compile" }
    let text = html as NSString
    var open: [String] = []
    var remainder = ""
    var cursor = 0
    for match in tagExpression.matches(in: html, range: NSRange(location: 0, length: text.length)) {
        remainder += text.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
        cursor = match.range.location + match.range.length
        let isClosing = match.range(at: 1).length > 0
        let name = text.substring(with: match.range(at: 2))
        guard allowedTags.contains(name) else { return "unexpected tag <\(name)>" }
        if isClosing {
            guard open.popLast() == name else { return "</\(name)> does not close the open tag" }
            continue
        }
        if !voidTags.contains(name) { open.append(name) }
        let attributes = text.substring(with: match.range(at: 3))
        let attributeText = attributes as NSString
        for attribute in attributeExpression.matches(
            in: attributes, range: NSRange(location: 0, length: attributeText.length))
        {
            let attributeName = attributeText.substring(with: attribute.range(at: 1))
            guard allowedAttributes.contains(attributeName) else { return "unexpected attribute \(attributeName)" }
            guard attributeName == "href" || attributeName == "src", attribute.range(at: 2).location != NSNotFound
            else { continue }
            let address = attributeText.substring(with: attribute.range(at: 2)).lowercased()
                .filter { !$0.isWhitespace }
            if forbiddenSchemes.contains(where: address.hasPrefix) { return "forbidden address \(address)" }
        }
    }
    remainder += text.substring(from: cursor)
    if !open.isEmpty { return "unclosed tags \(open)" }
    if remainder.contains("<") || remainder.contains(">") || remainder.contains("\"") {
        return "unescaped markup characters in text"
    }
    return nil
}

/// Checks the structural invariants of a JSON tree, complete or partial.
private func jsonTreeViolation(_ tree: JSONTree, sourceLength: Int) -> String? {
    var childTotal = 0
    for (index, node) in tree.nodes.enumerated() {
        guard node.byteRange.lowerBound >= 0, node.byteRange.upperBound <= sourceLength else {
            return "node \(index) lies outside the source"
        }
        guard node.line >= 1, node.column >= 1 else { return "node \(index) has no location" }
        if index == 0 {
            guard node.parent == nil else { return "the root has a parent" }
        } else {
            guard let parent = node.parent, parent < index, tree.nodes[parent].isContainer else {
                return "node \(index) has no earlier container as parent"
            }
            guard tree.children(of: parent).contains(index) else {
                return "node \(index) is not among its parent's children"
            }
        }
        let children = Array(tree.children(of: index))
        guard node.isContainer || children.isEmpty else { return "scalar \(index) has children" }
        guard children == children.sorted() else { return "children of \(index) are out of document order" }
        for (position, child) in children.enumerated() {
            guard tree.nodes[child].parent == index, tree.nodes[child].indexInParent == position else {
                return "child \(child) of \(index) has the wrong parent or position"
            }
            guard (tree.nodes[child].keyRange != nil) == (node.kind == .object) else {
                return "child \(child) of \(index) has a name exactly when its parent is not an object"
            }
        }
        childTotal += children.count
    }
    guard tree.nodes.isEmpty || childTotal == tree.nodes.count - 1 else {
        return "a node is listed as a child twice or never"
    }
    return nil
}

private func parsedJSON(_ text: String, limits: PreviewLimits = .standard) -> JSONTree? {
    if case .parsed(let tree) = JSONTree.parse(text, limits: limits, isCancelled: never) { return tree }
    return nil
}

private func jsonError(_ text: String) -> JSONSyntaxError? {
    if case .invalid(_, let error) = JSONTree.parse(text, isCancelled: never) { return error }
    return nil
}

private func parsedTable(_ text: String, delimiter: Character = ",", limits: PreviewLimits = .standard)
    -> DelimitedTable?
{
    if case .parsed(let table) = DelimitedTable.parse(text, delimiter: delimiter, limits: limits, isCancelled: never) {
        return table
    }
    return nil
}

private func preparedHTML(_ html: String) -> PreparedHTML? {
    if case .prepared(let prepared) = StaticHTMLPolicy.prepare(html: html, isCancelled: never) { return prepared }
    return nil
}

private func inspectedSVG(_ svg: String) -> SVGInspection? {
    if case .inspected(let inspection) = SVGPolicy.scan(svg, isCancelled: never) { return inspection }
    return nil
}

private func seconds(_ work: () -> Void) -> Double {
    let start = Date()
    work()
    return Date().timeIntervalSince(start)
}

@main struct PreviewCoreChecks {
    static func main() async {
        await Checks.run("PreviewCoreChecks") {
            Checks.section("preview kind") { checkKinds() }
            Checks.section("limits") { checkLimits() }
            Checks.section("Markdown fixtures") { try checkMarkdownFixtures() }
            Checks.section("Markdown constructs") { checkMarkdownConstructs() }
            Checks.section("Markdown safety") { try checkMarkdownSafety() }
            Checks.section("Markdown bounds") { checkMarkdownBounds() }
            await Checks.section("Markdown cancellation") { await checkMarkdownCancellation() }
            Checks.section("HTML wrapper") { checkWrapper() }
            Checks.section("HTML preparation") { try checkHTMLPreparation() }
            Checks.section("resource resolver") { try checkResourceResolver() }
            Checks.section("summary") { checkSummary() }
            Checks.section("delimited text") { try checkDelimited() }
            Checks.section("delimited bounds") { checkDelimitedBounds() }
            Checks.section("JSON tree") { try checkJSON() }
            Checks.section("JSON errors") { try checkJSONErrors() }
            Checks.section("JSON bounds") { checkJSONBounds() }
            Checks.section("SVG") { try checkSVG() }
            Checks.summary { "PASS PreviewCoreChecks: \(Checks.count) assertions" }
        }
    }

    // MARK: Kind and limits

    static func checkKinds() {
        func kind(_ language: String, _ fileExtension: String?) -> PreviewKind? {
            PreviewKind.kind(languageID: language, fileExtension: fileExtension)
        }
        check(kind("markdown", "md") == .markdown, "Markdown language previews as Markdown")
        check(kind("markdown", nil) == .markdown, "untitled Markdown previews by language")
        check(kind("html", nil) == .html && kind("json", nil) == .json, "untitled HTML and JSON preview by language")
        check(kind("normal", nil) == nil, "untitled plain text has no preview")
        check(kind("xml", nil) == nil, "untitled XML has no preview, so SVG needs a saved name")
        check(kind("xml", "svg") == .svg && kind("xml", "SVG") == .svg, "XML named .svg previews as SVG in any case")
        check(kind("normal", "svg") == .svg, "the .svg extension alone selects SVG")
        check(kind("xml", "xml") == nil, "other XML has no preview")
        check(kind("normal", "csv") == .delimited(","), "a .csv file is comma-delimited")
        check(
            kind("normal", "tsv") == .delimited("\t") && kind("normal", "tab") == .delimited("\t"),
            ".tsv and .tab are tab-delimited")
        check(kind("python", "CSV") == .delimited(","), "the delimited extensions win over the language")
        check(kind("json5", "json") == nil && kind("json5", "json5") == nil, "JSON5 has no tree preview")
        check(kind("jsonc", "json") == nil, "JSON with comments has no tree preview")
        for name in ["md", "markdown", "mdown", "mkd", "mkdn", "MD"] {
            check(kind("normal", name) == .markdown, "extension \(name) falls back to Markdown")
        }
        for name in ["html", "htm", "xhtml", "HTM"] {
            check(kind("normal", name) == .html, "extension \(name) falls back to HTML")
        }
        check(kind("normal", "json") == .json, "extension json falls back to JSON")
        check(kind("normal", "txt") == nil && kind("normal", "") == nil, "unrelated extensions have no preview")
        check(kind("javascript", "js") == nil, "source code has no preview")
        check(PreviewScheme.name == "texttank-preview", "the preview scheme name is stable")
    }

    static func checkLimits() {
        let limits = PreviewLimits.standard
        check(limits.maxSourceBytes == 8 * 1024 * 1024, "the source limit is 8 MiB")
        check(
            limits.delimitedMaxRows == 100_000 && limits.delimitedMaxColumns == 512,
            "delimited limits are 100,000 rows and 512 columns")
        check(
            limits.jsonMaxNodes == 500_000 && limits.jsonMaxDepth == 512,
            "JSON limits are 500,000 values and 512 levels")
        check(limits.maxOutputBytes == 16 * 1024 * 1024, "the Markdown output limit is 16 MiB")
        check(limits.maxResourceBytes == 8 * 1024 * 1024, "the local resource limit is 8 MiB")
        check(
            limits.markdownMaxTableColumns == 4096 && limits.markdownMaxTableCells == 1_000_000,
            "Markdown tables are limited to 4,096 columns and 1,000,000 cells in a document")
        let messages: [PreviewLimit] = [
            .sourceTooLarge(maxBytes: limits.maxSourceBytes), .outputTooLarge(maxBytes: limits.maxOutputBytes),
            .tooManyRows(shown: 100_000), .tooManyColumns(shown: 512), .tooManyValues(shown: 500_000),
            .nestedTooDeeply(maxDepth: 512), .tooManyTableCells(maxCells: limits.markdownMaxTableCells)
        ]
        for limit in messages {
            let message = limit.message
            check(
                message.hasSuffix(".") && !message.contains("%") && message.first?.isUppercase == true,
                "limit message is a whole sentence: \(message)")
        }
        check(
            PreviewLimit.tooManyRows(shown: 100_000).message.contains(Strings.number(100_000)),
            "the row limit message names the number of rows shown")
        check(
            PreviewLimit.sourceTooLarge(maxBytes: limits.maxSourceBytes).message.contains(
                Strings.bytes(limits.maxSourceBytes)), "the size limit message names the size")
    }

    // MARK: Markdown

    static func checkMarkdownFixtures() throws {
        let names = try PreviewFixtures.names(in: "markdown", withExtension: "md")
        try require(names.count >= 14, "the Markdown fixtures are present")
        for name in names {
            let source = try PreviewFixtures.data("markdown/\(name).md")
            let expected = try PreviewFixtures.text("markdown/\(name).html")
            fixtureCheck(!source.isEmpty && !expected.isEmpty, "markdown/\(name) has a source and an expected file")
            guard case .rendered(let html) = MarkdownRenderer.render(source, isCancelled: never) else {
                check(false, "markdown/\(name).md renders")
                continue
            }
            if !check(html == expected, "markdown/\(name).md renders to its expected HTML") {
                let actual = TestPaths.artifacts.appendingPathComponent("preview-\(name).actual.html")
                try? FileManager.default.createDirectory(at: TestPaths.artifacts, withIntermediateDirectories: true)
                try? Data(html.utf8).write(to: actual)
                print("  actual output written to \(actual.lastPathComponent) in the test artifacts folder")
            }
            let violation = markdownOutputViolation(html)
            check(violation == nil, "markdown/\(name).md output has only the renderer's tags (\(violation ?? "ok"))")
            check(
                rendered(String(decoding: source, as: UTF8.self)) == html,
                "markdown/\(name).md renders the same from text and from bytes")
        }
        fixtureCheck(
            try PreviewFixtures.data("markdown/line-endings.md").contains(0x0D),
            "the line-endings fixture still contains carriage returns")
        fixtureCheck(
            try PreviewFixtures.data("markdown/whitespace.md").contains(0x09),
            "the whitespace fixture still contains tabs")
        fixtureCheck(
            try PreviewFixtures.text("markdown/unicode.md").contains("\u{00A0}"),
            "the Unicode fixture still contains no-break spaces")
    }

    /// Small inputs with the output the CommonMark specification gives for them, plus the
    /// documented differences.
    static func checkMarkdownConstructs() {
        let cases: [(String, String)] = [
            ("", ""),
            ("\n\n  \n", ""),
            ("plain", "<p>plain</p>\n"),
            ("*foo bar*", "<p><em>foo bar</em></p>\n"),
            ("a * foo bar*", "<p>a * foo bar*</p>\n"),
            ("foo*bar*", "<p>foo<em>bar</em></p>\n"),
            ("_foo bar_", "<p><em>foo bar</em></p>\n"),
            ("foo_bar_", "<p>foo_bar_</p>\n"),
            ("пристаням_стремятся_", "<p>пристаням_стремятся_</p>\n"),
            ("**foo bar**", "<p><strong>foo bar</strong></p>\n"),
            ("__foo, __bar__, baz__", "<p><strong>foo, <strong>bar</strong>, baz</strong></p>\n"),
            ("*foo**bar**baz*", "<p><em>foo<strong>bar</strong>baz</em></p>\n"),
            ("***strong emph***", "<p><em><strong>strong emph</strong></em></p>\n"),
            ("foo ***", "<p>foo ***</p>\n"),
            ("**foo*", "<p>*<em>foo</em></p>\n"),
            ("*foo**", "<p><em>foo</em>*</p>\n"),
            ("*foo _bar* baz_", "<p><em>foo _bar</em> baz_</p>\n"),
            ("*foo**bar*", "<p><em>foo**bar</em></p>\n"),
            ("foo***bar***baz", "<p>foo<em><strong>bar</strong></em>baz</p>\n"),
            ("*(*foo*)*", "<p><em>(<em>foo</em>)</em></p>\n"),
            ("**foo bar **", "<p>**foo bar **</p>\n"),
            ("`foo`", "<p><code>foo</code></p>\n"),
            ("`` foo ` bar ``", "<p><code>foo ` bar</code></p>\n"),
            ("` a`", "<p><code> a</code></p>\n"),
            ("`foo\nbar`", "<p><code>foo bar</code></p>\n"),
            ("*foo`*`", "<p>*foo<code>*</code></p>\n"),
            ("`<http://foo.bar.`baz>`", "<p><code>&lt;http://foo.bar.</code>baz&gt;`</p>\n"),
            ("[link](/uri \"title\")", "<p><a href=\"/uri\" title=\"title\">link</a></p>\n"),
            ("[link]()", "<p><a href=\"\">link</a></p>\n"),
            ("[a](<b)c>)", "<p><a href=\"b)c\">a</a></p>\n"),
            ("[link](foo(and(bar)))", "<p><a href=\"foo(and(bar))\">link</a></p>\n"),
            ("[link](foo\\)\\:)", "<p><a href=\"foo):\">link</a></p>\n"),
            ("\\[not a link](/foo)", "<p>[not a link](/foo)</p>\n"),
            ("[link](/url \"title \\\"&quot;\")", "<p><a href=\"/url\" title=\"title &quot;&quot;\">link</a></p>\n"),
            ("[foo]\n\n[foo]: /url \"title\"", "<p><a href=\"/url\" title=\"title\">foo</a></p>\n"),
            ("[foo][BaR]\n\n[bar]: /url", "<p><a href=\"/url\">foo</a></p>\n"),
            ("[foo] [bar]\n\n[bar]: /url", "<p>[foo] <a href=\"/url\">bar</a></p>\n"),
            ("![foo](/url \"title\")", "<p><img src=\"/url\" alt=\"foo\" title=\"title\" /></p>\n"),
            ("![foo *bar*](/url)", "<p><img src=\"/url\" alt=\"foo bar\" /></p>\n"),
            ("<http://foo.bar.baz>", "<p><a href=\"http://foo.bar.baz\">http://foo.bar.baz</a></p>\n"),
            ("<foo@bar.example.com>", "<p><a href=\"mailto:foo@bar.example.com\">foo@bar.example.com</a></p>\n"),
            ("<http://foo.bar/baz bim>", "<p>&lt;http://foo.bar/baz bim&gt;</p>\n"),
            ("foo  \nbar", "<p>foo<br />\nbar</p>\n"),
            ("foo\\\nbar", "<p>foo<br />\nbar</p>\n"),
            ("foo \nbar", "<p>foo\nbar</p>\n"),
            ("foo  ", "<p>foo</p>\n"),
            ("# foo *bar* \\*baz\\*", "<h1>foo <em>bar</em> *baz*</h1>\n"),
            ("#5 bolt\n\n#hashtag", "<p>#5 bolt</p>\n<p>#hashtag</p>\n"),
            ("## foo ##\n  ###   bar    ###", "<h2>foo</h2>\n<h3>bar</h3>\n"),
            ("Foo *bar*\n=========\n\nFoo *bar*\n---------", "<h1>Foo <em>bar</em></h1>\n<h2>Foo <em>bar</em></h2>\n"),
            ("Foo\nbar\n---\nbaz", "<h2>Foo\nbar</h2>\n<p>baz</p>\n"),
            ("***\n---\n___", "<hr />\n<hr />\n<hr />\n"),
            ("+++", "<p>+++</p>\n"),
            ("- foo\n***\n- bar", "<ul>\n<li>foo</li>\n</ul>\n<hr />\n<ul>\n<li>bar</li>\n</ul>\n"),
            ("    a simple\n      indented code block", "<pre><code>a simple\n  indented code block\n</code></pre>\n"),
            ("Foo\n    bar", "<p>Foo\nbar</p>\n"),
            ("```\n<\n >\n```", "<pre><code>&lt;\n &gt;\n</code></pre>\n"),
            ("```ruby\ndef foo(x)\nend\n```", "<pre><code class=\"language-ruby\">def foo(x)\nend\n</code></pre>\n"),
            ("```\naaa\n~~~\n```", "<pre><code>aaa\n~~~\n</code></pre>\n"),
            ("``` ```\naaa", "<p><code> </code>\naaa</p>\n"),
            ("> # Foo\n> bar\n> baz", "<blockquote>\n<h1>Foo</h1>\n<p>bar\nbaz</p>\n</blockquote>\n"),
            ("> bar\nbaz\n> foo", "<blockquote>\n<p>bar\nbaz\nfoo</p>\n</blockquote>\n"),
            ("> foo\n---", "<blockquote>\n<p>foo</p>\n</blockquote>\n<hr />\n"),
            ("> foo\n\n> bar", "<blockquote>\n<p>foo</p>\n</blockquote>\n<blockquote>\n<p>bar</p>\n</blockquote>\n"),
            (
                ">>> foo\n> bar\n>>baz",
                "<blockquote>\n<blockquote>\n<blockquote>\n<p>foo\nbar\nbaz</p>\n</blockquote>\n</blockquote>\n</blockquote>\n"
            ),
            ("- foo\n- bar\n+ baz", "<ul>\n<li>foo</li>\n<li>bar</li>\n</ul>\n<ul>\n<li>baz</li>\n</ul>\n"),
            (
                "1. foo\n2. bar\n3) baz",
                "<ol>\n<li>foo</li>\n<li>bar</li>\n</ol>\n<ol start=\"3\">\n<li>baz</li>\n</ol>\n"
            ),
            ("- foo\n\n  bar", "<ul>\n<li>\n<p>foo</p>\n<p>bar</p>\n</li>\n</ul>\n"),
            (
                "- foo\n  - bar\n    - baz",
                "<ul>\n<li>foo\n<ul>\n<li>bar\n<ul>\n<li>baz</li>\n</ul>\n</li>\n</ul>\n</li>\n</ul>\n"
            ),
            ("* a\n*\n\n* c", "<ul>\n<li>\n<p>a</p>\n</li>\n<li></li>\n<li>\n<p>c</p>\n</li>\n</ul>\n"),
            ("- a\n- b\n\n- c", "<ul>\n<li>\n<p>a</p>\n</li>\n<li>\n<p>b</p>\n</li>\n<li>\n<p>c</p>\n</li>\n</ul>\n"),
            ("1. a\n\n   b", "<ol>\n<li>\n<p>a</p>\n<p>b</p>\n</li>\n</ol>\n"),
            ("-one\n\n2.two", "<p>-one</p>\n<p>2.two</p>\n"),
            ("1234567890. not ok", "<p>1234567890. not ok</p>\n"),
            (
                "- [ ] foo\n- [x] bar",
                "<ul>\n<li><input type=\"checkbox\" disabled /> foo</li>\n<li><input type=\"checkbox\" disabled checked /> bar</li>\n</ul>\n"
            ),
            (
                "| a |\n| - |\n| b |",
                "<table>\n<thead>\n<tr>\n<th>a</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td>b</td>\n</tr>\n</tbody>\n</table>\n"
            ),
            ("&nbsp; &amp; &copy; &#35; &#X22;", "<p>&nbsp; &amp; &copy; &#35; &#X22;</p>\n"),
            ("&nbsp &x; &#; &#x;", "<p>&amp;nbsp &x; &amp;#; &amp;#x;</p>\n"),
            ("\\!\\\"\\#\\$\\%\\&\\'\\(\\)\\*", "<p>!&quot;#$%&amp;'()*</p>\n"),
            ("\\\t\\A\\a\\ \\3\\φ\\«", "<p>\\\t\\A\\a\\ \\3\\φ\\«</p>\n"),
            // Documented differences from CommonMark: raw HTML is escaped, never passed through.
            ("<a><bab><c2c>", "<p>&lt;a&gt;&lt;bab&gt;&lt;c2c&gt;</p>\n"),
            ("<div>\n*hello*\n</div>", "<p>&lt;div&gt;\n<em>hello</em>\n&lt;/div&gt;</p>\n"),
            ("foo <!-- this is a\ncomment --> bar", "<p>foo &lt;!-- this is a\ncomment --&gt; bar</p>\n")
        ]
        for (source, expected) in cases {
            let actual = rendered(source)
            let label = source.replacingOccurrences(of: "\n", with: "\\n")
            if !check(actual == expected, "Markdown renders: \(label)") {
                print("  expected: \(expected.debugDescription)\n  actual:   \((actual ?? "nil").debugDescription)")
            }
        }
        check(
            rendered("a\r\nb\r\n\r\nc") == rendered("a\nb\n\nc") && rendered("a\rb\r\rc") == rendered("a\nb\n\nc"),
            "CRLF, CR and LF line endings render alike")
        check(rendered("x") == rendered("x\n"), "a final line ending does not change the output")
        let repeated = (0..<3).map { _ in rendered("# T\n\n- a\n- b\n\n[x][y]\n\n[y]: /z") }
        check(Set(repeated).count == 1 && repeated[0] != nil, "rendering is deterministic")
        check(
            MarkdownRenderer.render(Data([0x61, 0xFF, 0x62]), isCancelled: never) == .rendered("<p>a\u{FFFD}b</p>\n"),
            "invalid UTF-8 renders as the replacement character")
    }

    static func checkMarkdownSafety() throws {
        let hostile = [
            "<script>alert(1)</script>", "<img src=x onerror=alert(1)>",
            "<iframe src=\"https://example.com\"></iframe>",
            "<svg/onload=alert(1)>", "<style>body{display:none}</style>", "<a href=\"javascript:alert(1)\">x</a>",
            "<!--\n<script>\n-->", "<script>\nalert(1)\n</script>\n\ntext", "[x](javascript:alert(1))",
            "[x](JAVASCRIPT:alert(1))",
            "[x](  javascript:alert(1))", "[x](<javascript:alert(1)>)", "[x](<java\u{01}script:alert(1)>)",
            "[x](<\u{01}javascript:alert(1)>)", "[x](java\tscript:alert(1))", "[x](java\nscript:alert(1))",
            "![x](data:image/svg+xml;base64,AAAA)", "![x](javascript:alert(1))", "[x]: javascript:alert(1)\n\n[x]",
            "[x]: data:text/html,<script>alert(1)</script>\n\n![x]", "<javascript:alert(1)>", "<data:text/html,x>",
            "[x](vbscript:msgbox)", "[x](file:///etc/passwd)", "[x](FILE:///etc/passwd)", "![x](file:///etc/passwd)",
            "[x](https://a\" onmouseover=\"alert(1))", "![a\" onerror=\"alert(1)](x.png)",
            "[a](x \"t\\\" onclick=\\\"alert(1)\")", "```\"><script>alert(1)</script>\ncode\n```",
            "~~~ x\" onload=\"alert(1)\ncode\n~~~", "[x](&#x6A;avascript:alert(1))", "[x](javascript&colon;alert(1))",
            "[x](&#106;&#97;vascript:alert(1))", "[x](\\javascript:alert(1))",
            "[<b>x</b>](https://example.com \"<i>t</i>\")",
            "| <script> |\n|---|\n| <img onerror=x> |", "- <script>alert(1)</script>\n> <script>alert(2)</script>",
            "# <script>alert(1)</script>", "`<script>`", "    <script>alert(1)</script>",
            "\\<script>alert(1)\\</script>",
            "&lt;script&gt; &#60;script&#62;", "[x][y]\n\n[y]: <javascript:alert(1)> \"t\"", "<http://a\"onclick=\"x>",
            "<x@y.z\"onclick=\"a>", "![\"><script>](a.png)", "[a](b \"c\" d)", "[a](b 'c\"d')", "[a](b (c\"d))"
        ]
        for source in hostile {
            guard let html = rendered(source) else {
                check(false, "hostile Markdown renders: \(source.debugDescription)")
                continue
            }
            let violation = markdownOutputViolation(html)
            if !check(violation == nil, "hostile Markdown stays inert: \(source.debugDescription)") {
                print("  \(violation ?? "") in \(html.debugDescription)")
            }
        }
        check(rendered("[x](javascript:alert(1))") == "<p>x</p>\n", "a refused link keeps its text without an anchor")
        check(
            rendered("![alt *text*](javascript:alert(1))") == "<p>alt text</p>\n",
            "a refused image keeps its description")
        check(
            rendered("[x](https://example.com)")?.contains("href=\"https://example.com\"") == true,
            "an https link is kept")
        check(
            rendered("[x](mailto:a@example.com)")?.contains("href=\"mailto:a@example.com\"") == true,
            "a mailto link is kept")
        check(
            rendered("[x](../other/page.md#part)")?.contains("href=\"../other/page.md#part\"") == true,
            "a relative link is kept")
        // "//host/path" asks for another computer. Written out, it would be counted once as an
        // external resource and again as a local file that was refused.
        check(
            rendered("[x](//example.com/a) ![alt](//example.com/i.png) [y](<//example.com/b>)")
                == "<p>x alt y</p>\n",
            "a destination that starts with two slashes is refused: the link keeps its text, the image its description")
        check(
            rendered("[x]: //example.com/a\n\n[x] and [z](/one//two)")
                == "<p>x and <a href=\"/one//two\">z</a></p>\n",
            "through a reference too; two slashes later in a path are ordinary")
        if case .rendered(let fragment) = MarkdownRenderer.render("![alt](//example.com/i.png)", isCancelled: never),
            case .prepared(let scanned) = StaticHTMLPolicy.prepare(html: fragment, isCancelled: never)
        {
            check(scanned.report.externalReferences.isEmpty, "so nothing is left to report twice")
        } else {
            check(false, "a refused image renders")
        }
        for (url, allowed) in [
            ("http://a", true), ("HTTPS://a", true), ("mailto:a@b", true), ("a/b.png", true), ("#x", true),
            ("?q=1", true),
            ("a:b/c d", false), ("javascript:1", false), (" javascript:1", false), ("java\nscript:1", false),
            ("data:,x", false), ("file:///x", false), ("ftp://a", false), ("tel:1", false), ("x-custom://a", false),
            ("1a:b", true), ("a b:c", true), ("", true), ("//a/b", false), (" //a/b", false), ("/a//b", true),
            ("/a", true)
        ] {
            check(
                PreviewURLPolicy.allowsMarkdownDestination(url) == allowed,
                "URL policy \(allowed ? "allows" : "refuses") \(url.debugDescription)")
        }
        check(
            PreviewURLPolicy.scheme(of: "HtTp://x") == "http" && PreviewURLPolicy.scheme(of: "a/b:c") == nil,
            "the scheme is read as a browser reads it")
    }

    static func checkMarkdownBounds() {
        // Ten thousand nested quote markers on one line, and on many lines.
        let deepQuote = String(repeating: ">", count: 10_000) + " text"
        if let html = rendered(deepQuote) {
            let depth = html.components(separatedBy: "<blockquote>").count - 1
            check(depth == PreviewLimits.standard.markdownMaxNesting, "block quotes nest only to the cap (\(depth))")
            check(markdownOutputViolation(html) == nil, "over-deep block quotes still give well-formed output")
        } else {
            check(false, "10,000 nested quote markers render")
        }
        func deepestList(in html: String) -> Int {
            var depth = 0
            var deepest = 0
            for line in html.split(separator: "\n") {
                if line == "<ul>" { depth += 1 }
                if line == "</ul>" { depth -= 1 }
                deepest = max(deepest, depth)
            }
            return deepest
        }
        let cap = PreviewLimits.standard.markdownMaxNesting
        // Ten thousand list items whose indentation climbs to 40 levels again and again.
        let manyItems = (0..<10_000).map { String(repeating: "  ", count: $0 % 41) + "- item \($0)" }.joined(
            separator: "\n")
        if let html = rendered(manyItems) {
            check(
                deepestList(in: html) == cap,
                "10,000 list items indented to 40 levels nest only to the cap (\(deepestList(in: html)))")
            check(markdownOutputViolation(html) == nil, "over-deep lists still give well-formed output")
        } else {
            check(false, "10,000 nested list items render")
        }
        // One list that goes 300 levels deep, each item inside the one before.
        let staircase = (0..<300).map { String(repeating: "  ", count: $0) + "- level \($0)" }.joined(separator: "\n")
        if let html = rendered(staircase) {
            check(
                deepestList(in: html) == cap, "a list 300 levels deep nests only to the cap (\(deepestList(in: html)))")
            check(
                html.contains("level 299") && markdownOutputViolation(html) == nil,
                "text beyond the nesting cap is still shown")
        } else {
            check(false, "a list 300 levels deep renders")
        }
        var shallow = PreviewLimits.standard
        shallow.markdownMaxNesting = 2
        check(
            rendered("> > > a", limits: shallow)
                == "<blockquote>\n<blockquote>\n<p>&gt; a</p>\n</blockquote>\n</blockquote>\n",
            "a marker beyond the nesting cap is shown as text")

        check(
            rendered("```\nnever closed\n# still code") == "<pre><code>never closed\n# still code\n</code></pre>\n",
            "an unterminated fence runs to the end of the document")
        check(
            rendered("> ```\n> quoted code\nafter")
                == "<blockquote>\n<pre><code>quoted code\n</code></pre>\n</blockquote>\n<p>after</p>\n",
            "an unterminated fence ends with its container")

        let wideRow = "|" + String(repeating: " c |", count: 2_000)
        let wideTable =
            wideRow + "\n|" + String(repeating: "---|", count: 2_000) + "\n"
            + String(repeating: wideRow + "\n", count: 100)
        if let html = rendered(wideTable) {
            check(html.components(separatedBy: "<td>").count - 1 == 200_000, "a 2,000 by 100 table renders every cell")
        } else {
            check(false, "a huge table renders")
        }

        checkMarkdownTableBounds()
        checkLinkTargetScan()

        let storms: [(String, String)] = [
            ("unclosed brackets", String(repeating: "[", count: 200_000)),
            ("closing brackets", String(repeating: "]", count: 200_000)),
            ("bracket pairs", String(repeating: "[]", count: 100_000)),
            ("link openings", String(repeating: "[a](", count: 50_000)),
            ("link tails without an end", String(repeating: "[a](x", count: 50_000)),
            ("nested images", String(repeating: "![a", count: 50_000) + String(repeating: "](u)", count: 50_000)),
            ("emphasis openers", String(repeating: "*a ", count: 70_000)),
            ("mixed emphasis", String(repeating: "_a ", count: 35_000) + String(repeating: "b* ", count: 35_000)),
            ("alternating runs", String(repeating: "*a**b***c", count: 20_000)),
            ("backtick runs", (0..<8_000).map { String(repeating: "`", count: $0 % 50 + 1) + "a" }.joined()),
            ("angle brackets", String(repeating: "<", count: 200_000)),
            ("ampersands", String(repeating: "&", count: 200_000)),
            ("backslashes", String(repeating: "\\", count: 200_000)),
            ("reference links", "[a]: /u\n\n" + String(repeating: "[a][a]", count: 30_000)),
            (
                "reference brackets",
                "[a]: /u\n\n" + String(repeating: "[", count: 100_000) + "a" + String(repeating: "]", count: 100_000)
            ),
            ("quote lines", String(repeating: String(repeating: "> ", count: 30) + "text\n", count: 3_000)),
            ("lazy lines", "> a\n" + String(repeating: "b\n", count: 100_000)),
            ("pipes", String(repeating: "|\n", count: 100_000)),
            ("one long line", String(repeating: "word ", count: 50_000))
        ]
        for (name, source) in storms {
            var output: String?
            let elapsed = seconds { output = rendered(source) }
            let violation = output.flatMap(markdownOutputViolation)
            check(
                output != nil && violation == nil,
                "adversarial Markdown (\(name), \(source.utf8.count) bytes) renders safely in bounded time (\(String(format: "%.2f", elapsed)) s; \(violation ?? "ok"))"
            )
        }

        var small = PreviewLimits.standard
        small.maxSourceBytes = 1_000
        let tooLarge = String(repeating: "a", count: 1_001)
        check(
            MarkdownRenderer.render(tooLarge, limits: small, isCancelled: never)
                == .limited(.sourceTooLarge(maxBytes: 1_000)),
            "Markdown over the source limit is refused with the reason")
        check(
            MarkdownRenderer.render(Data(tooLarge.utf8), limits: small, isCancelled: never)
                == .limited(.sourceTooLarge(maxBytes: 1_000)),
            "Markdown bytes over the source limit are refused with the reason")
        check(
            rendered(String(repeating: "a", count: 1_000), limits: small) != nil,
            "Markdown exactly at the source limit renders")
        var smallOutput = PreviewLimits.standard
        smallOutput.maxOutputBytes = 2_000
        let expanding = String(repeating: "&\n\n", count: 1_000)
        check(
            MarkdownRenderer.render(expanding, limits: smallOutput, isCancelled: never)
                == .limited(.outputTooLarge(maxBytes: 2_000)),
            "Markdown whose HTML passes the output limit is refused with the reason")
    }

    /// The most memory this process has used so far, in bytes.
    private static func peakMemory() -> Int {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Int(usage.ru_maxrss)
    }

    /// A table whose rows are much shorter than its header must not be padded in memory: 100 KB
    /// of source once asked for 300 million empty cells.
    static func checkMarkdownTableBounds() {
        func table(columns: Int, rows: Int) -> String {
            String(repeating: "|a", count: columns) + "\n" + String(repeating: "|-", count: columns) + "\n"
                + String(repeating: "|\n", count: rows)
        }
        let megabyte = 1_048_576
        let limits = PreviewLimits.standard

        // Wider than the column cap: not a table at all.
        let tooWide = table(columns: 12_500, rows: 25_000)
        var memoryBefore = peakMemory()
        var outcome = MarkdownRendering.cancelled
        var elapsed = seconds { outcome = MarkdownRenderer.render(tooWide, isCancelled: never) }
        var growth = (peakMemory() - memoryBefore) / megabyte
        if case .rendered(let html) = outcome {
            check(
                !html.contains("<table>") && html.contains("|a|a") && markdownOutputViolation(html) == nil,
                "a header wider than \(limits.markdownMaxTableColumns) columns is shown as text, not as a table")
        } else {
            check(false, "a 12,500-column header with 25,000 short rows renders as text: \(outcome)")
        }
        check(
            elapsed < 5 && growth < 200,
            "100 KB of table-shaped text costs little: \(String(format: "%.2f", elapsed)) s, peak memory grew \(growth) MB")

        // Inside the column cap, but 96 million cells once padded.
        let manyCells = table(columns: 4_000, rows: 24_000)
        memoryBefore = peakMemory()
        elapsed = seconds { outcome = MarkdownRenderer.render(manyCells, isCancelled: never) }
        growth = (peakMemory() - memoryBefore) / megabyte
        check(
            outcome == .limited(.tooManyTableCells(maxCells: limits.markdownMaxTableCells)),
            "a table of 4,000 columns and 24,000 short rows stops at the cell limit")
        check(
            elapsed < 5 && growth < 200,
            "and stops early: \(String(format: "%.2f", elapsed)) s, peak memory grew \(growth) MB")
        check(
            PreviewLimit.tooManyTableCells(maxCells: 1_000_000).message
                == "This document is too large to preview. Its tables have more than \(Strings.number(1_000_000)) cells.",
            "the cell limit has a plain sentence")

        // With the cell limit out of the way, the rows are still not padded in memory, the
        // output limit ends the work, and cancellation is seen while the rows are read.
        var unlimitedCells = limits
        unlimitedCells.markdownMaxTableCells = Int.max
        memoryBefore = peakMemory()
        elapsed = seconds { outcome = MarkdownRenderer.render(manyCells, limits: unlimitedCells, isCancelled: never) }
        growth = (peakMemory() - memoryBefore) / megabyte
        check(
            outcome == .limited(.outputTooLarge(maxBytes: limits.maxOutputBytes)) && elapsed < 10 && growth < 300,
            "short rows are padded only as they are written, under the output limit: \(String(format: "%.2f", elapsed)) s, peak memory grew \(growth) MB")
        let tallTable = table(columns: 2, rows: 400_000)
        let rowProbe = CancellationProbe()
        _ = MarkdownRenderer.render(tallTable, limits: unlimitedCells, isCancelled: rowProbe.isCancelled)
        let cancelling = CancellationProbe(cancelAtPoll: 20)
        elapsed = seconds {
            outcome = MarkdownRenderer.render(tallTable, limits: unlimitedCells, isCancelled: cancelling.isCancelled)
        }
        check(
            outcome == .cancelled && cancelling.polls == 20 && rowProbe.polls >= 2 * (tallTable.utf8.count / 8192),
            "table rows are polled as they are read and as they are written (\(rowProbe.polls) polls for \(tallTable.utf8.count) bytes), and cancelling stops at once")
        let wideCancel = CancellationProbe(cancelAtPoll: 2)
        memoryBefore = peakMemory()
        elapsed = seconds {
            outcome = MarkdownRenderer.render(manyCells, limits: unlimitedCells, isCancelled: wideCancel.isCancelled)
        }
        growth = (peakMemory() - memoryBefore) / megabyte
        check(
            outcome == .cancelled && wideCancel.polls == 2 && elapsed < 1 && growth < 100,
            "cancelling a wide table is prompt: \(String(format: "%.3f", elapsed)) s, peak memory grew \(growth) MB")

        check(
            rendered("| a | b | c |\n|---|---|---|\n| 1 |\n| 1 | 2 | 3 | 4 |")
                == "<table>\n<thead>\n<tr>\n<th>a</th>\n<th>b</th>\n<th>c</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td>1</td>\n<td></td>\n<td></td>\n</tr>\n<tr>\n<td>1</td>\n<td>2</td>\n<td>3</td>\n</tr>\n</tbody>\n</table>\n",
            "a short row is still padded and a long row still cut to the header's width")
        var narrow = limits
        narrow.markdownMaxTableColumns = 2
        check(
            rendered("|a|b|\n|-|-|\n|1|2|", limits: narrow)?.contains("<table>") == true
                && rendered("|a|b|c|\n|-|-|-|\n|1|2|3|", limits: narrow)?.contains("<table>") == false,
            "the column cap is exact")
    }

    /// `[](a (` repeated: every `](` once started a scan of up to 2,048 bytes for a closing
    /// parenthesis that is not there.
    static func checkLinkTargetScan() {
        let hostile = String(repeating: "[](a (", count: 1_048_576 / 6)
        let plain = String(repeating: "word ", count: hostile.utf8.count / 5)
        var plainHTML: String?
        var hostileHTML: String?
        let plainSeconds = seconds { plainHTML = rendered(plain) }
        let hostileSeconds = seconds { hostileHTML = rendered(hostile) }
        check(
            plainHTML != nil && hostileHTML != nil && hostileSeconds < 10 * plainSeconds + 0.3,
            "1 MB of failed link targets takes time in proportion to its size: \(String(format: "%.2f", hostileSeconds)) s against \(String(format: "%.2f", plainSeconds)) s for plain text of the same size")
        check(
            hostileHTML == "<p>" + hostile + "</p>\n" && markdownOutputViolation(hostileHTML ?? "") == nil,
            "and is shown as the text that was typed")
        let later = String(repeating: "[](a (", count: 100) + " [real](https://example.com/x \"t\")"
        check(
            rendered(later)?.contains("<a href=\"https://example.com/x\" title=\"t\">real</a>") == true,
            "a link after a few failed attempts is still a link")
        let exhausted = String(repeating: "[](a (", count: 4_000) + " [real](https://example.com/x) [ref]\n\n[ref]: /r"
        check(
            rendered(exhausted)?.contains("[real](https://example.com/x)") == true
                && rendered(exhausted)?.contains("<a href=\"/r\">ref</a>") == true,
            "once the allowance is used up the paragraph has no more inline links; reference links still work")
        check(
            rendered(exhausted + "\n\n[next](https://example.com/y)")?.contains(
                "<a href=\"https://example.com/y\">next</a>") == true,
            "the next paragraph starts with a full allowance")
    }

    /// A document of about two mebibytes that mixes every block construct.
    static func largeMarkdown() -> String {
        let section = """
            # Section *title* with `code`

            A paragraph with **strong text**, a [link](https://example.com/page "Title"), an image
            ![picture](images/p.png) and a reference to [the note][note]. It runs on for a while so
            that paragraphs carry most of the bytes, as they do in ordinary documents.

            - first item
            - second item with *emphasis*
              - nested item
            - [x] finished task

            > A quoted paragraph
            > over two lines.

            ```swift
            let value = items.map { $0 * 2 }.filter { $0 > 10 }
            ```

            | Name | Value |
            |------|------:|
            | one  |     1 |
            | two  |     2 |

            [note]: https://example.com/note


            """
        return String(repeating: section, count: 2 * 1024 * 1024 / section.utf8.count + 1)
    }

    static func checkMarkdownCancellation() async {
        let source = largeMarkdown()
        let bytes = source.utf8.count
        check(
            bytes >= 2 * 1024 * 1024 && bytes <= PreviewLimits.standard.maxSourceBytes,
            "the timing document is at least 2 MiB (\(bytes) bytes)")

        let probe = CancellationProbe()
        var result = MarkdownRendering.cancelled
        let elapsed = seconds { result = MarkdownRenderer.render(source, isCancelled: probe.isCancelled) }
        if case .rendered(let html) = result {
            check(
                html.utf8.count > bytes,
                "a 2 MiB Markdown document renders completely (\(String(format: "%.2f", elapsed)) s in this build)")
        } else {
            check(false, "a 2 MiB Markdown document renders completely")
        }
        check(
            probe.polls >= bytes / 8192,
            "cancellation is polled at least every few thousand bytes (\(probe.polls) polls for \(bytes) bytes)")

        // Cancelling at the Nth poll stops the work at that poll, wherever it is in the document.
        for cancelAt in [1, 2, 10, probe.polls / 2, probe.polls] {
            let cancelling = CancellationProbe(cancelAtPoll: cancelAt)
            let outcome = MarkdownRenderer.render(source, isCancelled: cancelling.isCancelled)
            check(
                outcome == .cancelled && cancelling.polls == cancelAt,
                "cancelling at poll \(cancelAt) stops rendering at once")
        }

        let longLine = String(repeating: "a", count: 1024 * 1024)
        let lineProbe = CancellationProbe()
        _ = MarkdownRenderer.render(longLine, isCancelled: lineProbe.isCancelled)
        check(
            lineProbe.polls >= longLine.utf8.count / 8192,
            "a single 1 MiB line is polled as often as many short lines (\(lineProbe.polls) polls)")

        // Blocks that are read line by line before any inline text is rendered are polled there.
        let codeBlock = String(repeating: "    indented code\n", count: 60_000)
        let codeProbe = CancellationProbe()
        _ = MarkdownRenderer.render(codeBlock, isCancelled: codeProbe.isCancelled)
        check(
            codeProbe.polls >= codeBlock.utf8.count / 4096 - 1,
            "one indented code block of \(codeBlock.utf8.count) bytes is polled while it is read (\(codeProbe.polls) polls)")
        let paragraph = String(repeating: "one line of a long paragraph\n", count: 40_000)
        let paragraphProbe = CancellationProbe()
        _ = MarkdownRenderer.render(paragraph, isCancelled: paragraphProbe.isCancelled)
        check(
            paragraphProbe.polls >= paragraph.utf8.count / 4096 + paragraph.utf8.count / 8192,
            "one paragraph of \(paragraph.utf8.count) bytes is polled while its lines are gathered and again while it is rendered (\(paragraphProbe.polls) polls)")

        // The default closure reads the cancellation state of the calling task.
        let detached = Task.detached { () -> MarkdownRendering in
            withUnsafeCurrentTask { $0?.cancel() }
            return MarkdownRenderer.render(String(repeating: "paragraph text\n\n", count: 10_000))
        }
        let detachedResult = await detached.value
        check(detachedResult == .cancelled, "the default cancellation check works inside Task.detached")
        let running = Task.detached { MarkdownRenderer.render("still *runs*") }
        let runningResult = await running.value
        check(
            runningResult == .rendered("<p>still <em>runs</em></p>\n"), "a task that is not cancelled renders normally")
    }

    // MARK: HTML

    static func checkWrapper() {
        let policy = StaticHTMLPolicy.contentSecurityPolicy()
        check(
            policy
                == "default-src 'none'; img-src texttank-preview:; style-src texttank-preview: 'unsafe-inline'; font-src 'none'; script-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'",
            "the content security policy is exactly the strict policy")
        check(
            StaticHTMLPolicy.contentSecurityPolicy(scheme: "other").contains(
                "img-src other:; style-src other: 'unsafe-inline'"), "the policy scheme is a parameter")
        let page = StaticHTMLPolicy.wrapFragment(
            "<p>body</p>", title: "A <b> & \"title\"", stylesheet: "p { margin: 0 } /* </style><script>x</script> */")
        check(
            page.hasPrefix(
                "<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">\n"
            ), "the wrapper starts with the charset and then the policy")
        check(page.contains("<title>A &lt;b&gt; &amp; &quot;title&quot;</title>"), "the wrapper escapes the title")
        check(
            page.components(separatedBy: "</style>").count == 2 && !page.contains("</script>"),
            "stylesheet text cannot close its style element")
        check(page.contains("<body>\n<p>body</p>\n</body>\n</html>\n"), "the wrapper places the fragment in the body")
        check(
            StaticHTMLPolicy.wrapFragment("", title: "", stylesheet: "", bodyClass: "a\"b").contains(
                "<body class=\"a&quot;b\">"), "the body class is escaped")
        if let stylesheet = try? String(
            contentsOf: TestPaths.resources.appendingPathComponent("Preview/preview.css"), encoding: .utf8)
        {
            check(
                stylesheet.contains("color-scheme: light dark") && stylesheet.contains("system-ui")
                    && stylesheet.contains("max-width: none"),
                "the bundled stylesheet follows the system appearance and font")
            check(
                !stylesheet.contains("</") && !stylesheet.contains("@import") && !stylesheet.contains("http"),
                "the bundled stylesheet loads nothing")
            check(
                stylesheet.range(of: "#[0-9a-fA-F]{3,8}\\b|rgb\\(|hsl\\(", options: .regularExpression) == nil,
                "the bundled stylesheet names no literal colour")
            check(stylesheet.contains("body.\(SVGPolicy.bodyClass)"), "the bundled stylesheet styles the image page")
            check(
                PreviewStylesheet.resourceName == "preview" && PreviewStylesheet.resourceExtension == "css",
                "the stylesheet resource name matches the bundled file")
        } else {
            check(false, "the bundled preview stylesheet is readable")
        }
    }

    static func checkHTMLPreparation() throws {
        let policyTag =
            "<meta http-equiv=\"Content-Security-Policy\" content=\"\(StaticHTMLPolicy.contentSecurityPolicy())\">"

        let trickySource = try PreviewFixtures.text("html/tricky.html")
        let tricky = try requireValue(preparedHTML(trickySource), "the tricky HTML fixture is prepared")
        check(
            tricky.html.contains("<HEAD data-x=\"<head>\">" + policyTag + "\n<TITLE>"),
            "the policy is the first thing in an uppercase head with a quoted bracket")
        check(tricky.html.components(separatedBy: policyTag).count == 2, "the policy is inserted exactly once")
        check(
            tricky.html.replacingOccurrences(of: policyTag, with: "") == trickySource,
            "nothing else in the document is rewritten")
        let expectedReferences = [
            "http://cdn.example/style.css", "http://import.example/a.css", "https://import.example/b.css",
            "HTTPS://bg.example/bg.png", "//protocol-relative.example/lib.js", "http://attr.example/bg.png",
            "http://img.example/a.png", "http://img.example/a-1x.png", "https://img.example/a-2x.png",
            "https://frame.example/", "http://video.example/poster.jpg", "http://video.example/v.mp4",
            "http://audio.example/a.mp3", "http://object.example/o.swf", "http://embed.example/e.swf"
        ]
        if !check(
            tricky.report.externalReferences == expectedReferences,
            "external references are found in order, once each, outside comments, scripts and CDATA")
        {
            print("  actual: \(tricky.report.externalReferences)")
        }
        check(
            tricky.report.scriptCount == 7,
            "script elements, event handlers and javascript: addresses are counted (\(tricky.report.scriptCount))")
        check(tricky.report.hasBaseTag, "a base tag is reported")
        check(
            PreviewSummary.text(for: tricky.report) == "15 external resources were blocked. 7 scripts were not run.",
            "the summary for the tricky fixture reads correctly")

        let plainSource = try PreviewFixtures.text("html/plain.html")
        let plain = try requireValue(preparedHTML(plainSource), "the plain HTML fixture is prepared")
        check(
            plain.html.contains("<head>" + policyTag + "\n<meta charset=\"utf-8\">"),
            "the policy comes before the document's own head content")
        check(plain.report == PreviewContentReport(), "a page with only local resources has an empty report")
        check(PreviewSummary.text(for: plain.report) == nil, "an empty report has no summary")

        let noHead = try requireValue(
            preparedHTML(try PreviewFixtures.text("html/no-head.html")), "the no-head fixture is prepared")
        check(
            noHead.html.hasPrefix("<html lang=\"en\"><head>" + policyTag + "</head><body>"),
            "a head is created after the html tag when missing")
        let doctypeOnly = try requireValue(
            preparedHTML(try PreviewFixtures.text("html/doctype-only.html")), "the doctype-only fixture is prepared")
        check(
            doctypeOnly.html.hasPrefix("<!DOCTYPE html><head>" + policyTag + "</head>\n<p>"),
            "a head is created after the doctype when there is no html tag")
        let fragment = try requireValue(
            preparedHTML(try PreviewFixtures.text("html/fragment.html")), "the fragment fixture is prepared")
        check(
            fragment.html.hasPrefix("<head>" + policyTag + "</head><p>A bare fragment"),
            "a head is created at the start of a bare fragment")

        check(preparedHTML("")?.html == "<head>" + policyTag + "</head>", "an empty document becomes just the policy")
        check(
            preparedHTML("<!-- <head> --><html><body>")?.html.hasPrefix("<!-- <head> --><html><head>" + policyTag)
                == true, "a head tag inside a comment is ignored")
        check(
            preparedHTML("<script>var s = '<head>';</script><p>")?.html.hasPrefix(
                "<head>" + policyTag + "</head><script>") == true, "a head tag inside a script is ignored")
        check(
            preparedHTML("<head><head>")?.html == "<head>" + policyTag + "<head>",
            "only the first head receives the policy")
        check(
            preparedHTML("<html><head")?.html.hasSuffix("<head" + policyTag) == true,
            "an unfinished head tag at the end of the document still receives the policy")

        func report(_ html: String) -> PreviewContentReport { preparedHTML(html)?.report ?? PreviewContentReport() }
        check(
            report("<IMG SRC=HTTP://X.example/A.PNG>").externalReferences == ["HTTP://X.example/A.PNG"],
            "uppercase tags and unquoted attributes are read")
        check(
            report("<img\n\tsrc = 'http://x.example/a.png'\n>").externalReferences == ["http://x.example/a.png"],
            "attributes may be spread over lines with spaces around the equals sign")
        check(
            report("<img src=\"  http://x.example/a.png \">").externalReferences == ["http://x.example/a.png"],
            "whitespace around an address is ignored")
        check(
            report("<img src=\"http://x.example/a.png").externalReferences == ["http://x.example/a.png"],
            "an unterminated attribute at the end of the document is still read")
        check(
            report("<img data-src=\"http://x.example/a.png\" alt=\"http://x.example/b.png\">").externalReferences
                .isEmpty, "attributes that load nothing are not reported")
        check(
            report("<a href=\"http://x.example/\">x</a><form action=\"http://x.example/\">").externalReferences.isEmpty,
            "links and forms are not loaded resources")
        check(
            report("<img srcset=\"a.png 1x,http://x.example/b.png 2x , //y.example/c.png\">").externalReferences == [
                "http://x.example/b.png", "//y.example/c.png"
            ], "each srcset candidate is examined")
        check(
            report("<style>@IMPORT 'HTTP://x.example/a.css'; p{background:URL(\"https://x.example/b.png\")}</style>")
                .externalReferences == ["HTTP://x.example/a.css", "https://x.example/b.png"],
            "style sheets are scanned without regard to case")
        check(
            report("<style>p{background:url(data:image/png;base64,AAAA)} @import 'local.css';</style>")
                .externalReferences.isEmpty, "local and data addresses in style sheets are not external")
        check(
            report("<p style='background:url(//x.example/a.png)'>").externalReferences == ["//x.example/a.png"],
            "inline styles are scanned")
        check(
            report("<script>\"</scr\" + \"ipt>\"; x = '<img src=http://x.example/a.png>'</script>").externalReferences
                .isEmpty, "markup inside a script is not markup")
        check(
            report("<script></script><SCRIPT SRC=a.js></SCRIPT><script/>").scriptCount == 3,
            "script elements are counted in any case")
        check(
            report("<p onclick=a ONMOUSEOVER='b' on='c' open>").scriptCount == 2,
            "only attributes that start with on and have more letters are event handlers")
        check(
            report("<a href='javascript:x'></a><a href=' java\tscript:x'></a><form action=JAVASCRIPT:x>").scriptCount
                == 3, "javascript: addresses are counted however they are disguised")
        check(
            report("<!--<script>--><![CDATA[<script>]]><p title='<script>'>&lt;script&gt;").scriptCount == 0,
            "script text in comments, CDATA, attributes and entities is not a script")
        check(
            report("<base href='/x'>").hasBaseTag && !report("<p>base</p><!-- <base> -->").hasBaseTag,
            "only a real base tag is reported")
        check(report("< p><3 <-- a < b > c <\n").scriptCount == 0, "stray angle brackets are tolerated")

        // A script ends at "</script" followed by a space, a slash or ">", not at "</scriptx".
        let longerName = report("<script>a</scriptx><img src='http://inside.example/a.png'></script><img src='http://after.example/b.png'>")
        check(
            longerName.externalReferences == ["http://after.example/b.png"] && longerName.scriptCount == 1,
            "\"</scriptx\" does not end a script: \(longerName.externalReferences)")
        check(
            preparedHTML("<script></scriptx><head></script><p>")?.html == "<head>" + policyTag + "</head><script></scriptx><head></script><p>",
            "so a head tag written inside that script is not taken for the document's head")
        for ending in ["</script>", "</SCRIPT >", "</script/>", "</script\n>"] {
            check(
                report("<script>x\(ending)<img src='http://after.example/b.png'>").externalReferences
                    == ["http://after.example/b.png"], "a script ends at \(ending.debugDescription)")
        }
        check(
            report("<style>a{}</stylesheet>b{background:url(http://in.example/a.png)}</style>").externalReferences
                == ["http://in.example/a.png"], "\"</stylesheet\" does not end a style element")

        // Style sheets are polled like everything else.
        let sheet = String(repeating: "a { color: red; background: none }\n", count: 30_000)
        // The tokenizer polls a style element byte by byte and a tag once; the style scan then
        // reads the same bytes again, polling as it goes.
        for (name, document, passes) in [
            ("a style element", "<style>" + sheet + "</style>", 2),
            ("a style attribute", "<p style=\"" + sheet + "\">", 1)
        ] {
            let probe = CancellationProbe()
            _ = StaticHTMLPolicy.prepare(html: document, isCancelled: probe.isCancelled)
            check(
                probe.polls >= passes * (document.utf8.count / 4096) - 2,
                "\(name) of \(document.utf8.count) bytes is polled while its addresses are read (\(probe.polls) polls)")
            let cancelling = CancellationProbe(cancelAtPoll: probe.polls - 1)
            check(
                StaticHTMLPolicy.prepare(html: document, isCancelled: cancelling.isCancelled) == .cancelled,
                "and cancelling near the end of \(name) stops it")
        }
        let svgSheet = "<svg><style>" + sheet + "</style></svg>"
        let svgProbe = CancellationProbe()
        _ = SVGPolicy.scan(svgSheet, isCancelled: svgProbe.isCancelled)
        check(svgProbe.polls >= 2 * (svgSheet.utf8.count / 4096) - 2, "an SVG style sheet is polled too")
        check(
            report(String(repeating: "<img src='http://x.example/a.png'>", count: 5_000)).externalReferences.count == 1,
            "a repeated reference is listed once")
        let many = (0..<1_500).map { "<img src='http://x.example/\($0).png'>" }.joined()
        check(
            report(many).externalReferences.count == PreviewContentReport.maxListedReferences,
            "the list of references is capped")

        var small = PreviewLimits.standard
        small.maxSourceBytes = 100
        check(
            StaticHTMLPolicy.prepare(html: String(repeating: "x", count: 101), limits: small, isCancelled: never)
                == .limited(.sourceTooLarge(maxBytes: 100)), "HTML over the source limit is refused with the reason")
        let large = String(repeating: "<p class=\"a\">text</p><!-- comment --><script>x < y</script>\n", count: 20_000)
        let probe = CancellationProbe()
        var outcome = HTMLPreparation.cancelled
        let elapsed = seconds { outcome = StaticHTMLPolicy.prepare(html: large, isCancelled: probe.isCancelled) }
        if case .prepared(let prepared) = outcome {
            check(
                prepared.report.scriptCount == 20_000,
                "a large HTML document is scanned completely (\(large.utf8.count) bytes, \(String(format: "%.2f", elapsed)) s)"
            )
        } else {
            check(false, "a large HTML document is scanned completely")
        }
        check(
            probe.polls >= large.utf8.count / 8192,
            "HTML scanning polls for cancellation every few thousand bytes (\(probe.polls) polls)")
        let cancelling = CancellationProbe(cancelAtPoll: 3)
        check(
            StaticHTMLPolicy.prepare(html: large, isCancelled: cancelling.isCancelled) == .cancelled
                && cancelling.polls == 3, "HTML scanning stops when cancelled")
        for hostile in [
            "<!--" + String(repeating: "-", count: 300_000), String(repeating: "<", count: 300_000),
            "<a " + String(repeating: "b ", count: 150_000), "<script>" + String(repeating: "</", count: 150_000),
            String(repeating: "<a b=\"", count: 50_000)
        ] {
            check(
                preparedHTML(hostile) != nil,
                "malformed HTML is scanned in bounded time (\(hostile.prefix(12))…, \(hostile.utf8.count) bytes)")
        }
    }

    static func checkResourceResolver() throws {
        let document = URL(fileURLWithPath: "/Users/reader/Site/page.html")
        /// A fake disk: path to size. Symbolic links are a second table.
        let files: [String: Int] = [
            "/Users/reader/Site/style.css": 10, "/Users/reader/Site/images/a.png": 20,
            "/Users/reader/Site/images/B.JPG": 30,
            "/Users/reader/Site/big.png": 9 * 1024 * 1024, "/Users/reader/Site/exact.png": 8 * 1024 * 1024,
            "/Users/reader/Site/notes.txt": 5, "/Users/reader/Site/page.html": 5, "/Users/reader/Site/a b.png": 1,
            "/Users/reader/Site/100%.png": 1, "/Users/reader/secret.png": 1, "/Users/reader/Site-other/x.png": 1,
            "/etc/passwd": 1, "/Users/reader/Site/sub/deep/c.svg": 1, "/Users/reader/Site/script.js": 1,
            "/Users/reader/Site/noextension": 1, "/Users/reader/Site/archive.png.zip": 1
        ]
        let links: [String: String] = [
            "/Users/reader/Site/escape.png": "/Users/reader/secret.png",
            "/Users/reader/Site/inside.png": "/Users/reader/Site/images/a.png",
            "/Users/reader/Site/disguised.png": "/Users/reader/Site/notes.txt",
            "/Users/reader/Site/linkdir": "/Users/reader"
        ]
        let resolveLinks: @Sendable (URL) -> URL = { url in
            var path = url.path
            for (link, target) in links where path == link || path.hasPrefix(link + "/") {
                path = target + path.dropFirst(link.count)
            }
            return URL(fileURLWithPath: path)
        }
        let home = URL(fileURLWithPath: "/Users/reader")
        let resolver = PreviewResourceResolver(
            documentURL: document, homeDirectory: home, resolveSymlinks: resolveLinks, fileSize: { files[$0.path] })
        func resolve(_ path: String) -> PreviewResourceResolver.Resolution { resolver.resolve(requestPath: path) }

        // A document saved directly in the home folder or at the top of the disk has no folder
        // of its own: "its folder" would be everything the person owns, or the whole disk.
        func resolve(_ path: String, documentAt location: String) -> PreviewResourceResolver.Resolution {
            PreviewResourceResolver(
                documentURL: URL(fileURLWithPath: location), homeDirectory: home, resolveSymlinks: resolveLinks,
                fileSize: { _ in 1 }
            ).resolve(requestPath: path)
        }
        check(
            resolve("secret.png", documentAt: "/Users/reader/page.html") == .denied(.documentFolderTooBroad)
                && resolve("Site/style.css", documentAt: "/Users/reader/page.html") == .denied(.documentFolderTooBroad),
            "a document in the home folder itself is served no local file")
        check(
            resolve("etc/x.png", documentAt: "/page.html") == .denied(.documentFolderTooBroad),
            "a document at the top of the disk is served no local file")
        check(
            resolve("x.png", documentAt: "/Users/reader/Site/linkdir/page.html") == .denied(.documentFolderTooBroad),
            "a folder that is a link to the home folder counts as the home folder")
        check(
            resolve("x.png", documentAt: "/Users/reader/Documents/page.html")
                == .allowed(URL(fileURLWithPath: "/Users/reader/Documents/x.png"), mimeType: "image/png")
                && resolve("x.png", documentAt: "/Users/other/page.html")
                    == .allowed(URL(fileURLWithPath: "/Users/other/x.png"), mimeType: "image/png"),
            "a subfolder of the home folder, and another folder beside it, are ordinary document folders")
        func allowed(_ path: String, _ mimeType: String) -> PreviewResourceResolver.Resolution {
            .allowed(URL(fileURLWithPath: path), mimeType: mimeType)
        }

        check(
            resolve("/style.css") == allowed("/Users/reader/Site/style.css", "text/css"),
            "a stylesheet beside the document is served")
        check(
            resolve("style.css") == allowed("/Users/reader/Site/style.css", "text/css"), "the leading slash is optional"
        )
        check(
            resolve("/images/a.png") == allowed("/Users/reader/Site/images/a.png", "image/png"),
            "an image in a subfolder is served")
        check(
            resolve("/images/B.JPG") == allowed("/Users/reader/Site/images/B.JPG", "image/jpeg"),
            "the extension is matched without regard to case")
        check(
            resolve("/sub/deep/c.svg") == allowed("/Users/reader/Site/sub/deep/c.svg", "image/svg+xml"),
            "SVG is served as an image")
        check(
            resolve("/a%20b.png") == allowed("/Users/reader/Site/a b.png", "image/png"), "percent-encoding is decoded")
        check(
            resolve("/100%25.png") == allowed("/Users/reader/Site/100%.png", "image/png"),
            "an encoded percent sign is decoded once")
        check(
            resolve("/images/./../images//a.png") == allowed("/Users/reader/Site/images/a.png", "image/png"),
            "dots that stay inside the folder are harmless")
        check(
            resolve("/exact.png") == allowed("/Users/reader/Site/exact.png", "image/png"),
            "a file exactly at the size cap is served")
        check(
            resolve("/inside.png") == allowed("/Users/reader/Site/images/a.png", "image/png"),
            "a link that stays inside the folder is followed")

        check(resolve("/../secret.png") == .denied(.outsideDocumentFolder), "a parent-folder path is refused")
        check(
            resolve("/images/../../secret.png") == .denied(.outsideDocumentFolder),
            "a path that climbs out through a subfolder is refused")
        check(resolve("/%2e%2e/secret.png") == .denied(.outsideDocumentFolder), "encoded dots are refused")
        check(resolve("/..%2Fsecret.png") == .denied(.outsideDocumentFolder), "an encoded slash is refused")
        check(
            resolve("/%2E%2E%2F%2E%2E%2F%2E%2E%2Fetc%2Fpasswd.png") == .denied(.outsideDocumentFolder),
            "a fully encoded climbing path is refused")
        check(
            resolve("/../Site-other/x.png") == .denied(.outsideDocumentFolder),
            "a sibling folder with the same name prefix is refused")
        check(resolve("/..") == .denied(.outsideDocumentFolder), "the parent folder itself is refused")
        check(
            resolve("/escape.png") == .denied(.outsideDocumentFolder), "a link that leads outside the folder is refused"
        )
        check(
            resolve("/linkdir/secret.png") == .denied(.outsideDocumentFolder),
            "a linked folder that leads outside is refused")
        check(
            resolve("//etc/passwd") == .denied(.typeNotAllowed) && resolve("/etc/passwd.png") == .denied(.missing),
            "an absolute-looking path is read inside the document folder")
        check(
            resolve("/Users/reader/secret.png") == .denied(.missing),
            "a full path is read inside the document folder, where it does not exist")

        check(resolve("/notes.txt") == .denied(.typeNotAllowed), "a text file is refused")
        check(resolve("/page.html") == .denied(.typeNotAllowed), "the document's own HTML is not a resource")
        check(resolve("/script.js") == .denied(.typeNotAllowed), "a script file is refused")
        check(
            resolve("/noextension") == .denied(.typeNotAllowed)
                && resolve("/archive.png.zip") == .denied(.typeNotAllowed), "only the final extension counts")
        check(
            resolve("/disguised.png") == .denied(.typeNotAllowed),
            "a link named like an image that leads to another type is refused")
        check(resolve("/big.png") == .denied(.tooLarge), "a file over the size cap is refused")
        check(resolve("/absent.png") == .denied(.missing), "a file that does not exist is reported missing")
        check(
            resolve("/a.png%00.txt") == .denied(.missing) && resolve("/images/a%00.png") == .denied(.missing),
            "a null byte is refused")
        check(
            resolve("/bad%zz.png") == .denied(.missing) && resolve("/%") == .denied(.missing),
            "malformed percent-encoding is refused")
        check(resolve("") == .denied(.missing) && resolve("/") == .denied(.missing), "an empty path names nothing")
        check(resolve("/images") == .denied(.typeNotAllowed), "a folder is not a resource")

        let untitled = PreviewResourceResolver(
            documentURL: nil, resolveSymlinks: resolveLinks, fileSize: { files[$0.path] })
        check(
            untitled.resolve(requestPath: "/style.css") == .denied(.untitledDocument),
            "an untitled document has no folder to load from")
        let remote = PreviewResourceResolver(
            documentURL: URL(string: "https://example.com/page.html"), resolveSymlinks: resolveLinks,
            fileSize: { _ in 1 })
        check(
            remote.resolve(requestPath: "/style.css") == .denied(.untitledDocument),
            "a document that is not a local file has no folder to load from")
        let tiny = PreviewResourceResolver(
            documentURL: document, maxBytes: 15, resolveSymlinks: resolveLinks, fileSize: { files[$0.path] })
        check(
            tiny.resolve(requestPath: "/style.css") != .denied(.tooLarge)
                && tiny.resolve(requestPath: "/images/a.png") == .denied(.tooLarge), "the size cap is a parameter")
        for name in ["css", "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "ico", "avif", "heic"] {
            check(PreviewResourceResolver.mimeTypes[name] != nil, "the type .\(name) is permitted")
        }
        check(PreviewResourceResolver.mimeTypes.count == 11, "no other type is permitted")

        // The default closures against a real folder, including a real symbolic link.
        let folder = TestPaths.artifacts.appendingPathComponent(
            "preview-resolver-\(UUID().uuidString)", isDirectory: true)
        let inside = folder.appendingPathComponent("site", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("body{}".utf8).write(to: inside.appendingPathComponent("real.css"))
        try Data("secret".utf8).write(to: folder.appendingPathComponent("outside.css"))
        try FileManager.default.createSymbolicLink(
            at: inside.appendingPathComponent("leak.css"),
            withDestinationURL: folder.appendingPathComponent("outside.css"))
        try FileManager.default.createDirectory(
            at: inside.appendingPathComponent("folder.css", isDirectory: true), withIntermediateDirectories: true)
        let real = PreviewResourceResolver(documentURL: inside.appendingPathComponent("index.html"))
        if case .allowed(let url, let mimeType) = real.resolve(requestPath: "/real.css") {
            check(
                url.lastPathComponent == "real.css" && mimeType == "text/css"
                    && (try? Data(contentsOf: url)) == Data("body{}".utf8),
                "a real file in the document folder is served")
        } else {
            check(false, "a real file in the document folder is served")
        }
        check(
            real.resolve(requestPath: "/leak.css") == .denied(.outsideDocumentFolder),
            "a real symbolic link out of the folder is refused")
        check(
            real.resolve(requestPath: "/../outside.css") == .denied(.outsideDocumentFolder),
            "a real parent path is refused")
        check(real.resolve(requestPath: "/absent.css") == .denied(.missing), "a real missing file is reported missing")
        check(
            real.resolve(requestPath: "/folder.css") == .denied(.missing),
            "a real folder named like a stylesheet is not served")
    }

    static func checkSummary() {
        func summary(_ external: Int, _ scripts: Int, _ missing: Int) -> String? {
            PreviewSummary.text(blockedExternalResources: external, scriptsNotRun: scripts, missingLocalFiles: missing)
        }
        check(summary(0, 0, 0) == nil, "nothing left out gives no summary")
        check(
            summary(1, 2, 1)
                == "1 external resource was blocked. 2 scripts were not run. 1 local file could not be found.",
            "the summary is whole sentences with correct singular and plural")
        check(
            summary(2, 1, 3)
                == "2 external resources were blocked. 1 script was not run. 3 local files could not be found.",
            "each count chooses its own singular or plural")
        check(summary(0, 1, 0) == "1 script was not run.", "a single sentence stands alone")
        check(summary(0, 0, 2) == "2 local files could not be found.", "missing files alone are reported")
        check(
            summary(1_500, 0, 0) == "\(Strings.number(1_500)) external resources were blocked.",
            "large counts are formatted as numbers")
        var report = PreviewContentReport()
        report.scriptCount = 4
        check(
            PreviewSummary.text(for: report, missingLocalFiles: 1)
                == "4 scripts were not run. 1 local file could not be found.",
            "a report and a missing-file count combine")
    }

    // MARK: Delimited text

    static func checkDelimited() throws {
        let values = try requireValue(
            parsedTable(try PreviewFixtures.text("delimited/values.csv")), "the CSV fixture parses")
        check(
            values.rows == [
                ["id", "name", "amount", "note"], ["001", "Smith, Jane", "=SUM(A1)", "said \"hello\""],
                ["002", " padded ", "+1", "1e5"], ["003", "multi\nline", "-0.50", ""], ["004", "", "", ""]
            ], "every CSV value is kept as text exactly as written")
        check(
            values.rowLines == [1, 2, 3, 4, 6],
            "each row knows the source line it starts on, counting lines inside quotes")
        check(
            values.columnCount == 4 && values.rowCount == 5 && values.diagnostics.isEmpty && !values.isTruncated,
            "a well-formed CSV has no diagnostics")
        check(
            values.cell(row: 1, column: 0) == "001" && values.cell(row: 2, column: 3) == "1e5",
            "leading zeros and exponents are not interpreted")

        let ragged = try requireValue(
            parsedTable(try PreviewFixtures.text("delimited/ragged.tsv"), delimiter: "\t"), "the TSV fixture parses")
        check(
            ragged.rows == [
                ["a", "b", "c", "", ""], ["1", "tab\tinside", "3", "", ""], ["only one", "", "", "", ""],
                ["1", "2", "3", "4", "5"]
            ], "short rows are padded to the widest row")
        check(
            ragged.columnCount == 5 && (0..<4).map(ragged.cellCount(inRow:)) == [3, 3, 1, 5],
            "the widest row sets the column count and each row keeps its own length")
        check(ragged.cell(row: 2, column: 4) == "" && ragged.row(2).count == 5, "a missing cell reads as empty text")

        func rows(_ text: String, _ delimiter: Character = ",") -> [[String]]? {
            parsedTable(text, delimiter: delimiter)?.rows
        }
        check(rows("") == [] && parsedTable("")?.columnCount == 0, "an empty document has no rows")
        check(rows("a") == [["a"]] && rows("a\n") == [["a"]], "a final line break does not start another row")
        check(
            rows("a\n\n") == [["a"], [""]] && rows("\n") == [[""]],
            "an empty line before the end is a row with one empty cell")
        check(rows("a,b\r\nc,d\r\n") == [["a", "b"], ["c", "d"]], "CRLF ends a row")
        check(rows("a,b\rc,d\r") == [["a", "b"], ["c", "d"]], "CR alone ends a row")
        check(
            rows("a,b\nc,d\r\ne,f\rg,h") == [["a", "b"], ["c", "d"], ["e", "f"], ["g", "h"]],
            "mixed line endings are accepted")
        check(
            rows(",") == [["", ""]] && rows("a,") == [["a", ""]] && rows(",,\n") == [["", "", ""]],
            "empty cells are kept, including the last")
        check(rows("\u{FEFF}a,b") == [["a", "b"]], "a byte order mark is skipped")
        check(rows("a,\u{FEFF}b") == [["a", "\u{FEFF}b"]], "the same character elsewhere is data")
        check(rows("\"\"") == [[""]] && rows("\"\",\"\"") == [["", ""]], "an empty quoted value is empty text")
        check(rows("\"a,b\",c") == [["a,b", "c"]], "a delimiter inside quotes is text")
        check(
            rows("\"a\"\"b\"") == [["a\"b"]] && rows("\"\"\"\"") == [["\""]],
            "a doubled quote inside quotes is one quote")
        check(
            rows("\"a\nb\",c\n\"d\r\ne\",f\n\"g\rh\"") == [["a\nb", "c"], ["d\r\ne", "f"], ["g\rh", ""]],
            "line breaks inside quotes are kept as written")
        check(
            parsedTable("\"a\nb\",c\n\"d\r\ne\",f\n\"g\rh\"")?.rowLines == [1, 3, 5],
            "each kind of line break inside quotes counts as one line")
        check(rows("  a  , b\t,\" c \"") == [["  a  ", " b\t", " c "]], "whitespace is never trimmed")
        check(
            rows("007,=1+1,+1,-1,@x,1e5,0x1F,1.50,TRUE,2020-01-01") == [
                ["007", "=1+1", "+1", "-1", "@x", "1e5", "0x1F", "1.50", "TRUE", "2020-01-01"]
            ], "no value is converted or evaluated")
        check(
            rows("a\tb,c\td", "\t") == [["a", "b,c", "d"]] && rows("a\tb,c\td", ",") == [["a\tb", "c\td"]],
            "only the chosen delimiter separates cells")
        check(rows("ä,日本,👩‍💻\nمرحبا,\"é,è\"") == [["ä", "日本", "👩‍💻"], ["مرحبا", "é,è", ""]], "Unicode text is kept")
        if case .parsed(let invalid) = DelimitedTable.parse(
            Data([0x61, 0xFF, 0x2C, 0x62]), delimiter: ",", isCancelled: never)
        {
            check(
                invalid.rows == [["a\u{FFFD}", "b"]], "bytes that are not UTF-8 are shown as the replacement character")
        } else {
            check(false, "bytes that are not UTF-8 still parse")
        }
        check(rows("a;b", ";") == [["a", "b"]], "another ASCII delimiter also works")

        // Malformed quoting is tolerated and reported.
        let unterminated = try requireValue(parsedTable("a,b\nc,\"d,e\nf,g\n"), "an unterminated quote parses")
        check(
            unterminated.rows == [["a", "b"], ["c", "d,e\nf,g\n"]],
            "after an unterminated quote the rest of the document is one value")
        check(
            unterminated.diagnostics == [DelimitedDiagnostic(kind: .unterminatedQuote, row: 2, line: 2)]
                && unterminated.diagnosticCount == 1, "the unterminated quote is reported with its 1-based row and line"
        )
        check(
            unterminated.diagnostics[0].message.contains("Row 2") && unterminated.diagnostics[0].message.hasSuffix("."),
            "the unterminated-quote message is a sentence naming the row")
        let stray = try requireValue(parsedTable("x\na,b\"c,d\n\"e\"f,g\nh\"\n"), "stray quotes parse")
        check(
            stray.rows == [["x", "", ""], ["a", "b\"c", "d"], ["\"e\"f", "g", ""], ["h\"", "", ""]],
            "a stray quote is kept literally")
        check(
            stray.diagnostics.map(\.row) == [2, 3, 4] && stray.diagnostics.allSatisfy { $0.kind == .strayQuote },
            "each stray quote is reported with its row")
        check(stray.diagnostics.map(\.line) == [2, 3, 4], "each stray quote is reported with its line")
        // The message says "It is shown as written", so nothing may be removed from such a value.
        check(
            rows("\"a\"b,c") == [["\"a\"b", "c"]] && parsedTable("\"a\"b,c")?.diagnostics.map(\.kind) == [.strayQuote],
            "a value with text after its closing quote keeps every byte, quotes included: \(rows("\"a\"b,c") ?? [])")
        check(
            rows("\"a\" ,b") == [["\"a\" ", "b"]] && parsedTable("\"a\" ,b")?.diagnosticCount == 1,
            "a space after a closing quote keeps the quotes and the space: \(rows("\"a\" ,b") ?? [])")
        check(
            rows("\"a,\"\"b\nc\"x,d\ne") == [["\"a,\"\"b\nc\"x", "d"], ["e", ""]]
                && parsedTable("\"a,\"\"b\nc\"x,d\ne")?.rowLines == [1, 3],
            "such a value keeps its delimiter, doubled quote and line break as written, and lines are still counted")
        check(
            rows("\"a\",\"b\"\"c\"") == [["a", "b\"c"]] && parsedTable("\"a\",\"b\"\"c\"")?.diagnosticCount == 0,
            "a well-formed quoted value is still unquoted")
        check(
            parsedTable("\"a\"b,c")?.diagnostics.first?.message.contains("shown as written") == true,
            "the stray-quote sentence says the value is shown as written")
        check(
            rows("\"") == [[""]] && parsedTable("\"")?.diagnostics.first?.kind == .unterminatedQuote,
            "a lone quote is an unterminated empty value")
        let noisy = try requireValue(parsedTable(String(repeating: "a\"b\n", count: 500)), "many stray quotes parse")
        check(
            noisy.diagnosticCount == 500 && noisy.diagnostics.count == DelimitedTable.maxListedDiagnostics,
            "diagnostics are counted in full and listed up to a cap")
    }

    static func checkDelimitedBounds() {
        let limits = PreviewLimits.standard
        let overRows = String(repeating: "1,2,3\n", count: limits.delimitedMaxRows + 1)
        var parsed: DelimitedTable?
        let elapsed = seconds { parsed = parsedTable(overRows) }
        if let table = parsed {
            check(
                table.rowCount == limits.delimitedMaxRows && table.isTruncated
                    && table.limitsReached == [.tooManyRows(shown: limits.delimitedMaxRows)],
                "rows past 100,000 are left out and the table says so (\(String(format: "%.2f", elapsed)) s)")
            check(
                table.rowLines.last == limits.delimitedMaxRows
                    && table.cell(row: limits.delimitedMaxRows - 1, column: 2) == "3", "the last kept row is complete")
        } else {
            check(false, "a table over the row limit still parses")
        }
        let exactRows = String(repeating: "1\n", count: limits.delimitedMaxRows)
        check(parsedTable(exactRows)?.isTruncated == false, "exactly 100,000 rows are not truncated")
        let wide = Array(repeating: "x", count: 600).joined(separator: ",") + "\na,b\n"
        if let table = parsedTable(wide) {
            check(
                table.columnCount == limits.delimitedMaxColumns
                    && table.limitsReached == [.tooManyColumns(shown: limits.delimitedMaxColumns)],
                "columns past 512 are left out and the table says so")
            check(
                table.rows[1].prefix(3) == ["a", "b", ""] && table.rowCount == 2,
                "rows after an over-wide row are still read")
        } else {
            check(false, "a table over the column limit still parses")
        }
        var small = PreviewLimits.standard
        small.delimitedMaxRows = 2
        small.delimitedMaxColumns = 2
        check(
            parsedTable("a,b,c\nd\ne\n", limits: small)?.limitsReached == [
                .tooManyColumns(shown: 2), .tooManyRows(shown: 2)
            ], "both limits can be reached in one table, in order")
        small.maxSourceBytes = 4
        check(
            DelimitedTable.parse("a,b,c", delimiter: ",", limits: small, isCancelled: never)
                == .limited(.sourceTooLarge(maxBytes: 4)),
            "delimited text over the source limit is refused with the reason")

        let large = String(repeating: "alpha,\"beta, gamma\",12345,,end of row\n", count: 60_000)
        let probe = CancellationProbe()
        _ = DelimitedTable.parse(large, delimiter: ",", isCancelled: probe.isCancelled)
        check(
            probe.polls >= large.utf8.count / 8192,
            "delimited parsing polls for cancellation every few thousand bytes (\(probe.polls) polls for \(large.utf8.count) bytes)"
        )
        let cancelling = CancellationProbe(cancelAtPoll: 5)
        check(
            DelimitedTable.parse(large, delimiter: ",", isCancelled: cancelling.isCancelled) == .cancelled
                && cancelling.polls == 5, "delimited parsing stops when cancelled")
        let quoteProbe = CancellationProbe()
        _ = DelimitedTable.parse(
            "\"" + String(repeating: "x", count: 500_000), delimiter: ",", isCancelled: quoteProbe.isCancelled)
        check(quoteProbe.polls >= 500_000 / 8192, "a long unterminated quote is polled too")
        let emptyCells = String(repeating: ",", count: 1_000_000)
        check(
            parsedTable(emptyCells)?.columnCount == limits.delimitedMaxColumns,
            "a million empty cells on one row are bounded by the column limit")
        let emptyProbe = CancellationProbe()
        _ = DelimitedTable.parse(emptyCells, delimiter: ",", isCancelled: emptyProbe.isCancelled)
        check(
            emptyProbe.polls >= emptyCells.utf8.count / 8192,
            "a row of empty values is polled too (\(emptyProbe.polls) polls)")
        let emptyCancel = CancellationProbe(cancelAtPoll: 3)
        check(
            DelimitedTable.parse(emptyCells, delimiter: ",", isCancelled: emptyCancel.isCancelled) == .cancelled
                && emptyCancel.polls == 3, "and stops when cancelled")
    }

    // MARK: JSON

    static func checkJSON() throws {
        let sample = try PreviewFixtures.text("json/sample.json")
        let tree = try requireValue(parsedJSON(sample), "the JSON fixture parses")
        check(
            jsonTreeViolation(tree, sourceLength: sample.utf8.count) == nil,
            "the JSON fixture tree is well formed (\(jsonTreeViolation(tree, sourceLength: sample.utf8.count) ?? "ok"))"
        )
        let root = try requireValue(tree.root, "the JSON fixture has a root")
        let members = Array(tree.children(of: root))
        check(
            tree.nodes[root].kind == .object && tree.nodes[root].line == 1 && tree.nodes[root].column == 1,
            "the root is an object at line 1, column 1")
        check(
            members.map { tree.key(of: $0) } == [
                "name", "version", "big", "tiny", "negative", "exp", "flags", "empty", "escapes", "ключ", "dup", "dup",
                "nested"
            ], "members keep their order and duplicate names")
        check(members.map { tree.nodes[$0].indexInParent } == Array(0..<13), "members know their position")
        func member(_ name: String, last: Bool = false) -> Int {
            let matches = members.filter { tree.key(of: $0) == name }
            return (last ? matches.last : matches.first) ?? root
        }
        check(tree.displayValue(of: member("version")) == "1.0", "a number keeps its trailing zero")
        check(
            tree.displayValue(of: member("big")) == "123456789012345678901234567890",
            "a number too large for any numeric type is kept as written")
        check(
            tree.displayValue(of: member("tiny")) == "1e400" && tree.displayValue(of: member("negative")) == "-0.0"
                && tree.displayValue(of: member("exp")) == "6.02E+23", "exponents and negative zero are kept as written"
        )
        check(
            tree.displayValue(of: member("dup")) == "1" && tree.displayValue(of: member("dup", last: true)) == "2",
            "both values of a duplicated name are kept")
        check(
            tree.displayValue(of: member("name")) == "TextTank" && tree.rawText(of: member("name")) == "\"TextTank\"",
            "a string is shown decoded and keeps its raw literal")
        check(
            tree.displayValue(of: member("escapes"))
                == "quote \" slash / back \\ tab \t line \n unicode é pair 😀 lone \u{FFFD}",
            "escapes and surrogate pairs are decoded; a lone surrogate becomes the replacement character")
        check(tree.rawText(of: member("escapes")).contains("\\ud83d\\ude00"), "the raw literal keeps its escapes")
        check(
            tree.key(of: member("ключ")) == "ключ" && tree.displayValue(of: member("ключ")) == "значение",
            "names and values outside ASCII are kept")
        let flags = Array(tree.children(of: member("flags")))
        check(
            flags.map { tree.nodes[$0].kind } == [.true, .false, .null]
                && flags.map { tree.displayValue(of: $0) } == ["true", "false", "null"],
            "true, false and null are distinct kinds")
        check(
            flags.allSatisfy { tree.key(of: $0) == nil } && flags.map { tree.nodes[$0].indexInParent } == [0, 1, 2],
            "array elements have positions and no names")
        check(
            tree.nodes[flags[0]].line == 8 && tree.nodes[flags[0]].column == 13,
            "a nested value reports its line and column")
        check(
            tree.nodes[member("ключ")].line == 11 && tree.nodes[member("ключ")].column == 11,
            "columns count characters, not bytes")
        let empties = Array(tree.children(of: member("empty")))
        check(
            empties.map { tree.nodes[$0].kind } == [.object, .array, .string]
                && empties.allSatisfy { tree.nodes[$0].childCount == 0 }, "empty containers and empty text are values")
        check(
            tree.displayValue(of: empties[0]) == Strings.count(0, .item)
                && tree.displayValue(of: member("flags")) == Strings.count(3, .item)
                && tree.displayValue(of: root) == Strings.count(13, .item),
            "a container is described by its number of items")
        check(tree.displayValue(of: empties[2]) == "" && tree.rawText(of: empties[2]) == "\"\"", "empty text is empty")
        let rootRange = tree.nodes[root].byteRange
        check(
            rootRange.lowerBound == 0 && rootRange.upperBound == sample.utf8.count - 1,
            "the root's byte range covers the object and not the final line break")
        let nameNode = tree.nodes[member("name")]
        check(
            String(decoding: Array(sample.utf8)[nameNode.byteRange], as: UTF8.self) == "\"TextTank\""
                && nameNode.keyRange.map { String(decoding: Array(sample.utf8)[$0], as: UTF8.self) } == "\"name\"",
            "byte ranges select the value and the name in the source")
        check(
            tree.nodes[member("nested")].parent == root
                && tree.rawText(of: member("nested")) == "[[1, [2, [3]]], {\"a\": {\"b\": {\"c\": \"deep\"}}}]",
            "a container's raw text is its whole source")

        let scalars: [(String, JSONNode.Kind, String)] = [
            ("0", .number, "0"), ("-0", .number, "-0"), ("-12.50e-3", .number, "-12.50e-3"), ("1E5", .number, "1E5"),
            ("\"\"", .string, ""), ("\"a\"", .string, "a"), ("true", .true, "true"), ("false", .false, "false"),
            ("null", .null, "null"),
            ("  \t\r\n 7 \n", .number, "7"), ("\u{FEFF}8", .number, "8"), ("\"\\u0041\\u00e9\\u4e2d\"", .string, "Aé中"),
            ("\"\\ud834\\udd1e\"", .string, "𝄞"), ("\"\\udd1e\\ud834\"", .string, "\u{FFFD}\u{FFFD}"),
            ("\"\\uD83D\"", .string, "\u{FFFD}"),
            ("\"\\\"\\\\\\/\\b\\f\\n\\r\\t\"", .string, "\"\\/\u{08}\u{0C}\n\r\t"),
            ("\"\u{7F}\u{80}\u{10FFFF}\"", .string, "\u{7F}\u{80}\u{10FFFF}")
        ]
        for (text, kind, display) in scalars {
            let tree = parsedJSON(text)
            check(
                tree?.nodes.count == 1 && tree?.nodes[0].kind == kind && tree?.displayValue(of: 0) == display,
                "JSON scalar parses: \(text.debugDescription)")
        }
        check(
            parsedJSON("[]")?.nodes[0].kind == .array && parsedJSON("{}")?.nodes[0].kind == .object,
            "empty containers parse")
        check(
            parsedJSON("[ ]")?.nodes.count == 1 && parsedJSON("{\n}")?.nodes.count == 1,
            "whitespace inside empty containers is accepted")
        check(parsedJSON("{\"\":0}").map { $0.key(of: 1) } == "", "an empty name is a name")
        check(
            parsedJSON("{\"a\":{\"a\":{\"a\":[]}}}")?.nodes.map(\.kind) == [.object, .object, .object, .array],
            "nodes are stored in document order")
        check(
            JSONTree.parse("", isCancelled: never) == .empty
                && JSONTree.parse(" \n\t\r\n", isCancelled: never) == .empty
                && JSONTree.parse("\u{FEFF}", isCancelled: never) == .empty,
            "an empty or whitespace-only document is reported as empty")
        check(parsedJSON(sample) == parsedJSON(sample), "parsing is deterministic")
    }

    static func checkJSONErrors() throws {
        let cases: [(String, JSONSyntaxError.Kind, line: Int, column: Int, offset: Int)] = [
            ("[1,]", .expectedValue, 1, 4, 3),
            ("{\"a\":1,}", .expectedName, 1, 8, 7),
            ("{a:1}", .expectedNameOrClosingBrace, 1, 2, 1),
            ("{'a':1}", .expectedNameOrClosingBrace, 1, 2, 1),
            ("{\"a\":1,b:2}", .expectedName, 1, 8, 7),
            ("{\"a\" 1}", .expectedColon, 1, 6, 5),
            ("{\"a\":1 \"b\":2}", .expectedCommaOrClosingBrace, 1, 8, 7),
            ("[1 2]", .expectedCommaOrClosingBracket, 1, 4, 3),
            ("[1}", .expectedCommaOrClosingBracket, 1, 3, 2),
            ("{\"a\":1]", .expectedCommaOrClosingBrace, 1, 7, 6),
            ("[,1]", .expectedValueOrClosingBracket, 1, 2, 1),
            ("{\"a\":}", .expectedValue, 1, 6, 5),
            ("tru", .expectedValue, 1, 1, 0),
            ("True", .expectedValue, 1, 1, 0),
            ("nul", .expectedValue, 1, 1, 0),
            ("undefined", .expectedValue, 1, 1, 0),
            ("NaN", .expectedValue, 1, 1, 0),
            ("// comment\n1", .expectedValue, 1, 1, 0),
            ("\"abc", .unterminatedString, 1, 1, 0),
            ("[\"a\",\n \"bc", .unterminatedString, 2, 2, 7),
            ("\"a\\", .unterminatedString, 1, 3, 2),
            ("\"a\\x\"", .invalidEscape, 1, 3, 2),
            ("\"\\u12G4\"", .invalidEscape, 1, 2, 1),
            ("\"\\u12\"", .invalidEscape, 1, 2, 1),
            ("\"a\nb\"", .controlCharacterInString, 1, 3, 2),
            ("\"a\tb\"", .controlCharacterInString, 1, 3, 2),
            ("00012345678901234567890", .leadingZero, 1, 1, 0),
            ("[01]", .leadingZero, 1, 2, 1),
            ("-01", .leadingZero, 1, 1, 0),
            ("-", .invalidNumber, 1, 1, 0),
            ("1.", .invalidNumber, 1, 1, 0),
            ("[1.e3]", .invalidNumber, 1, 2, 1),
            ("1e", .invalidNumber, 1, 1, 0),
            ("1e+", .invalidNumber, 1, 1, 0),
            ("-x", .invalidNumber, 1, 1, 0),
            (".5", .expectedValue, 1, 1, 0),
            ("+1", .expectedValue, 1, 1, 0),
            ("1 2", .textAfterValue, 1, 3, 2),
            ("{} x", .textAfterValue, 1, 4, 3),
            ("[]]", .textAfterValue, 1, 3, 2),
            ("1x", .textAfterValue, 1, 2, 1),
            ("0x10", .textAfterValue, 1, 2, 1),
            ("1.5.2", .textAfterValue, 1, 4, 3),
            ("[", .unexpectedEnd, 1, 2, 1),
            ("{\"a\":", .unexpectedEnd, 1, 6, 5),
            ("{\"a\"", .unexpectedEnd, 1, 5, 4),
            ("[1,", .unexpectedEnd, 1, 4, 3),
            ("{\n  \"a\": [1,\n    2\n", .unexpectedEnd, 4, 1, 19),
            ("{\n  \"été\": 1\n  \"b\": 2\n}", .expectedCommaOrClosingBrace, 3, 3, 17),
            ("[\"日本語\", x]", .expectedValue, 1, 9, 14),
            ("[1,\r\n2,\r3,\n4 5]", .expectedCommaOrClosingBracket, 4, 3, 13)
        ]
        for (text, kind, line, column, offset) in cases {
            let error = jsonError(text)
            if !check(
                error?.kind == kind && error?.line == line && error?.column == column && error?.byteOffset == offset,
                "invalid JSON is located: \(text.debugDescription)")
            {
                print(
                    "  expected \(kind) at line \(line), column \(column), offset \(offset); got \(String(describing: error))"
                )
            }
        }
        check(
            jsonError("{\n  \"a\": 1\n  \"b\": 2\n}")?.message
                == "Expected a comma or closing brace at line 3, column 3.",
            "the error message is a sentence with the line and column")
        for kind in [
            JSONSyntaxError.Kind.expectedValue, .expectedValueOrClosingBracket, .expectedNameOrClosingBrace,
            .expectedName, .expectedColon, .expectedCommaOrClosingBrace, .expectedCommaOrClosingBracket,
            .unterminatedString, .invalidEscape, .controlCharacterInString, .invalidNumber, .leadingZero, .invalidUTF8,
            .unexpectedEnd, .textAfterValue
        ] {
            let message = JSONSyntaxError(kind: kind, byteOffset: 0, line: 12, column: 5).message
            check(
                message.contains("line 12, column 5") && message.hasSuffix(".") && !message.contains("%"),
                "JSON error message names its place: \(message)")
        }

        // Invalid UTF-8 inside and outside strings.
        for (bytes, kind, offset) in [
            ([0x22, 0xFF, 0x22], JSONSyntaxError.Kind.invalidUTF8, 1), ([0x22, 0xC3, 0x22], .invalidUTF8, 1),
            ([0x22, 0xE2, 0x82, 0x22], .invalidUTF8, 1), ([0x22, 0xC0, 0xAF, 0x22], .invalidUTF8, 1),
            ([0x22, 0xED, 0xA0, 0x80, 0x22], .invalidUTF8, 1), ([0x22, 0xF4, 0x90, 0x80, 0x80, 0x22], .invalidUTF8, 1),
            ([0x22, 0x61, 0x80, 0x22], .invalidUTF8, 2), ([0x22, 0xF0, 0x9F], .invalidUTF8, 1),
            ([0xFF], .expectedValue, 0), ([0x5B, 0x31, 0x2C, 0xC3, 0x28, 0x5D], .expectedValue, 3)
        ] as [([UInt8], JSONSyntaxError.Kind, Int)] {
            if case .invalid(_, let error) = JSONTree.parse(Data(bytes), isCancelled: never) {
                check(error.kind == kind && error.byteOffset == offset, "invalid UTF-8 in JSON is located: \(bytes)")
            } else {
                check(false, "invalid UTF-8 in JSON is an error: \(bytes)")
            }
        }
        check(parsedJSON("\"\u{E9}\u{20AC}\u{1F600}\"") != nil, "well-formed UTF-8 of every length is accepted")

        // The partial tree: everything read before the error, with open containers closed there.
        let broken = "{\"a\": [1, 2, {\"b\": tru"
        guard case .invalid(let partial, let error) = JSONTree.parse(broken, isCancelled: never) else {
            check(false, "broken JSON returns a partial tree and an error")
            return
        }
        check(
            partial.nodes.map(\.kind) == [.object, .array, .number, .number, .object],
            "the partial tree holds every value read before the error")
        check(
            partial.nodes.filter(\.isContainer).allSatisfy { $0.byteRange.upperBound == error.byteOffset },
            "containers still open are closed at the error")
        check(
            Array(partial.children(of: 1)) == [2, 3, 4] && partial.key(of: 1) == "a"
                && partial.nodes[4].childCount == 0, "the partial tree keeps its structure and names")
        check(jsonTreeViolation(partial, sourceLength: broken.utf8.count) == nil, "the partial tree is well formed")
        if case .invalid(let rootless, _) = JSONTree.parse("x", isCancelled: never) {
            check(
                rootless.root == nil && rootless.nodes.isEmpty, "an error before any value gives an empty partial tree")
        } else {
            check(false, "an error before any value is reported")
        }
        if case .invalid(let afterRoot, let trailing) = JSONTree.parse("[1] x", isCancelled: never) {
            check(
                afterRoot.nodes.count == 2 && trailing.kind == .textAfterValue,
                "text after a complete value keeps the whole tree")
        } else {
            check(false, "text after a complete value is reported")
        }

        // Every prefix of the fixture: never a crash, always a location inside the input.
        let sample = Array(try PreviewFixtures.data("json/sample.json"))
        var prefixOutcomes = ["empty": 0, "parsed": 0, "invalid": 0]
        var prefixFailures: [String] = []
        for length in 0...sample.count {
            let prefix = Data(sample[..<length])
            switch JSONTree.parse(prefix, isCancelled: never) {
            case .empty:
                prefixOutcomes["empty", default: 0] += 1
                if length != 0 { prefixFailures.append("prefix \(length) reported empty") }
            case .parsed(let tree):
                prefixOutcomes["parsed", default: 0] += 1
                if let violation = jsonTreeViolation(tree, sourceLength: length) {
                    prefixFailures.append("prefix \(length): \(violation)")
                }
            case .invalid(let partial, let error):
                prefixOutcomes["invalid", default: 0] += 1
                if error.byteOffset < 0 || error.byteOffset > length || error.line < 1 || error.column < 1 {
                    prefixFailures.append("prefix \(length): location outside the input")
                }
                if !error.message.contains("line \(error.line), column \(error.column)") {
                    prefixFailures.append("prefix \(length): message without its place")
                }
                if let violation = jsonTreeViolation(partial, sourceLength: length) {
                    prefixFailures.append("prefix \(length): \(violation)")
                }
            case .limited, .cancelled:
                prefixFailures.append("prefix \(length) was limited or cancelled")
            }
        }
        if !check(
            prefixFailures.isEmpty,
            "every prefix of the JSON fixture (\(sample.count + 1) documents) gives a well-formed result with a location inside the input"
        ) {
            print("  " + prefixFailures.prefix(5).joined(separator: "\n  "))
        }
        check(
            prefixOutcomes["parsed"] == 2 && prefixOutcomes["empty"] == 1
                && prefixOutcomes["invalid"] == sample.count - 2,
            "only the complete fixture, with or without its final line break, parses (\(prefixOutcomes))")

        // Every single-byte corruption of a small document: never a crash.
        let small = Array("{\"k\":[1,-2.5e3,\"s\\n\",true,false,null,{\"x\":[]}]}".utf8)
        var corruptionFailures = 0
        for index in small.indices {
            for replacement: UInt8 in [0x00, 0x20, 0x22, 0x2C, 0x5B, 0x5C, 0x5D, 0x7B, 0x7D, 0x80, 0xFF] {
                var corrupted = small
                corrupted[index] = replacement
                switch JSONTree.parse(Data(corrupted), isCancelled: never) {
                case .parsed(let tree):
                    if jsonTreeViolation(tree, sourceLength: corrupted.count) != nil { corruptionFailures += 1 }
                case .invalid(let partial, let error):
                    if jsonTreeViolation(partial, sourceLength: corrupted.count) != nil
                        || error.byteOffset > corrupted.count
                    {
                        corruptionFailures += 1
                    }
                case .empty, .limited, .cancelled:
                    corruptionFailures += 1
                }
            }
        }
        check(
            corruptionFailures == 0,
            "every single-byte corruption of a small document gives a well-formed result (\(small.count * 11) documents)"
        )
    }

    static func checkJSONBounds() {
        let limits = PreviewLimits.standard
        let atDepth =
            String(repeating: "[", count: limits.jsonMaxDepth) + String(repeating: "]", count: limits.jsonMaxDepth)
        if let tree = parsedJSON(atDepth) {
            check(
                tree.nodes.count == limits.jsonMaxDepth && tree.nodes.last?.parent == limits.jsonMaxDepth - 2,
                "nesting exactly at the depth cap parses")
        } else {
            check(false, "nesting exactly at the depth cap parses")
        }
        let overDepth =
            String(repeating: "[", count: limits.jsonMaxDepth + 1)
            + String(repeating: "]", count: limits.jsonMaxDepth + 1)
        if case .limited(let partial, let limit) = JSONTree.parse(overDepth, isCancelled: never) {
            check(
                limit == .nestedTooDeeply(maxDepth: limits.jsonMaxDepth) && partial.nodes.count == limits.jsonMaxDepth,
                "nesting past the depth cap stops with the reason and the tree so far")
            check(
                jsonTreeViolation(partial, sourceLength: overDepth.utf8.count) == nil,
                "the depth-limited tree is well formed")
        } else {
            check(false, "nesting past the depth cap is limited")
        }
        let objectDepth = String(repeating: "{\"a\":", count: 100_000)
        if case .limited(let partial, let limit) = JSONTree.parse(objectDepth, isCancelled: never) {
            check(
                limit == .nestedTooDeeply(maxDepth: limits.jsonMaxDepth) && partial.nodes.count == limits.jsonMaxDepth,
                "100,000 unclosed objects stop at the depth cap without exhausting the stack")
        } else {
            check(false, "100,000 unclosed objects are limited")
        }

        var small = PreviewLimits.standard
        small.jsonMaxNodes = 5
        if case .limited(let partial, let limit) = JSONTree.parse(
            "[1,2,[3,4,5,6],7]", limits: small, isCancelled: never)
        {
            check(
                limit == .tooManyValues(shown: 5) && partial.nodes.count == 5
                    && Array(partial.children(of: 0)) == [1, 2, 3],
                "values past the node cap are left out and the tree so far is kept")
            check(jsonTreeViolation(partial, sourceLength: 17) == nil, "the node-limited tree is well formed")
        } else {
            check(false, "values past the node cap are limited")
        }
        check(parsedJSON("[1,2,3,4]", limits: small) != nil, "a document exactly at the node cap parses")
        small.maxSourceBytes = 3
        if case .limited(let partial, let limit) = JSONTree.parse("[1,2]", limits: small, isCancelled: never) {
            check(
                limit == .sourceTooLarge(maxBytes: 3) && partial.root == nil,
                "JSON over the source limit is refused with the reason")
        } else {
            check(false, "JSON over the source limit is limited")
        }

        // About 5 MiB: an array of short strings and numbers, under the node cap.
        let element = "\"0123456789abcdef\",1234567890.125,"
        let count = 5 * 1024 * 1024 / element.utf8.count
        let large = "[" + String(repeating: element, count: count) + "null]"
        let probe = CancellationProbe()
        var outcome = JSONTreeOutcome.cancelled
        let elapsed = seconds { outcome = JSONTree.parse(large, isCancelled: probe.isCancelled) }
        if case .parsed(let tree) = outcome {
            check(
                tree.nodes.count == count * 2 + 2 && tree.children(of: 0).count == count * 2 + 1,
                "a 5 MiB array parses completely (\(large.utf8.count) bytes, \(tree.nodes.count) values, \(String(format: "%.2f", elapsed)) s in this build)"
            )
            check(
                tree.displayValue(of: tree.nodes.count - 2) == "1234567890.125"
                    && tree.nodes[tree.nodes.count - 1].kind == .null, "the last values of the large array are intact")
        } else {
            check(false, "a 5 MiB array parses completely")
        }
        check(
            probe.polls >= large.utf8.count / 8192,
            "JSON parsing polls for cancellation every few thousand bytes (\(probe.polls) polls)")
        for cancelAt in [1, 7, probe.polls] {
            let cancelling = CancellationProbe(cancelAtPoll: cancelAt)
            check(
                JSONTree.parse(large, isCancelled: cancelling.isCancelled) == .cancelled
                    && cancelling.polls == cancelAt, "JSON parsing stops when cancelled at poll \(cancelAt)")
        }
        let longString = "\"" + String(repeating: "x", count: 1024 * 1024) + "\""
        let stringProbe = CancellationProbe()
        _ = JSONTree.parse(longString, isCancelled: stringProbe.isCancelled)
        check(
            stringProbe.polls >= longString.utf8.count / 8192,
            "one long JSON string is polled too (\(stringProbe.polls) polls)")
        let numbers = "[" + String(repeating: "1,", count: 600_000) + "1]"
        if case .limited(let partial, let limit) = JSONTree.parse(numbers, isCancelled: never) {
            check(
                limit == .tooManyValues(shown: limits.jsonMaxNodes) && partial.nodes.count == limits.jsonMaxNodes,
                "more than 500,000 values stop at the cap with the tree so far")
        } else {
            check(false, "more than 500,000 values are limited")
        }
    }

    // MARK: SVG

    static func checkSVG() throws {
        let plain = try requireValue(
            inspectedSVG(try PreviewFixtures.text("svg/plain.svg")), "the plain SVG fixture is scanned")
        check(
            plain.isSVG && plain.report == PreviewContentReport(), "a plain SVG is recognized and has an empty report")
        let hostile = try requireValue(
            inspectedSVG(try PreviewFixtures.text("svg/hostile.svg")), "the hostile SVG fixture is scanned")
        check(hostile.isSVG, "an SVG with a declaration and doctype is recognized")
        let expected = [
            "http://evil.example/x.js", "http://css.example/s.css", "http://img.example/a.png",
            "https://img.example/b.png", "//use.example/sprite.svg#a", "http://attr.example/p.svg#p"
        ]
        if !check(
            hostile.report.externalReferences == expected,
            "external images, scripts, style imports and uses in SVG are listed; links and namespaces are not")
        {
            print("  actual: \(hostile.report.externalReferences)")
        }
        check(
            hostile.report.scriptCount == 3,
            "SVG script elements and event handlers are counted (\(hostile.report.scriptCount))")
        check(
            PreviewSummary.text(for: hostile.report) == "6 external resources were blocked. 3 scripts were not run.",
            "the SVG summary reads correctly")
        let notSVG = try requireValue(
            inspectedSVG(try PreviewFixtures.text("svg/not-svg.xml")), "the non-SVG fixture is scanned")
        check(!notSVG.isSVG, "XML whose first element is not svg is not an SVG image")
        check(
            try requireValue(
                inspectedSVG(try PreviewFixtures.text("svg/prefixed.svg")), "the prefixed fixture is scanned"
            ).isSVG, "a namespace-prefixed svg root is recognized")
        check(
            inspectedSVG("")?.isSVG == false && inspectedSVG("just text")?.isSVG == false
                && inspectedSVG("<!-- <svg> -->")?.isSVG == false, "text without an svg element is not an SVG image")
        check(
            inspectedSVG("<html><body><svg></svg></body></html>")?.isSVG == false,
            "HTML that contains an svg element is not an SVG image")
        check(
            inspectedSVG("<svg")?.isSVG == true && inspectedSVG("\u{FEFF}  <svg/>")?.isSVG == true,
            "an unfinished or preceded svg root is still recognized")
        check(
            inspectedSVG("<svg><script/><image href='http://x.example/a.png'/></svg>")?.report.externalReferences == [
                "http://x.example/a.png"
            ], "a self-closing script does not swallow the rest of an SVG")
        check(
            SVGPolicy.notSVGMessage == "This document is not an SVG image.",
            "the not-an-SVG message is a plain sentence")

        let wrapper = SVGPolicy.wrapper(
            imageURL: "texttank-preview://document/image.svg?v=\"1\"&w=<2>", title: "Logo & \"mark\"",
            stylesheet: "body { margin: 0 }")
        check(
            wrapper.contains(
                "<img src=\"texttank-preview://document/image.svg?v=&quot;1&quot;&amp;w=&lt;2&gt;\" alt=\"Logo &amp; &quot;mark&quot;\">"
            ), "the SVG wrapper shows the image with an escaped address and description")
        check(
            wrapper.contains("<body class=\"image-preview\">")
                && wrapper.contains(StaticHTMLPolicy.contentSecurityPolicy()),
            "the SVG wrapper uses the image page class and the strict policy")
        check(
            !wrapper.contains("<script") && !wrapper.contains("<object") && !wrapper.contains("<embed")
                && !wrapper.contains("<iframe"), "the SVG wrapper embeds the image only as an image")

        var small = PreviewLimits.standard
        small.maxSourceBytes = 10
        check(
            SVGPolicy.scan("<svg></svg> ", limits: small, isCancelled: never)
                == .limited(.sourceTooLarge(maxBytes: 10)), "SVG over the source limit is refused with the reason")
        let large = "<svg>" + String(repeating: "<rect width=\"1\" height=\"1\"/>", count: 40_000) + "</svg>"
        let cancelling = CancellationProbe(cancelAtPoll: 2)
        check(
            SVGPolicy.scan(large, isCancelled: cancelling.isCancelled) == .cancelled && cancelling.polls == 2,
            "SVG scanning stops when cancelled")
    }
}
