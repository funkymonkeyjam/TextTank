@testable import TextTankCore
import Foundation

enum SearchSessionChecks {
    static func run() throws {
        var options = SearchOptions()
        options.wrap = false
        let hits = [
            SearchHit(range: NSRange(location: 0, length: 3), replacement: "x"),
            SearchHit(range: NSRange(location: 2, length: 3), replacement: "y")
        ]
        let report = SearchReport(hits: hits, truncated: false, purpose: .navigation)
        let snapshot = SearchSession.Snapshot(
            text: "ababa", revision: 3, currentRevision: 3,
            selection: NSRange(location: 2, length: 0), isOpen: true)
        if case .select(let bytes) = try SearchSession.plan(
            report, snapshot: snapshot, options: options,
            action: "next", continuing: false)
        {
            check(
                bytes == NSRange(location: 2, length: 3),
                "F285 Foundation navigation preserves overlapping interior-caret candidates")
        } else {
            check(false, "F285 Foundation navigation returns the next candidate")
        }
        let truncated = SearchReport(hits: hits, truncated: true, purpose: .navigation)
        rejects(
            "F285 a truncated report never produces an application plan",
            where: { ($0 as? SearchFailure) == .macroResultLimit }
        ) {
            _ = try SearchSession.plan(
                truncated, snapshot: snapshot, options: options, action: "next", continuing: false)
        }
        let stale = SearchSession.Snapshot(
            text: "ababa", revision: 3, currentRevision: 4,
            selection: NSRange(location: 2, length: 0), isOpen: true)
        rejects("F285 a stale snapshot produces no selection or replacement plan") {
            _ = try SearchSession.plan(
                report, snapshot: stale, options: options, action: "replaceAll", continuing: false)
        }
        let closed = SearchSession.Snapshot(
            text: "ababa", revision: 3, currentRevision: 3,
            selection: NSRange(location: 2, length: 0), isOpen: false)
        rejects("F285 a closed snapshot produces no application plan") {
            _ = try SearchSession.plan(report, snapshot: closed, options: options, action: "next", continuing: false)
        }
        let selected = SearchSession.Snapshot(
            text: "ababa", revision: 3, currentRevision: 3,
            selection: NSRange(location: 2, length: 3), isOpen: true)
        if case .replace(let selectedHits) = try SearchSession.plan(
            report, snapshot: selected, options: options,
            action: "replaceOne", continuing: false)
        {
            check(
                selectedHits.count == 1 && selectedHits[0].range == hits[1].range,
                "F285 strict single replacement plans only the exact selected match")
        } else {
            check(false, "F285 strict replacement returns its selected match")
        }
        let unicode = SearchReport(
            hits: [.init(range: NSRange(location: 1, length: 2), replacement: "")],
            truncated: false, purpose: .navigation)
        let astral = SearchSession.Snapshot(
            text: "x😀z", revision: 1, currentRevision: 1,
            selection: NSRange(location: 0, length: 0), isOpen: true)
        if case .select(let bytes) = try SearchSession.plan(
            unicode, snapshot: astral, options: options,
            action: "next", continuing: false)
        {
            check(
                bytes == NSRange(location: 1, length: 4), "F285 pure planning retains UTF16-to-byte scalar boundaries")
        } else {
            check(false, "F285 Unicode navigation returns its byte range")
        }
        let insertion = SearchSession.carriedSelection(
            anchor: 2, caret: 2,
            edits: [.init(range: NSRange(location: 2, length: 0), replacementBytes: 3)])
        check(
            insertion.anchor == 5 && insertion.caret == 5,
            "F285 carrying a caret through a zero-width insertion keeps it after the inserted bytes")
        let backwards = SearchSession.carriedSelection(
            anchor: 10, caret: 2,
            edits: [.init(range: NSRange(location: 4, length: 2), replacementBytes: 1)])
        check(
            backwards.anchor == 9 && backwards.caret == 2,
            "F285 selection carry preserves backward orientation and unchanged boundaries")
    }
}
