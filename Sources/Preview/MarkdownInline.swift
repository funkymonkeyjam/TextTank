// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Renders the inline syntax of one paragraph, heading or table cell to HTML.
struct MarkdownInlineRenderer {
    let references: [String: MarkdownReference]
    let poll: CancellationPoll

    func render(_ text: [UInt8], into output: inout [UInt8]) throws {
        var pass = MarkdownInlinePass(text: text, references: references, poll: poll)
        try pass.run()
        pass.appendHTML(to: &output)
    }
}

/// One pass over a piece of inline text.
///
/// The text is first cut into a flat list of nodes. Emphasis markers and brackets start as
/// literal text; `processEmphasis` and `closeBracket` later give them meaning, following the
/// delimiter-stack method of the CommonMark specification. Work is linear in the text for
/// ordinary input and bounded for adversarial input by the caps declared below.
private struct MarkdownInlinePass {
    private enum Node {
        /// A range of the source text, escaped when written.
        case text(Range<Int>)
        /// Finished HTML, with the plain-text form used inside an image description.
        case fragment(html: [UInt8], plain: [UInt8])
        /// A run of `*` or `_`, by index into `runs`.
        case delimiter(Int)
        case softBreak
        case hardBreak
    }

    /// A run of `*` or `_`. Matching uses characters from the inner end of the run, so what is
    /// left of an opening run is written before its tags and what is left of a closing run after.
    private struct DelimiterRun {
        let marker: UInt8
        let originalCount: Int
        var count: Int
        let canOpen: Bool
        let canClose: Bool
        /// Tags this run opens, innermost first; true means `<strong>`, false `<em>`.
        var opens: [Bool] = []
        /// Tags this run closes, innermost first.
        var closes: [Bool] = []
    }

    private struct Bracket {
        /// The node holding the literal `[` or `![`.
        let nodeIndex: Int
        let isImage: Bool
        /// The first byte after the bracket: the start of the link text.
        let contentStart: Int
        /// How many delimiter runs were open when the bracket was seen. Emphasis inside the
        /// link text is matched only among the runs after these.
        let delimiterBase: Int
        /// A `[` before a finished link cannot start another link: links do not nest.
        var isActive = true
    }

    private struct LinkTarget {
        var destination: [UInt8]
        var title: [UInt8]?
        /// The index after the last byte of the link syntax.
        var end: Int
    }

    /// Brackets nested deeper than this are literal text, which bounds the repeated rendering
    /// of images inside image descriptions.
    private static let maxBracketDepth = 32
    /// The longest link destination or title, in bytes, that is recognized.
    private static let maxLinkPartLength = 2048
    private static let maxParenthesisDepth = 32

    private static let isSpecial: [Bool] = {
        var table = [Bool](repeating: false, count: 256)
        for byte in Array("\\`*_[]!<&\n".utf8) { table[Int(byte)] = true }
        return table
    }()

    private let text: [UInt8]
    private let references: [String: MarkdownReference]
    private let poll: CancellationPoll
    private var nodes: [Node] = []
    private var runs: [DelimiterRun] = []
    /// Indices into `runs` of the runs that may still open or close emphasis.
    private var delimiterStack: [Int] = []
    private var brackets: [Bracket] = []
    private var position = 0
    /// The start of the literal text that has not yet been made into a node.
    private var textStart = 0
    /// Start offsets of every backtick run, by run length. Built on first use.
    private var backtickRuns: [Int: [Int]]?

    init(text: [UInt8], references: [String: MarkdownReference], poll: CancellationPoll) {
        self.text = text
        self.references = references
        self.poll = poll
    }

    mutating func run() throws {
        while position < text.count {
            // Skip ordinary text in bounded steps so that cancellation is polled regularly.
            let skipStart = position
            let skipEnd = min(text.count, position + 1024)
            while position < skipEnd, !Self.isSpecial[Int(text[position])] { position += 1 }
            try poll.checkpoint(position - skipStart + 1)
            guard position < text.count, Self.isSpecial[Int(text[position])] else { continue }
            switch text[position] {
            case PreviewByte.backslash: scanBackslash()
            case PreviewByte.backtick: scanCodeSpan()
            case PreviewByte.star, PreviewByte.underscore: scanDelimiterRun()
            case PreviewByte.openBracket: openBracket(isImage: false)
            case PreviewByte.bang: scanBang()
            case PreviewByte.closeBracket: try closeBracket()
            case PreviewByte.lessThan: scanAutolink()
            case PreviewByte.ampersand: scanEntity()
            default: scanLineEnd()
            }
        }
        flushText(upTo: text.count)
        try processEmphasis(from: 0)
    }

