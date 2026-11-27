// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import NativeSearch

/// Persisted format, version 1; see "Persisted formats" in docs/architecture.md. A new field
/// must be Optional or decoded with decodeIfPresent in an extension, or old files stop loading.
package struct SearchOptions: Codable, Equatable, Sendable {
    package init(
        query: String = "", replacement: String = "", mode: Mode = .normal, matchCase: Bool = false,
        wholeWord: Bool = false, dotMatchesNewline: Bool = false, wrap: Bool = true
    ) {
        self.query = query
        self.replacement = replacement
        self.mode = mode
        self.matchCase = matchCase
        self.wholeWord = wholeWord
        self.dotMatchesNewline = dotMatchesNewline
        self.wrap = wrap
    }

    package enum Mode: Int, Codable, Sendable, CaseIterable {
        case normal = 0, extended = 1, regularExpression = 2
        package var nativeMode: TTSearchMode {
            switch self {
            case .normal: return .literal
            case .extended: return .extended
            case .regularExpression: return .regularExpression
            }
        }
        package var displayName: String {
            switch self {
            case .normal: return Strings.text("search.mode.normal", "Normal")
            case .extended: return Strings.text("search.mode.extended", "Extended (\\n, \\t, \\xNN)")
            case .regularExpression: return Strings.text("search.mode.regex", "Regular expression")
            }
        }
    }
    package var query: String, replacement: String
    package var mode: Mode
    package var matchCase: Bool, wholeWord: Bool, dotMatchesNewline: Bool, wrap: Bool
    package func validatePreferences() throws {
        guard query.utf16.count <= 65_536, replacement.utf16.count <= 1_048_576 else {
            throw SearchFailure.preferencesTooLarge
        }
    }
}

/// The last ten distinct things searched for and the last ten distinct replacements, newest
/// first. Entries are compared by their UTF-8 bytes, as the engine compares search text: two
/// spellings of one accented letter are two entries. An entry longer than `maximumEntryUnits`
/// is not remembered, so the private file stays small whatever was searched for.
package struct FindHistory: Equatable, Sendable {
    static package let capacity = 10
    static package let maximumEntryUnits = 1_000
    package private(set) var queries: [String]
    package private(set) var replacements: [String]
    package init(queries: [String] = [], replacements: [String] = []) {
        self.queries = Self.normalised(queries)
        self.replacements = Self.normalised(replacements)
    }
    /// Keeps the first of each distinct entry, drops empty and oversized ones, and stops at ten.
    static package func normalised(_ entries: [String]) -> [String] {
        var kept: [String] = []
        for entry in entries where kept.count < capacity {
            guard !entry.isEmpty, entry.utf16.count <= maximumEntryUnits,
                !kept.contains(where: { $0.utf8.elementsEqual(entry.utf8) })
            else { continue }
            kept.append(entry)
        }
        return kept
    }
    /// True when the history changed. An entry used again moves to the front.
    @discardableResult package mutating func remember(query: String) -> Bool {
        let updated = Self.normalised([query] + queries)
        defer { queries = updated }
        return !Self.same(updated, queries)
    }
    @discardableResult package mutating func remember(replacement: String) -> Bool {
        let updated = Self.normalised([replacement] + replacements)
        defer { replacements = updated }
        return !Self.same(updated, replacements)
    }
    package mutating func clearQueries() { queries = [] }
    package mutating func clearReplacements() { replacements = [] }
    private static func same(_ a: [String], _ b: [String]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }
}

