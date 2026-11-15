// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Persisted format, version 1; see "Persisted formats" in docs/architecture.md. A new field
/// must be Optional or decoded with decodeIfPresent in an extension, or old files stop loading.
struct SearchOptions: Codable, Equatable, Sendable {
    enum Mode: Int, Codable, Sendable { case normal = 0, extended = 1, regularExpression = 2 }
    var query = "", replacement = ""
    var mode: Mode = .normal
    var matchCase = false, wholeWord = false, dotMatchesNewline = false, wrap = true
    func validatePreferences() throws {
        guard query.utf16.count <= 65_536, replacement.utf16.count <= 1_048_576 else {
            throw SearchFailure.preferencesTooLarge
        }
    }
}

struct FindPreferences: Codable {
    var version = 1
    var options = SearchOptions()
    // Six JSON bytes per allowed UTF-16 unit plus keys/flags fit within 8 MiB.
    static let maximumBytes = 8 * 1024 * 1024
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw SearchFailure.preferencesTooLarge }
        try PersistedFormat.check(data, context: "Find settings")
        let value = try JSONInputFailure.decode(Self.self, from: data, context: "Find settings")
        guard value.version == 1 else { throw SearchFailure.preferencesVersion }
        try value.options.validatePreferences()
        return value
    }
    func encoded() throws -> Data {
        guard version == 1 else { throw SearchFailure.preferencesVersion }
        try options.validatePreferences()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
struct SearchHit {
    let range: NSRange
    let replacement: String
}
struct SearchReport {
    let hits: [SearchHit]
    let truncated: Bool
}
enum SearchFailure: LocalizedError, CustomNSError, Equatable {
    case preferencesTooLarge, preferencesVersion
    case invalidBookmarkLimit, bookmarkCancelled, bookmarkOffsetsUnordered, bookmarkOffsetOutOfBounds
    case replacementCancelled, invalidReplacementRange, macroResultLimit, macroReplacement(String)
    case unknownRecordedAction, macroStopped(String)
    static var errorDomain: String { "TextTank.Search" }
    var errorCode: Int {
        switch self {
        case .preferencesTooLarge: return 10
        case .preferencesVersion: return 11
        case .invalidReplacementRange: return 3
        case .macroResultLimit: return 4
        case .macroReplacement: return 5
        case .unknownRecordedAction: return 6
        case .invalidBookmarkLimit, .bookmarkOffsetsUnordered, .bookmarkOffsetOutOfBounds, .macroStopped: return 7
        case .bookmarkCancelled: return 8
        case .replacementCancelled: return 9
        }
    }
    var errorDescription: String? {
        switch self {
        case .preferencesTooLarge:
            return
                "The search text or replacement is too large to keep as saved settings. The search can still run; earlier saved settings were not changed."
        case .preferencesVersion:
            return "These saved search settings need another version of TextTank. The original entry was not changed."
        case .invalidBookmarkLimit: return "Invalid bookmark work limit."
        case .bookmarkCancelled:
            return "Bookmark calculation cancelled or exceeded its time budget; bookmarks were preserved."
        case .bookmarkOffsetsUnordered: return "Bookmark offsets are not in ascending order; bookmarks were preserved."
        case .bookmarkOffsetOutOfBounds:
            return "A bookmark offset is past the end of the text; bookmarks were preserved."
        case .replacementCancelled: return "Replacement cancelled; no text was changed."
        case .invalidReplacementRange: return "Invalid or overlapping replacement range."
        case .macroResultLimit: return "Macro search reached the result limit; no edits were applied."
        case .macroReplacement(let reason): return "Macro replacement was not applied: \(reason)."
        case .unknownRecordedAction: return "Unrecognized recorded search action."
        case .macroStopped(let reason): return "Macro stopped: \(reason). Prior edits remain undoable."
        }
    }
    var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: errorDescription ?? ""] }
}

enum SearchCore {
    /// One forward UTF-16 pass over zero-based lines. A break is counted once its terminator has
    /// been passed in full, so an offset between CR and LF is still on the line that owns the
    /// CRLF, as in Scintilla.
    /// Called off-main before any bookmarks are mutated.
    static func bookmarkLines(
        in text: String, locations: [Int], cancellation: TTSearchCancellation, timeLimit: TimeInterval = 2
    ) throws -> [Int] {
        guard locations.count <= 100000, timeLimit > 0, timeLimit <= 30 else {
            throw SearchFailure.invalidBookmarkLimit
        }
        let deadline = Date().addingTimeInterval(timeLimit)
        var index = text.utf16.startIndex, position = 0, line = 0, lines: [Int] = []
        func check() throws {
            if cancellation.cancelled || Date() >= deadline {
                throw SearchFailure.bookmarkCancelled
            }
        }
        try check()
        for target in locations {
            guard target >= position else {
                throw SearchFailure.bookmarkOffsetsUnordered
            }
            while position < target {
                guard index < text.utf16.endIndex else {
                    throw SearchFailure.bookmarkOffsetOutOfBounds
                }
                let unit = text.utf16[index], next = text.utf16.index(after: index)
                if unit == 10 || (unit == 13 && (next == text.utf16.endIndex || text.utf16[next] != 10)) { line += 1 }
                position += 1
                index = next
                if position & 4095 == 0 { try check() }
            }
            if lines.last != line { lines.append(line) }
        }
        try check()
        return lines
    }

