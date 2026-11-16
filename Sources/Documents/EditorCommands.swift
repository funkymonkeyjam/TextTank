// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum EditorTransform: String, CaseIterable {
    case sortAscending, sortDescending, sortCaseInsensitive, sortLength, reverseLines, uniqueLines, removeEmptyLines,
        trimLeading, trimBoth, invertCase, titleCase
    /// Locale-aware order, beside the code-point order of `sortAscending`; see `LineOrder`.
    case sortLocalized
    var title: String {
        switch self {
        case .sortAscending: return "Sort Lines Ascending"
        case .sortDescending: return "Sort Lines Descending"
        case .sortCaseInsensitive: return "Sort Lines Ignoring Case"
        case .sortLength: return "Sort Lines by Length"
        case .reverseLines: return "Reverse Line Order"
        case .uniqueLines: return "Remove Duplicate Lines"
        case .removeEmptyLines: return "Remove Empty Lines"
        case .trimLeading: return "Trim Leading Whitespace"
        case .trimBoth: return "Trim Leading and Trailing Whitespace"
        case .invertCase: return "Invert Case"
        case .titleCase: return "Title Case"
        case .sortLocalized: return "Sort Lines in Locale Order"
        }
    }
    func transform(_ text: String) -> String {
        if self == .titleCase { return text.capitalized(with: Locale(identifier: "en_US_POSIX")) }
        if self == .invertCase {
            // One scalar in, one scalar out, so the text never changes length: a mapping that would
            // expand (sharp s to "SS", a ligature to two letters) leaves the scalar as it is, and
            // so does a titlecase digraph. Upper if that changes the scalar, else lower.
            var inverted = String.UnicodeScalarView()
            for scalar in text.unicodeScalars {
                // ASCII, the bulk of most text, needs no property lookup and no temporary string.
                if scalar.value < 0x80 {
                    let v = scalar.value
                    let letter = (v | 0x20) >= 0x61 && (v | 0x20) <= 0x7A
                    inverted.append(letter ? Unicode.Scalar(UInt8(v ^ 0x20)) : scalar)
                    continue
                }
                let properties = scalar.properties, original = String(scalar)
                let mapped =
                    properties.generalCategory == .titlecaseLetter
                    ? original
                    : (properties.uppercaseMapping == original
                        ? properties.lowercaseMapping : properties.uppercaseMapping)
                inverted.append(mapped.unicodeScalars.count == 1 ? mapped.unicodeScalars.first! : scalar)
            }
            return String(inverted)
        }
        // Keep original separators by position for reordering, and move separators
        // with retained rows for deletion. A terminal newline is not an empty row.
        // Rows are slices of the text found by scanning its UTF-8 bytes for CR, LF and CR LF,
        // so nothing is copied or allocated per character.
        struct Row { var content: Substring, separator: Substring }
        var rows: [Row] = []
        let utf8 = text.utf8
        var rowStart = utf8.startIndex, i = utf8.startIndex
        while i < utf8.endIndex {
            let byte = utf8[i]
            guard byte == 13 || byte == 10 else {
                i = utf8.index(after: i)
                continue
            }
            var next = utf8.index(after: i)
            if byte == 13, next < utf8.endIndex, utf8[next] == 10 { next = utf8.index(after: next) }
            rows.append(Row(content: text[rowStart..<i], separator: text[i..<next]))
            rowStart = next
            i = next
        }
        if rowStart < utf8.endIndex || rows.isEmpty { rows.append(Row(content: text[rowStart...], separator: "")) }
        switch self {
        case .trimLeading, .trimBoth:
            rows = rows.map { row in
                var content = row.content.drop { $0 == " " || $0 == "\t" }
                if self == .trimBoth {
                    while let last = content.last, last == " " || last == "\t" { content = content.dropLast() }
                }
                return Row(content: content, separator: row.separator)
            }
        case .removeEmptyLines: rows = rows.filter { !$0.content.isEmpty }
        case .uniqueLines:
            // A duplicate final row without a line ending must not leave the previous row's behind.
            let unterminated = rows.last?.separator.isEmpty == true
            var seen = Set<Data>()
            rows = rows.filter { seen.insert(Data($0.content.utf8)).inserted }
            if unterminated, !rows.isEmpty { rows[rows.count - 1].separator = "" }
        default:
            // Each sort key is computed once per row; ties keep their original order.
            var order = Array(rows.indices)
            switch self {
            case .reverseLines: order.reverse()
            case .sortDescending:
                order.sort { rows[$0].content == rows[$1].content ? $0 < $1 : rows[$0].content > rows[$1].content }
            case .sortCaseInsensitive:
                let keys = rows.map { $0.content.lowercased() }
                order.sort { keys[$0] == keys[$1] ? $0 < $1 : keys[$0] < keys[$1] }
            case .sortLength:
                // User-facing character counts and native Scintilla lengths count Unicode scalars.
                let keys = rows.map { $0.content.unicodeScalars.count }
                order.sort { keys[$0] == keys[$1] ? $0 < $1 : keys[$0] < keys[$1] }
            case .sortLocalized:
                let keys = rows.map { String($0.content) }
                order.sort {
                    keys[$0].utf8.elementsEqual(keys[$1].utf8)
                        ? $0 < $1 : LineOrder.localizedAscending(keys[$0], keys[$1])
                }
            default:
                let keys = rows.map { String($0.content) }
                order.sort { keys[$0] == keys[$1] ? $0 < $1 : LineOrder.codePointAscending(keys[$0], keys[$1]) }
            }
            rows = zip(order, rows).map { index, row in Row(content: rows[index].content, separator: row.separator) }
        }
        var output = ""
        output.reserveCapacity(utf8.count)
        for row in rows {
            output += row.content
            output += row.separator
        }
        return output
    }
}
