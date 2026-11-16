@testable import TextTankCore
import Foundation
import NativeSearch
/// Reports "not cancelled" for the first polls and "cancelled" from then on, so
/// a search is cancelled while it is running without a timer or a second thread.
final class CancelAfterPolls: TTSearchCancellation, @unchecked Sendable {
    private let allowed: Int
    private let lock = NSLock()
    private var pollCount = 0
    var polls: Int {
        lock.lock()
        defer { lock.unlock() }
        return pollCount
    }
    init(allowed: Int) {
        self.allowed = allowed
        super.init()
    }
    override var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        pollCount += 1
        return pollCount > allowed
    }
}
@main struct SearchChecks {
    static func main() {
        Checks.run("SearchChecks") {
            try SearchSessionChecks.run()
            rejects(
                "F181 bookmark work-limit failures have a distinct typed identity",
                expecting: SearchFailure.invalidBookmarkLimit
            ) {
                _ = try SearchCore.bookmarkLines(
                    in: "abc", locations: [0], cancellation: TTSearchCancellation(), timeLimit: 0)
            }
            rejects(
                "F181 reversed bookmark offsets have their own typed identity",
                expecting: SearchFailure.bookmarkOffsetsUnordered
            ) {
                _ = try SearchCore.bookmarkLines(in: "abc", locations: [2, 1], cancellation: TTSearchCancellation())
            }
            check(
                POSIXError(.ENOENT).isFileNotFound
                    && NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)).isFileNotFound
                    && FileOperationFailure(ENOENT, operation: "read", path: "/fixture/absent").isFileNotFound
                    && !POSIXError(.EACCES).isFileNotFound,
                "F181 one missing-file predicate preserves native and bridged error identities")
            func search(
                _ text: String, _ query: String, _ replacement: String = "",
                mode: SearchOptions.Mode = .regularExpression, caseSensitive: Bool = true, whole: Bool = false,
                dot: Bool = false, range: NSRange? = nil
            ) throws -> SearchReport {
                var o = SearchOptions()
                o.query = query
                o.replacement = replacement
                o.mode = mode
                o.matchCase = caseSensitive
                o.wholeWord = whole
                o.dotMatchesNewline = dot
                return try SearchCore.search(text, options: o, range: range)
            }
            let literal = try search("a.b aXb a.b", "a.b", "X", mode: .normal)
            check(literal.hits.count == 2, "normal mode is literal")
            check(try SearchCore.replacing("a.b aXb a.b", with: literal.hits) == "X aXb X", "literal replace all exact")
            let extended = try search("x\r\ny\tz\0", "\\r\\n", "\\x41\\d066\\o103\\b01000100\\u0045", mode: .extended)
            check(
                try SearchCore.replacing("x\r\ny\tz\0", with: extended.hits) == "xABCDEy\tz\0",
                "extended numeric replacement forms")
            check(
                TTSearchEngine.decodeExtended("\\q\\xQ0\\u123\\") == "\\q\\xQ0\\u123\\",
                "unknown and malformed extended escapes remain literal")
            check(TTSearchEngine.decodeExtended("\\0") == "\0", "extended NUL preserved")
            check(
                try search("a\0b", "\\0", mode: .extended).hits.first?.range == NSRange(location: 1, length: 1),
                "NUL search is length aware")
            let capture = try search("one=12 two=34", "(?<key>[a-z]+)=(\\d+)", "$+{key}:$2")
            check(
                try SearchCore.replacing("one=12 two=34", with: capture.hits) == "one:12 two:34",
                "Boost named and numbered replacement captures")
            check(
                try search("abc123", "abc\\K\\d+").hits.first?.range == NSRange(location: 3, length: 3),
                "Boost reset-match operator")
            check(try search("ab ac", "(?<=a)b").hits.count == 1, "Boost lookbehind")
            check(try search("a\nb", "a.b").hits.isEmpty, "dot excludes newline by default")
            check(try search("a\nb", "a.b", dot: true).hits.count == 1, "dot newline option")
            check(
                try search("cat scatter Cat cat_", "cat", mode: .normal, caseSensitive: false, whole: true).hits.count
                    == 2, "whole word and case options")
            let empty = try search("ab", "(?=.)|$", "_")
            check(empty.hits.map { $0.range.location } == [0, 1, 2], "zero length matches progress and include end")
            check(try SearchCore.replacing("ab", with: empty.hits) == "_a_b_", "zero length replacement order")
            check(
                try search("🥑 café", "café").hits.first?.range == NSRange(location: 3, length: 4),
                "UTF16 range after astral Unicode")
            check(
                SearchCore.byteRange(NSRange(location: 3, length: 4), in: "🥑 café") == NSRange(location: 5, length: 5),
                "UTF16 to UTF8 exact")
            check(
                SearchCore.byteRanges([NSRange(location: 0, length: 2), NSRange(location: 3, length: 4)], in: "🥑 café")
                    == [NSRange(location: 0, length: 4), NSRange(location: 5, length: 5)],
                "linear multiple Unicode offsets")
            check(
                SearchCore.utf16Range(NSRange(location: 5, length: 5), in: "🥑 café") == NSRange(location: 3, length: 4),
                "UTF8 to UTF16 exact")
            check(SearchCore.byteRange(NSRange(location: 1, length: 1), in: "🥑") == nil, "surrogate split rejected")
            // F34: byte conversion is scalar-granular, not grapheme-granular, and total.
            check(
                SearchCore.byteRange(NSRange(location: 0, length: 2), in: "a\r\nb") == NSRange(location: 0, length: 2),
                "byte range may end between CR and LF")
            check(
                SearchCore.byteRange(NSRange(location: 0, length: 1), in: "e\u{301}x")
                    == NSRange(location: 0, length: 1), "byte range may end before a combining mark")
            check(
                SearchCore.byteRange(NSRange(location: 4, length: 0), in: "abc") == nil
                    && SearchCore.byteRange(NSRange(location: 2, length: 2), in: "abc") == nil,
                "out-of-range byte conversion rejected")
            check(
                SearchCore.byteRange(NSRange(location: -1, length: 1), in: "abc") == nil
                    && SearchCore.byteRange(NSRange(location: 1, length: -1), in: "abc") == nil,
                "negative byte conversion rejected")
            check(
                SearchCore.byteRange(NSRange(location: 3, length: 0), in: "abc") == NSRange(location: 3, length: 0)
                    && SearchCore.byteRange(NSRange(location: 0, length: 0), in: "") == NSRange(location: 0, length: 0),
                "empty range at end converts")
            let cafes = try search("🥑 café café", "café", "X", mode: .normal)
            let second = SearchCore.hits(cafes.hits, selectedBy: NSRange(location: 11, length: 5), in: "🥑 café café")
            check(
                cafes.hits.count == 2 && second.count == 1 && second[0].range == NSRange(location: 8, length: 4),
                "byte selection after astral and non-ASCII prefix picks exactly that hit")
            let crHits = try search("a\r\nb a\r\nb", "a\\r", "X", mode: .extended)
            let crPicked = SearchCore.hits(
                crHits.hits, selectedBy: NSRange(location: 5, length: 2), in: "a\r\nb a\r\nb")
            check(
                crHits.hits.count == 2 && crPicked.count == 1 && crPicked[0].range == NSRange(location: 5, length: 2),
                "selection ending between CR and LF picks that hit")
            check(
                SearchCore.hits(cafes.hits, selectedBy: NSRange(location: 11, length: 4), in: "🥑 café café").isEmpty
                    && SearchCore.hits(cafes.hits, selectedBy: NSRange(location: 11, length: 0), in: "🥑 café café")
                        .isEmpty
                    && SearchCore.hits(cafes.hits, selectedBy: NSRange(location: 0, length: 4), in: "🥑 café café")
                        .isEmpty,
                "partial, caret-only and non-hit selections pick nothing")
            check(
                SearchCore.hits([], selectedBy: NSRange(location: 0, length: 0), in: "abc").isEmpty
                    && SearchCore.hits(
                        [SearchHit(range: NSRange(location: 1, length: 1), replacement: "")],
                        selectedBy: NSRange(location: 0, length: 4), in: "🥑"
                    ).isEmpty, "no hits or an unmappable hit pick nothing")
            let manyLine = "é needle 0123456789 0123456789 0123456\n",
                manyText = String(repeating: manyLine, count: 50000)
            let manyHits = (0..<50000).map {
                SearchHit(range: NSRange(location: $0 * manyLine.utf16.count + 2, length: 6), replacement: "X")
            }
            let manyStart = Date(),
                manyPicked = SearchCore.hits(
                    manyHits, selectedBy: NSRange(location: 49999 * manyLine.utf8.count + 3, length: 6), in: manyText)
            check(
                manyPicked.count == 1 && manyPicked[0].range.location == 49999 * manyLine.utf16.count + 2
                    && Date().timeIntervalSince(manyStart) < 5,
                "50000 hits in a 2 MB document matched against the selection in one linear pass")
            check(SearchCore.utf16Range(NSRange(location: 1, length: 2), in: "🥑") == nil, "UTF8 interior rejected")
            var failed = false
            do { _ = try search("text", "(") } catch { failed = true }
            check(failed, "malformed Boost pattern rejected")
            // F19: the regex runs over code points, so these two no longer reject; they used to assert
            // "regex splitting surrogate rejected before mutation" and "replacement capture splitting
            // surrogate rejected".
            check(
                try search("🥑", ".").hits.map(\.range) == [NSRange(location: 0, length: 2)],
                "regex dot matches a whole astral character")
            check(try search("🥑", "(.).", "$1").hits.isEmpty, "two dots do not match the two halves of one character")
            let twoDots = try search("🥑🥑", "(.).", "$1")
            check(
                try twoDots.hits.map(\.range) == [NSRange(location: 0, length: 4)]
                    && (try SearchCore.replacing("🥑🥑", with: twoDots.hits)) == "🥑",
                "a capture of one astral character is written back whole")
            // F20/G343: extended escapes must not inject unpaired surrogates into matches or replacements.
            for (text, query, replacement, label) in [
                ("x😀y", "\\uD83D", "", "lone high-surrogate query"), ("x😀y", "\\uDE00", "", "lone low-surrogate query"),
                ("a", "a", "\\uD83D", "lone high-surrogate replacement"),
                ("a", "a", "\\uDE00", "lone low-surrogate replacement"),
                ("a", "a", "\\uDE00\\uD83D", "reversed surrogate replacement")
            ] {
                failed = false
                var message = ""
                do { _ = try search(text, query, replacement, mode: .extended) } catch {
                    failed = true
                    message = error.localizedDescription
                }
                check(failed && message.contains("surrogate"), "extended \(label) rejected with an explanation")
            }
            check(
                try search("x😀y", "\\uD83D\\uDE00", mode: .extended).hits.map(\.range) == [
                    NSRange(location: 1, length: 2)
                ], "extended surrogate pair written as two escapes matches the whole character")
            let paired = try search("x😀y", "x", "\\uD83D\\uDE00", mode: .extended)
            check(
                try SearchCore.replacing("x😀y", with: paired.hits) == "😀😀y",
                "extended surrogate pair replacement stays valid")
            var options = SearchOptions()
            options.query = "a"
            options.mode = .regularExpression
            let limited = try SearchCore.search("aaa", options: options, limit: 2)
            check(limited.truncated && limited.hits.count == 2, "result cap explicit")
            let cancelled = TTSearchCancellation()
            cancelled.cancel()
            failed = false
            do { _ = try SearchCore.search("aaa", options: options, cancellation: cancelled) } catch { failed = true }
            check(failed, "pre-cancelled search rejected")
            // The product's own time budget and cancellation are what bound these searches, so the
            // checks assert the reason for the rejection; the stopwatch is only a generous hang guard.
            options.query = "(a+)+$"
            let start = Date()
            rejects("pathological Boost pattern stopped by its time budget", message: "exceeded its time budget") {
                _ = try SearchCore.search(String(repeating: "a", count: 100) + "!", options: options, timeLimit: 0.05)
            }
            check(Date().timeIntervalSince(start) < 10, "pathological Boost pattern returns well inside the hang guard")
            let token = CancelAfterPolls(allowed: 1), cancelStart = Date()
            rejects("active Boost search observes cancellation", message: "Search cancelled") {
                _ = try SearchCore.search(
                    String(repeating: "a", count: 200) + "!", options: options, cancellation: token, timeLimit: 5)
            }
            check(
                token.polls == 2 && Date().timeIntervalSince(cancelStart) < 5,
                "active Boost search stops at the first cancellation poll after it started, not at its 5 s budget")
            failed = false
            do {
                _ = try SearchCore.replacing(
                    "abcd",
                    with: [
                        SearchHit(range: NSRange(location: 0, length: 3), replacement: "X"),
                        SearchHit(range: NSRange(location: 2, length: 1), replacement: "Y")
                    ])
            } catch { failed = true }
            check(failed, "overlap rejected before edits")
            // F40: replacing is one forward pass. 100,000 length-changing hits in 20 million
            // UTF-16 units took 15 to 30 s when every hit shifted the rest of the buffer.
            let row = "ab" + String(repeating: "é", count: 198), rows = 100_000
            let large = String(repeating: row, count: rows)
            let largeHits = (0..<rows).map {
                SearchHit(range: NSRange(location: $0 * 200, length: 2), replacement: "xyz")
            }
            let scale = Double(ProcessInfo.processInfo.environment["TEXTTANK_PERF_BUDGET_SCALE"] ?? "") ?? 1
            let started = Date()
            let rebuilt = try SearchCore.replacing(large, with: largeHits)
            let seconds = Date().timeIntervalSince(started)
            print("NOTE replacing 100,000 hits in 20 M units took \(String(format: "%.2f", seconds)) s")
            check(
                rebuilt == String(repeating: "xyz" + String(repeating: "é", count: 198), count: rows),
                "100,000 length-changing replacements give the exact text")
            check(seconds < 4 * max(scale, 1), "100,000 length-changing replacements finish within 4 s")
            rejects(
                "replacement range that splits a surrogate pair refused with code 3",
                where: { ($0 as NSError).code == 3 }
            ) {
                _ = try SearchCore.replacing(
                    "a🥑b", with: [SearchHit(range: NSRange(location: 1, length: 1), replacement: "X")])
            }
            rejects("replacement ranges out of order refused with code 3", where: { ($0 as NSError).code == 3 }) {
                _ = try SearchCore.replacing(
                    "abcd",
                    with: [
                        SearchHit(range: NSRange(location: 2, length: 1), replacement: "X"),
                        SearchHit(range: NSRange(location: 0, length: 1), replacement: "Y")
                    ])
            }
            rejects("replacement range past the end refused with code 3", where: { ($0 as NSError).code == 3 }) {
                _ = try SearchCore.replacing(
                    "abcd", with: [SearchHit(range: NSRange(location: 3, length: 2), replacement: "X")])
            }
            check(
                try SearchCore.replacing(
                    "abcd",
                    with: [
                        SearchHit(range: NSRange(location: 0, length: 0), replacement: "<"),
                        SearchHit(range: NSRange(location: 0, length: 1), replacement: "A"),
                        SearchHit(range: NSRange(location: 1, length: 0), replacement: "|"),
                        SearchHit(range: NSRange(location: 4, length: 0), replacement: ">")
                    ]) == "<A|bcd>", "adjacent and zero-width replacements keep their order")
            options.query = String(repeating: "(", count: 10000) + "a" + String(repeating: ")", count: 10000)
            failed = false
            let compileStart = Date()
            do { _ = try SearchCore.search("a", options: options, timeLimit: 0.1) } catch { failed = true }
            check(
                failed && Date().timeIntervalSince(compileStart) < 10,
                "deeply nested pattern compilation rejects safely")
            check(
                try SearchCore.bookmarkLines(
                    in: "a\r\nb\rc\n🥑", locations: [0, 1, 2, 3, 4, 5, 6, 7, 9], cancellation: TTSearchCancellation())
                    == [0, 1, 2, 3], "bookmark CRLF CR LF Unicode offsets linear")
            check(
                try SearchCore.bookmarkLines(in: "abc", locations: [], cancellation: TTSearchCancellation()).isEmpty,
                "empty bookmarks")
            // F46: an offset between CR and LF belongs to the line that owns the CRLF, as in Scintilla.
            func bookmarkLine(_ text: String, _ location: Int) throws -> [Int] {
                try SearchCore.bookmarkLines(in: text, locations: [location], cancellation: TTSearchCancellation())
            }
            check(try bookmarkLine("a\r\nb", 2) == [0], "bookmark offset on the LF of a CRLF stays on the CRLF's line")
            check(try bookmarkLine("a\r\n", 2) == [0], "bookmark offset on the LF of a final CRLF stays on its line")
            check(try bookmarkLine("a\rb", 2) == [1], "bookmark offset after a lone CR is on the next line")
            check(
                try bookmarkLine("a\r", 2) == [1], "bookmark offset after a lone CR ending the text is on the next line"
            )
            check(
                try SearchCore.bookmarkLines(
                    in: "a\r\nb\r\n\r\rc", locations: [1, 2, 3, 5, 6, 7, 8], cancellation: TTSearchCancellation())
                    == [0, 1, 2, 3, 4], "bookmark lines across CRLF, an empty CRLF line and consecutive lone CRs")
            failed = false
            do { _ = try SearchCore.bookmarkLines(in: "abc", locations: [0], cancellation: cancelled) } catch {
                failed = true
            }
            check(failed, "bookmark pre-cancellation")
            failed = false
            do {
                _ = try SearchCore.bookmarkLines(in: "abc", locations: [2, 1], cancellation: TTSearchCancellation())
            } catch { failed = true }
            check(failed, "bookmark reversed offsets reject")
            let denseStart = Date()
            check(
                try SearchCore.bookmarkLines(
                    in: String(repeating: "x\n", count: 100000), locations: Array(stride(from: 0, to: 200000, by: 2)),
                    cancellation: TTSearchCancellation()
                ).count == 100000 && Date().timeIntervalSince(denseStart) < 10,
                "dense bookmark offsets bounded linear pass")

