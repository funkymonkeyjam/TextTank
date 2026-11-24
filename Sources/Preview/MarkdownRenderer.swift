// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The result of rendering Markdown.
package enum MarkdownRendering: Sendable, Equatable {
    /// An HTML fragment: the content of a `<body>`. Wrap it with `StaticHTMLPolicy.wrapFragment`.
    case rendered(String)
    /// Nothing was rendered; show the limit's message instead.
    case limited(PreviewLimit)
    case cancelled
}

/// Renders the Markdown dialect described in docs/preview-model.md to an HTML fragment.
///
/// Rendering is a pure function of the source text. Raw HTML in the source is escaped, never
/// passed through, and link and image addresses are limited by `PreviewURLPolicy`, so the
/// output contains only the tags this renderer writes.
package enum MarkdownRenderer {
    /// - Parameter isCancelled: polled at least every few thousand bytes of input. The default
    ///   reads the cancellation state of the task that calls `render`.
    package static func render(
        _ source: String, limits: PreviewLimits = .standard, isCancelled: @escaping () -> Bool = { Task.isCancelled }
    ) -> MarkdownRendering {
        render(bytes: Array(source.utf8), limits: limits, isCancelled: isCancelled)
    }

    /// Renders UTF-8 bytes. Bytes that are not valid UTF-8 appear as the replacement character.
    package static func render(
        _ source: Data, limits: PreviewLimits = .standard, isCancelled: @escaping () -> Bool = { Task.isCancelled }
    ) -> MarkdownRendering {
        guard source.count <= limits.maxSourceBytes else {
            return .limited(.sourceTooLarge(maxBytes: limits.maxSourceBytes))
        }
        return render(bytes: Array(source), limits: limits, isCancelled: isCancelled)
    }

    /// Renders UTF-8 bytes and also says which source lines each top-level block of the output
    /// was made from. The fragment is the same one `render` returns: the map is a second
    /// result, not marks in the HTML. `map` is nil unless the rendering is `.rendered`.
    ///
    /// Lines are counted as the editor counts them: a line ends at LF, CRLF or CR.
    package static func renderWithScrollMap(
        _ source: Data, limits: PreviewLimits = .standard, isCancelled: @escaping () -> Bool = { Task.isCancelled }
    ) -> (rendering: MarkdownRendering, map: PreviewScrollMap?) {
        guard source.count <= limits.maxSourceBytes else {
            return (.limited(.sourceTooLarge(maxBytes: limits.maxSourceBytes)), nil)
        }
        var map: PreviewScrollMap?
        let rendering = render(bytes: Array(source), limits: limits, isCancelled: isCancelled, map: &map)
        return (rendering, map)
    }

    private static func render(bytes: [UInt8], limits: PreviewLimits, isCancelled: @escaping () -> Bool)
        -> MarkdownRendering
    {
        var noMap: PreviewScrollMap?
        return render(bytes: bytes, limits: limits, isCancelled: isCancelled, map: &noMap, wantsMap: false)
    }

    private static func render(
        bytes: [UInt8], limits: PreviewLimits, isCancelled: @escaping () -> Bool, map: inout PreviewScrollMap?,
        wantsMap: Bool = true
    ) -> MarkdownRendering {
        guard bytes.count <= limits.maxSourceBytes else {
            return .limited(.sourceTooLarge(maxBytes: limits.maxSourceBytes))
        }
        let poll = CancellationPoll(isCancelled)
        do {
            var parser = MarkdownBlockParser(limits: limits, poll: poll)
            let lines = MarkdownText.lines(of: bytes)
            let parsed = try parser.parse(lines, depth: 0)
            var writer = MarkdownHTMLWriter(
                inline: MarkdownInlineRenderer(references: parser.references, poll: poll),
                maxOutputBytes: limits.maxOutputBytes, poll: poll)
            try writer.write(parsed.blocks, isTight: false)
            if wantsMap {
                var blocks: [PreviewScrollMap.Block] = []
                blocks.reserveCapacity(parsed.lineRanges.count)
                for range in parsed.lineRanges {
                    try poll.checkpoint()
                    blocks.append(
                        PreviewScrollMap.Block(
                            firstLine: range.lowerBound, lineCount: range.count,
                            fingerprint: PreviewScrollMap.fingerprint(of: lines[range])))
                }
                map = PreviewScrollMap(blocks: blocks)
            }
            return .rendered(String(decoding: writer.output, as: UTF8.self))
        } catch PreviewStop.outputTooLarge {
            return .limited(.outputTooLarge(maxBytes: limits.maxOutputBytes))
        } catch PreviewStop.tooManyTableCells {
            return .limited(.tooManyTableCells(maxCells: limits.markdownMaxTableCells))
        } catch {
            return .cancelled
        }
    }
}

