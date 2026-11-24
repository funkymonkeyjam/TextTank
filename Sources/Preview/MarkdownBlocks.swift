// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One source line without its line ending. Lines are slices of the source bytes, so nested
/// containers strip their markers without copying text.
typealias MarkdownLine = ArraySlice<UInt8>

/// A block of a Markdown document. Text is kept as unparsed bytes: inline syntax is rendered
/// only after every block is known, because a link may use a definition that comes later.
indirect enum MarkdownBlock {
    case paragraph([UInt8])
    case heading(level: Int, text: [UInt8])
    case code(language: [UInt8], content: [UInt8])
    case quote([MarkdownBlock])
    case list(MarkdownList)
    case table(MarkdownTable)
    case thematicBreak
}

struct MarkdownList {
    var isOrdered: Bool
    var start: Int
    /// A tight list writes its paragraphs without `<p>` tags.
    var isTight: Bool
    var items: [MarkdownListItem]
}

struct MarkdownListItem {
    /// nil for an ordinary item; otherwise whether the task-list box is checked.
    var isChecked: Bool?
    var blocks: [MarkdownBlock]
}

struct MarkdownTable {
    enum Alignment { case none, left, center, right }
    var alignments: [Alignment]
    var header: [[UInt8]]
    /// The cells of each row as written, at most as many as the header has. A shorter row is
    /// padded with empty cells when it is written, where the output limit applies.
    var rows: [[[UInt8]]]
}

/// The target of a reference link, from a `[label]: destination "title"` line.
struct MarkdownReference {
    var destination: [UInt8]
    var title: [UInt8]?
}

/// Line-level helpers shared by the block and inline parsers.
enum MarkdownText {
    static func isBlank(_ line: MarkdownLine) -> Bool { line.allSatisfy(PreviewByte.isBlank) }

    /// The width of the leading spaces and tabs. A tab advances to the next multiple of four
    /// columns. `startColumn` is the column the slice starts at, which matters for a tab that
    /// follows a list or quote marker; a line as a whole starts at column 0 of its container.
    static func indentColumns(_ line: MarkdownLine, startColumn: Int = 0) -> Int {
        var column = startColumn
        for byte in line {
            if byte == PreviewByte.space {
                column += 1
            } else if byte == PreviewByte.tab {
                column += 4 - column % 4
            } else {
                break
            }
        }
        return column - startColumn
    }

    /// Removes up to `columns` columns of leading spaces and tabs. A tab that straddles the
    /// boundary is replaced by the spaces that remain of it.
    static func removingIndent(_ line: MarkdownLine, columns: Int, startColumn: Int = 0) -> MarkdownLine {
        let endColumn = startColumn + columns
        var column = startColumn
        var index = line.startIndex
        while index < line.endIndex, column < endColumn {
            if line[index] == PreviewByte.space {
                column += 1
            } else if line[index] == PreviewByte.tab {
                let width = 4 - column % 4
                if column + width > endColumn {
                    let padding = [UInt8](repeating: PreviewByte.space, count: column + width - endColumn)
                    return (padding + line[(index + 1)...])[...]
                }
                column += width
            } else {
                break
            }
            index += 1
        }
        return line[index...]
    }

    static func trimmingLeadingBlanks(_ line: MarkdownLine) -> MarkdownLine {
        line.drop(while: PreviewByte.isBlank)
    }

    static func trimmingBlanks(_ line: MarkdownLine) -> MarkdownLine {
        var trimmed = line.drop(while: PreviewByte.isBlank)
        while let last = trimmed.last, PreviewByte.isBlank(last) { trimmed = trimmed.dropLast() }
        return trimmed
    }

    /// Removes each backslash that escapes an ASCII punctuation character.
    static func unescaped<Bytes: Collection>(_ bytes: Bytes) -> [UInt8] where Bytes.Element == UInt8 {
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var pendingBackslash = false
        for byte in bytes {
            if pendingBackslash {
                if !PreviewByte.isPunctuation(byte) { result.append(PreviewByte.backslash) }
                result.append(byte)
                pendingBackslash = false
            } else if byte == PreviewByte.backslash {
                pendingBackslash = true
            } else {
                result.append(byte)
            }
        }
        if pendingBackslash { result.append(PreviewByte.backslash) }
        return result
    }