            func ranges(_ report: SearchReport) -> [NSRange] { report.hits.map(\.range) }
            func at(_ location: Int, _ length: Int) -> NSRange { NSRange(location: location, length: length) }
            func message(_ body: () throws -> Void) -> String {
                do { try body() } catch { return error.localizedDescription }
                return ""
            }
            // F19: regex over code points.
            let avocado = "🥑 a"
            let dots = try search(avocado, ".")
            check(ranges(dots) == [at(0, 2), at(2, 1), at(3, 1)], "regex dot steps over an astral character as one")
            check(
                SearchCore.byteRanges(ranges(dots), in: avocado)?.count == 3,
                "every dot hit on astral text maps to a byte range")
            check(ranges(try search(avocado, "[^a]")) == [at(0, 2), at(2, 1)], "negated class takes a whole character")
            let stars = try search(avocado, "a*", "_")
            check(
                ranges(stars) == [at(0, 0), at(2, 0), at(3, 1), at(4, 0)],
                "empty matches never land inside a surrogate pair")
            check(
                try SearchCore.replacing(avocado, with: stars.hits) == "_🥑_ __",
                "empty-match replace all on astral text is well formed")
            check(ranges(try search(avocado, "\\x{1F951}")) == [at(0, 2)], "astral code point escape matches")
            check(ranges(try search("🥑🥑", "🥑+")) == [at(0, 4)], "quantifier applies to the whole astral character")
            check(ranges(try search("🥑🍎x", "[🥑🍎]+")) == [at(0, 4)], "class of astral characters")
            let doubled = try search("🥑", "(.)", "$1$1")
            check(try SearchCore.replacing("🥑", with: doubled.hits) == "🥑🥑", "astral capture expands twice")
            check(
                try ranges(try search("🥑", "x|$", "\\x{1F34E}")) == [at(2, 0)]
                    && (try search("🥑", "$", "\\x{1F34E}")).hits.first?.replacement == "🍎",
                "astral escape in the replacement format is written as a surrogate pair")
            check(ranges(try search("🥑a", "a", whole: true)) == [at(2, 1)], "whole word after an emoji still matches")
            check(
                ranges(try search("\u{1D400}b", "\\w+", whole: true)) == [at(0, 3)],
                "an astral letter and a BMP letter are one regex word")
            check(
                ranges(try search("🥑é", "É", caseSensitive: false)) == [at(2, 1)],
                "case-insensitive regex after an emoji reports the UTF-16 range")
            check(
                try ranges(try search("a🥑b🥑c", "🥑", "X")) == [at(1, 2), at(4, 2)]
                    && ranges(try search("🥑🥑🥑abc🥑", "b")) == [at(7, 1)],
                "UTF-16 offsets stay exact after several astral characters")
            rejects("format producing half a surrogate pair is still refused", message: "surrogate") {
                _ = try search("a", "a", "\\x{D83D}")
            }
            let lone = NSString(characters: [0x61, 0xD83D, 0x62], length: 3) as String
            let loneDots = try search(lone, ".")
            check(
                ranges(loneDots) == [at(0, 1), at(1, 1), at(2, 1)],
                "text with an unpaired surrogate is searched unit by unit without a crash")
            rejects("an unpaired surrogate captured from the text is never written back", message: "surrogate") {
                _ = try search(lone, "(.)", "$1")
            }
            // 524,288 astral characters are 1 Mi UTF-16 units: 70 copies pass the 64 Mi limit only if
            // an astral character counts as two units; 60 copies stay below it.
            var expanding = SearchOptions()
            expanding.query = "a"
            expanding.replacement = String(repeating: "🥑", count: 512 * 1024)
            expanding.mode = .regularExpression
            rejects("expansion limit counts astral output as two UTF-16 units", message: "64 Mi") {
                _ = try SearchCore.search(String(repeating: "a", count: 70), options: expanding, timeLimit: 30)
            }
            check(
                try SearchCore.search(String(repeating: "a", count: 60), options: expanding, timeLimit: 30).hits.count
                    == 60, "expansion below the UTF-16 limit is accepted")
            // F23: regex mode folds case and classifies words by Unicode, as literal mode does.
            check(
                try ranges(try search("CAFÉ café", "café", caseSensitive: false)) == [at(0, 4), at(5, 4)]
                    && ranges(try search("CAFÉ café", "café")) == [at(5, 4)],
                "regex case folding covers non-ASCII letters")
            check(
                ranges(try search("café 中文", "\\w+")) == [at(0, 4), at(5, 2)], "regex word class covers non-ASCII")
            check(
                try search("café", "caf\\b").hits.isEmpty
                    && ranges(try search("cafés café", "café", whole: true)) == [at(6, 4)],
                "regex word boundary and Whole word agree on a non-ASCII letter")
            check(
                ranges(try search("CAFÉ", "[a-z]+", caseSensitive: false)) == [at(0, 3)],
                "explicit ASCII range is unchanged by Unicode folding")
            check(
                try ranges(search("١٢٣ 123", "\\d+")) == [at(4, 3)]
                    && ranges(search("١٢٣ 123", "[[:digit:]]+")) == [at(4, 3)]
                    && ranges(search("١a 1", "[\\d\\s]+")) == [at(2, 2)]
                    && ranges(search("١1", "\\D")) == [at(0, 1)],
                "regex digit class stays ASCII, as it was")
            check(
                try ranges(search("١٢٣ 123", "\\w+")) == [at(0, 3), at(4, 3)]
                    && search("١٢٣", "٢", mode: .normal, whole: true).hits.isEmpty,
                "non-ASCII digits are word characters in regex and Whole word alike")
            // F27: a rejected whole-word candidate must not hide an overlapping valid one.
            let overlap = try search("xab ab ab", "ab ab", "X", mode: .normal, whole: true)
            check(ranges(overlap) == [at(4, 5)], "whole word finds the occurrence overlapping a rejected candidate")
            check(
                try SearchCore.replacing("xab ab ab", with: overlap.hits) == "xab X",
                "whole-word hits after a rejected candidate do not overlap")
            check(
                ranges(try search("ab ab ab", "ab ab", mode: .normal, whole: true)) == [at(0, 5)],
                "accepted whole-word matches still advance past themselves")
            check(
                ranges(try search("🥑ab ab", "ab", mode: .normal, whole: true)) == [at(2, 2), at(5, 2)],
                "whole word beside a surrogate pair")
            check(
                try search("abc", "ab|abc", whole: true).hits.isEmpty,
                "regex whole word does not retry a rejected match (pinned; see F27)")
            // G349: astral letters are word characters on both sides, in both branches.
            for mode in [SearchOptions.Mode.normal, .regularExpression] {
                let name = mode == .normal ? "literal" : "regex"
                check(
                    try search("\u{1D431}ab", "ab", mode: mode, whole: true).hits.isEmpty,
                    "\(name) whole word rejected after an astral letter")
                check(
                    try search("ab\u{20000}", "ab", mode: mode, whole: true).hits.isEmpty,
                    "\(name) whole word rejected before an astral letter")
                check(
                    ranges(try search("🥑ab🥑", "ab", mode: mode, whole: true)) == [at(2, 2)],
                    "\(name) whole word accepted between plain emoji")
                check(
                    ranges(try search("ab \u{1D431}ab", "ab", mode: mode, whole: true)) == [at(0, 2)],
                    "\(name) whole word keeps only the occurrence not joined to an astral letter")
            }
            // F37: a range is searched inside the full text.
            for mode in [SearchOptions.Mode.normal, .regularExpression] {
                let name = mode == .normal ? "literal" : "regex"
                check(
                    try search("foobar foo", "foo", mode: mode, whole: true, range: at(0, 3)).hits.isEmpty,
                    "\(name) ranged whole word sees the letter after the range")
                check(
                    ranges(try search("foobar foo", "foo", mode: mode, whole: true, range: at(7, 3))) == [at(7, 3)],
                    "\(name) ranged hit is reported at its absolute location")
                check(
                    try search("xfoo", "foo", mode: mode, whole: true, range: at(1, 3)).hits.isEmpty,
                    "\(name) ranged whole word sees the letter before the range")
                check(
                    ranges(try search("🥑 foo foo foo", "foo", mode: mode, range: at(7, 7))) == [at(7, 3), at(11, 3)],
                    "\(name) ranged search stays inside the range after an astral prefix")
                check(
                    try search("foo", "foo", mode: mode, range: at(1, 2)).hits.isEmpty
                        && (try search("foo", "foo", mode: mode, range: at(0, 2))).hits.isEmpty,
                    "\(name) match may not extend past either end of the range")
                check(
                    message { _ = try search("abc", "a", mode: mode, range: at(2, 2)) }.contains("range")
                        && message { _ = try search("🥑", "a", mode: mode, range: at(1, 1)) }.contains("range"),
                    "\(name) range outside the text or inside a surrogate pair is refused")
            }
            check(ranges(try search("ab", "(?<=a)b", range: at(1, 1))) == [at(1, 1)], "ranged lookbehind sees the text")
            check(
                try search("ax", "^x", range: at(1, 1)).hits.isEmpty
                    && ranges(try search("a\nx", "^x", range: at(2, 1))) == [at(2, 1)],
                "ranged line start anchor uses the real line start")
            check(
                try search("xa", "x$", range: at(0, 1)).hits.isEmpty
                    && ranges(try search("x\na", "x$", range: at(0, 1))) == [at(0, 1)]
                    && ranges(try search("ax", "x$", range: at(1, 1))) == [at(1, 1)]
                    && ranges(try search("x\r\na", "x$", range: at(0, 1))) == [at(0, 1)]
                    && (try search("x\r\na", "\\r$", range: at(0, 2))).hits.isEmpty,
                "ranged line end anchor uses the real line end")
            check(try search("ab", "\\bb", range: at(1, 1)).hits.isEmpty, "ranged word boundary sees the text before")
            check(try search("ab", "\\Ab", range: at(1, 1)).hits.isEmpty, "ranged buffer start is the text start")
            check(
                ranges(try search("foo bar", "\\w+", range: at(0, 6))) == [at(0, 3), at(4, 2)],
                "ranged match is truncated at the range end")
            let rangedEmpty = try search("xab\nx", "(?=.)|$", "_", range: at(1, 2))
            check(
                ranges(rangedEmpty) == [at(1, 0), at(2, 0), at(3, 0)],
                "ranged zero-width matches progress and include the range end")
            check(
                try SearchCore.replacing("xab\nx", with: rangedEmpty.hits) == "x_a_b_\nx",
                "ranged zero-width replacements land at their absolute offsets")
            check(
                ranges(try search("xabx", "(?=.)|$", range: at(1, 2))) == [at(1, 0), at(2, 0)],
                "ranged zero-width matches stop where the range ends mid-line")
            check(
                try search("ab ab", "b", "[$`]", range: at(3, 2)).hits.first?.replacement == "[a]",
                "ranged prefix reference starts at the range, as a substring search did")
            var rangedOptions = SearchOptions()
            rangedOptions.query = "a"
            let rangedLimit = try SearchCore.search("aaaaa", options: rangedOptions, range: at(1, 3), limit: 2)
            check(
                rangedLimit.truncated && rangedLimit.hits.map(\.range) == [at(1, 1), at(2, 1)],
                "ranged result cap reports truncation")
            let rangedAll = try SearchCore.search("aaaaa", options: rangedOptions, range: at(1, 3), limit: 3)
            check(!rangedAll.truncated && rangedAll.hits.count == 3, "ranged result cap counts only hits in the range")
            // F210/F29: typed results and full-text requests preserve UTF-16 ranges and expansion.
            let typed = try TTSearchEngine.searchText(
                "a b", range: at(0, 3), query: "\\w", replacement: "<$0>", mode: .regularExpression, matchCase: true,
                wholeWord: false,
                dotMatchesNewline: false, cancellation: TTSearchCancellation(), maximumMatches: 1, timeLimit: 2)
            check(
                typed.truncated && typed.matches.count == 1 && typed.matches[0].range == at(0, 1)
                    && typed.matches[0].replacement == "<a>", "typed search result carries range and replacement")
            let fullText = try TTSearchEngine.searchText(
                "a b", range: at(0, 3), query: "\\w", replacement: "<$0>", mode: .regularExpression,
                matchCase: true, wholeWord: false, dotMatchesNewline: false,
                cancellation: TTSearchCancellation(), maximumMatches: 5, timeLimit: 2)
            check(
                !fullText.truncated && fullText.matches.map(\.range) == [at(0, 1), at(2, 1)]
                    && fullText.matches.map(\.replacement) == ["<a>", "<b>"],
                "typed full-text request returns the same UTF-16 matches and replacements")
            var bad = SearchOptions()
            bad.query = "a"
            check(
                message { _ = try SearchCore.search("a", options: bad, limit: 0) }.contains("result limit")
                    && message { _ = try SearchCore.search("a", options: bad, limit: 100001) }.contains("result limit"),
                "result limit outside its bounds is named")
            check(
                message { _ = try SearchCore.search("a", options: bad, timeLimit: 0) }.contains("time limit")
                    && message { _ = try SearchCore.search("a", options: bad, timeLimit: 31) }.contains("time limit"),
                "time limit outside its bounds is named")
            bad.replacement = String(repeating: "r", count: 1024 * 1024 + 1)
            check(
                message { _ = try SearchCore.search("a", options: bad) }.contains("replacement"),
                "oversized replacement is named")
            bad.replacement = ""
            bad.query = String(repeating: "q", count: 65537)
            check(
                message { _ = try SearchCore.search("a", options: bad) }.contains("search expression"),
                "oversized search expression is named")
            var overlapping = SearchOptions(query: "aa", replacement: "X", matchCase: true)
            let allAA = try SearchCore.search("aaa", options: overlapping)
            let nextAA = try SearchCore.search("aaa", options: overlapping, purpose: .navigation)
            check(
                allAA.hits.map(\.range) == [NSRange(location: 0, length: 2)]
                    && nextAA.hits.map(\.range) == [NSRange(location: 0, length: 2), NSRange(location: 1, length: 2)],
                "navigation purpose enumerates overlapping literals while Find All remains nonoverlap")
            let boundedAA = try SearchCore.search("aaa", options: overlapping, limit: 1, purpose: .navigation)
            check(
                boundedAA.hits.count == 1 && boundedAA.truncated, "overlapping navigation keeps the existing result cap"
            )
            overlapping.query = "😀😀"
            check(
                try SearchCore.search("😀😀😀", options: overlapping, purpose: .navigation).hits.map(\.range)
                    == [NSRange(location: 0, length: 4), NSRange(location: 2, length: 4)],
                "overlapping navigation advances past whole astral scalars")
            overlapping.query = "\u{301}\u{301}"
            check(
                try SearchCore.search("e\u{301}\u{301}\u{301}", options: overlapping, purpose: .navigation).hits.map(
                    \.range)
                    == [NSRange(location: 1, length: 2), NSRange(location: 2, length: 2)],
                "overlapping navigation advances by scalar rather than grapheme")
            overlapping.query = #"\x61\x61"#
            overlapping.mode = .extended
            check(
                try SearchCore.search("aaa", options: overlapping, purpose: .navigation).hits.count == 2
                    && SearchCore.search("aaa", options: overlapping).hits.count == 1,
                "extended literals share the navigation-purpose matcher")
            bad.query = ""
            check(
                message { _ = try SearchCore.search("a", options: bad) }.contains("nonempty"),
                "empty search expression is named")
            check(
                message {
                    _ = try TTSearchEngine.searchText(
                        "a", range: at(0, 1), query: "a", replacement: "", mode: TTSearchMode(rawValue: 3)!,
                        matchCase: true, wholeWord: false,
                        dotMatchesNewline: false, cancellation: TTSearchCancellation(), maximumMatches: 1, timeLimit: 2)
                }.contains("mode"), "unknown search mode is named")
            check(
                message {
                    _ = try SearchCore.bookmarkLines(in: "abc", locations: [2, 1], cancellation: TTSearchCancellation())
                }.contains("ascending")
                    && message {
                        _ = try SearchCore.bookmarkLines(
                            in: "abc", locations: [9], cancellation: TTSearchCancellation())
                    }.contains("past the end"), "bookmark offset errors carry a description")
            // F228: one compilation per pattern and flag set across consecutive searches.
            let compiledBefore = TTSearchEngine.regexCompilationCount()
            for file in ["one cache1", "two cache1", "three"] { _ = try search(file, "cache1\\d*") }
            check(
                TTSearchEngine.regexCompilationCount() == compiledBefore + 1,
                "the same regex is compiled once for consecutive searches")
            _ = try search("x", "cache1\\d*", caseSensitive: false)
            check(
                TTSearchEngine.regexCompilationCount() == compiledBefore + 2,
                "a different flag set compiles again")
            check(
                try ranges(try search("CACHE1 cache12", "cache1\\d*", caseSensitive: false)) == [at(0, 6), at(7, 7)]
                    && ranges(try search("CACHE1 cache12", "cache1\\d*")) == [at(7, 7)],
                "cached patterns keep their own case flag")
            let chunked = String(repeating: "ab🥑", count: 100000) + "Z"
            check(
                try ranges(try search(chunked, "Z")) == [at(400000, 1)]
                    && (try search(chunked, "🥑")).hits.count == 100000,
                "bulk-copied input keeps every surrogate pair and offset")
            // Searches run on background tasks, so two can compile and match at once. Before Boost's
            // locks were enabled this aborted the process inside its traits cache.
            let mismatches = SearchMismatchCounter()
            DispatchQueue.concurrentPerform(iterations: 16) { worker in
                var concurrent = SearchOptions()
                concurrent.mode = .regularExpression
                for turn in 0..<300 {
                    concurrent.query = turn % 2 == 0 ? "a+\(worker % 3)" : "b+"
                    let found = (try? SearchCore.search("aa\(worker % 3) bb", options: concurrent).hits.count) ?? -1
                    if found != 1 {
                        mismatches.record()
                    }
                }
            }
            check(
                mismatches.count == 0,
                "regex searches on sixteen threads at once compile, share the cache and match correctly")
            // F162: one cursor converts offsets for in-document and folder search alike.
            var cursor = SearchCore.UTFCursor("é\r\n🥑x\ry", tracksLines: true)
            check(
                cursor.advance(to: 3) && cursor.byteOffset == 4 && cursor.line == 2 && cursor.columnUTF16 == 1,
                "cursor counts CRLF as one line break and é as two bytes")
            check(!cursor.advance(to: 4), "cursor refuses a target inside a surrogate pair")
            var later = SearchCore.UTFCursor("é\r\n🥑x\ry", tracksLines: true)
            check(
                later.advance(to: 7) && later.byteOffset == 10 && later.line == 3 && later.columnUTF16 == 1
                    && !later.advance(to: 6) && !later.advance(to: 9),
                "cursor follows a lone CR, and refuses to go back or past the end")
            var stopped = SearchCore.UTFCursor("abc")
            check(!stopped.advance(to: 2, stop: { true }), "cursor stops when asked")
            let pair = "a🥑" as NSString
            check(
                SearchCore.isScalarBoundary(0, in: pair) && SearchCore.isScalarBoundary(1, in: pair)
                    && !SearchCore.isScalarBoundary(2, in: pair) && SearchCore.isScalarBoundary(3, in: pair),
                "only the middle of a surrogate pair is not a boundary")
            let chosen = NSRange(location: 4, length: 2)
            func candidate(_ location: Int, _ length: Int, backwards: Bool, continuing: Bool = false) -> Bool {
                SearchCore.isNavigationCandidate(
                    NSRange(location: location, length: length), from: chosen, backwards: backwards,
                    continuing: continuing)
            }
            check(
                candidate(6, 2, backwards: false) && !candidate(5, 2, backwards: false)
                    && candidate(2, 2, backwards: true) && !candidate(3, 2, backwards: true),
                "Next takes matches after the selection and Previous matches before it")
            let caret = NSRange(location: 4, length: 0)
            check(
                SearchCore.isNavigationCandidate(caret, from: caret, backwards: false, continuing: false)
                    && !SearchCore.isNavigationCandidate(caret, from: caret, backwards: false, continuing: true)
                    && !SearchCore.isNavigationCandidate(caret, from: caret, backwards: true, continuing: true),
                "a zero-width match just chosen is not chosen again")
            Checks.summary { "PASS SearchChecks: \(Checks.count) assertions" }
        }
    }
}

/// The complete shared mismatch count is private and lock-protected.
private final class SearchMismatchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func record() {
        lock.lock()
        value += 1
        lock.unlock()
    }
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