    /// The time one interactive search may take. Macro playback of a recorded search step uses
    /// the same value, so a step that could be recorded can also be replayed (F43).
    static let defaultTimeLimit: TimeInterval = 2
    /// `range` (UTF-16, default the whole text) limits where matches may lie; hits keep their
    /// offsets in `text` and the engine still sees the text around the range.
    static func search(
        _ text: String, options: SearchOptions, range: NSRange? = nil,
        cancellation: TTSearchCancellation = TTSearchCancellation(), limit: Int = 100000,
        timeLimit: TimeInterval = defaultTimeLimit
    ) throws -> SearchReport {
        let result = try TTSearchEngine.searchText(
            text, range: range ?? NSRange(location: 0, length: (text as NSString).length), query: options.query,
            replacement: options.replacement, mode: options.mode.rawValue, matchCase: options.matchCase,
            wholeWord: options.wholeWord, dotMatchesNewline: options.dotMatchesNewline, cancellation: cancellation,
            maximumMatches: limit, timeLimit: timeLimit)
        return SearchReport(
            hits: result.matches.map { SearchHit(range: $0.range, replacement: $0.replacement) },
            truncated: result.truncated)
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
        var cursor = UTFCursor(text), output: [NSRange] = []
        for range in ranges {
            guard range.location >= 0, range.length >= 0, range.length <= Int.max - range.location,
                cursor.advance(to: range.location)
            else { return nil }
            let start = cursor.byteOffset
            guard cursor.advance(to: NSMaxRange(range)) else { return nil }
            output.append(NSRange(location: start, length: cursor.byteOffset - start))
        }
        return output
    }
    /// The one forward walk from UTF-16 offsets to UTF-8 offsets, shared by in-document search and
    /// folder search. Targets must not go backwards, so any number of sorted matches costs a single
    /// pass over the text. Line and column (one-based, CRLF counted once) are kept only on request.
    struct UTFCursor {
        let text: String
        let tracksLines: Bool
        private var index: String.UnicodeScalarView.Index
        private(set) var utf16Offset = 0
        private(set) var byteOffset = 0
        private(set) var line = 1
        private(set) var columnUTF16 = 1
        init(_ text: String, tracksLines: Bool = false) {
            self.text = text
            self.tracksLines = tracksLines
            index = text.unicodeScalars.startIndex
        }
        /// False when the target is behind the cursor, past the end of the text or inside a
        /// surrogate pair, and when `stop` (asked every 4,096 scalars) answers true.
        mutating func advance(to target: Int, stop: () -> Bool = { false }) -> Bool {
            let scalars = text.unicodeScalars
            var count = 0
            guard target >= utf16Offset else { return false }
            while utf16Offset < target && index < scalars.endIndex {
                if count % 4096 == 0, stop() { return false }
                count += 1
                let value = scalars[index].value, width = value > 0xFFFF ? 2 : 1
                if utf16Offset + width > target { return false }
                let next = scalars.index(after: index)
                utf16Offset += width
                byteOffset += value < 0x80 ? 1 : (value < 0x800 ? 2 : (value < 0x10000 ? 3 : 4))
                if tracksLines {
                    if value == 10 || (value == 13 && (next == scalars.endIndex || scalars[next].value != 10)) {
                        line += 1
                        columnUTF16 = 1
                    } else {
                        columnUTF16 += width
                    }
                }
                index = next
            }
            return utf16Offset == target
        }
    }
    /// False only between the two halves of a surrogate pair.
    static func isScalarBoundary(_ i: Int, in source: NSString) -> Bool {
        i <= 0 || i >= source.length
            || !(source.character(at: i) >= 0xDC00 && source.character(at: i) <= 0xDFFF
                && source.character(at: i - 1) >= 0xD800 && source.character(at: i - 1) <= 0xDBFF)
    }
    /// Whether a match is where Next (or Previous) may go from `selection`. `continuing` is true
    /// when the selection is the match the last navigation chose, which is then not chosen again.
    static func isNavigationCandidate(_ range: NSRange, from selection: NSRange, backwards: Bool, continuing: Bool)
        -> Bool
    {
        backwards
            ? NSMaxRange(range) <= selection.location && !(continuing && range == selection)
            : range.location >= NSMaxRange(selection) && !(continuing && range == selection)
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
    /// Builds the result in one forward pass: the text between matches and each replacement are
    /// appended once, so the cost is linear however many matches change length. Hits must be in
    /// ascending order, must not overlap and must not split a surrogate pair (invalidReplacementRange).
    /// A cancelled token stops the pass with replacementCancelled and nothing is returned.
    static func replacing(_ text: String, with hits: [SearchHit], cancellation: TTSearchCancellation? = nil) throws
        -> String
    {
        let source = text as NSString, length = source.length
        let result = NSMutableString(capacity: length)
        var previousEnd = 0
        for (number, hit) in hits.enumerated() {
            if number & 1023 == 0, cancellation?.cancelled == true {
                throw SearchFailure.replacementCancelled
            }
            guard hit.range.location >= previousEnd, hit.range.length >= 0, hit.range.location <= length,
                hit.range.length <= length - hit.range.location, isScalarBoundary(hit.range.location, in: source),
                isScalarBoundary(NSMaxRange(hit.range), in: source)
            else {
                throw SearchFailure.invalidReplacementRange
            }
            if hit.range.location > previousEnd {
                result.append(
                    source.substring(with: NSRange(location: previousEnd, length: hit.range.location - previousEnd)))
            }
            result.append(hit.replacement)
            previousEnd = NSMaxRange(hit.range)
        }
        if previousEnd < length { result.append(source.substring(from: previousEnd)) }
        return result as String
    }
}