    /// The key a reference label is stored and looked up under: trimmed, inner whitespace
    /// collapsed to one space, lowercased.
    static func normalizedLabel<Bytes: Collection>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        let words = String(decoding: bytes, as: UTF8.self).split(whereSeparator: { $0.isWhitespace })
        return words.joined(separator: " ").lowercased()
    }

    /// Splits source text into lines at LF, CRLF and CR.
    static func lines(of source: [UInt8]) -> [MarkdownLine] {
        var lines: [MarkdownLine] = []
        var lineStart = 0
        var index = 0
        while index < source.count {
            let byte = source[index]
            if byte == PreviewByte.lineFeed || byte == PreviewByte.carriageReturn {
                lines.append(source[lineStart..<index])
                let isCRLF =
                    byte == PreviewByte.carriageReturn && index + 1 < source.count
                    && source[index + 1] == PreviewByte.lineFeed
                index += isCRLF ? 2 : 1
                lineStart = index
            } else {
                index += 1
            }
        }
        if lineStart < source.count { lines.append(source[lineStart...]) }
        return lines
    }
}

/// The opening line of a fenced code block.
private struct MarkdownFence {
    let marker: UInt8
    let length: Int
    let indent: Int
    let info: MarkdownLine

    init?(opening line: MarkdownLine) {
        let indent = MarkdownText.indentColumns(line)
        guard indent < 4 else { return nil }
        let content = MarkdownText.trimmingLeadingBlanks(line)
        guard let marker = content.first, marker == PreviewByte.backtick || marker == PreviewByte.tilde else {
            return nil
        }
        let run = content.prefix(while: { $0 == marker })
        guard run.count >= 3 else { return nil }
        let info = MarkdownText.trimmingBlanks(content.dropFirst(run.count))
        // A backtick fence cannot have a backtick in its info string; that is an inline code span.
        if marker == PreviewByte.backtick, info.contains(PreviewByte.backtick) { return nil }
        self.marker = marker
        self.length = run.count
        self.indent = indent
        self.info = info
    }

    func isClosed(by line: MarkdownLine) -> Bool {
        guard MarkdownText.indentColumns(line) < 4 else { return false }
        let content = MarkdownText.trimmingBlanks(line)
        return content.count >= length && content.allSatisfy { $0 == marker }
    }
}

/// The marker that starts a list item, and the first line of the item's content.
private struct MarkdownListMarker {
    let isOrdered: Bool
    /// The bullet character, or the `.` or `)` after an ordered item's number. Items belong to
    /// the same list only when this matches.
    let delimiter: UInt8
    let start: Int
    /// The column the item's content starts at. Later lines indented at least this far belong
    /// to the item.
    let contentColumn: Int
    let firstLine: MarkdownLine
    var startsEmpty: Bool { MarkdownText.isBlank(firstLine) }

    init?(_ line: MarkdownLine) {
        let indent = MarkdownText.indentColumns(line)
        guard indent < 4 else { return nil }
        let content = MarkdownText.trimmingLeadingBlanks(line)
        guard let first = content.first else { return nil }
        var markerLength = 1
        if first == PreviewByte.minus || first == PreviewByte.plus || first == PreviewByte.star {
            isOrdered = false
            delimiter = first
            start = 1
        } else {
            let digits = content.prefix(while: PreviewByte.isDigit)
            guard (1...9).contains(digits.count), digits.count < content.count else { return nil }
            let closer = content[content.startIndex + digits.count]
            guard closer == PreviewByte.dot || closer == PreviewByte.closeParen else { return nil }
            isOrdered = true
            delimiter = closer
            start = Int(String(decoding: digits, as: UTF8.self)) ?? 1
            markerLength = digits.count + 1
        }
        let rest = content.dropFirst(markerLength)
        if let next = rest.first, !PreviewByte.isBlank(next) { return nil }
        let markerEnd = indent + markerLength
        let spacing = MarkdownText.indentColumns(rest, startColumn: markerEnd)
        if MarkdownText.isBlank(rest) {
            contentColumn = markerEnd + 1
            firstLine = rest.suffix(0)
        } else if spacing >= 5 {
            // Five or more spaces after the marker: the content is an indented code block.
            contentColumn = markerEnd + 1
            firstLine = MarkdownText.removingIndent(rest, columns: 1, startColumn: markerEnd)
        } else {
            contentColumn = markerEnd + spacing
            firstLine = MarkdownText.removingIndent(rest, columns: spacing, startColumn: markerEnd)
        }
    }

