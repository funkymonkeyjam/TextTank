import Foundation

/// Immutable application-time facts. The AppKit adapter captures and validates the real editor;
/// this layer plans navigation/replacement without holding a view, window or mutable text model.
enum SearchSession {
    struct Snapshot {
        let text: String
        let revision: UInt
        let currentRevision: UInt
        let selection: NSRange?
        let isOpen: Bool
    }
    enum Effect {
        case noMatch
        case select(NSRange)
        case replace([SearchHit])
    }
    static func plan(
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
    struct Edit {
        let range: NSRange
        let replacementBytes: Int
    }
    /// Carries the original selection through already validated byte edits. No editor is mutated.
    static func carriedSelection(anchor: Int, caret: Int, edits: [Edit]) -> (anchor: Int, caret: Int) {
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
