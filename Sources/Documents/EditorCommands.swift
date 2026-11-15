// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

enum EditorTransform: String, CaseIterable {
    case sortAscending, sortDescending, sortCaseInsensitive, sortLength, reverseLines, uniqueLines, removeEmptyLines,
        trimLeading, trimBoth, invertCase, titleCase
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
        var rows: [(String, String)] = []
        var content = ""
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "\r\n" || c == "\r" || c == "\n" {
                rows.append((content, String(c)))
                content = ""
            } else {
                content.append(c)
            }
            i = text.index(after: i)
        }
        if !content.isEmpty || rows.isEmpty { rows.append((content, "")) }
        switch self {
        case .trimLeading, .trimBoth:
            rows = rows.map { row in
                var s = row.0
                while s.first == " " || s.first == "\t" { s.removeFirst() }
                if self == .trimBoth { while s.last == " " || s.last == "\t" { s.removeLast() } }
                return (s, row.1)
            }
        case .removeEmptyLines: rows = rows.filter { !$0.0.isEmpty }
        case .uniqueLines:
            // A duplicate final row without a line ending must not leave the previous row's behind.
            let unterminated = rows.last?.1.isEmpty == true
            var seen = Set<Data>()
            rows = rows.filter { seen.insert(Data($0.0.utf8)).inserted }
            if unterminated, !rows.isEmpty { rows[rows.count - 1].1 = "" }
        default:
            let values = rows.enumerated().map { ($0.offset, $0.element.0) }
            let sorted: [(Int, String)]
            switch self {
            case .reverseLines: sorted = Array(values.reversed())
            case .sortDescending: sorted = values.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
            case .sortCaseInsensitive:
                sorted = values.sorted {
                    let a = $0.1.lowercased(), b = $1.1.lowercased()
                    return a == b ? $0.0 < $1.0 : a < b
                }
            case .sortLength:
                sorted = values.sorted { $0.1.count == $1.1.count ? $0.0 < $1.0 : $0.1.count < $1.1.count }
            default: sorted = values.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }
            }
            rows = zip(sorted, rows).map { ($0.0.1, $0.1.1) }
        }
        return rows.map { $0.0 + $0.1 }.joined()
    }
    func apply(to editor: TTEditor) throws {
        guard !editor.readOnly, editor.selectionCount == 1 else {
            throw NSError(
                domain: "TextTank", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Choose one selection in a writable document."])
        }
        let selection = editor.selectionStart != editor.selectionEnd
        let source = selection ? editor.selectedText : editor.text
        guard source.utf8.count <= 16 * 1024 * 1024 else {
            throw NSError(
                domain: "TextTank", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Select at most 16 MiB for this command."])
        }
        let output = transform(source)
        guard output != source else { return }
        editor.beginUndoGroup()
        defer { editor.endUndoGroup() }
        // The whole-document case replaces only the span that differs, keeping bookmarks and the caret line.
        guard selection ? editor.replaceSelection(output) : editor.replaceDocumentText(output) else {
            throw NSError(
                domain: "TextTank", code: 6,
                userInfo: [NSLocalizedDescriptionKey: "The document could not be changed."])
        }
    }
}