    func continuesList(of other: MarkdownListMarker) -> Bool {
        isOrdered == other.isOrdered && delimiter == other.delimiter
    }
}

/// Decides whether an unmarked line may continue the paragraph a container ended on (a "lazy
/// continuation line"). It looks only at the container's previous line: lazy lines are allowed
/// after any non-blank line that is not inside a fenced code block and is not a heading or
/// thematic break.
private struct LazyContinuation {
    private var openFence: MarkdownFence?
    private(set) var isAllowed = false

    mutating func noteContainerLine(_ line: MarkdownLine) {
        if let fence = openFence {
            if fence.isClosed(by: line) { openFence = nil }
            isAllowed = false
        } else if let fence = MarkdownFence(opening: line) {
            openFence = fence
            isAllowed = false
        } else {
            isAllowed =
                !MarkdownText.isBlank(line) && MarkdownBlockParser.headingContent(line) == nil
                && !MarkdownBlockParser.isThematicBreak(line)
        }
    }

    /// A lazy line is stored indented by four columns. Indented text continues a paragraph but
    /// can never start a block or underline a heading, which is exactly what a lazy line may do.
    static func marked(_ line: MarkdownLine) -> MarkdownLine {
        let indent = [UInt8](repeating: PreviewByte.space, count: 4)
        return (indent + MarkdownText.trimmingLeadingBlanks(line))[...]
    }
}

/// Turns lines into blocks. Containers (block quotes and list items) strip their markers and
/// parse their content recursively, at most `maxNesting` levels deep; deeper markers stay text.
struct MarkdownBlockParser {
    struct Result {
        var blocks: [MarkdownBlock]
        /// True when a blank line separates two of `blocks`. This is what makes a list loose.
        var hasBlankLineBetweenBlocks: Bool
        /// For the outermost level only: the lines each of `blocks` was made from, as indices
        /// into the lines that were parsed. Empty for the content of a quote or a list item.
        var lineRanges: [Range<Int>] = []
    }

    let maxNesting: Int
    let maxTableColumns: Int
    let maxTableCells: Int
    let poll: CancellationPoll
    /// Link reference definitions found so far, by normalized label. The first definition wins.
    private(set) var references: [String: MarkdownReference] = [:]
    /// Table cells in the document so far, counting every row as wide as its header.
    private var tableCellCount = 0

    init(limits: PreviewLimits, poll: CancellationPoll) {
        self.maxNesting = limits.markdownMaxNesting
        self.maxTableColumns = limits.markdownMaxTableColumns
        self.maxTableCells = limits.markdownMaxTableCells
        self.poll = poll
    }

    mutating func parse(_ lines: [MarkdownLine], depth: Int) throws -> Result {
        var blocks: [MarkdownBlock] = []
        var index = 0
        var sawBlankLine = false
        var hasBlankLineBetweenBlocks = false
        var lineRanges: [Range<Int>] = []
        while index < lines.count {
            try poll.checkpoint(lines[index].count + 1)
            if MarkdownText.isBlank(lines[index]) {
                sawBlankLine = true
                index += 1
                continue
            }
            let blockCountBefore = blocks.count
            let firstLine = index
            index = try parseBlock(at: index, in: lines, depth: depth, into: &blocks)
            if blocks.count > blockCountBefore {
                if sawBlankLine && blockCountBefore > 0 { hasBlankLineBetweenBlocks = true }
                sawBlankLine = false
                // A block is made of at least the line it starts on.
                if depth == 0 { lineRanges.append(firstLine..<max(firstLine + 1, index)) }
            }
        }
        return Result(
            blocks: blocks, hasBlankLineBetweenBlocks: hasBlankLineBetweenBlocks, lineRanges: lineRanges)
    }