/// Writes blocks as HTML, one block per line in the style of the CommonMark reference output.
private struct MarkdownHTMLWriter {
    let inline: MarkdownInlineRenderer
    let maxOutputBytes: Int
    let poll: CancellationPoll
    private(set) var output: [UInt8] = []

    init(inline: MarkdownInlineRenderer, maxOutputBytes: Int, poll: CancellationPoll) {
        self.inline = inline
        self.maxOutputBytes = maxOutputBytes
        self.poll = poll
    }

    /// - Parameter isTight: true inside an item of a tight list, where a paragraph is written
    ///   without `<p>` tags.
    mutating func write(_ blocks: [MarkdownBlock], isTight: Bool) throws {
        for block in blocks {
            try poll.checkpoint()
            try write(block, isTight: isTight)
            if output.count > maxOutputBytes { throw PreviewStop.outputTooLarge }
        }
    }

    private mutating func write(_ block: MarkdownBlock, isTight: Bool) throws {
        switch block {
        case .paragraph(let text):
            if isTight {
                try inline.render(text, into: &output)
            } else {
                startLine()
                append("<p>")
                try inline.render(text, into: &output)
                append("</p>\n")
            }
        case .heading(let level, let text):
            startLine()
            append("<h\(level)>")
            try inline.render(text, into: &output)
            append("</h\(level)>\n")
        case .code(let language, let content):
            startLine()
            if language.isEmpty {
                append("<pre><code>")
            } else {
                append("<pre><code class=\"language-")
                HTMLText.appendEscaped(language, to: &output)
                append("\">")
            }
            HTMLText.appendEscaped(content, to: &output)
            append("</code></pre>\n")
        case .quote(let blocks):
            startLine()
            append("<blockquote>\n")
            try write(blocks, isTight: false)
            startLine()
            append("</blockquote>\n")
        case .list(let list):
            try write(list)
        case .table(let table):
            try write(table)
        case .thematicBreak:
            startLine()
            append("<hr />\n")
        }
    }

    private mutating func write(_ list: MarkdownList) throws {
        startLine()
        if !list.isOrdered {
            append("<ul>\n")
        } else if list.start == 1 {
            append("<ol>\n")
        } else {
            append("<ol start=\"\(list.start)\">\n")
        }
        for item in list.items {
            append("<li>")
            if let isChecked = item.isChecked {
                // In a loose list the box goes inside the item's first paragraph.
                let box =
                    isChecked
                    ? "<input type=\"checkbox\" disabled checked /> " : "<input type=\"checkbox\" disabled /> "
                if !list.isTight, case .paragraph(let text)? = item.blocks.first {
                    append("\n<p>" + box)
                    try inline.render(text, into: &output)
                    append("</p>\n")
                    try write(Array(item.blocks.dropFirst()), isTight: false)
                } else {
                    append(box)
                    try write(item.blocks, isTight: list.isTight)
                }
            } else {
                try write(item.blocks, isTight: list.isTight)
            }
            append("</li>\n")
        }
        append(list.isOrdered ? "</ol>\n" : "</ul>\n")
    }

    private mutating func write(_ table: MarkdownTable) throws {
        startLine()
        append("<table>\n<thead>\n")
        try write(row: table.header, cellTag: "th", alignments: table.alignments)
        append("</thead>\n")
        if !table.rows.isEmpty {
            append("<tbody>\n")
            for row in table.rows {
                try poll.checkpoint()
                try write(row: row, cellTag: "td", alignments: table.alignments)
                if output.count > maxOutputBytes { throw PreviewStop.outputTooLarge }
            }
            append("</tbody>\n")
        }
        append("</table>\n")
    }

    /// Writes one cell per column. A row with fewer cells than the header is padded with empty
    /// ones here, so the padding is bounded by the output limit.
    private mutating func write(row: [[UInt8]], cellTag: String, alignments: [MarkdownTable.Alignment]) throws {
        append("<tr>\n")
        for (column, alignment) in alignments.enumerated() {
            try poll.checkpoint()
            if output.count > maxOutputBytes { throw PreviewStop.outputTooLarge }
            switch alignment {
            case .none: append("<\(cellTag)>")
            case .left: append("<\(cellTag) align=\"left\">")
            case .center: append("<\(cellTag) align=\"center\">")
            case .right: append("<\(cellTag) align=\"right\">")
            }
            if column < row.count { try inline.render(row[column], into: &output) }
            append("</\(cellTag)>\n")
        }
        append("</tr>\n")
    }

    private mutating func append(_ text: String) {
        output.append(contentsOf: Array(text.utf8))
    }

    /// Ends the current line unless the output is already at the start of one.
    private mutating func startLine() {
        if let last = output.last, last != PreviewByte.lineFeed { output.append(PreviewByte.lineFeed) }
    }
}