package struct FindPreferences: Codable {
    package init(
        version: Int = 1, options: SearchOptions = SearchOptions(), queryHistory: [String]? = nil,
        replacementHistory: [String]? = nil
    ) {
        self.version = version
        self.options = options
        self.queryHistory = queryHistory
        self.replacementHistory = replacementHistory
    }
    /// What an action saves: the option flags and the history. The text being searched for and
    /// the search mode are not carried to the next launch (see `startingOptions`).
    package init(saving options: SearchOptions, history: FindHistory) {
        var kept = options
        kept.query = ""
        kept.replacement = ""
        kept.mode = .normal
        self.init(options: kept, queryHistory: history.queries, replacementHistory: history.replacements)
    }

    package var version: Int
    package var options: SearchOptions
    /// Optional, so a file written before the history existed still loads; newest first.
    package var queryHistory: [String]?
    package var replacementHistory: [String]?
    /// A new launch starts in Normal mode with nothing in either field, whatever the file holds:
    /// a regular expression left over from an earlier day is never silently in force. The flags
    /// (match case, whole word, dot matches newline, wrap) are kept.
    package var startingOptions: SearchOptions {
        var start = options
        start.query = ""
        start.replacement = ""
        start.mode = .normal
        return start
    }
    /// The saved history. A file from before the history existed offers the text it restored
    /// then as the first entry, so nothing the person had is lost; it is offered, not applied.
    package var history: FindHistory {
        FindHistory(
            queries: queryHistory ?? [options.query], replacements: replacementHistory ?? [options.replacement])
    }
    // Six JSON bytes per allowed UTF-16 unit plus keys/flags fit within 8 MiB.
    static package let maximumBytes = SizePolicy.standard.searchSettings
    static package func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw SearchFailure.preferencesTooLarge }
        try PersistedFormat.check(data, context: "Find settings")
        let value = try JSONInputFailure.decode(Self.self, from: data, context: "Find settings")
        guard value.version == 1 else { throw SearchFailure.preferencesVersion }
        try value.options.validatePreferences()
        return value
    }
    package func encoded() throws -> Data {
        guard version == 1 else { throw SearchFailure.preferencesVersion }
        try options.validatePreferences()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
package struct SearchDisplayPosition: Equatable, Sendable {
    package init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }

    package let line: Int
    package let column: Int
}
package struct SearchHit: Sendable {
    package init(range: NSRange, replacement: String, displayPosition: SearchDisplayPosition? = nil) {
        self.range = range
        self.replacement = replacement
        self.displayPosition = displayPosition
    }

    package let range: NSRange
    package let replacement: String
    package var displayPosition: SearchDisplayPosition?
}
package struct SearchReport: Sendable {
    package init(hits: [SearchHit], truncated: Bool, purpose: SearchCore.Purpose) {
        self.hits = hits
        self.truncated = truncated
        self.purpose = purpose
    }

    package let hits: [SearchHit]
    package let truncated: Bool
    package let purpose: SearchCore.Purpose
}
/// One match in a document searched as bytes: a UTF-8 byte range in the document, never a
/// UTF-16 range, and the text that replaces it.
package struct ByteSearchHit: Equatable, Sendable {
    package init(range: NSRange, replacement: String) {
        self.range = range
        self.replacement = replacement
    }

    package let range: NSRange
    package let replacement: String
}
package struct ByteSearchReport: Sendable {
    package init(hits: [ByteSearchHit], truncated: Bool) {
        self.hits = hits
        self.truncated = truncated
    }

    package let hits: [ByteSearchHit]
    package let truncated: Bool
}
package enum SearchFailure: LocalizedError, CustomNSError, Equatable {
    package enum ReplacementCondition: Error, Equatable { case readOnly, multipleSelections, closed, stale }
    case positionMapping
    case preferencesTooLarge, preferencesVersion, inlineResultLimit, inlineReplacement(ReplacementCondition)
    case invalidBookmarkLimit, bookmarkCancelled, bookmarkOffsetsUnordered, bookmarkOffsetOutOfBounds
    case replacementByteLimit(Int)
    case replacementCancelled, invalidReplacementRange, macroResultLimit, macroReplacement(String)
    case unknownRecordedAction, macroStopped(String)
    case largeDocumentRegex, largeSelectionRegex, largeDocumentAction, largeDocumentAllOpen(String)
    case largeDocumentMacro
    static package var errorDomain: String { "TextTank.Search" }
    package var errorCode: Int {
        switch self {
        case .replacementByteLimit: return 15
        case .largeDocumentRegex: return 16
        case .largeSelectionRegex: return 17
        case .largeDocumentAction: return 18
        case .largeDocumentAllOpen: return 19
        case .largeDocumentMacro: return 20
        case .inlineResultLimit: return 12
        case .inlineReplacement: return 13
        case .positionMapping: return 14
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
    package var errorDescription: String? {
        switch self {
        case .largeDocumentMacro:
            return
                "Macro stopped: a recorded search cannot be replayed in a document this large. Use Find or Find and Replace for this step. The search changed nothing; prior edits remain undoable."
        case .largeDocumentRegex:
            return
                "This document is too large for a regular expression search. Select part of it and choose Selection in Find and Replace, or change the search mode to Normal. Nothing was changed."
        case .largeSelectionRegex:
            return
                "The selection is too large for a regular expression search. Select less text, or change the search mode to Normal. Nothing was changed."
        case .largeDocumentAction:
            return
                "Bookmark Matches and Mark Matches are not available in a document this large. Use Next, Previous, Find All / Count or Replace. Nothing was changed."
        case .largeDocumentAllOpen(let name):
            return
                "“\(name)” is too large to search together with the other open documents. Choose Current document to search it on its own. Nothing was changed."
        case .replacementByteLimit(let bytes):
            return "Replacement exceeds the \(bytes / 1_048_576) MiB result limit. Nothing was changed."
        case .inlineResultLimit:
            return "The search reached the result limit. Narrow the Find text and search again; nothing was changed."
        case .inlineReplacement(.readOnly):
            return "The selected match could not be replaced because the document is read-only. Nothing was changed."
        case .inlineReplacement(.multipleSelections):
            return
                "The selected match could not be replaced because multiple selections are not supported. Nothing was changed."
        case .inlineReplacement(.closed):
            return
                "The selected match could not be replaced because the document is not in a window. Nothing was changed."
        case .inlineReplacement(.stale):
            return
                "The selected match could not be replaced because the document changed during the step. Nothing was changed."
        case .positionMapping:
            return
                "Search positions could not be prepared within the work limit. Search again; the document was not changed."
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
    package var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: errorDescription ?? ""] }
}

package enum SearchCore {
    package enum Purpose: Sendable, Equatable { case allMatches, navigation }
    /// One forward UTF-16 pass over zero-based lines. A break is counted once its terminator has
    /// been passed in full, so an offset between CR and LF is still on the line that owns the
    /// CRLF, as in Scintilla.
    /// Called off-main before any bookmarks are mutated.
    static package func bookmarkLines(
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
    static package let defaultTimeLimit: TimeInterval = 2
    /// `range` (UTF-16, default the whole text) limits where matches may lie; hits keep their
    /// offsets in `text` and the engine still sees the text around the range.
    static package func search(
        _ text: String, options: SearchOptions, range: NSRange? = nil,
        cancellation: TTSearchCancellation = TTSearchCancellation(), limit: Int = 100000,
        timeLimit: TimeInterval = defaultTimeLimit, purpose: Purpose = .allMatches, displayTabWidth: Int? = nil
    ) throws -> SearchReport {
        let displayDeadline = Date().addingTimeInterval(timeLimit)
        let result = try TTSearchEngine.searchText(
            text, range: range ?? NSRange(location: 0, length: (text as NSString).length), query: options.query,
            replacement: options.replacement, mode: options.mode.nativeMode, matchCase: options.matchCase,
            wholeWord: options.wholeWord, dotMatchesNewline: options.dotMatchesNewline, cancellation: cancellation,
            maximumMatches: limit, overlappingLiterals: purpose == .navigation, timeLimit: timeLimit)
        var hits = result.matches.map { SearchHit(range: $0.range, replacement: $0.replacement) }
        if let displayTabWidth {
            let positions = try displayPositions(
                hits.map { $0.range.location }, in: text,
                tabWidth: displayTabWidth, cancellation: cancellation, deadline: displayDeadline)
            for index in hits.indices { hits[index].displayPosition = positions[index] }
        }
        return SearchReport(
            hits: hits,
            truncated: result.truncated, purpose: purpose)
    }
    /// The longest text, in UTF-16 units, the snapshot engine searches in one piece (64 Mi). A
    /// longer document is searched as bytes, in windows.
    static package var maximumTextUnits: Int { Int(TTSearchEngine.maximumTextUnits()) }
    /// The window a large document is read in. Working memory follows this, not the document.
    static package let largeChunkBytes = 4 * 1_048_576
    /// The large-document variant of the time budget: the interactive two seconds for every
    /// started 64 MiB, so a large document is allowed the same rate as a document at the limit
    /// and no more. The search runs off the main thread with progress and Cancel throughout.
    static package func largeTimeLimit(bytes: Int) -> TimeInterval {
        let pieces = max(1, (bytes + 64 * 1_048_576 - 1) / (64 * 1_048_576))
        return min(600, defaultTimeLimit * Double(pieces))
    }
    /// Whether `data` is longer than `limit` UTF-16 units. Bytes are never fewer than units, and
    /// three bytes are never more than one unit short of three units, so most answers need no count.
    static package func isLarge(_ data: Data, limit: Int = maximumTextUnits) -> Bool {
        data.count > limit && (data.count / 3 > limit || utf16Length(ofUTF8: data) > limit)
    }
    /// UTF-16 length of UTF-8 `data` without decoding it: one pass, no second copy.
    static package func utf16Length(ofUTF8 data: Data) -> Int {
        autoreleasepool { Int(TTSearchEngine.utf16Length(ofUTF8: data)) }
    }
    /// Normal and Extended search of a document's UTF-8 bytes in bounded windows; see
    /// TTSearchEngine.searchUTF8. `range` and the reported hits are byte ranges in `data`. The
    /// result cap is the snapshot engine's. A regular expression is refused in plain words.
    static package func searchBytes(
        _ data: Data, options: SearchOptions, range: NSRange? = nil, backwards: Bool = false,
        overlapping: Bool = false, limit: Int = 100000, stopAtLimit: Bool = false, timeLimit: TimeInterval? = nil,
        chunkBytes: Int = largeChunkBytes, cancellation: TTSearchCancellation = TTSearchCancellation(),
        progress: ((Int) -> Void)? = nil
    ) throws -> ByteSearchReport {
        guard options.mode != .regularExpression else { throw SearchFailure.largeDocumentRegex }
        let scope = range ?? NSRange(location: 0, length: data.count)
        // The engine reads the bytes through a bridged object that is kept alive by the calling
        // thread's autorelease pool. A search runs on a concurrency thread whose pool may not be
        // drained for a long time, so the pool is drained here: the document's bytes are released
        // when the search that copied them ends, not several searches later.
        let result = try autoreleasepool {
            try TTSearchEngine.searchUTF8(
                data, range: scope, query: options.query, replacement: options.replacement,
                mode: options.mode.nativeMode, matchCase: options.matchCase, wholeWord: options.wholeWord,
                backwards: backwards, overlapping: overlapping, maximumMatches: limit, stopAtLimit: stopAtLimit,
                chunkBytes: UInt(max(0, chunkBytes)),
                cancellation: cancellation, timeLimit: timeLimit ?? largeTimeLimit(bytes: scope.length),
                progress: progress.map { report in { report(Int($0)) } })
        }
        return ByteSearchReport(
            hits: result.matches.map { ByteSearchHit(range: $0.range, replacement: $0.replacement) },
            truncated: result.truncated)
    }
    /// Presentation positions share one cancellable forward pass over existing immutable text.
    /// Internal UTF-16 columns/ranges stay unchanged. Tabs advance to the captured tab stops;
    /// astral and combining scalars each occupy one column, like native SCI_GETCOLUMN.
    static package func displayPositions(
        _ locations: [Int], in text: String, tabWidth: Int,
        cancellation: TTSearchCancellation, deadline: Date = Date().addingTimeInterval(defaultTimeLimit)
    ) throws -> [SearchDisplayPosition] {
        guard (1...32).contains(tabWidth), locations.count <= 100000 else { throw SearchFailure.positionMapping }
        var cursor = UTFCursor(text, tracksLines: true, tabWidth: tabWidth), positions: [SearchDisplayPosition] = []
        positions.reserveCapacity(locations.count)
        let stop = { cancellation.cancelled || Date() >= deadline }
        for location in locations {
            guard !stop(), cursor.advance(to: location, stop: stop) else { throw SearchFailure.positionMapping }
            positions.append(.init(line: cursor.line, column: cursor.displayColumn))
        }
        guard !stop() else { throw SearchFailure.positionMapping }
        return positions
    }
    /// Scalar-granular like byteRanges: nil for surrogate splits, negative and out-of-range input.
    static package func byteRange(_ range: NSRange, in text: String) -> NSRange? {
        byteRanges([range], in: text)?.first
    }
    /// The hits whose byte range is exactly the byte selection. All hits are converted in one
    /// linear pass, so a single Replace costs the same for one match as for a hundred thousand.
    static package func hits(_ hits: [SearchHit], selectedBy selection: NSRange, in text: String) -> [SearchHit] {
        guard let ranges = byteRanges(hits.map(\.range), in: text) else { return [] }
        return zip(hits, ranges).filter { $0.1 == selection }.map(\.0)
    }
    /// Linear offset conversion for sorted nonoverlapping matches; avoids copying
    /// a document prefix separately for every replacement.
    static package func byteRanges(_ ranges: [NSRange], in text: String) -> [NSRange]? {
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
    package struct UTFCursor {
        package let text: String
        package let tracksLines: Bool
        private var index: String.UnicodeScalarView.Index
        private(set) package var utf16Offset = 0
        private(set) package var byteOffset = 0
        private(set) package var line = 1
        private(set) package var columnUTF16 = 1
        private(set) package var displayColumn = 1
        package let tabWidth: Int
        package init(_ text: String, tracksLines: Bool = false, tabWidth: Int = 4) {
            self.tabWidth = tabWidth
            self.text = text
            self.tracksLines = tracksLines
            index = text.unicodeScalars.startIndex
        }
        /// False when the target is behind the cursor, past the end of the text or inside a
        /// surrogate pair, and when `stop` (asked every 4,096 scalars) answers true.
        mutating package func advance(to target: Int, stop: () -> Bool = { false }) -> Bool {
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
                        displayColumn = 1
                    } else {
                        columnUTF16 += width
                        // Scintilla's column stops at CR even at the boundary inside CRLF.
                        if value == 9 {
                            displayColumn += tabWidth - ((displayColumn - 1) % tabWidth)
                        } else if value != 13 {
                            displayColumn += 1
                        }
                    }
                }
                index = next
            }
            return utf16Offset == target
        }
    }
    /// False only between the two halves of a surrogate pair.
    static package func isScalarBoundary(_ i: Int, in source: NSString) -> Bool {
        i <= 0 || i >= source.length
            || !(source.character(at: i) >= 0xDC00 && source.character(at: i) <= 0xDFFF
                && source.character(at: i - 1) >= 0xD800 && source.character(at: i - 1) <= 0xDBFF)
    }
    /// Whether a match is where Next (or Previous) may go from `selection`. `continuing` is true
    /// when the selection is the match the last navigation chose, which is then not chosen again.
    static package func isNavigationCandidate(
        _ range: NSRange, from selection: NSRange, backwards: Bool, continuing: Bool
    )
        -> Bool
    {
        backwards
            ? NSMaxRange(range) <= selection.location && !(continuing && range == selection)
            : range.location >= NSMaxRange(selection) && !(continuing && range == selection)
    }
    /// A literal wrap searches the other side of the original boundary, never a match crossing
    /// that boundary. Regex navigation retains its whole-report/zero-width semantics.
    static package func isWrappedNavigationCandidate(
        _ range: NSRange, from selection: NSRange, backwards: Bool,
        mode: SearchOptions.Mode
    ) -> Bool {
        mode == .regularExpression
            || (backwards ? range.location >= selection.location : NSMaxRange(range) <= NSMaxRange(selection))
    }
    static package func utf16Range(_ range: NSRange, in text: String) -> NSRange? {
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
    static package func replacing(
        _ text: String, with hits: [SearchHit], cancellation: TTSearchCancellation? = nil,
        maximumResultBytes: Int? = nil
    )
        throws
        -> String
    {
        let source = text as NSString, length = source.length
        let result = NSMutableString(capacity: length)
        var remaining = maximumResultBytes
        func append(_ part: String) throws {
            if let available = remaining, let maximumResultBytes {
                let count = part.utf8.count
                guard count <= available else { throw SearchFailure.replacementByteLimit(maximumResultBytes) }
                remaining = available - count
            }
            result.append(part)
        }
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
                try append(
                    source.substring(with: NSRange(location: previousEnd, length: hit.range.location - previousEnd)))
            }
            try append(hit.replacement)
            previousEnd = NSMaxRange(hit.range)
        }
        if previousEnd < length { try append(source.substring(from: previousEnd)) }
        return result as String
    }
}