    /// Parses the block that starts at the non-blank line `index` and returns the index of the
    /// first line after it.
    private mutating func parseBlock(
        at index: Int, in lines: [MarkdownLine], depth: Int, into blocks: inout [MarkdownBlock]
    ) throws -> Int {
        let line = lines[index]
        if MarkdownText.indentColumns(line) >= 4 {
            return try parseIndentedCode(at: index, in: lines, into: &blocks)
        }
        if let fence = MarkdownFence(opening: line) {
            return try parseFencedCode(fence, at: index, in: lines, into: &blocks)
        }
        if let heading = Self.headingContent(line) {
            blocks.append(.heading(level: heading.level, text: Array(heading.text)))
            return index + 1
        }
        if Self.isThematicBreak(line) {
            blocks.append(.thematicBreak)
            return index + 1
        }
        if depth < maxNesting {
            if Self.quoteContent(line) != nil {
                return try parseQuote(at: index, in: lines, depth: depth, into: &blocks)
            }
            if let marker = MarkdownListMarker(line) {
                return try parseList(marker, at: index, in: lines, depth: depth, into: &blocks)
            }
        }
        if let table = Self.tableStart(at: index, in: lines, maxColumns: maxTableColumns) {
            return try parseTable(table, at: index, in: lines, into: &blocks)
        }
        return try parseParagraph(at: index, in: lines, into: &blocks)
    }

    // MARK: Leaf blocks

    /// An ATX heading: one to six `#`, then a space or the end of the line.
    static func headingContent(_ line: MarkdownLine) -> (level: Int, text: MarkdownLine)? {
        guard MarkdownText.indentColumns(line) < 4 else { return nil }
        let content = MarkdownText.trimmingBlanks(line)
        let level = content.prefix(while: { $0 == PreviewByte.hash }).count
        guard (1...6).contains(level) else { return nil }
        let rest = content.dropFirst(level)
        if let next = rest.first, !PreviewByte.isBlank(next) { return nil }
        var text = MarkdownText.trimmingBlanks(rest)
        // An optional closing run of `#` is dropped when a space comes before it.
        let withoutClosingRun = text.prefix(
            text.count - text.reversed().prefix(while: { $0 == PreviewByte.hash }).count)
        if withoutClosingRun.isEmpty {
            text = withoutClosingRun
        } else if withoutClosingRun.count < text.count, let last = withoutClosingRun.last, PreviewByte.isBlank(last) {
            text = MarkdownText.trimmingBlanks(withoutClosingRun)
        }
        return (level, text)
    }

    /// Three or more `*`, `-` or `_` with nothing but spaces between them.
    static func isThematicBreak(_ line: MarkdownLine) -> Bool {
        guard MarkdownText.indentColumns(line) < 4 else { return false }
        let content = MarkdownText.trimmingLeadingBlanks(line)
        guard let marker = content.first,
            marker == PreviewByte.star || marker == PreviewByte.minus || marker == PreviewByte.underscore
        else { return false }
        var count = 0
        for byte in content {
            if byte == marker {
                count += 1
            } else if !PreviewByte.isBlank(byte) {
                return false
            }
        }
        return count >= 3
    }

    /// The level of a setext heading underline: a line of only `=` (1) or only `-` (2).
    private static func setextLevel(_ line: MarkdownLine) -> Int? {
        guard MarkdownText.indentColumns(line) < 4 else { return nil }
        let content = MarkdownText.trimmingBlanks(line)
        guard let marker = content.first, content.allSatisfy({ $0 == marker }) else { return nil }
        if marker == PreviewByte.equals { return 1 }
        if marker == PreviewByte.minus { return 2 }
        return nil
    }

