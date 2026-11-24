import Foundation
import NativeSearch

/// Immutable application-time facts. The AppKit adapter captures and validates the real editor;
/// this layer plans navigation/replacement without holding a view, window or mutable text model.
package enum SearchSession {
    package struct Snapshot {
        package init(text: String, revision: UInt, currentRevision: UInt, selection: NSRange?, isOpen: Bool) {
            self.text = text
            self.revision = revision
            self.currentRevision = currentRevision
            self.selection = selection
            self.isOpen = isOpen
        }

        package let text: String
        package let revision: UInt
        package let currentRevision: UInt
        package let selection: NSRange?
        package let isOpen: Bool
    }
    package enum Effect {
        case noMatch
        case select(NSRange)
        case replace([SearchHit])
    }
    static package func plan(
        _ report: SearchReport, snapshot: Snapshot, options: SearchOptions,
        action: String, continuing: Bool
    ) throws -> Effect {
        guard !report.truncated else { throw SearchFailure.macroResultLimit }
        guard snapshot.isOpen, snapshot.currentRevision == snapshot.revision, let selection = snapshot.selection else {
            throw SearchFailure.macroStopped("the document changed or selection is not on a character boundary")
        }
        if action == "replaceAll" || action == "replaceOne" {
            let hits = action == "replaceAll" ? report.hits : report.hits.filter { $0.range == selection }
            return hits.isEmpty ? .noMatch : .replace(hits)
        } else if action == "next" || action == "previous" {
            let backwards = action == "previous"
            let candidates = report.hits.filter {
                SearchCore.isNavigationCandidate(
                    $0.range, from: selection, backwards: backwards, continuing: continuing)
            }
            let wrapped = report.hits.filter {
                SearchCore.isWrappedNavigationCandidate(
                    $0.range, from: selection, backwards: backwards, mode: options.mode)
            }
            let hit =
                (backwards ? candidates.last : candidates.first)
                ?? (options.wrap ? (backwards ? wrapped.last : wrapped.first) : nil)
            guard let hit else { return .noMatch }
            guard let bytes = SearchCore.byteRange(hit.range, in: snapshot.text) else {
                throw SearchFailure.macroStopped("the match could not be selected")
            }
            return .select(bytes)
        }
        throw SearchFailure.unknownRecordedAction
    }
    /// How a document searched as bytes is read: the window size and one deadline for the whole
    /// action, however many passes it takes.
    package struct ByteSearch: Sendable {
        package init(
            chunkBytes: Int = SearchCore.largeChunkBytes, timeLimit: TimeInterval? = nil,
            cancellation: TTSearchCancellation = TTSearchCancellation(),
            progress: (@Sendable (Int, Int) -> Void)? = nil
        ) {
            self.chunkBytes = chunkBytes
            self.timeLimit = timeLimit
            self.cancellation = cancellation
            self.progress = progress
        }

        package let chunkBytes: Int
        package let timeLimit: TimeInterval?
        package let cancellation: TTSearchCancellation
        /// Bytes covered and bytes to cover, for the pass that is running.
        package let progress: (@Sendable (Int, Int) -> Void)?
    }
    package enum ByteEffect: Equatable, Sendable {
        case noMatch
        case select(NSRange)
        case replace([ByteSearchHit])
    }
    /// The same four actions as `plan`, for a document above the engine's UTF-16 limit. Nothing is
    /// enumerated to move: Next and Previous ask the engine for the one nearest match, forwards or
    /// backwards from the selection, and for the wrapped one only when that finds nothing. Positions
    /// are UTF-8 bytes. `scope` limits where matches may lie; `freshScope` is the first press in
    /// Selection scope, when the selection is the scope and not a place to continue from.
    static package func planBytes(
        _ data: Data, options: SearchOptions, action: String, selection: NSRange, scope: NSRange? = nil,
        freshScope: Bool = false, search: ByteSearch = ByteSearch()
    ) throws -> ByteEffect {
        let bounds = scope ?? NSRange(location: 0, length: data.count)
        let lower = bounds.location, upper = NSMaxRange(bounds)
        guard lower >= 0, upper <= data.count, selection.location >= 0, NSMaxRange(selection) <= data.count else {
            throw SearchFailure.macroStopped("the document changed or selection is not on a character boundary")
        }
        let deadline = Date().addingTimeInterval(search.timeLimit ?? SearchCore.largeTimeLimit(bytes: bounds.length))
        func find(_ range: NSRange, backwards: Bool, limit: Int, overlapping: Bool) throws -> ByteSearchReport {
            let total = range.length
            return try SearchCore.searchBytes(
                data, options: options, range: range, backwards: backwards, overlapping: overlapping, limit: limit,
                stopAtLimit: limit == 1,
                timeLimit: max(0.001, deadline.timeIntervalSinceNow), chunkBytes: search.chunkBytes,
                cancellation: search.cancellation, progress: search.progress.map { report in { report($0, total) } })
        }
        func span(_ from: Int, _ to: Int) -> NSRange? {
            let a = max(from, lower), b = min(to, upper)
            return a <= b ? NSRange(location: a, length: b - a) : nil
        }
        switch action {
        case "next", "previous":
            let backwards = action == "previous"
            let start = selection.location, end = NSMaxRange(selection)
            // The first pass is the side of the selection the search moves towards; the wrapped
            // pass is the other side, and never a match that crosses the starting boundary.
            let ahead = freshScope ? bounds : (backwards ? span(lower, start) : span(end, upper))
            if let ahead, let hit = try find(ahead, backwards: backwards, limit: 1, overlapping: true).hits.first {
                return .select(hit.range)
            }
            guard options.wrap, !freshScope, let behind = backwards ? span(start, upper) : span(lower, end),
                let hit = try find(behind, backwards: backwards, limit: 1, overlapping: true).hits.first
            else { return .noMatch }
            return .select(hit.range)
        case "replaceOne":
            guard selection.length > 0, let inside = span(selection.location, NSMaxRange(selection)),
                inside == selection,
                let hit = try find(selection, backwards: false, limit: 1, overlapping: true).hits.first,
                hit.range == selection
            else { return .noMatch }
            return .replace([hit])
        case "replaceAll":
            let report = try find(bounds, backwards: false, limit: 100000, overlapping: false)
            guard !report.truncated else { throw SearchFailure.macroResultLimit }
            return report.hits.isEmpty ? .noMatch : .replace(report.hits)
        default: throw SearchFailure.unknownRecordedAction
        }
    }
    /// `plan` for matches already held as byte ranges: a regular expression searched in a selection
    /// of a large document. The candidate rules are the same; only the unit differs.
    static package func plan(
        byteHits hits: [ByteSearchHit], options: SearchOptions, action: String, selection: NSRange,
        freshScope: Bool, continuing: Bool
    ) throws -> ByteEffect {
        switch action {
        case "replaceAll": return hits.isEmpty ? .noMatch : .replace(hits)
        case "replaceOne":
            let chosen = hits.filter { $0.range == selection }
            return chosen.isEmpty ? .noMatch : .replace(chosen)
        case "next", "previous":
            let backwards = action == "previous"
            if freshScope { return (backwards ? hits.last : hits.first).map { .select($0.range) } ?? .noMatch }
            let candidates = hits.filter {
                SearchCore.isNavigationCandidate(
                    $0.range, from: selection, backwards: backwards, continuing: continuing)
            }
            let wrapped = hits.filter {
                SearchCore.isWrappedNavigationCandidate(
                    $0.range, from: selection, backwards: backwards, mode: options.mode)
            }
            let hit =
                (backwards ? candidates.last : candidates.first)
                ?? (options.wrap ? (backwards ? wrapped.last : wrapped.first) : nil)
            return hit.map { .select($0.range) } ?? .noMatch
        default: throw SearchFailure.unknownRecordedAction
        }
    }
    package struct Edit {
        package init(range: NSRange, replacementBytes: Int) {
            self.range = range
            self.replacementBytes = replacementBytes
        }

        package let range: NSRange
        package let replacementBytes: Int
    }
    /// Carries the original selection through already validated byte edits. No editor is mutated.
    static package func carriedSelection(anchor: Int, caret: Int, edits: [Edit]) -> (anchor: Int, caret: Int) {
        func carried(_ position: Int, upper: Bool) -> Int {
            var delta = 0
            for edit in edits {
                let start = edit.range.location, end = NSMaxRange(edit.range), length = edit.replacementBytes
                if position < start || (position == start && (!upper || end > start)) { break }
                if position < end { return start + delta + (upper ? length : 0) }
                delta += length - edit.range.length
            }
            return position + delta
        }
        let atInsertion = anchor == caret && edits.contains { $0.range.location == caret && $0.range.length == 0 }
        let low = carried(min(anchor, caret), upper: atInsertion)
        let high = anchor == caret ? low : carried(max(anchor, caret), upper: true)
        return (anchor <= caret ? low : high, anchor <= caret ? high : low)
    }
}
