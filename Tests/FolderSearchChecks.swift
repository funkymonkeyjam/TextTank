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
            let malformedReport = try await FolderSearch.search(malformed)
            check(
                !malformedReport.isComplete && malformedReport.matches.isEmpty
                    && malformedReport.skipped.contains {
                        if case .unreadable(let reason) = $0.reason { return reason.hasPrefix("Search:") }
                        return false
                    }, "invalid folder regex explicit per-file failure")
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
            Checks.summary {
                "PASS FolderSearchChecks: \(Checks.count) assertions; normal/extended/Boost cases, no complete parity or disk replacement claim"
            }
        }
    }
}
