// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One value in a JSON document.
package struct JSONNode: Sendable, Equatable {
    package enum Kind: Sendable, Equatable {
        case object, array, string, number, `true`, `false`, null
    }

    package var kind: Kind
    /// The bytes of the value in the source. For a container this runs from its opening bracket
    /// to its closing bracket, or to where parsing stopped if it was never closed.
    package var byteRange: Range<Int>
    /// The bytes of the member name, quotes included, when the value is a member of an object.
    package var keyRange: Range<Int>?
    /// The value's position among its parent's children, from 0. The root has 0.
    package var indexInParent: Int
    /// The index of the parent node, or nil for the root.
    package var parent: Int?
    /// The 1-based line the value starts on.
    package var line: Int
    /// The 1-based column the value starts at, counted in Unicode scalars.
    package var column: Int
    /// Where this container's children are listed in `JSONTree.childOrder`. Empty for a scalar.
    fileprivate var childRange: Range<Int> = 0..<0

    package var childCount: Int { childRange.count }
    package var isContainer: Bool { kind == .object || kind == .array }
}

/// Where and why JSON text stopped being valid.
package struct JSONSyntaxError: Sendable, Equatable {
    package enum Kind: Sendable, Equatable {
        case expectedValue
        case expectedValueOrClosingBracket
        case expectedNameOrClosingBrace
        case expectedName
        case expectedColon
        case expectedCommaOrClosingBrace
        case expectedCommaOrClosingBracket
        case unterminatedString
        case invalidEscape
        case controlCharacterInString
        case invalidNumber
        case leadingZero
        case invalidUTF8
        case unexpectedEnd
        case textAfterValue
    }

    package var kind: Kind
    /// The byte offset of the problem, from 0: the offset of the offending byte, or, for
    /// `unexpectedEnd`, the length of the document, which is the place just after its last
    /// byte. Go to Error puts the caret there. It is never greater than the length.
    package var byteOffset: Int
    /// 1-based.
    package var line: Int
    /// 1-based, counted in Unicode scalars.
    package var column: Int

    /// A whole sentence that names the problem and its line and column.
    package var message: String {
        String(format: format, String(line), String(column))
    }

    private var format: String {
        switch kind {
        case .expectedValue:
            return Strings.text("preview.json.expectedValue", "Expected a value at line %@, column %@.")
        case .expectedValueOrClosingBracket:
            return Strings.text(
                "preview.json.expectedValueOrBracket", "Expected a value or closing bracket at line %@, column %@.")
        case .expectedNameOrClosingBrace:
            return Strings.text(
                "preview.json.expectedNameOrBrace",
                "Expected a name in double quotes or a closing brace at line %@, column %@.")
        case .expectedName:
            return Strings.text(
                "preview.json.expectedName", "Expected a name in double quotes at line %@, column %@.")
        case .expectedColon:
            return Strings.text("preview.json.expectedColon", "Expected a colon after the name at line %@, column %@.")
        case .expectedCommaOrClosingBrace:
            return Strings.text(
                "preview.json.expectedCommaOrBrace", "Expected a comma or closing brace at line %@, column %@.")
        case .expectedCommaOrClosingBracket:
            return Strings.text(
                "preview.json.expectedCommaOrBracket", "Expected a comma or closing bracket at line %@, column %@.")
        case .unterminatedString:
            return Strings.text(
                "preview.json.unterminatedString", "The text that starts at line %@, column %@ has no closing quote.")
        case .invalidEscape:
            return Strings.text(
                "preview.json.invalidEscape", "The backslash sequence at line %@, column %@ is not valid.")
        case .controlCharacterInString:
            return Strings.text(
                "preview.json.controlCharacter",
                "Quoted text cannot contain a line break or control character, found at line %@, column %@.")
        case .invalidNumber:
            return Strings.text(
                "preview.json.invalidNumber", "The number at line %@, column %@ is not written correctly.")
        case .leadingZero:
            return Strings.text(
                "preview.json.leadingZero", "The number at line %@, column %@ starts with an extra zero.")
        case .invalidUTF8:
            return Strings.text(
                "preview.json.invalidUTF8", "The text at line %@, column %@ is not valid UTF-8.")
        case .unexpectedEnd:
            return Strings.text(
                "preview.json.unexpectedEnd", "The document ends before the JSON is complete, at line %@, column %@.")
        case .textAfterValue:
            return Strings.text(
                "preview.json.textAfterValue", "There is extra text after the end of the JSON at line %@, column %@.")
        }
    }
}

