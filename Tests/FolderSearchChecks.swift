@testable import TextTankCore
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

@main struct FolderSearchChecks {
    static func main() async {
        await Checks.run("FolderSearchChecks") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "TextTankFolderSearch-" + UUID().uuidString
            ).resolvingSymlinksInPath()
            let outside = root.deletingLastPathComponent().appendingPathComponent(
                "TextTankSearchOutside-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: root)
                try? FileManager.default.removeItem(at: outside)
            }
            let displayRoot = root.appendingPathComponent("display-columns")
            try FileManager.default.createDirectory(at: displayRoot, withIntermediateDirectories: true)
            try Data("\t😀e\u{301}x\r\n".utf8).write(to: displayRoot.appendingPathComponent("columns.txt"))
            var displayRequest = FolderSearchRequest(directory: displayRoot, query: "x")
            displayRequest.displayTabWidth = 8
            let displayResult = try await FolderSearch.search(displayRequest)
            displayRequest.displayTabWidth = 4
            check(
                displayResult.matches.count == 1 && displayResult.matches[0].columnUTF16 == 6
                    && displayResult.matches[0].displayColumn == 12 && displayResult.matches[0].displayTabWidth == 8
                    && displayResult.matches[0].utf8Range.location == 8,
                "G346 disk result captures tab stops while preserving UTF16/byte navigation metadata")
            try FileManager.default.removeItem(at: displayRoot)
            let unicode = "α🦋x\r\nβ🦋\n🦋\rfinal🦋"
            let unicodeURL = root.appendingPathComponent("unicode.txt")
            try Data(unicode.utf8).write(to: unicodeURL)
            let utf16URL = root.appendingPathComponent("utf16.txt")
            let utf16 = try FileCodec.encode("one\n🦋", format: FileFormat(encoding: .utf16LE, bom: true))
            try utf16.write(to: utf16URL)
            try Data([0xFF]).write(to: root.appendingPathComponent("invalid.bin"))
            try Data("hidden 🦋".utf8).write(to: root.appendingPathComponent(".hidden.txt"))
            let nested = root.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try Data("nested 🦋".utf8).write(to: nested.appendingPathComponent("nested.txt"))
            try Data("outside 🦋".utf8).write(to: outside)
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("symlink.txt"), withDestinationURL: outside)
            var request = FolderSearchRequest(directory: root, query: "🦋")
            // F42: policy exclusions are only counted unless a request asks for the list. The
            // checks below that read individual exclusions ask for it; the default is checked
            // against the same tree further down.
            request.listsPolicyExclusions = true
            let report = try await FolderSearch.search(request)
            check(report.matches.count == 6, "recursive Unicode search across strict UTF8/UTF16")
            let hits = report.matches.filter { $0.url.lastPathComponent == unicodeURL.lastPathComponent }
            check(hits.map(\.line) == [1, 2, 3, 4], "CRLF LF CR line mapping")
            check(hits.map(\.columnUTF16) == [2, 2, 1, 6], "columns use documented UTF16 units")
            check(
                hits.map { $0.utf16Range.location } == [1, 7, 10, 18] && hits.allSatisfy { $0.utf16Range.length == 2 },
                "UTF16 emoji offsets exact")
            check(
                hits.map { $0.utf8Range.location } == [2, 11, 16, 26] && hits.allSatisfy { $0.utf8Range.length == 4 },
                "UTF8 emoji offsets exact")
            for hit in report.matches {
                let range = NSRange(location: hit.previewMatchRange.location, length: hit.previewMatchRange.length)
                check((hit.preview as NSString).substring(with: range) == "🦋", "preview highlight exact Unicode")
            }
            check(report.skipped.contains { $0.reason == .symbolicLink }, "symlink skipped explicitly")
            check(report.skipped.contains { $0.reason == .hidden }, "hidden file skipped explicitly")
            check(
                report.skipped.contains {
                    if case .invalidEncoding = $0.reason { return true }
                    return false
                }, "invalid bytes are reported, never replacement-decoded")
            check(try Data(contentsOf: unicodeURL) == Data(unicode.utf8), "search leaves source bytes unchanged")
            check(try Data(contentsOf: utf16URL) == utf16, "search leaves original UTF16 BOM intact")
            let utf16Hit = report.matches.first { $0.url.lastPathComponent == utf16URL.lastPathComponent }!
            check(
                utf16Hit.utf8Range.location == 4 && utf16Hit.utf16Range.location == 4,
                "BOM offsets refer to decoded editor model")
            request.recursive = false
            await checkAsync(
                try await FolderSearch.search(request).matches.count == 5, "nonrecursive scope excludes nested file")
            request.recursive = true
            request.includeHidden = true
            request.extensions = ["TXT"]
            let visible = try await FolderSearch.search(request)
            check(
                visible.matches.count == 7 && visible.skipped.contains { $0.reason == .extensionFiltered },
                "hidden opt-in and exact case-insensitive extension filter")
            check(visible.isComplete, "policy exclusions do not imply incomplete coverage")
            var counted = FolderSearchRequest(directory: root, query: "🦋")
            let countedReport = try await FolderSearch.search(counted)
            check(
                countedReport.matches == report.matches && countedReport.isComplete == report.isComplete
                    && countedReport.excludedCounts == report.excludedCounts,
                "counting exclusions changes no match, count or coverage verdict")
            check(
                countedReport.excludedCounts == [.symbolicLink: 1, .hidden: 1] && countedReport.excludedTotal == 2,
                "policy exclusions are counted by reason")
            check(
                countedReport.skipped.count == 1 && countedReport.skipped.allSatisfy { $0.reason.affectsCoverage }
                    && countedReport.notSearched == countedReport.skipped
                    && countedReport.skipped[0].url.lastPathComponent == "invalid.bin",
                "only entries that could not be searched are listed by default")
            check(
                report.skipped.count == 3 && report.notSearched.count == 1,
                "the opt-in list holds the exclusions as well as the entry that could not be searched")
            counted.extensions = ["none"]
            let allFiltered = try await FolderSearch.search(counted)
            check(
                allFiltered.skipped.isEmpty && allFiltered.isComplete
                    && allFiltered.excludedCounts[.extensionFiltered] == 4
                    && allFiltered.filesSearched == 0, "files left out by a filter cost a counter, not a list entry")
            check(!report.isComplete, "invalid encoding explicitly makes coverage incomplete")
            let literalURL = root.appendingPathComponent("literal.txt")
            try Data("a.*b A.*B café café\0tail".utf8).write(to: literalURL)
            var literal = FolderSearchRequest(directory: root, query: "a.*b")
            literal.matchCase = false
            await checkAsync(
                try await FolderSearch.search(literal).matches.count == 2,
                "regex metacharacters are literal and case option works")
            literal.matchCase = true
            await checkAsync(
                try await FolderSearch.search(literal).matches.count == 1, "case-sensitive literal distinction")
            var regex = FolderSearchRequest(directory: root, query: "[aA]\\.\\*[bB]")
            regex.mode = .regularExpression
            await checkAsync(
                try await FolderSearch.search(regex).matches.count == 2, "Boost folder pattern exact matches")
            var extended = FolderSearchRequest(directory: root, query: "\\0tail")
            extended.mode = .extended
            await checkAsync(try await FolderSearch.search(extended).matches.count == 1, "extended folder NUL query")
            var zero = FolderSearchRequest(directory: root, query: "(?=tail)")
            zero.mode = .regularExpression
            let zeros = try await FolderSearch.search(zero)
            check(zeros.matches.count == 1 && zeros.matches[0].utf8Range.length == 0, "zero-width folder offsets")
            var malformed = FolderSearchRequest(directory: root, query: "(")
            malformed.mode = .regularExpression
            // F200: an expression that cannot compile is one error before any file is read, on
            // both entry points. This check used to pin one "unreadable" skip per file.
            func invalidRequest(_ error: Error) -> Bool {
                if case FolderSearchError.invalidRequest(let reason)? = error as? FolderSearchError {
                    return !reason.isEmpty
                }
                return false
            }
            await rejects("invalid folder regex is one up-front error", where: invalidRequest) {
                _ = try await FolderSearch.search(malformed)
            }
            await rejects("invalid folder regex is one up-front error across roots", where: invalidRequest) {
                _ = try await FolderSearch.searchAcross(malformed, directories: [root])
            }
            let cancelledFirst = FolderSearchCancellation()
            cancelledFirst.cancel()
            await checkAsync(
                try await FolderSearch.search(regex, cancellation: cancelledFirst).wasCancelled,
                "a cancelled search with a valid expression still reports cancellation, not an error")
            let nul = try await FolderSearch.search(FolderSearchRequest(directory: root, query: "\0tail"))
            check(nul.matches.count == 1 && nul.matches[0].utf8Range.length == 5, "embedded NUL literal query retained")
            let crossing = try await FolderSearch.search(FolderSearchRequest(directory: root, query: "\r\nβ"))
            check(
                crossing.matches.count == 1 && crossing.matches[0].line == 1 && crossing.matches[0].columnUTF16 == 5
                    && crossing.matches[0].utf8Range.length == 4, "multiline literal range preserves CRLF and Unicode")
            let longQuery = String(repeating: "🦋", count: 20)
            try Data(("α" + longQuery + "tail").utf8).write(to: root.appendingPathComponent("long.txt"))
            var previewRequest = FolderSearchRequest(directory: root, query: longQuery)
            previewRequest.previewUTF16Length = 16
            let previewHit = try await FolderSearch.search(previewRequest).matches[0]
            check(
                previewHit.isMatchTruncatedInPreview && (previewHit.preview as NSString).length <= 16
                    && previewHit.utf8Range.length == 80,
                "bounded preview reports truncated match without changing full offsets")
            let composed = try await FolderSearch.search(FolderSearchRequest(directory: root, query: "café"))
            check(composed.matches.count == 1, "literal matching does not normalize decomposed spelling")
            var limited = FolderSearchRequest(directory: root, query: "🦋")
            limited.maximumResults = 1
            let resultLimit = try await FolderSearch.search(limited)
            check(
                resultLimit.matches.count == 1 && resultLimit.reachedLimit == .results && !resultLimit.isComplete,
                "result cap visibly marks truncated search")
            limited.maximumResults = 100
            limited.maximumEntries = 1
            let entryLimit = try await FolderSearch.search(limited)
            check(entryLimit.entriesVisited == 1 && entryLimit.reachedLimit == .entries, "entry traversal cap enforced")
            limited.maximumEntries = 100
            limited.maximumFiles = 1
            await checkAsync(try await FolderSearch.search(limited).reachedLimit == .files, "file count cap reported")
            limited.maximumFiles = 100
            limited.maximumTotalBytes = 2
            let byteLimit = try await FolderSearch.search(limited)
            check(
                byteLimit.reachedLimit == .totalBytes && byteLimit.bytesRead <= 2,
                "total read bytes bounded and reported")
            limited.maximumTotalBytes = 10000
            limited.maximumFileBytes = 2
            await checkAsync(
                try await FolderSearch.search(limited).skipped.contains { $0.reason == .fileTooLarge },
                "individual large file excluded with explicit reason")
            let token = FolderSearchCancellation()
            let cancelled = try await FolderSearch.search(
                request, cancellation: token,
                progress: { progress in if progress.filesSearched == 1 { token.cancel() } })
            check(
                cancelled.wasCancelled && cancelled.filesSearched == 1,
                "background progress supports cooperative cancellation with partial report")
            let task = Task { try await FolderSearch.search(request) }
            task.cancel()
            await checkAsync(try await task.value.wasCancelled, "Task cancellation propagated into detached search")
            let directoryLink = root.deletingLastPathComponent().appendingPathComponent(
                "TextTankSearchRootLink-" + UUID().uuidString)
            try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: root)
            defer { try? FileManager.default.removeItem(at: directoryLink) }
            await rejects("symlink root refused", where: { ($0 as? POSIXError)?.code == .ENOTDIR }) {
                _ = try await FolderSearch.search(FolderSearchRequest(directory: directoryLink, query: "x"))
            }
            await rejects("empty query refused", where: { $0 is FolderSearchError }) {
                _ = try await FolderSearch.search(FolderSearchRequest(directory: root, query: ""))
            }
            await rejects("remote directory refused", where: { $0 is FolderSearchError }) {
                _ = try await FolderSearch.search(
                    FolderSearchRequest(directory: URL(string: "https://example.com")!, query: "x"))
            }
            let fifo = root.appendingPathComponent("named-pipe")
            try require(mkfifo(fifo.path, mode_t(0o600)) == 0, "fixture: FIFO created")
            await checkAsync(
                try await FolderSearch.search(request).skipped.contains {
                    $0.url.lastPathComponent == fifo.lastPathComponent && $0.reason == .notRegularFile
                }, "FIFO skipped without blocking reader")
            // F200: once the expression compiles, a failure while searching one file skips that
            // file only. Catastrophic backtracking is stopped by the engine for the first file.
            let perFile = root.deletingLastPathComponent().appendingPathComponent(
                "TextTankFolderSearchPerFile-" + UUID().uuidString
            ).resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: perFile, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: perFile) }
            try Data(String(repeating: "x", count: 48).utf8).write(to: perFile.appendingPathComponent("slow.txt"))
            try Data("xxy".utf8).write(to: perFile.appendingPathComponent("quick.txt"))
            var costly = FolderSearchRequest(directory: perFile, query: "(x+x+)+y")
            costly.mode = .regularExpression
            let costlyReport = try await FolderSearch.search(costly)
            check(
                costlyReport.matches.map { $0.url.lastPathComponent } == ["quick.txt"] && !costlyReport.isComplete
                    && costlyReport.skipped.count == 1
                    && costlyReport.skipped.contains {
                        if case .unreadable(let reason) = $0.reason {
                            return reason.hasPrefix("Search:") && $0.url.lastPathComponent == "slow.txt"
                        }
                        return false
                    }, "a search failure in one file skips that file and the other file still matches")
            // F47 and F200: half a surrogate pair in an Extended query can never match a whole
            // character. It is refused once, up front, and no root is reported unreadable.
            try Data("ab😀cd".utf8).write(to: perFile.appendingPathComponent("emoji.txt"))
            try Data("abcd".utf8).write(to: perFile.appendingPathComponent("plain.txt"))
            var half = FolderSearchRequest(directory: perFile, query: "\\uD83D")
            half.mode = .extended
            await rejects("half a surrogate pair in a folder query is one up-front error", where: invalidRequest) {
                _ = try await FolderSearch.search(half)
            }
            var whole = FolderSearchRequest(directory: perFile, query: "cd")
            whole.mode = .extended
            await checkAsync(
                try await Set(FolderSearch.search(whole).matches.map { $0.url.lastPathComponent }) == [
                    "emoji.txt", "plain.txt"
                ], "an Extended query matches beside an emoji in every file")
            // F47: a range that splits a character is a nil for this file, never a thrown error
            // that would discard the whole root.
            check(
                FolderSearch.located([NSRange(location: 2, length: 1)], in: "ab😀cd", stop: { false }) == nil
                    && FolderSearch.located([NSRange(location: 4, length: 9)], in: "ab😀cd", stop: { false }) == nil
                    && FolderSearch.located(
                        [NSRange(location: 4, length: 1), NSRange(location: 2, length: 2)], in: "ab😀cd",
                        stop: { false }) == nil
                    && FolderSearch.located([NSRange(location: 0, length: 1)], in: "ab", stop: { true }) == nil,
                "a range that splits a character, runs past the end or goes backwards, or a stop, locates nothing")
            let positions = FolderSearch.located(
                [NSRange(location: 2, length: 2), NSRange(location: 6, length: 1)], in: "ab😀\r\ncd", stop: { false })
            check(
                positions?.count == 2 && positions?[0].line == 1 && positions?[0].columnUTF16 == 3
                    && positions?[0].utf8Range == SearchSpan(location: 2, length: 4) && positions?[1].line == 2
                    && positions?[1].columnUTF16 == 1 && positions?[1].utf8Range == SearchSpan(location: 8, length: 1),
                "whole-character ranges are located by line, column and UTF-8 span")
            check(
                FolderSearch.relativeComponents(of: "/r/a/\u{301}b/c", under: "/r/") ?? [] == ["a", "\u{301}b", "c"]
                    && FolderSearch.relativeComponents(of: "/r/a//b", under: "/r/") ?? [] == ["a", "b"],
                "relative components are split on the path separator byte")
            check(
                FolderSearch.relativeComponents(of: "/r/../x", under: "/r/") == nil
                    && FolderSearch.relativeComponents(of: "/r/./x", under: "/r/") == nil
                    && FolderSearch.relativeComponents(of: "/r/a\0b", under: "/r/") == nil
                    && FolderSearch.relativeComponents(of: "/r/", under: "/r/") == nil
                    && FolderSearch.relativeComponents(of: "/other/x", under: "/r/") == nil
                    && FolderSearch.relativeComponents(of: "/rr/x", under: "/r") == nil,
                "a path outside the root, or with a dot, dot-dot or NUL component, has no components")
            // G352: a name that starts with a combining mark is inside the root. Comparing
            // Characters fused the mark with the "/" before it.
            let marked = root.deletingLastPathComponent().appendingPathComponent(
                "TextTankFolderSearchMarks-" + UUID().uuidString
            ).resolvingSymlinksInPath()
            let markedDirectory = marked.appendingPathComponent("sub").appendingPathComponent("\u{301}dir")
            try FileManager.default.createDirectory(at: markedDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: marked) }
            try Data("needle".utf8).write(to: marked.appendingPathComponent("\u{301}lead.txt"))
            try Data("needle".utf8).write(to: markedDirectory.appendingPathComponent("inner.txt"))
            // G344: a decomposed file name, as an unzipped archive or a synced folder stores it.
            try Data("needle".utf8).write(to: marked.appendingPathComponent("cafe\u{301}.md"))
            let markedReport = try await FolderSearch.search(FolderSearchRequest(directory: marked, query: "needle"))
            check(
                markedReport.matches.count == 3 && markedReport.isComplete
                    && !markedReport.skipped.contains {
                        if case .unreadable = $0.reason { return true }
                        return false
                    }, "names that start with a combining mark are searched, at the root and below it")
            var composedFilter = FolderSearchRequest(directory: marked, query: "needle")
            composedFilter.filenameFilters = "caf\u{e9}*.md"
            await checkAsync(
                try await FolderSearch.search(composedFilter).matches.count == 1,
                "a composed filename filter finds a file whose name is stored decomposed")
            composedFilter.filenameFilters = "*.* !caf\u{e9}*.md"
            await checkAsync(
                try await FolderSearch.search(composedFilter).matches.count == 2,
                "a composed exclusion filter keeps a decomposed file name out of the results")
            Checks.summary {
                "PASS FolderSearchChecks: \(Checks.count) assertions; normal/extended/Boost cases, no complete parity or disk replacement claim"
            }
        }
    }
}