    private func parseIndentedCode(
        at start: Int, in lines: [MarkdownLine], into blocks: inout [MarkdownBlock]
    ) throws -> Int {
        var codeLines: [MarkdownLine] = []
        var endOfCode = start
        var index = start
        while index < lines.count {
            let line = lines[index]
            try poll.checkpoint(line.count + 1)
            let isBlank = MarkdownText.isBlank(line)
            guard isBlank || MarkdownText.indentColumns(line) >= 4 else { break }
            codeLines.append(MarkdownText.removingIndent(line, columns: 4))
            index += 1
            if !isBlank { endOfCode = index }
        }
        // Blank lines after the last code line are not part of the block.
        var content: [UInt8] = []
        for line in codeLines.prefix(endOfCode - start) {
            content.append(contentsOf: line)
            content.append(PreviewByte.lineFeed)
        }
        blocks.append(.code(language: [], content: content))
        return endOfCode
    }

    /// A fenced block runs to its closing fence, or to the end of its container when the fence
    /// is never closed.
    private func parseFencedCode(
        _ fence: MarkdownFence, at start: Int, in lines: [MarkdownLine], into blocks: inout [MarkdownBlock]
    ) throws -> Int {
        var content: [UInt8] = []
        var index = start + 1
        while index < lines.count {
            let line = lines[index]
            try poll.checkpoint(line.count + 1)
            index += 1
            if fence.isClosed(by: line) { break }
            content.append(contentsOf: MarkdownText.removingIndent(line, columns: fence.indent))
            content.append(PreviewByte.lineFeed)
        }
        let language = fence.info.prefix(while: { !PreviewByte.isBlank($0) })
        blocks.append(.code(language: MarkdownText.unescaped(language), content: content))
        return index
    }

    private mutating func parseParagraph(
        at start: Int, in lines: [MarkdownLine], into blocks: inout [MarkdownBlock]
    ) throws -> Int {
        var textLines = [MarkdownText.trimmingLeadingBlanks(lines[start])]
        var headingLevel: Int?
        var underline: MarkdownLine?
        var index = start + 1
        while index < lines.count {
            let line = lines[index]
            try poll.checkpoint(line.count + 1)
            if MarkdownText.isBlank(line) { break }
            if let level = Self.setextLevel(line) {
                headingLevel = level
                underline = line
                index += 1
                break
            }
            if Self.startsBlock(line) || Self.tableStart(at: index, in: lines, maxColumns: maxTableColumns) != nil {
                break
            }
            textLines.append(MarkdownText.trimmingLeadingBlanks(line))
            index += 1
        }
        // Reference definitions are only recognized at the start of a paragraph.
        var firstTextLine = 0
        while firstTextLine < textLines.count, let definition = Self.referenceDefinition(textLines[firstTextLine]) {
            if references[definition.label] == nil { references[definition.label] = definition.reference }
            firstTextLine += 1
        }
        textLines.removeFirst(firstTextLine)
        if textLines.isEmpty {
            // Only definitions came before the underline, so it is ordinary text.
            if let underline { blocks.append(.paragraph(Array(MarkdownText.trimmingBlanks(underline)))) }
            return index
        }
        var text: [UInt8] = []
        for (offset, line) in textLines.enumerated() {
            if offset > 0 { text.append(PreviewByte.lineFeed) }
            text.append(contentsOf: line)
        }
        while let last = text.last, PreviewByte.isBlank(last) { text.removeLast() }
        if let headingLevel {
            blocks.append(.heading(level: headingLevel, text: text))
        } else {
            blocks.append(.paragraph(text))
        }
        return index
    }