    func appendHTML(to output: inout [UInt8]) {
        appendHTML(of: nodes[...], to: &output)
    }

    // MARK: Nodes

    /// Makes the pending literal text before `end` into a node.
    private mutating func flushText(upTo end: Int) {
        if end > textStart { nodes.append(.text(textStart..<end)) }
        textStart = end
    }

    /// Continues after a construct that ended at `end`.
    private mutating func resume(at end: Int) {
        position = end
        textStart = end
    }

    private func appendHTML(of slice: ArraySlice<Node>, to output: inout [UInt8]) {
        for node in slice {
            switch node {
            case .text(let range):
                HTMLText.appendEscaped(text[range], to: &output)
            case .fragment(let html, _):
                output.append(contentsOf: html)
            case .delimiter(let runIndex):
                let run = runs[runIndex]
                for isStrong in run.closes { output.append(contentsOf: Array((isStrong ? "</strong>" : "</em>").utf8)) }
                output.append(contentsOf: repeatElement(run.marker, count: run.count))
                for isStrong in run.opens.reversed() {
                    output.append(contentsOf: Array((isStrong ? "<strong>" : "<em>").utf8))
                }
            case .softBreak:
                output.append(PreviewByte.lineFeed)
            case .hardBreak:
                output.append(contentsOf: Array("<br />\n".utf8))
            }
        }
    }

    /// The text of the nodes without any tags, escaped for use in an attribute.
    private func appendPlainText(of slice: ArraySlice<Node>, to output: inout [UInt8]) {
        for node in slice {
            switch node {
            case .text(let range): HTMLText.appendEscaped(text[range], to: &output)
            case .fragment(_, let plain): output.append(contentsOf: plain)
            case .delimiter(let runIndex):
                output.append(contentsOf: repeatElement(runs[runIndex].marker, count: runs[runIndex].count))
            case .softBreak, .hardBreak: output.append(PreviewByte.space)
            }
        }
    }

    // MARK: Simple constructs

    private mutating func scanBackslash() {
        let next = position + 1
        if next < text.count, text[next] == PreviewByte.lineFeed {
            flushText(upTo: position)
            nodes.append(.hardBreak)
            resume(at: indexAfterBlanks(from: next + 1))
        } else if next < text.count, PreviewByte.isPunctuation(text[next]) {
            // Drop the backslash; the escaped character is literal text.
            flushText(upTo: position)
            textStart = next
            position = next + 1
        } else {
            position += 1
        }
    }

    /// A line ending inside a paragraph: a hard break after two or more spaces, else a soft one.
    private mutating func scanLineEnd() {
        var contentEnd = position
        while contentEnd > textStart, text[contentEnd - 1] == PreviewByte.space { contentEnd -= 1 }
        let trailingSpaces = position - contentEnd
        flushText(upTo: contentEnd)
        nodes.append(trailingSpaces >= 2 ? .hardBreak : .softBreak)
        resume(at: indexAfterBlanks(from: position + 1))
    }

    private func indexAfterBlanks(from start: Int) -> Int {
        var index = start
        while index < text.count, PreviewByte.isBlank(text[index]) { index += 1 }
        return index
    }

    private mutating func scanEntity() {
        guard let length = HTMLText.entityLength(in: text, at: position) else {
            position += 1
            return
        }
        flushText(upTo: position)
        let entity = Array(text[position..<position + length])
        nodes.append(.fragment(html: entity, plain: entity))
        resume(at: position + length)
    }