/// A JSON document as a tree that preserves the source: members keep their order, duplicate
/// names are all kept, and numbers are shown exactly as written, never converted.
///
/// Nodes are stored in document order, so the root is node 0 and every parent comes before its
/// children. Text is not copied out of the source; `key(of:)`, `displayValue(of:)` and
/// `rawText(of:)` read it on request.
package struct JSONTree: Sendable, Equatable {
    package fileprivate(set) var nodes: [JSONNode] = []
    /// Child node indices, grouped by parent; see `JSONNode.childRange`.
    fileprivate var childOrder: [Int] = []
    fileprivate let source: [UInt8]

    fileprivate init(source: [UInt8]) { self.source = source }

    /// The index of the outermost value, or nil when none was parsed.
    package var root: Int? { nodes.isEmpty ? nil : 0 }

    /// The indices of a container's children, in document order.
    package func children(of index: Int) -> ArraySlice<Int> { childOrder[nodes[index].childRange] }

    /// The value's text exactly as written in the source.
    package func rawText(of index: Int) -> String {
        String(decoding: source[nodes[index].byteRange], as: UTF8.self)
    }

    /// The member name with its escapes decoded, or nil when the value is not an object member.
    package func key(of index: Int) -> String? {
        nodes[index].keyRange.map { JSONText.decodedString(source[$0]) }
    }

    /// What to show for the value: decoded text for a string, the literal as written for a
    /// number, `true`, `false` or `null`, and the number of items for a container.
    package func displayValue(of index: Int) -> String {
        let node = nodes[index]
        switch node.kind {
        case .string: return JSONText.decodedString(source[node.byteRange])
        case .object, .array: return Strings.count(node.childCount, .item)
        case .number, .true, .false, .null: return rawText(of: index)
        }
    }
}

package enum JSONTreeOutcome: Sendable, Equatable {
    /// The document is empty or contains only whitespace.
    case empty
    case parsed(JSONTree)
    /// The document is not valid JSON. `partial` holds everything read before the error, with
    /// containers that were still open closed at the error.
    case invalid(partial: JSONTree, error: JSONSyntaxError)
    /// A limit was reached. `partial` holds what was read before it; for a document that is too
    /// large to read at all it is empty.
    case limited(partial: JSONTree, limit: PreviewLimit)
    case cancelled
}

extension JSONTree {
    /// Parses UTF-8 JSON text (RFC 8259). A byte order mark is skipped. Parsing is iterative, so
    /// deep nesting cannot overflow the stack.
    package static func parse(
        _ source: Data, limits: PreviewLimits = .standard, isCancelled: @escaping () -> Bool = { Task.isCancelled }
    ) -> JSONTreeOutcome {
        guard source.count <= limits.maxSourceBytes else {
            return .limited(partial: JSONTree(source: []), limit: .sourceTooLarge(maxBytes: limits.maxSourceBytes))
        }
        var parser = JSONTreeParser(
            source: Array(source), limits: limits, poll: CancellationPoll(isCancelled))
        return parser.parse()
    }

    package static func parse(
        _ source: String, limits: PreviewLimits = .standard, isCancelled: @escaping () -> Bool = { Task.isCancelled }
    ) -> JSONTreeOutcome {
        parse(Data(source.utf8), limits: limits, isCancelled: isCancelled)
    }
}

