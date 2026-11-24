@testable import TextTankCore
import Foundation
import NativeSearch

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
        try findStateChecks()
        try byteSearchChecks()
    }
    /// V3: the history and what a new launch starts from.
    static func findStateChecks() throws {
        var history = FindHistory()
        for number in 1...12 { history.remember(query: "query \(number)") }
        check(
            history.queries.count == 10 && history.queries.first == "query 12" && history.queries.last == "query 3",
            "the history keeps the last ten searches, newest first")
        check(
            history.remember(query: "query 5") && history.queries.count == 10 && history.queries.first == "query 5"
                && history.queries.filter { $0 == "query 5" }.count == 1,
            "a search used again moves to the front and is listed once")
        check(!history.remember(query: "query 5"), "remembering the newest search again changes nothing")
        history.remember(query: "\u{e9}")
        history.remember(query: "e\u{301}")
        check(
            history.queries.prefix(2).map { Array($0.utf8) } == [Array("e\u{301}".utf8), Array("\u{e9}".utf8)],
            "two spellings of one letter are two history entries, as the engine tells them apart")
        check(
            !history.remember(query: "") && !history.remember(query: String(repeating: "q", count: 1_001))
                && history.remember(query: String(repeating: "q", count: 1_000)),
            "an empty or oversized search is not remembered; one at the limit is")
        history.remember(replacement: "with")
        check(history.replacements == ["with"], "replacements have their own history")
        history.clearQueries()
        check(history.queries.isEmpty && history.replacements == ["with"], "forgetting searches keeps replacements")
        // A file written before the history existed: the mode it would have restored is Regex.
        let legacy = Data(
            #"{"options":{"dotMatchesNewline":true,"matchCase":true,"mode":2,"query":"(a+)","replacement":"$1","wholeWord":false,"wrap":false},"version":1}"#
                .utf8)
        let old = try FindPreferences.decode(legacy)
        check(
            old.startingOptions.query.isEmpty && old.startingOptions.replacement.isEmpty
                && old.startingOptions.mode == .normal,
            "a new launch starts in Normal mode with nothing in either field, whatever was saved")
        check(
            old.startingOptions.matchCase && old.startingOptions.dotMatchesNewline && !old.startingOptions.wrap,
            "the option flags of an older file are kept")
        check(
            old.history.queries == ["(a+)"] && old.history.replacements == ["$1"],
            "what an older file would have restored is offered as history instead")
        check(
            try FindPreferences(options: old.options).encoded() == legacy,
            "settings without a history still encode to the bytes an older file holds")
        var kept = FindHistory()
        kept.remember(query: "needle")
        kept.remember(replacement: "pin")
        let saved = try FindPreferences.decode(
            FindPreferences(
                saving: SearchOptions(query: "needle", replacement: "pin", mode: .regularExpression),
                history: kept
            ).encoded())
        check(
            saved.options.query.isEmpty && saved.options.replacement.isEmpty && saved.options.mode == .normal
                && saved.history == kept,
            "a save keeps the history and never the live text or the Regex mode")
        let crowded = try FindPreferences.decode(
            Data(
                (#"{"options":{"dotMatchesNewline":false,"matchCase":false,"mode":0,"query":"","replacement":"","wholeWord":false,"wrap":true},"queryHistory":["#
                    + (1...14).map { "\"h\($0)\"" }.joined(separator: ",") + #","h1"],"version":1}"#).utf8))
        check(
            crowded.history.queries == (1...10).map { "h\($0)" } && crowded.history.replacements.isEmpty,
            "a history longer than ten in a file is read as its first ten distinct entries")
    }
    /// The byte offset of a UTF-16 offset; small fixtures only.
    private static func byteOffset(_ unit: Int, in text: String) -> Int {
        text.utf8.distance(from: text.utf8.startIndex, to: String.Index(utf16Offset: unit, in: text))
    }
    private static func bytes(_ range: NSRange, in text: String) -> NSRange {
        let start = byteOffset(range.location, in: text)
        return NSRange(location: start, length: byteOffset(NSMaxRange(range), in: text) - start)
    }
    /// V5: the windowed byte search agrees with the snapshot engine and finds a match that
    /// straddles two windows exactly once.
    static func byteSearchChecks() throws {
        let texts = [
            "alpha beta ALPHA Alpha alphabet _alpha alpha_ \u{e9}alpha alpha",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "na\u{ef}ve NA\u{cf}VE \u{1F600}na\u{ef}ve\u{1F600} nai\u{308}ve \u{65e5}\u{672c}\u{8a9e}na\u{ef}ve stra\u{df}e STRASSE \u{212a}elvin kelvin",
            String(repeating: "\u{1F600}x\u{e9}y ", count: 40) + "\u{1F600}",
            "line one\r\nline two\nx\0y line\tthree line"
        ]
        let needles = ["alpha", "a", "aa", "na\u{ef}ve", "\u{1F600}", "x\u{e9}", "line", "ss", "k", "\u{e9}", "e", "y "]
        var compared = 0, mismatches = 0
        for text in texts {
            let data = Data(text.utf8)
            for needle in needles {
                for flags in 0..<8 {
                    var options = SearchOptions(query: needle, replacement: "R")
                    options.matchCase = flags & 1 != 0
                    options.wholeWord = flags & 2 != 0
                    let overlapping = flags & 4 != 0
                    let expected = try SearchCore.search(
                        text, options: options, purpose: overlapping ? .navigation : .allMatches
                    ).hits.map { bytes($0.range, in: text) }
                    for chunk in [16, 17, 19, 23, 64, 4096] {
                        let forward = try SearchCore.searchBytes(
                            data, options: options, overlapping: overlapping, chunkBytes: chunk)
                        compared += 1
                        if forward.hits.map(\.range) != expected || forward.truncated
                            || forward.hits.contains(where: { $0.replacement != "R" })
                        {
                            mismatches += 1
                            print("NOTE byte search differs: \(needle.debugDescription) flags \(flags) chunk \(chunk)")
                        }
                        if overlapping {
                            let backward = try SearchCore.searchBytes(
                                data, options: options, backwards: true, overlapping: true, chunkBytes: chunk)
                            compared += 1
                            if backward.hits.map(\.range) != expected.reversed() {
                                mismatches += 1
                                print(
                                    "NOTE backward search differs: \(needle.debugDescription) flags \(flags) chunk \(chunk)"
                                )
                            }
                        }
                    }
                }
            }
        }
        check(
            mismatches == 0 && compared > 3_000,
            "the windowed byte search reports exactly the snapshot engine's matches, forwards and backwards, for every window size, case rule and multi-byte text tried"
        )
        // One match, moved one byte at a time across a window boundary.
        var once = 0, positions = 0
        for lead in 40...90 {
            let text =
                String(repeating: "\u{e9}", count: lead / 2) + (lead % 2 == 1 ? "z" : "") + "Na\u{ef}ve\u{1F600}end"
                + String(repeating: ".", count: 80)
            let data = Data(text.utf8)
            for matchCase in [true, false] {
                var options = SearchOptions(query: matchCase ? "Na\u{ef}ve\u{1F600}" : "NA\u{cf}VE\u{1F600}")
                options.matchCase = matchCase
                let found = try SearchCore.searchBytes(data, options: options, chunkBytes: 64).hits
                let back = try SearchCore.searchBytes(data, options: options, backwards: true, chunkBytes: 64).hits
                positions += 1
                if found.count == 1, back == found, found[0].range == NSRange(location: lead, length: 10) { once += 1 }
            }
        }
        check(once == positions && positions == 102, "a match that straddles two windows is found exactly once")
        let many = Data(String(repeating: "ab", count: 500).utf8)
        let capped = try SearchCore.searchBytes(many, options: SearchOptions(query: "ab"), limit: 100, chunkBytes: 64)
        check(capped.hits.count == 100 && capped.truncated, "the result cap stops a windowed search and says so")
        let exact = try SearchCore.searchBytes(many, options: SearchOptions(query: "ab"), limit: 500, chunkBytes: 64)
        check(exact.hits.count == 500 && !exact.truncated, "a search that ends at the cap is not reported as cut off")
        var covered: [Int] = []
        _ = try SearchCore.searchBytes(
            many, options: SearchOptions(query: "zz"), chunkBytes: 64, progress: { covered.append($0) })
        check(
            covered.count >= 15 && covered == covered.sorted() && covered.last == many.count,
            "progress is real: it rises window by window to the whole document")
        rejects(
            "a regular expression is refused for a large document in plain words",
            expecting: SearchFailure.largeDocumentRegex
        ) {
            _ = try SearchCore.searchBytes(many, options: SearchOptions(query: "a+", mode: .regularExpression))
        }
        check(
            SearchFailure.largeDocumentRegex.localizedDescription.contains("Selection")
                && SearchFailure.largeDocumentRegex.localizedDescription.contains("Normal")
                && SearchFailure.largeDocumentRegex.localizedDescription.contains("Nothing was changed"),
            "the refusal says what to do next: search a selection, or change to Normal")
        let stopped = TTSearchCancellation()
        stopped.cancel()
        rejects("a cancelled windowed search returns nothing", message: "cancelled") {
            _ = try SearchCore.searchBytes(many, options: SearchOptions(query: "ab"), cancellation: stopped)
        }
        rejects("a windowed search past its time budget stops", where: { TTSearchEngine.timedOut($0 as NSError) }) {
            _ = try SearchCore.searchBytes(
                Data(count: 8 * 1_048_576), options: SearchOptions(query: "zz", matchCase: false),
                timeLimit: 0.000_001, chunkBytes: 4_096)
        }
        rejects("a byte range that splits a character is refused", message: "splits a character") {
            _ = try SearchCore.searchBytes(
                Data("\u{e9}a".utf8), options: SearchOptions(query: "a"), range: NSRange(location: 1, length: 2))
        }
        let extended = try SearchCore.searchBytes(
            Data("a\tb a\\tb".utf8), options: SearchOptions(query: "a\\tb", replacement: "\\n", mode: .extended))
        check(
            extended.hits == [ByteSearchHit(range: NSRange(location: 0, length: 3), replacement: "\n")],
            "Extended mode is searched as the literal its escapes stand for")
        check(
            texts.allSatisfy { text in
                (0...9).allSatisfy { lead in
                    let shifted = String(repeating: "x", count: lead) + text
                    return SearchCore.utf16Length(ofUTF8: Data(shifted.utf8)) == shifted.utf16.count
                }
            }, "the counted UTF-16 length is exact for multi-byte text at every alignment")
        let mixed = "a\u{e9}\u{65e5}\u{1F600}"
        check(
            SearchCore.utf16Length(ofUTF8: Data(mixed.utf8)) == mixed.utf16.count
                && SearchCore.isLarge(Data(mixed.utf8), limit: 4) && !SearchCore.isLarge(Data(mixed.utf8), limit: 5),
            "the UTF-16 length of UTF-8 bytes is counted without decoding them")
        check(
            SearchCore.largeTimeLimit(bytes: 1) == 2 && SearchCore.largeTimeLimit(bytes: 64 * 1_048_576) == 2
                && SearchCore.largeTimeLimit(bytes: 64 * 1_048_576 + 1) == 4
                && SearchCore.largeTimeLimit(bytes: 200 * 1_048_576) == 8,
            "the large-document budget is the interactive two seconds per started 64 MiB")
        // Navigation: the nearest match each way is the one the enumerating planner chooses.
        var moves = 0, wrong = 0
        for text in texts.prefix(3) {
            let data = Data(text.utf8)
            for needle in ["alpha", "aa", "na\u{ef}ve", "e"] {
                for wrap in [true, false] {
                    var options = SearchOptions(query: needle, wrap: wrap)
                    options.matchCase = false
                    let report = try SearchCore.search(text, options: options, purpose: .navigation)
                    for unit in stride(from: 0, through: text.utf16.count, by: 3)
                    where SearchCore.isScalarBoundary(unit, in: text as NSString) {
                        for length in [0, 2]
                        where unit + length <= text.utf16.count
                            && SearchCore.isScalarBoundary(unit + length, in: text as NSString)
                        {
                            let selection = NSRange(location: unit, length: length)
                            let snapshot = SearchSession.Snapshot(
                                text: text, revision: 1, currentRevision: 1, selection: selection, isOpen: true)
                            for action in ["next", "previous"] {
                                let expected = try SearchSession.plan(
                                    report, snapshot: snapshot, options: options, action: action, continuing: false)
                                let actual = try SearchSession.planBytes(
                                    data, options: options, action: action, selection: bytes(selection, in: text),
                                    search: SearchSession.ByteSearch(chunkBytes: 16))
                                moves += 1
                                switch (expected, actual) {
                                case (.noMatch, .noMatch): break
                                case (.select(let a), .select(let b)) where a == b: break
                                default: wrong += 1
                                }
                            }
                        }
                    }
                }
            }
        }
        check(
            wrong == 0 && moves > 500,
            "Next and Previous in a large document go where the enumerating planner goes, with and without wrap")
        // Fix round 1, item 2: Next and Previous stop at the nearest match. Nothing after it is
        // read, so a deadline or Cancel that would have come later cannot discard it.
        let late = Data((String(repeating: ".", count: 2_000) + "needle" + String(repeating: ".", count: 2_000)).utf8)
        var read: [Int] = []
        let nearest = try SearchCore.searchBytes(
            late, options: SearchOptions(query: "needle"), limit: 1, stopAtLimit: true, chunkBytes: 64,
            progress: { read.append($0) })
        check(
            nearest.hits.map(\.range) == [NSRange(location: 2_000, length: 6)] && !nearest.truncated
                && (read.last ?? 0) < 2_100,
            "a search for the nearest match stops reading at that match")
        read = []
        let nearestBack = try SearchCore.searchBytes(
            late, options: SearchOptions(query: "NEEDLE"), backwards: true, limit: 1, stopAtLimit: true,
            chunkBytes: 64, progress: { read.append($0) })
        check(
            nearestBack.hits.map(\.range) == [NSRange(location: 2_000, length: 6)] && (read.last ?? 0) < 2_100,
            "a backwards search for the nearest match stops reading at that match")
        // 2,000 bytes in 64-byte windows are about 32 looks at Cancel. Forty are allowed: the
        // match is reached, and the 31 windows after it must not be read.
        for action in ["next", "previous"] {
            let selection = NSRange(location: action == "next" ? 0 : late.count, length: 0)
            let found = try? SearchSession.planBytes(
                late, options: SearchOptions(query: "needle", matchCase: true, wrap: false), action: action,
                selection: selection,
                search: SearchSession.ByteSearch(chunkBytes: 64, cancellation: CancelAfterPolls(allowed: 40)))
            check(
                found == .select(NSRange(location: 2_000, length: 6)),
                "\(action): a match already found is not lost to a Cancel or deadline that comes after it")
        }
        // Item 3: Cancel and the deadline are looked at inside a window. A long search text with a
        // repetitive start costs its whole length at every position of this one 256 KiB window.
        let run = Data(String(repeating: "a", count: 262_144).utf8)
        let costly = String(repeating: "a", count: 60_000) + "b"
        for (matchCase, backwards) in [(true, false), (true, true), (false, false), (false, true)] {
            let token = CancelAfterPolls(allowed: 3)
            rejects(
                "a costly search inside one window is cancelled (match case \(matchCase), backwards \(backwards))",
                message: "cancelled"
            ) {
                _ = try SearchCore.searchBytes(
                    run, options: SearchOptions(query: costly, matchCase: matchCase), backwards: backwards,
                    cancellation: token)
            }
            check(token.polls >= 4, "Cancel is looked at more than once per window")
        }
        rejects(
            "a costly search inside one window meets its deadline", where: { TTSearchEngine.timedOut($0 as NSError) }
        ) {
            _ = try SearchCore.searchBytes(
                run, options: SearchOptions(query: costly, matchCase: true), timeLimit: 0.01)
        }
        // Item 6: the real path at the real limit and the real window size. 65 MiB of zero bytes
        // is 68,157,440 UTF-16 units, above the engine's 67,108,864, with three planted matches
        // of multi-byte text: across the first 4 MiB window boundary, mid-document and at the end.
        try autoreleasepool {
            let size = 65 * 1_048_576, marker = Array("Straddle-\u{c9}\u{dc}\u{1F600}-Mark".utf8)
            let planted = [4 * 1_048_576 - 7, 33 * 1_048_576 + 12_345, size - marker.count]
            var real = Data(count: size)
            for position in planted { real.replaceSubrange(position..<position + marker.count, with: marker) }
            check(
                real.count > SearchCore.maximumTextUnits && SearchCore.isLarge(real)
                    && SearchCore.utf16Length(ofUTF8: real) == size - 3 * 4,
                "a 65 MiB document is above the engine's real 64 Mi UTF-16 limit")
            let expected = planted.map { NSRange(location: $0, length: marker.count) }
            let exact = try SearchCore.searchBytes(
                real, options: SearchOptions(query: "Straddle-\u{c9}\u{dc}\u{1F600}-Mark", matchCase: true))
            let folded = try SearchCore.searchBytes(
                real, options: SearchOptions(query: "STRADDLE-\u{c9}\u{dc}\u{1F600}-MARK"))
            check(
                exact.hits.map(\.range) == expected && folded.hits.map(\.range) == expected && !exact.truncated
                    && !folded.truncated,
                "at the real limit and window size the count is right, with the boundary match found once")
            let options = SearchOptions(query: "straddle-\u{e9}\u{fc}\u{1F600}-mark")
            check(
                try SearchSession.planBytes(
                    real, options: options, action: "next", selection: NSRange(location: 0, length: 0))
                    == .select(expected[0])
                    && SearchSession.planBytes(real, options: options, action: "next", selection: expected[2])
                        == .select(expected[0])
                    && SearchSession.planBytes(real, options: options, action: "previous", selection: expected[0])
                        == .select(expected[2]),
                "at the real limit Next finds the boundary match and both directions wrap")
            rejects("at the real limit a regular expression is refused", expecting: SearchFailure.largeDocumentRegex) {
                _ = try SearchCore.searchBytes(
                    real, options: SearchOptions(query: "Strad+le", mode: .regularExpression))
            }
        }
        let pairs = Data("ab ab ab".utf8)
        check(
            try SearchSession.planBytes(
                pairs, options: SearchOptions(query: "ab", replacement: "X"), action: "replaceOne",
                selection: NSRange(location: 3, length: 2))
                == .replace([ByteSearchHit(range: NSRange(location: 3, length: 2), replacement: "X")]),
            "Replace in a large document replaces the selected match")
        check(
            try SearchSession.planBytes(
                pairs, options: SearchOptions(query: "ab", replacement: "X"), action: "replaceOne",
                selection: NSRange(location: 2, length: 3)) == .noMatch
                && SearchSession.planBytes(
                    pairs, options: SearchOptions(query: "ab", replacement: "X"), action: "replaceOne",
                    selection: NSRange(location: 3, length: 0)) == .noMatch,
            "Replace never replaces a selection that is not exactly a match")
        if case .replace(let all) = try SearchSession.planBytes(
            pairs, options: SearchOptions(query: "ab", replacement: "X"), action: "replaceAll",
            selection: NSRange(location: 0, length: 0), search: SearchSession.ByteSearch(chunkBytes: 16))
        {
            check(all.map(\.range.location) == [0, 3, 6], "Replace All plans every match once, in order")
        } else {
            check(false, "Replace All plans every match once, in order")
        }
        check(
            try SearchSession.planBytes(
                pairs, options: SearchOptions(query: "ab"), action: "next", selection: NSRange(location: 0, length: 8),
                scope: NSRange(location: 2, length: 6), freshScope: true) == .select(NSRange(location: 3, length: 2))
                && SearchSession.planBytes(
                    pairs, options: SearchOptions(query: "ab"), action: "next",
                    selection: NSRange(location: 6, length: 2), scope: NSRange(location: 2, length: 4))
                    == .select(NSRange(location: 3, length: 2)),
            "a scope keeps large-document navigation inside it, first press and wrap alike")
    }
}
