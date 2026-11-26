// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Something in delimited text that does not follow the quoting rules. The text is still shown.
package struct DelimitedDiagnostic: Sendable, Equatable {
    package enum Kind: Sendable, Equatable {
        /// A quoted value was opened and the document ended before its closing quote.
        case unterminatedQuote
        /// A quote appeared inside a value that is not quoted, or text followed a closing quote.
        /// The value is then every byte between its delimiters, quotes included.
        case strayQuote
    }

    package var kind: Kind
    /// The 1-based number of the row the problem is in.
    package var row: Int
    /// The 1-based source line the row starts on.
    package var line: Int

    package var message: String {
        switch kind {
        case .unterminatedQuote:
            return String(
                format: Strings.text(
                    "preview.table.unterminatedQuote",
                    "Row %@ opens a quoted value that is never closed. The rest of the document is shown as one value."
                ), Strings.number(row))
        case .strayQuote:
            return String(
                format: Strings.text(
                    "preview.table.strayQuote",
                    "Row %@ has a quotation mark in an unexpected place. It is shown as written."),
                Strings.number(row))
        }
    }
}

/// Comma- or tab-separated text as rows of cells.
///
/// Every cell is the text exactly as written: no trimming, no number or date detection, no
/// formula evaluation. Only the quoting is interpreted (RFC 4180: a value may be wrapped in
/// double quotes, inside which a doubled quote stands for one quote and delimiters and line
/// breaks are ordinary text).
///
/// Cells are stored as one byte buffer and an end offset per cell, which keeps a table of
/// millions of short cells compact; `cell(row:column:)` makes a `String` on request.
package struct DelimitedTable: Sendable, Equatable {
    /// The most diagnostics that are kept. `diagnosticCount` still counts all of them.
    package static let maxListedDiagnostics = 100

    /// The bytes of every cell, one after another: unquoted for a well-formed quoted value.
    private var cellBytes: [UInt8] = []
    /// For each cell, the offset in `cellBytes` just after it. A document is at most
    /// `PreviewLimits.maxSourceBytes` long, far below what 32 bits can hold.
    private var cellEnds: [UInt32] = []
    /// For each row, the index of its first cell, followed by the total number of cells.
    private var rowStarts: [Int] = [0]
    /// For each row, the 1-based source line it starts on.
    package private(set) var rowLines: [Int] = []
    /// The original bytes of each record, including field quoting and embedded line endings,
    /// excluding the record terminator. Set by the parser, even for a truncated final table.
    package fileprivate(set) var rowSourceRanges: [Range<Int>] = []
    /// The widest row, in cells. Narrower rows read as empty text in their missing columns.
    package private(set) var columnCount = 0
    package private(set) var diagnostics: [DelimitedDiagnostic] = []
    package private(set) var diagnosticCount = 0
    /// The limits that cut the table short, in the order they were reached.
    package private(set) var limitsReached: [PreviewLimit] = []

    package var rowCount: Int { rowLines.count }
    /// True when rows or columns were left out because a limit was reached.
    package var isTruncated: Bool { !limitsReached.isEmpty }

    /// How many cells the row has in the source, before padding.
    package func cellCount(inRow row: Int) -> Int { rowStarts[row + 1] - rowStarts[row] }

    /// The text of a cell, or empty text when the row is shorter than `column`.
    package func cell(row: Int, column: Int) -> String {
        guard column < cellCount(inRow: row) else { return "" }
        let index = rowStarts[row] + column
        let start = index == 0 ? 0 : Int(cellEnds[index - 1])
        return String(decoding: cellBytes[start..<Int(cellEnds[index])], as: UTF8.self)
    }

    /// One row padded with empty text to `columnCount` cells.
    package func row(_ row: Int) -> [String] {
        (0..<columnCount).map { cell(row: row, column: $0) }
    }

    /// Every row, padded. This copies the whole table; a table view should ask for cells.
    package var rows: [[String]] { (0..<rowCount).map(row) }

    fileprivate mutating func beginRow(line: Int) { rowLines.append(line) }

    fileprivate mutating func appendCell(_ bytes: [UInt8]) {
        cellBytes.append(contentsOf: bytes)
        cellEnds.append(UInt32(cellBytes.count))
    }

    fileprivate mutating func endRow() {
        rowStarts.append(cellEnds.count)
        columnCount = max(columnCount, cellCount(inRow: rowLines.count - 1))
    }

    fileprivate mutating func note(_ kind: DelimitedDiagnostic.Kind) {
        diagnosticCount += 1
        guard diagnostics.count < Self.maxListedDiagnostics else { return }
        diagnostics.append(DelimitedDiagnostic(kind: kind, row: rowLines.count, line: rowLines.last ?? 1))
    }

    fileprivate mutating func noteLimit(_ limit: PreviewLimit) {
        if !limitsReached.contains(limit) { limitsReached.append(limit) }
    }
}

package enum DelimitedParsing: Sendable, Equatable {
    case parsed(DelimitedTable)
    /// The document is too large to read at all.
    case limited(PreviewLimit)
    case cancelled
}