/// Reading JSON string literals and UTF-8.
enum JSONText {
    /// The length of the well-formed UTF-8 sequence that starts at `index`, or nil. Rejects
    /// overlong forms, surrogates and values above U+10FFFF.
    static func utf8SequenceLength(in bytes: [UInt8], at index: Int) -> Int? {
        let lead = bytes[index]
        let length: Int
        var secondByteRange: ClosedRange<UInt8> = 0x80...0xBF
        switch lead {
        case 0x00...0x7F: return 1
        case 0xC2...0xDF: length = 2
        case 0xE0:
            length = 3
            secondByteRange = 0xA0...0xBF
        case 0xED:
            length = 3
            secondByteRange = 0x80...0x9F
        case 0xE1...0xEF: length = 3
        case 0xF0:
            length = 4
            secondByteRange = 0x90...0xBF
        case 0xF4:
            length = 4
            secondByteRange = 0x80...0x8F
        case 0xF1...0xF3: length = 4
        default: return nil
        }
        guard index + length <= bytes.count, secondByteRange.contains(bytes[index + 1]) else { return nil }
        for offset in 2..<max(2, length) where bytes[index + offset] & 0xC0 != 0x80 { return nil }
        return length
    }

    /// Decodes a string literal, quotes included, that the parser has already accepted. An
    /// escaped surrogate without its partner becomes the replacement character.
    static func decodedString(_ literal: ArraySlice<UInt8>) -> String {
        let content = literal.dropFirst().dropLast()
        guard content.contains(PreviewByte.backslash) else { return String(decoding: content, as: UTF8.self) }
        var scalars = String.UnicodeScalarView()
        var plain: [UInt8] = []
        func flushPlain() {
            scalars.append(contentsOf: String(decoding: plain, as: UTF8.self).unicodeScalars)
            plain.removeAll(keepingCapacity: true)
        }
        var index = content.startIndex
        while index < content.endIndex {
            guard content[index] == PreviewByte.backslash, index + 1 < content.endIndex else {
                plain.append(content[index])
                index += 1
                continue
            }
            let escape = content[index + 1]
            index += 2
            switch escape {
            case UInt8(ascii: "b"): plain.append(0x08)
            case UInt8(ascii: "f"): plain.append(0x0C)
            case UInt8(ascii: "n"): plain.append(PreviewByte.lineFeed)
            case UInt8(ascii: "r"): plain.append(PreviewByte.carriageReturn)
            case UInt8(ascii: "t"): plain.append(PreviewByte.tab)
            case UInt8(ascii: "u"):
                flushPlain()
                var value = hexValue(content, at: index) ?? 0xFFFD
                index = min(content.endIndex, index + 4)
                let isHighSurrogate = (0xD800...0xDBFF).contains(value)
                if isHighSurrogate, index + 6 <= content.endIndex, content[index] == PreviewByte.backslash,
                    content[index + 1] == UInt8(ascii: "u"), let low = hexValue(content, at: index + 2),
                    (0xDC00...0xDFFF).contains(low)
                {
                    value = 0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00)
                    index += 6
                }
                scalars.append(Unicode.Scalar(value) ?? "\u{FFFD}")
            default: plain.append(escape)
            }
        }
        flushPlain()
        return String(scalars)
    }

    /// The value of the four hexadecimal digits at `index`, or nil.
    static func hexValue(_ bytes: ArraySlice<UInt8>, at index: Int) -> UInt32? {
        guard index + 4 <= bytes.endIndex else { return nil }
        var value: UInt32 = 0
        for byte in bytes[index..<index + 4] {
            guard PreviewByte.isHexDigit(byte) else { return nil }
            let digit = PreviewByte.isDigit(byte) ? byte - 0x30 : PreviewByte.lowercased(byte) - 0x61 + 10
            value = value << 4 | UInt32(digit)
        }
        return value
    }
}

/// An iterative JSON parser. Open containers are kept on an explicit stack, so nesting depth is
/// limited by `PreviewLimits.jsonMaxDepth` and not by the call stack.
private struct JSONTreeParser {
    /// What may come next.
    private enum Expectation {
        case value
        case firstElementOrClose
        case firstMemberOrClose
        case member
        case commaOrClose
    }