    /// True when `line` begins a block and so cannot continue the text before it.
    ///
    /// Directly after a paragraph (`interruptingParagraph`), a list item counts only when it is
    /// not empty and, if numbered, starts at 1; this keeps a wrapped line such as "2019. A year"
    /// in its paragraph. A lazy continuation line of a block quote or list item is stricter:
    /// there every list marker starts a block.
    private static func startsBlock(_ line: MarkdownLine, interruptingParagraph: Bool = true) -> Bool {
        guard MarkdownText.indentColumns(line) < 4 else { return false }
        if MarkdownFence(opening: line) != nil || headingContent(line) != nil { return true }
        if isThematicBreak(line) || quoteContent(line) != nil { return true }
        guard let marker = MarkdownListMarker(line) else { return false }
        if !interruptingParagraph { return true }
        return !marker.startsEmpty && (!marker.isOrdered || marker.start == 1)
    }

    /// Parses `[label]: destination "title"` written on one line.
    private static func referenceDefinition(_ line: MarkdownLine) -> (label: String, reference: MarkdownReference)? {
        guard line.first == PreviewByte.openBracket else { return nil }
        guard let labelEnd = closingBracket(in: line, after: line.startIndex) else { return nil }
        let label = MarkdownText.normalizedLabel(line[(line.startIndex + 1)..<labelEnd])
        guard !label.isEmpty, labelEnd + 1 < line.endIndex, line[labelEnd + 1] == PreviewByte.colon else { return nil }
        var rest = MarkdownText.trimmingBlanks(line[(labelEnd + 2)...])
        guard let first = rest.first else { return nil }
        let destination: MarkdownLine
        if first == PreviewByte.lessThan {
            guard let close = rest.firstIndex(of: PreviewByte.greaterThan) else { return nil }
            destination = rest[(rest.startIndex + 1)..<close]
            rest = rest[(close + 1)...]
        } else {
            destination = rest.prefix(while: { !PreviewByte.isBlank($0) })
            rest = rest.dropFirst(destination.count)
        }
        let title = MarkdownText.trimmingBlanks(rest)
        if title.isEmpty {
            return (label, MarkdownReference(destination: MarkdownText.unescaped(destination), title: nil))
        }
        // A title needs a space before it and matching quotes or parentheses around it.
        guard title.count < rest.count, title.count >= 2, let opener = title.first, let closer = title.last else {
            return nil
        }
        let isQuoted =
            (opener == PreviewByte.quote && closer == PreviewByte.quote)
            || (opener == PreviewByte.apostrophe && closer == PreviewByte.apostrophe)
            || (opener == PreviewByte.openParen && closer == PreviewByte.closeParen)
        guard isQuoted else { return nil }
        let reference = MarkdownReference(
            destination: MarkdownText.unescaped(destination),
            title: MarkdownText.unescaped(title.dropFirst().dropLast()))
        return (label, reference)
    }

    /// The index of the `]` that closes the `[` at `open`, when the label between them has no
    /// unescaped bracket and is at most 999 bytes long.
    static func closingBracket(in bytes: MarkdownLine, after open: Int) -> Int? {
        var index = open + 1
        let limit = min(bytes.endIndex, open + 1001)
        while index < limit {
            let byte = bytes[index]
            if byte == PreviewByte.backslash {
                index += 2
                continue
            }
            if byte == PreviewByte.openBracket { return nil }
            if byte == PreviewByte.closeBracket { return index }
            index += 1
        }
        return nil
    }

    // MARK: Containers

    /// The text after a block quote marker, or nil when the line does not start with `>`.
    static func quoteContent(_ line: MarkdownLine) -> MarkdownLine? {
        let indent = MarkdownText.indentColumns(line)
        guard indent < 4 else { return nil }
        let content = MarkdownText.trimmingLeadingBlanks(line)
        guard content.first == PreviewByte.greaterThan else { return nil }
        return MarkdownText.removingIndent(content.dropFirst(), columns: 1, startColumn: indent + 1)
    }

    private mutating func parseQuote(
        at start: Int, in lines: [MarkdownLine], depth: Int, into blocks: inout [MarkdownBlock]
    ) throws -> Int {
        var inner: [MarkdownLine] = []
        var lazy = LazyContinuation()
        var index = start
        while index < lines.count {
            let line = lines[index]
            try poll.checkpoint(line.count + 1)
            if let content = Self.quoteContent(line) {
                inner.append(content)
                lazy.noteContainerLine(content)
            } else if lazy.isAllowed, !MarkdownText.isBlank(line), !Self.startsBlock(line, interruptingParagraph: false)
            {
                inner.append(LazyContinuation.marked(line))
            } else {
                break
            }
            index += 1
        }
        blocks.append(.quote(try parse(inner, depth: depth + 1).blocks))
        return index
    }