extension DelimitedTable {
    /// Parses UTF-8 text. `delimiter` is a comma or a tab; any other ASCII character also works.
    /// A delimiter that is not ASCII is a programming error and stops the program: it could only
    /// be read as some other character, which would show a table the document does not contain.
    ///
    /// A byte order mark is skipped. Rows end at LF, CRLF or CR; a line break at the very end of
    /// the document does not start another row. Bytes that are not valid UTF-8 are shown as the
    /// replacement character. The parser reads malformed quoting the way it is most likely
    /// meant and records a diagnostic.
    package static func parse(
        _ source: Data, delimiter: Character, limits: PreviewLimits = .standard,
        isCancelled: @escaping () -> Bool = { Task.isCancelled }
    ) -> DelimitedParsing {
        guard source.count <= limits.maxSourceBytes, source.count <= Int(UInt32.max) else {
            return .limited(.sourceTooLarge(maxBytes: limits.maxSourceBytes))
        }
        guard let delimiterByte = delimiter.asciiValue else {
            preconditionFailure("DelimitedTable.parse needs an ASCII delimiter")
        }
        var reader = DelimitedReader(
            bytes: Array(source), delimiter: delimiterByte, limits: limits, poll: CancellationPoll(isCancelled))
        do {
            try reader.readAll()
            return .parsed(reader.table)
        } catch {
            return .cancelled
        }
    }

    package static func parse(
        _ source: String, delimiter: Character, limits: PreviewLimits = .standard,
        isCancelled: @escaping () -> Bool = { Task.isCancelled }
    ) -> DelimitedParsing {
        parse(Data(source.utf8), delimiter: delimiter, limits: limits, isCancelled: isCancelled)
    }
}

private struct DelimitedReader {
    private enum FieldEnd { case delimiter, lineBreak, endOfInput }

    private let bytes: [UInt8]
    private let delimiter: UInt8
    private let limits: PreviewLimits
    private let poll: CancellationPoll
    private var position = 0
    /// The 1-based line that `position` is on.
    private var line = 1
    private(set) var table = DelimitedTable()

    init(bytes: [UInt8], delimiter: UInt8, limits: PreviewLimits, poll: CancellationPoll) {
        self.bytes = bytes
        self.delimiter = delimiter
        self.limits = limits
        self.poll = poll
        let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]
        if bytes.starts(with: byteOrderMark) { position = byteOrderMark.count }
    }

    mutating func readAll() throws {
        while position < bytes.count {
            guard table.rowCount < limits.delimitedMaxRows else {
                table.noteLimit(.tooManyRows(shown: limits.delimitedMaxRows))
                return
            }
            try readRow()
        }
    }

    private mutating func readRow() throws {
        let rowStart = position
        table.beginRow(line: line)
        var column = 0
        var end = FieldEnd.delimiter
        while end == .delimiter {
            var field: [UInt8] = []
            end = try readField(into: &field)
            if column < limits.delimitedMaxColumns {
                table.appendCell(field)
            } else {
                table.noteLimit(.tooManyColumns(shown: limits.delimitedMaxColumns))
            }
            column += 1
        }
        var rowEnd = position
        if end == .lineBreak {
            rowEnd -= 1
            if bytes[rowEnd] == 10, rowEnd > rowStart, bytes[rowEnd - 1] == 13 { rowEnd -= 1 }
        }
        table.rowSourceRanges.append(rowStart..<rowEnd)
        table.endRow()
    }

    /// Reads one value and the delimiter or line break after it.
    private mutating func readField(into field: inout [UInt8]) throws -> FieldEnd {
        // Counted here as well, so that a row of empty values is polled too.
        try poll.checkpoint()
        let fieldStart = position
        var hasStrayQuote = false
        var hasTextAfterClosingQuote = false
        if position < bytes.count, bytes[position] == PreviewByte.quote {
            position += 1
            guard try readQuotedText(into: &field) else {
                table.note(.unterminatedQuote)
                return .endOfInput
            }
            hasTextAfterClosingQuote = position < bytes.count && !isFieldEnd(bytes[position])
            hasStrayQuote = hasTextAfterClosingQuote
        }
        while position < bytes.count, !isFieldEnd(bytes[position]) {
            try poll.checkpoint()
            if bytes[position] == PreviewByte.quote { hasStrayQuote = true }
            field.append(bytes[position])
            position += 1
        }
        // The quotes of such a value were not quoting, so nothing is removed: the value is its
        // bytes as written. This keeps "shown as written" true for malformed rows as well.
        if hasTextAfterClosingQuote { field = Array(bytes[fieldStart..<position]) }
        if hasStrayQuote { table.note(.strayQuote) }
        guard position < bytes.count else { return .endOfInput }
        if bytes[position] == delimiter {
            position += 1
            return .delimiter
        }
        consumeLineBreak()
        return .lineBreak
    }

    /// Reads up to and past the closing quote. Returns false when the input ends first.
    private mutating func readQuotedText(into field: inout [UInt8]) throws -> Bool {
        while position < bytes.count {
            try poll.checkpoint()
            let byte = bytes[position]
            if byte == PreviewByte.quote {
                position += 1
                guard position < bytes.count, bytes[position] == PreviewByte.quote else { return true }
                field.append(PreviewByte.quote)
                position += 1
            } else if byte == PreviewByte.lineFeed || byte == PreviewByte.carriageReturn {
                let start = position
                consumeLineBreak()
                field.append(contentsOf: bytes[start..<position])
            } else {
                field.append(byte)
                position += 1
            }
        }
        return false
    }

    private func isFieldEnd(_ byte: UInt8) -> Bool {
        byte == delimiter || byte == PreviewByte.lineFeed || byte == PreviewByte.carriageReturn
    }

    /// Moves past the LF, CRLF or CR at `position` and counts the line.
    private mutating func consumeLineBreak() {
        let isCRLF =
            bytes[position] == PreviewByte.carriageReturn && position + 1 < bytes.count
            && bytes[position + 1] == PreviewByte.lineFeed
        position += isCRLF ? 2 : 1
        line += 1
    }
}