    private struct OpenContainer {
        let nodeIndex: Int
        let isObject: Bool
        /// Where this container's finished children start in `finishedChildren`.
        let firstFinishedChild: Int
        var childCount = 0
    }

    /// Why parsing stopped early.
    private enum Stop: Error {
        case syntax(JSONSyntaxError.Kind, at: Int)
        case limit(PreviewLimit)
    }

    private let bytes: [UInt8]
    private let limits: PreviewLimits
    private let poll: CancellationPoll
    private var tree: JSONTree
    private var position = 0
    private var line = 1
    /// A position whose column is known, on the current line. Columns are counted forward from
    /// here, so the whole document is scanned for columns only once.
    private var columnAnchor = (offset: 0, column: 1)
    private var open: [OpenContainer] = []
    /// Indices of finished child nodes of the containers in `open`, innermost last.
    private var finishedChildren: [Int] = []
    private var pendingKey: Range<Int>?

    init(source: [UInt8], limits: PreviewLimits, poll: CancellationPoll) {
        self.bytes = source
        self.limits = limits
        self.poll = poll
        self.tree = JSONTree(source: source)
        let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]
        if source.starts(with: byteOrderMark) {
            position = byteOrderMark.count
            columnAnchor = (position, 1)
        }
    }

    mutating func parse() -> JSONTreeOutcome {
        do {
            skipWhitespace()
            if position == bytes.count { return .empty }
            try parseDocument()
            return .parsed(tree)
        } catch Stop.syntax(let kind, let offset) {
            let offset = min(offset, bytes.count)
            let location = lineAndColumn(at: offset)
            closeOpenContainers(at: offset)
            let error = JSONSyntaxError(kind: kind, byteOffset: offset, line: location.line, column: location.column)
            return .invalid(partial: tree, error: error)
        } catch Stop.limit(let limit) {
            closeOpenContainers(at: position)
            return .limited(partial: tree, limit: limit)
        } catch {
            return .cancelled
        }
    }

    private mutating func parseDocument() throws {
        var expectation = Expectation.value
        var polledPosition = position
        while true {
            try poll.checkpoint(position - polledPosition + 1)
            polledPosition = position
            skipWhitespace()
            guard position < bytes.count else {
                if open.isEmpty, expectation == .commaOrClose { return }
                throw Stop.syntax(.unexpectedEnd, at: position)
            }
            let byte = bytes[position]
            switch expectation {
            case .value, .firstElementOrClose:
                if expectation == .firstElementOrClose, byte == PreviewByte.closeBracket {
                    closeContainer()
                    expectation = .commaOrClose
                } else {
                    expectation = try parseValue(orClosingBracket: expectation == .firstElementOrClose)
                }
            case .firstMemberOrClose, .member:
                if expectation == .firstMemberOrClose, byte == PreviewByte.closeBrace {
                    closeContainer()
                    expectation = .commaOrClose
                } else {
                    try parseMemberName(isFirst: expectation == .firstMemberOrClose)
                    expectation = .value
                }
            case .commaOrClose:
                expectation = try parseSeparator(byte)
            }
        }
    }

    /// Reads a scalar, or opens a container. Returns what may follow.
    private mutating func parseValue(orClosingBracket: Bool) throws -> Expectation {
        let start = position
        let byte = bytes[start]
        switch byte {
        case PreviewByte.openBrace, PreviewByte.openBracket:
            guard open.count < limits.jsonMaxDepth else {
                throw Stop.limit(.nestedTooDeeply(maxDepth: limits.jsonMaxDepth))
            }
            let isObject = byte == PreviewByte.openBrace
            let nodeIndex = try addNode(isObject ? .object : .array, from: start)
            open.append(
                OpenContainer(nodeIndex: nodeIndex, isObject: isObject, firstFinishedChild: finishedChildren.count))
            position += 1
            return isObject ? .firstMemberOrClose : .firstElementOrClose
        case PreviewByte.quote:
            let end = try endOfString(from: start)
            try addScalar(.string, from: start, to: end)
        case PreviewByte.minus, 0x30...0x39:
            let end = try endOfNumber(from: start)
            try addScalar(.number, from: start, to: end)
        default:
            if let end = endOfLiteral("true", from: start) {
                try addScalar(.true, from: start, to: end)
            } else if let end = endOfLiteral("false", from: start) {
                try addScalar(.false, from: start, to: end)
            } else if let end = endOfLiteral("null", from: start) {
                try addScalar(.null, from: start, to: end)
            } else {
                throw Stop.syntax(orClosingBracket ? .expectedValueOrClosingBracket : .expectedValue, at: start)
            }
        }
        return .commaOrClose
    }

    private mutating func parseMemberName(isFirst: Bool) throws {
        guard bytes[position] == PreviewByte.quote else {
            throw Stop.syntax(isFirst ? .expectedNameOrClosingBrace : .expectedName, at: position)
        }
        let end = try endOfString(from: position)
        pendingKey = position..<end
        position = end
        skipWhitespace()
        guard position < bytes.count else { throw Stop.syntax(.unexpectedEnd, at: position) }
        guard bytes[position] == PreviewByte.colon else { throw Stop.syntax(.expectedColon, at: position) }
        position += 1
    }

    /// Reads the comma or closing bracket after a value.
    private mutating func parseSeparator(_ byte: UInt8) throws -> Expectation {
        guard let container = open.last else { throw Stop.syntax(.textAfterValue, at: position) }
        let closer = container.isObject ? PreviewByte.closeBrace : PreviewByte.closeBracket
        if byte == PreviewByte.comma {
            position += 1
            return container.isObject ? .member : .value
        }
        if byte == closer {
            closeContainer()
            return .commaOrClose
        }
        throw Stop.syntax(
            container.isObject ? .expectedCommaOrClosingBrace : .expectedCommaOrClosingBracket, at: position)
    }

    // MARK: Nodes

    private mutating func addNode(_ kind: JSONNode.Kind, from start: Int) throws -> Int {
        guard tree.nodes.count < limits.jsonMaxNodes else {
            throw Stop.limit(.tooManyValues(shown: limits.jsonMaxNodes))
        }
        let location = lineAndColumn(at: start)
        let node = JSONNode(
            kind: kind, byteRange: start..<start, keyRange: pendingKey, indexInParent: open.last?.childCount ?? 0,
            parent: open.last?.nodeIndex, line: location.line, column: location.column)
        pendingKey = nil
        if !open.isEmpty { open[open.count - 1].childCount += 1 }
        tree.nodes.append(node)
        return tree.nodes.count - 1
    }

    private mutating func addScalar(_ kind: JSONNode.Kind, from start: Int, to end: Int) throws {
        let index = try addNode(kind, from: start)
        tree.nodes[index].byteRange = start..<end
        if !open.isEmpty { finishedChildren.append(index) }
        position = end
    }

    /// Closes the innermost container at the bracket at `position`.
    private mutating func closeContainer() {
        position += 1
        finishContainer(end: position)
    }

    /// Records the innermost container's children and makes it a finished child of its parent.
    private mutating func finishContainer(end: Int) {
        guard let container = open.popLast() else { return }
        let firstChild = tree.childOrder.count
        tree.childOrder.append(contentsOf: finishedChildren[container.firstFinishedChild...])
        finishedChildren.removeSubrange(container.firstFinishedChild...)
        tree.nodes[container.nodeIndex].childRange = firstChild..<tree.childOrder.count
        tree.nodes[container.nodeIndex].byteRange = tree.nodes[container.nodeIndex].byteRange.lowerBound..<end
        if !open.isEmpty { finishedChildren.append(container.nodeIndex) }
    }

    /// After an error or a limit: every container still open ends where parsing stopped.
    private mutating func closeOpenContainers(at offset: Int) {
        while !open.isEmpty { finishContainer(end: offset) }
    }

    // MARK: Tokens

    private mutating func skipWhitespace() {
        while position < bytes.count {
            let byte = bytes[position]
            if byte == PreviewByte.space || byte == PreviewByte.tab {
                position += 1
            } else if byte == PreviewByte.lineFeed || byte == PreviewByte.carriageReturn {
                let isCRLF =
                    byte == PreviewByte.carriageReturn && position + 1 < bytes.count
                    && bytes[position + 1] == PreviewByte.lineFeed
                position += isCRLF ? 2 : 1
                line += 1
                columnAnchor = (position, 1)
            } else {
                return
            }
        }
    }

    /// The line and column of `offset`, which must not be before the last offset asked about.
    private mutating func lineAndColumn(at offset: Int) -> (line: Int, column: Int) {
        var column = columnAnchor.column
        var index = columnAnchor.offset
        while index < offset {
            // Continuation bytes belong to the scalar before them.
            if bytes[index] & 0xC0 != 0x80 { column += 1 }
            index += 1
        }
        columnAnchor = (max(offset, columnAnchor.offset), column)
        return (line, column)
    }

    /// Validates the string literal that starts at `start` and returns the index after its
    /// closing quote.
    private func endOfString(from start: Int) throws -> Int {
        var index = start + 1
        while index < bytes.count {
            try poll.checkpoint()
            let byte = bytes[index]
            if byte == PreviewByte.quote { return index + 1 }
            if byte < 0x20 { throw Stop.syntax(.controlCharacterInString, at: index) }
            if byte == PreviewByte.backslash {
                index = try endOfEscape(from: index)
            } else if byte < 0x80 {
                index += 1
            } else if let length = JSONText.utf8SequenceLength(in: bytes, at: index) {
                index += length
            } else {
                throw Stop.syntax(.invalidUTF8, at: index)
            }
        }
        throw Stop.syntax(.unterminatedString, at: start)
    }

    private func endOfEscape(from backslash: Int) throws -> Int {
        guard backslash + 1 < bytes.count else { throw Stop.syntax(.unterminatedString, at: backslash) }
        switch bytes[backslash + 1] {
        case PreviewByte.quote, PreviewByte.backslash, PreviewByte.slash, UInt8(ascii: "b"), UInt8(ascii: "f"),
            UInt8(ascii: "n"), UInt8(ascii: "r"), UInt8(ascii: "t"):
            return backslash + 2
        case UInt8(ascii: "u"):
            guard JSONText.hexValue(bytes[...], at: backslash + 2) != nil else {
                throw Stop.syntax(.invalidEscape, at: backslash)
            }
            return backslash + 6
        default:
            throw Stop.syntax(.invalidEscape, at: backslash)
        }
    }

    /// Validates the number that starts at `start`: `-? (0 | 1-9 digits) (. digits)? (e ± digits)?`.
    private func endOfNumber(from start: Int) throws -> Int {
        var index = start
        func digits() -> Int {
            let first = index
            while index < bytes.count, PreviewByte.isDigit(bytes[index]) { index += 1 }
            return index - first
        }
        if bytes[index] == PreviewByte.minus { index += 1 }
        let integerStart = index
        guard digits() > 0 else { throw Stop.syntax(.invalidNumber, at: start) }
        if index - integerStart > 1, bytes[integerStart] == 0x30 { throw Stop.syntax(.leadingZero, at: start) }
        if index < bytes.count, bytes[index] == PreviewByte.dot {
            index += 1
            guard digits() > 0 else { throw Stop.syntax(.invalidNumber, at: start) }
        }
        if index < bytes.count, PreviewByte.lowercased(bytes[index]) == UInt8(ascii: "e") {
            index += 1
            if index < bytes.count, bytes[index] == PreviewByte.plus || bytes[index] == PreviewByte.minus { index += 1 }
            guard digits() > 0 else { throw Stop.syntax(.invalidNumber, at: start) }
        }
        return index
    }

    private func endOfLiteral(_ literal: String, from start: Int) -> Int? {
        let expected = Array(literal.utf8)
        guard start + expected.count <= bytes.count, bytes[start..<start + expected.count].elementsEqual(expected)
        else { return nil }
        return start + expected.count
    }
}