    /// A code span opens with a run of backticks and closes at the next run of the same length.
    private mutating func scanCodeSpan() {
        var openerEnd = position
        while openerEnd < text.count, text[openerEnd] == PreviewByte.backtick { openerEnd += 1 }
        let length = openerEnd - position
        guard let closerStart = nextBacktickRun(ofLength: length, after: openerEnd) else {
            position = openerEnd
            return
        }
        flushText(upTo: position)
        var content = text[openerEnd..<closerStart].map { $0 == PreviewByte.lineFeed ? PreviewByte.space : $0 }
        // One space of padding on each side is removed, so that `` ` `` can show a backtick.
        if content.count >= 2, content.first == PreviewByte.space, content.last == PreviewByte.space,
            content.contains(where: { $0 != PreviewByte.space })
        {
            content.removeFirst()
            content.removeLast()
        }
        var escaped: [UInt8] = []
        HTMLText.appendEscaped(content, to: &escaped)
        nodes.append(.fragment(html: Array("<code>".utf8) + escaped + Array("</code>".utf8), plain: escaped))
        resume(at: closerStart + length)
    }

    /// The start of the first backtick run of exactly `length` at or after `minimum`. Runs are
    /// indexed once, so many unmatched backticks cannot make the search quadratic.
    private mutating func nextBacktickRun(ofLength length: Int, after minimum: Int) -> Int? {
        if backtickRuns == nil {
            var table: [Int: [Int]] = [:]
            var index = 0
            while index < text.count {
                guard text[index] == PreviewByte.backtick else {
                    index += 1
                    continue
                }
                let start = index
                while index < text.count, text[index] == PreviewByte.backtick { index += 1 }
                table[index - start, default: []].append(start)
            }
            backtickRuns = table
        }
        guard let starts = backtickRuns?[length] else { return nil }
        var low = 0
        var high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] < minimum { low = middle + 1 } else { high = middle }
        }
        return low < starts.count ? starts[low] : nil
    }

    /// `<https://example.com>` and `<name@example.com>`. Anything else that starts with `<`,
    /// including raw HTML, stays literal text and is escaped.
    private mutating func scanAutolink() {
        var end = position + 1
        let limit = min(text.count, position + 1 + Self.maxLinkPartLength)
        while end < limit, text[end] > PreviewByte.space, text[end] != PreviewByte.lessThan,
            text[end] != PreviewByte.greaterThan, text[end] != 0x7F
        {
            end += 1
        }
        guard end < text.count, text[end] == PreviewByte.greaterThan, end > position + 1 else {
            position += 1
            return
        }
        let address = text[(position + 1)..<end]
        let addressText = String(decoding: address, as: UTF8.self)
        let destination: [UInt8]
        if let scheme = PreviewURLPolicy.scheme(of: addressText), scheme.utf8.count >= 2 {
            // A scheme that is not allowed leaves the whole `<...>` as text.
            guard PreviewURLPolicy.allowsMarkdownDestination(addressText) else {
                position = end + 1
                return
            }
            destination = Array(address)
        } else if Self.isEmailAddress(address) {
            destination = Array("mailto:".utf8) + address
        } else {
            position += 1
            return
        }
        flushText(upTo: position)
        var label: [UInt8] = []
        HTMLText.appendEscaped(address, to: &label)
        var html = Array("<a href=\"".utf8)
        HTMLText.appendEscaped(destination, to: &html)
        html.append(contentsOf: Array("\">".utf8))
        html.append(contentsOf: label)
        html.append(contentsOf: Array("</a>".utf8))
        nodes.append(.fragment(html: html, plain: label))
        resume(at: end + 1)
    }

    private static func isEmailAddress(_ bytes: ArraySlice<UInt8>) -> Bool {
        guard let at = bytes.firstIndex(of: PreviewByte.at), at > bytes.startIndex, at + 1 < bytes.endIndex else {
            return false
        }
        let localPartExtras = Array(".!#$%&'*+/=?^_`{|}~-".utf8)
        let isLocalPart = bytes[..<at].allSatisfy { PreviewByte.isAlphanumeric($0) || localPartExtras.contains($0) }
        let isDomain = bytes[(at + 1)...].allSatisfy {
            PreviewByte.isAlphanumeric($0) || $0 == PreviewByte.minus || $0 == PreviewByte.dot
        }
        return isLocalPart && isDomain
    }

    // MARK: Emphasis

    private mutating func scanDelimiterRun() {
        let marker = text[position]
        var end = position
        while end < text.count, text[end] == marker { end += 1 }
        let before = scalar(endingAt: position)
        let after = scalar(startingAt: end)
        let beforeIsSpace = Self.isWhitespace(before)
        let afterIsSpace = Self.isWhitespace(after)
        let beforeIsPunctuation = Self.isPunctuation(before)
        let afterIsPunctuation = Self.isPunctuation(after)
        let leftFlanking = !afterIsSpace && (!afterIsPunctuation || beforeIsSpace || beforeIsPunctuation)
        let rightFlanking = !beforeIsSpace && (!beforeIsPunctuation || afterIsSpace || afterIsPunctuation)
        let canOpen: Bool
        let canClose: Bool
        if marker == PreviewByte.star {
            canOpen = leftFlanking
            canClose = rightFlanking
        } else {
            // An underscore inside a word is literal: snake_case_name has no emphasis.
            canOpen = leftFlanking && (!rightFlanking || beforeIsPunctuation)
            canClose = rightFlanking && (!leftFlanking || afterIsPunctuation)
        }
        flushText(upTo: position)
        runs.append(
            DelimiterRun(
                marker: marker, originalCount: end - position, count: end - position, canOpen: canOpen,
                canClose: canClose))
        delimiterStack.append(runs.count - 1)
        nodes.append(.delimiter(runs.count - 1))
        resume(at: end)
    }

    /// The character that ends just before `index`, or nil at the start of the text.
    private func scalar(endingAt index: Int) -> Unicode.Scalar? {
        guard index > 0 else { return nil }
        var start = index - 1
        while start > 0, index - start < 4, text[start] & 0xC0 == 0x80 { start -= 1 }
        return String(decoding: text[start..<index], as: UTF8.self).unicodeScalars.last
    }

    /// The character that starts at `index`, or nil at the end of the text.
    private func scalar(startingAt index: Int) -> Unicode.Scalar? {
        guard index < text.count else { return nil }
        var end = index + 1
        while end < text.count, end - index < 4, text[end] & 0xC0 == 0x80 { end += 1 }
        return String(decoding: text[index..<end], as: UTF8.self).unicodeScalars.first
    }

    /// The start and end of the text count as whitespace.
    private static func isWhitespace(_ scalar: Unicode.Scalar?) -> Bool {
        guard let scalar else { return true }
        return scalar.properties.isWhitespace
    }

    private static func isPunctuation(_ scalar: Unicode.Scalar?) -> Bool {
        guard let scalar else { return false }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
            .finalPunctuation, .otherPunctuation, .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }

    /// Pairs opening and closing runs among the runs on `delimiterStack` from `base` upward, then
    /// removes them from the stack. This is the "process emphasis" procedure of the CommonMark
    /// specification, including its rule that a run able to both open and close does not pair
    /// with another when their combined length is a multiple of three.
    private mutating func processEmphasis(from base: Int) throws {
        let candidates = Array(delimiterStack[base...])
        delimiterStack.removeSubrange(base...)
        let count = candidates.count
        // A doubly linked list over `candidates`; `count` and -1 mark the ends.
        var previous = Array(-1..<(count - 1))
        var next = Array(1..<(count + 1))
        func unlink(_ index: Int, _ previous: inout [Int], _ next: inout [Int]) {
            if previous[index] >= 0 { next[previous[index]] = next[index] }
            if next[index] < count { previous[next[index]] = previous[index] }
        }
        // For each kind of closer, the position at or below which no opener can match it. This
        // keeps the search for openers linear overall.
        var openersBottom = [Int](repeating: -1, count: 12)
        var closer = 0
        while closer < count {
            try poll.checkpoint()
            let closerRun = runs[candidates[closer]]
            guard closerRun.canClose else {
                closer = next[closer]
                continue
            }
            let bottomIndex =
                (closerRun.marker == PreviewByte.star ? 0 : 6) + (closerRun.canOpen ? 3 : 0)
                + closerRun.originalCount % 3
            var opener = previous[closer]
            var foundOpener = false
            while opener > openersBottom[bottomIndex] {
                let openerRun = runs[candidates[opener]]
                let isOddMatch =
                    (closerRun.canOpen || openerRun.canClose) && closerRun.originalCount % 3 != 0
                    && (openerRun.originalCount + closerRun.originalCount) % 3 == 0
                if openerRun.marker == closerRun.marker, openerRun.canOpen, !isOddMatch {
                    foundOpener = true
                    break
                }
                opener = previous[opener]
            }
            guard foundOpener else {
                openersBottom[bottomIndex] = previous[closer]
                let following = next[closer]
                if !closerRun.canOpen { unlink(closer, &previous, &next) }
                closer = following
                continue
            }
            let openerIndex = candidates[opener]
            let closerIndex = candidates[closer]
            let isStrong = runs[openerIndex].count >= 2 && runs[closerIndex].count >= 2
            let used = isStrong ? 2 : 1
            runs[openerIndex].count -= used
            runs[openerIndex].opens.append(isStrong)
            runs[closerIndex].count -= used
            runs[closerIndex].closes.append(isStrong)
            // Runs between the pair can no longer match anything.
            next[opener] = closer
            previous[closer] = opener
            if runs[openerIndex].count == 0 { unlink(opener, &previous, &next) }
            if runs[closerIndex].count == 0 {
                let following = next[closer]
                unlink(closer, &previous, &next)
                closer = following
            }
        }
    }

    // MARK: Links and images

    private mutating func scanBang() {
        if position + 1 < text.count, text[position + 1] == PreviewByte.openBracket {
            openBracket(isImage: true)
        } else {
            position += 1
        }
    }

    private mutating func openBracket(isImage: Bool) {
        let markerLength = isImage ? 2 : 1
        guard brackets.count < Self.maxBracketDepth else {
            position += markerLength
            return
        }
        flushText(upTo: position)
        let contentStart = position + markerLength
        nodes.append(.text(position..<contentStart))
        brackets.append(
            Bracket(
                nodeIndex: nodes.count - 1, isImage: isImage, contentStart: contentStart,
                delimiterBase: delimiterStack.count))
        resume(at: contentStart)
    }

    /// A `]` completes a link or image when a target follows it; otherwise it is literal text and
    /// so is the bracket it would have closed.
    private mutating func closeBracket() throws {
        guard let opener = brackets.popLast(), opener.isActive,
            let target = linkTarget(afterBracketAt: position, opener: opener)
        else {
            position += 1
            return
        }
        flushText(upTo: position)
        try processEmphasis(from: opener.delimiterBase)
        var contentHTML: [UInt8] = []
        var contentPlain: [UInt8] = []
        // The slice of nodes is not kept in a variable: removing nodes while a slice of the
        // array is alive would copy the whole array for every link.
        appendHTML(of: nodes[(opener.nodeIndex + 1)...], to: &contentHTML)
        appendPlainText(of: nodes[(opener.nodeIndex + 1)...], to: &contentPlain)
        nodes.removeSubrange(opener.nodeIndex...)
        nodes.append(
            .fragment(
                html: Self.linkHTML(target, isImage: opener.isImage, content: contentHTML, plain: contentPlain),
                plain: contentPlain))
        if !opener.isImage {
            for index in brackets.indices where !brackets[index].isImage { brackets[index].isActive = false }
        }
        resume(at: target.end)
    }

    /// Writes the link or image. A destination the URL policy refuses produces no tag: a link
    /// keeps its text and an image keeps its description.
    private static func linkHTML(_ target: LinkTarget, isImage: Bool, content: [UInt8], plain: [UInt8]) -> [UInt8] {
        guard PreviewURLPolicy.allowsMarkdownDestination(String(decoding: target.destination, as: UTF8.self)) else {
            return isImage ? plain : content
        }
        var html = Array((isImage ? "<img src=\"" : "<a href=\"").utf8)
        HTMLText.appendEscaped(target.destination, to: &html)
        html.append(PreviewByte.quote)
        if isImage {
            html.append(contentsOf: Array(" alt=\"".utf8))
            html.append(contentsOf: plain)
            html.append(PreviewByte.quote)
        }
        if let title = target.title {
            html.append(contentsOf: Array(" title=\"".utf8))
            HTMLText.appendEscaped(title, to: &html, preservingEntities: true)
            html.append(PreviewByte.quote)
        }
        if isImage {
            html.append(contentsOf: Array(" />".utf8))
        } else {
            html.append(PreviewByte.greaterThan)
            html.append(contentsOf: content)
            html.append(contentsOf: Array("</a>".utf8))
        }
        return html
    }

    /// Finds what the bracket pair ending at `close` links to: `(destination "title")`, a
    /// `[label]` naming a definition, or the bracket's own text naming a definition.
    private func linkTarget(afterBracketAt close: Int, opener: Bracket) -> LinkTarget? {
        let after = close + 1
        if after < text.count, text[after] == PreviewByte.openParen, let target = inlineLinkTarget(openParen: after) {
            return target
        }
        guard !references.isEmpty else { return nil }
        var label = text[opener.contentStart..<close]
        var end = after
        if after < text.count, text[after] == PreviewByte.openBracket,
            let labelEnd = MarkdownBlockParser.closingBracket(in: text[...], after: after)
        {
            // `[text][label]`; an empty second pair, `[text][]`, uses the text as the label.
            if labelEnd > after + 1 { label = text[(after + 1)..<labelEnd] }
            end = labelEnd + 1
        }
        guard label.count <= 999, let reference = references[MarkdownText.normalizedLabel(label)] else { return nil }
        return LinkTarget(destination: reference.destination, title: reference.title, end: end)
    }

    /// Parses `(destination)` or `(destination "title")` starting at the `(`.
    private func inlineLinkTarget(openParen: Int) -> LinkTarget? {
        var index = indexAfterWhitespace(from: openParen + 1)
        guard index < text.count else { return nil }
        let destination: ArraySlice<UInt8>
        if text[index] == PreviewByte.lessThan {
            guard
                let close = endOfDelimitedPart(from: index + 1, closer: PreviewByte.greaterThan, allowsLineBreak: false)
            else { return nil }
            destination = text[(index + 1)..<close]
            index = close + 1
        } else {
            guard let end = endOfBareDestination(from: index) else { return nil }
            destination = text[index..<end]
            index = end
        }
        let afterDestination = index
        index = indexAfterWhitespace(from: index)
        var title: [UInt8]?
        if index < text.count, index > afterDestination, let closer = Self.titleCloser(for: text[index]) {
            guard let close = endOfDelimitedPart(from: index + 1, closer: closer, allowsLineBreak: true) else {
                return nil
            }
            title = MarkdownText.unescaped(text[(index + 1)..<close])
            index = indexAfterWhitespace(from: close + 1)
        }
        guard index < text.count, text[index] == PreviewByte.closeParen else { return nil }
        return LinkTarget(destination: MarkdownText.unescaped(destination), title: title, end: index + 1)
    }

    private static func titleCloser(for opener: UInt8) -> UInt8? {
        switch opener {
        case PreviewByte.quote: return PreviewByte.quote
        case PreviewByte.apostrophe: return PreviewByte.apostrophe
        case PreviewByte.openParen: return PreviewByte.closeParen
        default: return nil
        }
    }

    private func indexAfterWhitespace(from start: Int) -> Int {
        var index = start
        while index < text.count, PreviewByte.isWhitespace(text[index]) { index += 1 }
        return index
    }

    /// The index of the unescaped `closer` that ends a `<destination>` or a title.
    private func endOfDelimitedPart(from start: Int, closer: UInt8, allowsLineBreak: Bool) -> Int? {
        var index = start
        let limit = min(text.count, start + Self.maxLinkPartLength)
        while index < limit {
            let byte = text[index]
            if byte == PreviewByte.backslash {
                index += 2
                continue
            }
            if byte == closer { return index }
            if byte == PreviewByte.lineFeed, !allowsLineBreak { return nil }
            if byte == PreviewByte.lessThan, closer == PreviewByte.greaterThan { return nil }
            index += 1
        }
        return nil
    }

    /// The end of a destination written without angle brackets: it stops at whitespace or at the
    /// `)` that closes the link, and may contain balanced parentheses.
    private func endOfBareDestination(from start: Int) -> Int? {
        var index = start
        var depth = 0
        let limit = min(text.count, start + Self.maxLinkPartLength)
        while index < limit {
            let byte = text[index]
            if byte == PreviewByte.backslash, index + 1 < text.count, PreviewByte.isPunctuation(text[index + 1]) {
                index += 2
                continue
            }
            if byte <= PreviewByte.space || byte == 0x7F { break }
            if byte == PreviewByte.openParen {
                depth += 1
                if depth > Self.maxParenthesisDepth { return nil }
            } else if byte == PreviewByte.closeParen {
                if depth == 0 { break }
                depth -= 1
            }
            index += 1
        }
        return (index < limit && depth == 0) ? index : nil
    }
}
