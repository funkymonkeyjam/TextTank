// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Persisted format, version 1; see "Persisted formats" in docs/architecture.md. A new field
/// must be Optional or decoded with decodeIfPresent in an extension, or old files stop loading.
struct SearchOptions: Codable, Equatable, Sendable {
    enum Mode: Int, Codable, Sendable { case normal = 0, extended = 1, regularExpression = 2 }
    var query = "", replacement = ""
    var mode: Mode = .normal
    var matchCase = false, wholeWord = false, dotMatchesNewline = false, wrap = true
}
struct SearchHit {
    let range: NSRange
    let replacement: String
}
struct SearchReport {
    let hits: [SearchHit]
    let truncated: Bool
}
enum SearchCore {
    /// One forward UTF-16 pass; CRLF counts once, including offsets between CR and LF.
    /// Called off-main before any bookmarks are mutated.
    static func bookmarkLines(
        in text: String, locations: [Int], cancellation: TTSearchCancellation, timeLimit: TimeInterval = 2
    ) throws -> [Int] {
        guard locations.count <= 100000, timeLimit > 0, timeLimit <= 30 else {
            throw NSError(
                domain: "TextTank.Search", code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Invalid bookmark work limit."])
        }
        let deadline = Date().addingTimeInterval(timeLimit)
        var index = text.utf16.startIndex, position = 0, line = 0, priorCR = false, lines: [Int] = []
        func check() throws {
            if cancellation.cancelled || Date() >= deadline {
                throw NSError(
                    domain: "TextTank.Search", code: 8,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Bookmark calculation cancelled or exceeded its time budget; bookmarks were preserved."
                    ])
            }
        }
        try check()
        for target in locations {
            guard target >= position else { throw NSError(domain: "TextTank.Search", code: 7) }
            while position < target {
                guard index < text.utf16.endIndex else { throw NSError(domain: "TextTank.Search", code: 7) }
                let unit = text.utf16[index]
                if unit == 13 { line += 1 } else if unit == 10 && !priorCR { line += 1 }
                priorCR = unit == 13
                position += 1
                index = text.utf16.index(after: index)
                if position & 4095 == 0 { try check() }
            }
            if lines.last != line { lines.append(line) }
        }
        try check()
        return lines
    }

    static func search(
        _ text: String, options: SearchOptions, cancellation: TTSearchCancellation = TTSearchCancellation(),
        limit: Int = 100000, timeLimit: TimeInterval = 2
    ) throws -> SearchReport {
        let result = try TTSearchEngine.matches(
            inText: text, query: options.query, replacement: options.replacement, mode: options.mode.rawValue,
            matchCase: options.matchCase, wholeWord: options.wholeWord, dotMatchesNewline: options.dotMatchesNewline,
            cancellation: cancellation, maximumMatches: limit, timeLimit: timeLimit)
        let rows = result["matches"] as? [[String: Any]] ?? []
        return SearchReport(
            hits: rows.map {
                SearchHit(range: ($0["range"] as! NSValue).rangeValue, replacement: $0["replacement"] as! String)
            }, truncated: result["truncated"] as? Bool ?? false)
    }
    /// Scalar-granular like byteRanges: nil for surrogate splits, negative and out-of-range input.
    static func byteRange(_ range: NSRange, in text: String) -> NSRange? { byteRanges([range], in: text)?.first }
    /// The hits whose byte range is exactly the byte selection. All hits are converted in one
    /// linear pass, so a single Replace costs the same for one match as for a hundred thousand.
    static func hits(_ hits: [SearchHit], selectedBy selection: NSRange, in text: String) -> [SearchHit] {
        guard let ranges = byteRanges(hits.map(\.range), in: text) else { return [] }
        return zip(hits, ranges).filter { $0.1 == selection }.map(\.0)
    }
    /// Linear offset conversion for sorted nonoverlapping matches; avoids copying
    /// a document prefix separately for every replacement.
    static func byteRanges(_ ranges: [NSRange], in text: String) -> [NSRange]? {
        var index = text.unicodeScalars.startIndex, units = 0, bytes = 0, output: [NSRange] = []
        func advance(_ target: Int) -> Bool {
            guard target >= units else { return false }
            while units < target, index < text.unicodeScalars.endIndex {
                let value = text.unicodeScalars[index].value, width = value > 0xFFFF ? 2 : 1
                guard units + width <= target else { return false }
                units += width
                bytes += value < 0x80 ? 1 : value < 0x800 ? 2 : value < 0x10000 ? 3 : 4
                index = text.unicodeScalars.index(after: index)
            }
            return units == target
        }
        for range in ranges {
            guard range.location >= 0, range.length >= 0, range.length <= Int.max - range.location,
                advance(range.location)
            else { return nil }
            let start = bytes
            guard advance(NSMaxRange(range)) else { return nil }
            output.append(NSRange(location: start, length: bytes - start))
        }
        return output
    }
    static func utf16Range(_ range: NSRange, in text: String) -> NSRange? {
        let bytes = text.utf8
        guard range.location >= 0, range.length >= 0, range.location <= bytes.count,
            range.length <= bytes.count - range.location
        else { return nil }
        let start = bytes.index(bytes.startIndex, offsetBy: range.location),
            end = bytes.index(start, offsetBy: range.length)
        guard let a = start.samePosition(in: text), let b = end.samePosition(in: text) else { return nil }
        return NSRange(a..<b, in: text)
    }
    static func replacing(_ text: String, with hits: [SearchHit]) throws -> String {
        let result = NSMutableString(string: text), source = text as NSString
        func boundary(_ i: Int) -> Bool {
            i == 0 || i == source.length
                || !(source.character(at: i) >= 0xDC00 && source.character(at: i) <= 0xDFFF
                    && source.character(at: i - 1) >= 0xD800 && source.character(at: i - 1) <= 0xDBFF)
        }
        var previous = source.length
        for hit in hits.reversed() {
            guard hit.range.location >= 0, hit.range.length >= 0, hit.range.location <= previous,
                hit.range.length <= previous - hit.range.location, boundary(hit.range.location),
                boundary(NSMaxRange(hit.range))
            else {
                throw NSError(
                    domain: "TextTank.Search", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid or overlapping replacement range."])
            }
            result.replaceCharacters(in: hit.range, with: hit.replacement)
            previous = hit.range.location
        }
        return result as String
    }
}