    private mutating func parseList(
        _ firstMarker: MarkdownListMarker, at start: Int, in lines: [MarkdownLine], depth: Int,
        into blocks: inout [MarkdownBlock]
    ) throws -> Int {
        var list = MarkdownList(
            isOrdered: firstMarker.isOrdered, start: firstMarker.start, isTight: true, items: [])
        var marker = firstMarker
        var index = start
        while true {
            var itemLines = [marker.firstLine]
            var lazy = LazyContinuation()
            lazy.noteContainerLine(marker.firstLine)
            // Blank lines belong to the item only if more of the item follows them.
            var pendingBlankLines = 0
            var next = index + 1
            while next < lines.count {
                let line = lines[next]
                try poll.checkpoint(line.count + 1)
                if MarkdownText.isBlank(line) {
                    pendingBlankLines += 1
                } else if MarkdownText.indentColumns(line) >= marker.contentColumn {
                    // An item that starts with an empty line ends at the first blank line.
                    if pendingBlankLines > 0, itemLines.count == 1, marker.startsEmpty { break }
                    for _ in 0..<pendingBlankLines {
                        itemLines.append(line.suffix(0))
                        lazy.noteContainerLine(line.suffix(0))
                    }
                    pendingBlankLines = 0
                    let content = MarkdownText.removingIndent(line, columns: marker.contentColumn)
                    itemLines.append(content)
                    lazy.noteContainerLine(content)
                } else if pendingBlankLines == 0, lazy.isAllowed, !Self.startsBlock(line, interruptingParagraph: false)
                {
                    itemLines.append(LazyContinuation.marked(line))
                } else {
                    break
                }
                next += 1
            }
            let content = try parse(itemLines, depth: depth + 1)
            if content.hasBlankLineBetweenBlocks { list.isTight = false }
            list.items.append(Self.listItem(content.blocks))

            let hasNextItem: Bool
            if next < lines.count, !Self.isThematicBreak(lines[next]), let following = MarkdownListMarker(lines[next]),
                following.continuesList(of: marker)
            {
                marker = following
                hasNextItem = true
            } else {
                hasNextItem = false
            }
            guard hasNextItem else {
                blocks.append(.list(list))
                // The blank lines after the last item are left for the enclosing container.
                return next - pendingBlankLines
            }
            if pendingBlankLines > 0 { list.isTight = false }
            index = next
        }
    }

    /// Recognizes a task-list item: content that starts with `[ ] ` or `[x] `.
    private static func listItem(_ blocks: [MarkdownBlock]) -> MarkdownListItem {
        guard case .paragraph(let text)? = blocks.first, text.count > 4,
            text[0] == PreviewByte.openBracket, text[2] == PreviewByte.closeBracket, PreviewByte.isBlank(text[3])
        else { return MarkdownListItem(isChecked: nil, blocks: blocks) }
        let isChecked: Bool
        switch text[1] {
        case PreviewByte.space: isChecked = false
        case UInt8(ascii: "x"), UInt8(ascii: "X"): isChecked = true
        default: return MarkdownListItem(isChecked: nil, blocks: blocks)
        }
        var remaining = blocks
        remaining[0] = .paragraph(Array(text.dropFirst(4).drop(while: PreviewByte.isBlank)))
        return MarkdownListItem(isChecked: isChecked, blocks: remaining)
    }

    // MARK: Tables

    private struct TableStart {
        var header: [[UInt8]]
        var alignments: [MarkdownTable.Alignment]
    }

