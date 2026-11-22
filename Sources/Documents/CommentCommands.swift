// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

package struct EditorSelection: Equatable, Sendable {
    package init(anchor: Int, caret: Int) {
        self.anchor = anchor
        self.caret = caret
    }

    package let anchor: Int
    package let caret: Int
}

package enum CommentCommand: String, CaseIterable {
    case toggleLine, lineComment, lineUncomment, blockComment, blockUncomment
    package var defaultMenuShortcut: MenuShortcut? { self == .toggleLine ? MenuShortcut("/") : nil }
    package var title: String {
        switch self {
        case .toggleLine: return "Toggle Line Comment"
        case .lineComment: return "Comment Selected Lines"
        case .lineUncomment: return "Uncomment Selected Lines"
        case .blockComment: return "Block Comment"
        case .blockUncomment: return "Remove Block Comment"
        }
    }
    package struct Edit: Hashable {
        package init(start: Int, end: Int, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
        package var start: Int, end: Int, text: String
    }
    /// `edits` are ascending, non-overlapping byte ranges of the input; applying them yields `text`.
    package struct Plan {
        package init(text: String, selections: [EditorSelection], edits: [Edit]) {
            self.text = text
            self.selections = selections
            self.edits = edits
        }
        package let text: String, selections: [EditorSelection], edits: [Edit]
    }
    package func plan(text: String, selections: [EditorSelection], profile: LanguageProfile) throws -> Plan {
        guard text.utf8.count <= SizePolicy.standard.commentDocument else {
            throw LanguageError.invalid("Comment commands accept documents up to \(SizePolicy.describe(SizePolicy.standard.commentDocument)). Use a smaller document.")
        }
        guard let markers = profile.comments else {
            throw LanguageError.invalid("This language has no configured comment delimiters.")
        }
        let bytes = Array(text.utf8)
        func boundary(_ offset: Int) -> Bool {
            offset >= 0 && offset <= bytes.count && (offset == bytes.count || bytes[offset] & 0xc0 != 0x80)
        }
        // Delimiters are matched as bytes, as Scintilla and the lexers see them. A valid UTF-8 needle
        // cannot match from inside another scalar, so no boundary check is needed.
        func find(_ needle: [UInt8], in range: Range<Int>, backwards: Bool = false) -> Int? {
            guard !needle.isEmpty, range.count >= needle.count else { return nil }
            let last = range.upperBound - needle.count
            var at = backwards ? last : range.lowerBound
            while at >= range.lowerBound && at <= last {
                if bytes[at] == needle[0] && bytes[at..<at + needle.count].elementsEqual(needle) { return at }
                at += backwards ? -1 : 1
            }
            return nil
        }
        var ranges: [(lower: Int, upper: Int)] = []
        for selection in selections {
            let anchor = selection.anchor, caret = selection.caret
            guard boundary(anchor), boundary(caret)
            else { throw LanguageError.invalid("Invalid Unicode selection boundary.") }
            ranges.append((lower: min(anchor, caret), upper: max(anchor, caret)))
        }
        guard !ranges.isEmpty else { throw LanguageError.invalid("No editor selection.") }
        var edits: [Edit] = []
        if self == .blockComment || self == .blockUncomment {
            let ordered = ranges.sorted { $0.lower < $1.lower }
            for index in 1..<max(1, ordered.count) {
                guard ordered[index].lower >= ordered[index - 1].upper else {
                    throw LanguageError.invalid("Overlapping block selections were not changed.")
                }
            }
            guard let open = markers.blockOpen, !open.isEmpty, let close = markers.blockClose, !close.isEmpty else {
                throw LanguageError.invalid("This language has no block-comment delimiters.")
            }
            let left = Array(open.utf8), right = Array(close.utf8)
            for (start, end) in ranges {
                if self == .blockComment {
                    guard start < end else { throw LanguageError.invalid("Select text to wrap in a block comment.") }
                    guard find(right, in: start..<end) == nil else {
                        throw LanguageError.invalid(
                            "Selection already contains a closing comment delimiter; nothing was changed.")
                    }
                    edits.append(Edit(start: start, end: start, text: open + " "))
                    edits.append(Edit(start: end, end: end, text: " " + close))
                } else {
                    var a = start, b = end
                    if !(end - start >= left.count + right.count
                        && Array(bytes[start..<min(start + left.count, end)]) == left
                        && Array(bytes[max(start, end - right.count)..<end]) == right)
                    {
                        // Include an immediately enclosing block; never infer an unrelated earlier block.
                        guard let opening = find(left, in: 0..<start, backwards: true),
                            let closing = find(right, in: end..<bytes.count)
                        else { throw LanguageError.invalid("No enclosing block comment found.") }
                        a = opening
                        b = closing + right.count
                        let interior = (a + left.count)..<(b - right.count)
                        guard find(right, in: interior) == nil, find(left, in: interior) == nil else {
                            throw LanguageError.invalid(
                                "Ambiguous nested comment boundaries; select the complete comment explicitly.")
                        }
                    }
                    var openingEnd = a + left.count, closingStart = b - right.count
                    if openingEnd < closingStart, bytes[openingEnd] == 32 { openingEnd += 1 }
                    if closingStart > openingEnd, bytes[closingStart - 1] == 32 { closingStart -= 1 }
                    edits.append(Edit(start: a, end: openingEnd, text: ""))
                    edits.append(Edit(start: closingStart, end: b, text: ""))
                }
            }
        } else {
            var lines: [(start: Int, end: Int, next: Int)] = [], start = 0, index = 0
            while index < bytes.count {
                if bytes[index] == 10 || bytes[index] == 13 {
                    let end = index
                    index += bytes[index] == 13 && index + 1 < bytes.count && bytes[index + 1] == 10 ? 2 : 1
                    lines.append((start, end, index))
                    start = index
                } else {
                    index += 1
                }
            }
            lines.append((start, bytes.count, bytes.count))
            // Unicode case folding is kept for the line marker; the folded forms are compared as bytes.
            let foldedMarker = Array((markers.line ?? "").lowercased().utf8)
            for line in lines {
                // Only the unterminated final line has end==next; a caret at its end is still on it.
                guard
                    ranges.contains(where: { range in
                        range.lower == range.upper
                            ? range.lower >= line.start && (range.lower < line.next || line.end == line.next)
                            : range.lower < line.next && range.upper > line.start
                    })
                else { continue }
                var indent = line.start
                while indent < line.end && (bytes[indent] == 32 || bytes[indent] == 9) { indent += 1 }
                if indent == line.end && profile.id != "baanc" { continue }
                if profile.id == "fortran77" || profile.id == "baanc" { indent = line.start }
                if let marker = markers.line, !marker.isEmpty {
                    let length = marker.utf8.count
                    let hasMarker =
                        indent + length <= line.end && boundary(indent + length)
                        && Array(String(decoding: bytes[indent..<indent + length], as: UTF8.self).lowercased().utf8)
                            == foldedMarker
                    if hasMarker && self != .lineComment {
                        let end =
                            indent + length
                            + (indent + length < line.end && bytes[indent + length] == 32 && profile.id != "baanc"
                                ? 1 : 0)
                        edits.append(Edit(start: indent, end: end, text: ""))
                    } else if self != .lineUncomment {
                        edits.append(
                            Edit(start: indent, end: indent, text: marker + (profile.id == "baanc" ? "" : " ")))
                    }
                } else if let open = markers.blockOpen, !open.isEmpty, let close = markers.blockClose, !close.isEmpty {
                    let left = Array(open.utf8), right = Array(close.utf8)
                    if line.end - indent >= left.count + right.count,
                        bytes[indent..<indent + left.count].elementsEqual(left),
                        bytes[(line.end - right.count)..<line.end].elementsEqual(right), self != .lineComment
                    {
                        var a = indent + left.count, b = line.end - right.count
                        if a < b, bytes[a] == 32 { a += 1 }
                        if b > a, bytes[b - 1] == 32 { b -= 1 }
                        edits.append(Edit(start: indent, end: a, text: ""))
                        edits.append(Edit(start: b, end: line.end, text: ""))
                    } else if self != .lineUncomment {
                        guard find(right, in: indent..<line.end) == nil else {
                            throw LanguageError.invalid(
                                "A selected line contains a closing delimiter; nothing was changed.")
                        }
                        edits.append(Edit(start: indent, end: indent, text: open + " "))
                        edits.append(Edit(start: line.end, end: line.end, text: " " + close))
                    }
                } else {
                    throw LanguageError.invalid("This language has no usable comment delimiters.")
                }
            }
        }
        edits = Array(Set(edits)).sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        var priorEnd = 0, priorStart: Int?
        for edit in edits {
            guard edit.start >= priorEnd, priorStart != edit.start else {
                throw LanguageError.invalid("Overlapping comment edits were not applied.")
            }
            priorEnd = edit.end
            priorStart = edit.start
        }
        var result = Data(bytes)
        for edit in edits.reversed() { result.replaceSubrange(edit.start..<edit.end, with: edit.text.utf8) }
        func mapped(_ position: Int) -> Int {
            var delta = 0
            for edit in edits {
                if position < edit.start { break }
                if position <= edit.end {
                    if self == .blockComment, edit.start == edit.end, edit.text == " " + (markers.blockClose ?? "") {
                        return edit.start + delta
                    }
                    return edit.start + delta + edit.text.utf8.count
                }
                delta += edit.text.utf8.count - (edit.end - edit.start)
            }
            return position + delta
        }
        let restored = selections.map {
            EditorSelection(anchor: mapped($0.anchor), caret: mapped($0.caret))
        }
        return Plan(text: String(decoding: result, as: UTF8.self), selections: restored, edits: edits)
    }
}