    /// A table starts at a line with a pipe whose next line is a delimiter row (`| --- | :-: |`)
    /// with the same number of cells, at most `maxColumns` of them.
    private static func tableStart(at index: Int, in lines: [MarkdownLine], maxColumns: Int) -> TableStart? {
        guard index + 1 < lines.count else { return nil }
        let headerLine = lines[index]
        let delimiterLine = lines[index + 1]
        guard MarkdownText.indentColumns(headerLine) < 4, MarkdownText.indentColumns(delimiterLine) < 4 else {
            return nil
        }
        // Reject quickly: a delimiter row starts with a pipe, colon or hyphen.
        guard let first = MarkdownText.trimmingLeadingBlanks(delimiterLine).first,
            first == PreviewByte.pipe || first == PreviewByte.colon || first == PreviewByte.minus,
            delimiterLine.contains(PreviewByte.pipe), headerLine.contains(PreviewByte.pipe)
        else { return nil }
        var alignments: [MarkdownTable.Alignment] = []
        for cell in tableCells(delimiterLine) {
            guard let alignment = columnAlignment(cell) else { return nil }
            alignments.append(alignment)
        }
        let header = tableCells(headerLine)
        guard !alignments.isEmpty, alignments.count <= maxColumns, header.count == alignments.count else { return nil }
        return TableStart(header: header, alignments: alignments)
    }

    private static func columnAlignment(_ cell: [UInt8]) -> MarkdownTable.Alignment? {
        var dashes = cell[...]
        let startsWithColon = dashes.first == PreviewByte.colon
        if startsWithColon { dashes = dashes.dropFirst() }
        let endsWithColon = dashes.last == PreviewByte.colon
        if endsWithColon { dashes = dashes.dropLast() }
        guard !dashes.isEmpty, dashes.allSatisfy({ $0 == PreviewByte.minus }) else { return nil }
        switch (startsWithColon, endsWithColon) {
        case (true, true): return .center
        case (true, false): return .left
        case (false, true): return .right
        case (false, false): return MarkdownTable.Alignment.none
        }
    }

    /// Splits a table row at each `|` that is not escaped as `\|`. One leading and one trailing
    /// pipe are optional. Cells are trimmed, and `\|` becomes `|`.
    private static func tableCells(_ line: MarkdownLine) -> [[UInt8]] {
        var content = MarkdownText.trimmingBlanks(line)
        if content.first == PreviewByte.pipe { content = content.dropFirst() }
        var cells: [[UInt8]] = []
        var cell: [UInt8] = []
        var endedWithPipe = false
        var index = content.startIndex
        while index < content.endIndex {
            let byte = content[index]
            endedWithPipe = false
            if byte == PreviewByte.backslash, index + 1 < content.endIndex {
                let next = content[index + 1]
                if next != PreviewByte.pipe { cell.append(byte) }
                cell.append(next)
                index += 2
                continue
            }
            if byte == PreviewByte.pipe {
                cells.append(Array(MarkdownText.trimmingBlanks(cell[...])))
                cell = []
                endedWithPipe = true
            } else {
                cell.append(byte)
            }
            index += 1
        }
        if !endedWithPipe { cells.append(Array(MarkdownText.trimmingBlanks(cell[...]))) }
        return cells
    }

    /// Rows are kept as written and never padded here: padding every short row of a wide table
    /// would cost far more memory than the source. The cell budget counts the padded size.
    private mutating func parseTable(
        _ start: TableStart, at index: Int, in lines: [MarkdownLine], into blocks: inout [MarkdownBlock]
    ) throws -> Int {
        let columnCount = start.header.count
        var table = MarkdownTable(alignments: start.alignments, header: start.header, rows: [])
        tableCellCount += columnCount
        var next = index + 2
        while next < lines.count, !MarkdownText.isBlank(lines[next]), !Self.startsBlock(lines[next]) {
            try poll.checkpoint(lines[next].count + 1)
            tableCellCount += columnCount
            guard tableCellCount <= maxTableCells else { throw PreviewStop.tooManyTableCells }
            table.rows.append(Array(Self.tableCells(lines[next]).prefix(columnCount)))
            next += 1
        }
        blocks.append(.table(table))
        return next
    }
}
