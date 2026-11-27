// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Darwin
import EditorBridge
import NativeSearch
@testable import TextTankCore
@testable import TextTankRuntime

/// The full tier runs each scenario in a fresh process so peak RSS can be attributed to that scenario.
/// Timings and high-water marks are observational. Correctness and successful publication are checked.
@main enum SwiftPerformanceChecks {
    private static let mib = 1_048_576
    private static func now() -> Double { ProcessInfo.processInfo.systemUptime }
    private static func peak() throws -> Int {
        var sample = rusage()
        try require(getrusage(RUSAGE_SELF, &sample) == 0, "read process high-water RSS")
        return sample.ru_maxrss // Darwin reports bytes.
    }
    private static func metric(_ name: String, since start: Double, initialPeak: Int) throws {
        let end = now(), high = try peak()
        print(
            String(
                format: "SWIFT_PERF %@ elapsed_s=%.6f peak_rss_bytes=%ld peak_growth_bytes=%ld",
                name, end - start, high, high - initialPeak))
        fflush(stdout)
    }
    private static let chunk = Data(
        String(
            repeating: "let value = 42 // " + String(repeating: "a", count: 109) + "\n",
            count: 512
        ).utf8)
    private static func fixture(_ file: URL, bytes: Int) throws {
        try require(chunk.count == 65536 && bytes.isMultiple(of: chunk.count), "exact streaming fixture geometry")
        try Data().write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        for _ in 0..<(bytes / chunk.count) { try handle.write(contentsOf: chunk) }
    }
    @MainActor private static func wait(_ label: String, until predicate: () -> Bool) throws -> Double {
        let deadline = now() + 120
        var last = now(), longest = 0.0
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
            let tick = now()
            longest = max(longest, tick - last)
            last = tick
        } while !predicate() && now() < deadline
        try require(predicate(), label)
        return longest
    }
    @MainActor private static func documentCase(_ mode: String, in root: URL) throws {
        let size = (mode == "recovery64" ? 64 : 32) * mib
        let url = root.appendingPathComponent("owned.swift")
        try fixture(url, bytes: size)
        let beforeOpen = try peak(), t0 = now()
        let doc = TextDocument()
        doc.fileURL = url
        doc.fileType = TextDocument.plainTextType
        try doc.read(from: url, ofType: TextDocument.plainTextType)
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        defer { doc.close() }
        if mode == "open32" {
            try metric("open32", since: t0, initialPeak: beforeOpen)
            let view = doc.editor
            doc.presentation?.hostWindow?.contentView?.layoutSubtreeIfNeeded()
            let bitmap = try requireValue(
                view.bitmapImageRepForCachingDisplay(in: view.bounds), "offscreen editor bitmap")
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try metric("open32_through_offscreen_paint", since: t0, initialPeak: beforeOpen)
            var colors = Set<NSColor>()
            for x in stride(from: 160, to: min(bitmap.pixelsWide, 600), by: 3) {
                for y in stride(from: max(0, bitmap.pixelsHigh - 110), to: bitmap.pixelsHigh - 15, by: 3) {
                    if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0 { colors.insert(color) }
                }
            }
            check(
                colors.count > 3 && view.byteLength == size && !doc.isDocumentEdited,
                "normal document open populates and renders the full UTF-8 fixture")
            print(
                "SWIFT_PERF open_language=\(doc.languageIdentifier) bytes=\(view.byteLength) bitmap=\(bitmap.pixelsWide)x\(bitmap.pixelsHigh)"
            )
            return
        }
        try require(doc.editor.setSelectionAnchor(size, caret: size), "valid end-of-document caret")
        let initialPeak = try peak(), editStart = now()
        try require(doc.editor.replaceSelection("!"), "one genuine native edit")
        if mode == "save32" {
            let start = now()
            var complete = false, failure: Error?
            doc.save(to: url, ofType: TextDocument.plainTextType, for: .saveOperation) { error in
                failure = error
                complete = true
            }
            let tick = try wait("ordinary safe save completed") { complete }
            if let failure { throw failure }
            try metric("save32", since: start, initialPeak: initialPeak)
            print(String(format: "SWIFT_PERF save32 max_main_tick_s=%.6f", tick))
            let saved = try Data(contentsOf: url, options: .mappedIfSafe)
            let originalIntact =
                saved.count == size + 1
                && saved.withUnsafeBytes { buffer in
                    chunk.withUnsafeBytes { expected in
                        stride(from: 0, to: size, by: chunk.count).allSatisfy { offset in
                            memcmp(buffer.baseAddress!.advanced(by: offset), expected.baseAddress!, chunk.count) == 0
                        }
                    }
                }
            check(
                originalIntact && saved.last == 33 && !doc.isDocumentEdited,
                "safe save publishes the edited fixture and clears the dirty state")
            return
        }
        if mode == "recovery64" {
            // Fire the exact one-shot installed by the ordinary edit. This isolates the
            // synchronous capture/enqueue call from the idle interval and the background writer.
            let timer = try requireValue(
                Mirror(reflecting: doc).children.first { $0.label == "recoveryTimer" }?.value as? Timer,
                "edit installed the production idle recovery timer")
            let start = now()
            timer.fire()
            try metric("recovery64_main_capture_and_enqueue", since: start, initialPeak: initialPeak)
        }
        let tick = try wait("automatic recovery reached confirmed save state") {
            doc.currentSaveStateStatus.contains("recovery copy kept")
        }
        try metric(mode, since: editStart, initialPeak: initialPeak)
        print(String(format: "SWIFT_PERF %@ max_main_tick_s=%.6f", mode, tick))
        let recovered = try TextDocument.recovery.load(id: doc.recoveryID)
        let disk = try Data(contentsOf: url, options: .mappedIfSafe)
        let utf8 = recovered.text.utf8
        check(
            utf8.count == size + 1 && utf8.last == 33 && utf8.dropLast().elementsEqual(disk)
                && doc.isDocumentEdited, "confirmed recovery retains every edited byte and preserves the original file")
    }
    @MainActor private static func replaceAll(using service: AppDelegate) throws {
        let document = DocumentFactory.makeUntitled(display: false)
        defer { document.close() }
        let source = String(repeating: "x\n", count: 100_000)
        _ = document.editor.loadDocumentText(source)
        let presentation = try requireValue(document.presentation, "owned document presentation")
        service.noteActive(presentation)
        let search = service.searchController
        search.queryField.stringValue = "x"
        search.replacementField.stringValue = "y"
        let before = try peak(), start = now()
        search.replaceAll(nil)
        let tick = try wait("actual Find and Replace action completed") { !search.isSearching }
        try metric("replace100k", since: start, initialPeak: before)
        print(String(format: "SWIFT_PERF replace100k max_main_tick_s=%.6f", tick))
        check(
            search.lastOutcome == .replaced(changed: 100_000, stale: 0)
                && document.editor.text == String(repeating: "y\n", count: 100_000),
            "current-document Replace All changes precisely 100,000 matches")
        document.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
        check(document.editor.text == source, "one native Undo restores all 100,000 matches")
        let overLimit = source + "x\n"
        _ = document.editor.loadDocumentText(overLimit)
        let revision = document.editor.revision
        search.replaceAll(nil)
        _ = try wait("over-limit comparison completed") { !search.isSearching }
        check(
            search.lastOutcome == .limitReached && document.editor.revision == revision
                && document.editor.text == overLimit,
            "100,001 matches preserve all bytes and the existing search cap")
    }
    /// V5: Find in a document above the 64 Mi UTF-16 limit, through the real Find and Replace
    /// window. The fixture is the existing streaming generator's, with three planted matches of
    /// multi-byte text: one across the first 4 MiB window boundary, one mid-document, one at the end.
    @MainActor private static func largeFind(using service: AppDelegate, in root: URL) throws {
        let size = 72 * mib
        let url = root.appendingPathComponent("large.txt")
        try fixture(url, bytes: size)
        let doc = TextDocument()
        doc.fileURL = url
        doc.fileType = TextDocument.plainTextType
        try doc.read(from: url, ofType: TextDocument.plainTextType)
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        defer { doc.close() }
        let editor = doc.editor
        let marker = "Straddle-\u{c9}\u{dc}\u{1F600}-Mark", length = marker.utf8.count
        // Descending, so an insertion never moves a position still to be used.
        let planted = [4 * mib - 7, 36 * mib + 12_345, size]
        for position in planted.reversed() {
            try require(editor.setSelectionAnchor(position, caret: position), "valid planting position")
            try require(editor.replaceSelection(marker), "planted match")
        }
        let starts = [planted[0], planted[1] + length, planted[2] + 2 * length]
        try require(
            editor.byteLength == size + 3 * length && SearchCore.isLarge(editor.utf8Data),
            "the fixture is above the engine's 64 Mi UTF-16 limit")
        let presentation = try requireValue(doc.presentation, "owned document presentation")
        service.noteActive(presentation)
        let search = service.searchController
        func selected(_ index: Int) -> Bool {
            editor.selectionStart == starts[index] && editor.selectionEnd == starts[index] + length
        }
        // Count, case-insensitively (decoded windows) and with Match case (bytes, no decoding).
        _ = editor.setSelectionAnchor(0, caret: 0)
        search.queryField.stringValue = marker.uppercased()
        var before = try peak(), start = now()
        search.findAll(nil)
        // What the main thread itself did before handing over: one copy of the bytes, and the
        // first time a count of their UTF-16 length.
        let handOver = now() - start
        check(search.isSearching, "the large count runs off the main thread")
        var tick = try wait("large case-insensitive count completed") { !search.isSearching }
        try metric("find72_count_folded", since: start, initialPeak: before)
        print(
            String(
                format: "SWIFT_PERF find72_count_folded max_main_tick_s=%.6f main_hand_over_s=%.6f", tick, handOver))
        check(handOver < 0.5 * budgetScale(), "starting a large search does not hold the main thread")
        check(
            search.lastOutcome == .found(matches: 3, documents: 1, truncated: false),
            "a literal Find above the limit reports the right count, with the boundary match counted once")
        check(tick < 0.5 * budgetScale(), "the window stays responsive while a 72 MiB document is counted")
        check(
            try peak() - before <= size + 64 * mib,
            "counting adds no more than one snapshot of the bytes and a few windows of working memory")
        search.caseButton.state = .on
        search.queryField.stringValue = marker
        before = try peak()
        start = now()
        search.findAll(nil)
        tick = try wait("large exact count completed") { !search.isSearching }
        try metric("find72_count_exact", since: start, initialPeak: before)
        print(String(format: "SWIFT_PERF find72_count_exact max_main_tick_s=%.6f", tick))
        check(
            search.lastOutcome == .found(matches: 3, documents: 1, truncated: false),
            "Match case counts the same three matches")
        search.caseButton.state = .off
        search.queryField.stringValue = marker.lowercased()
        // Next from the top finds the match that straddles the first window boundary; then on, and around.
        before = try peak()
        start = now()
        for index in [0, 1, 2, 0] {
            search.next(nil)
            _ = try wait("large Find Next completed") { !search.isSearching }
            check(
                selected(index) && search.lastOutcome == .movedToMatch,
                "Find Next reaches large-document match \(index + 1)")
        }
        try metric("find72_next_x4_with_wrap", since: start, initialPeak: before)
        start = now()
        search.previous(nil)
        tick = try wait("large Find Previous completed") { !search.isSearching }
        try metric("find72_previous_wrap", since: start, initialPeak: before)
        check(selected(2), "Find Previous from the first match wraps to the last, searching backwards")
        // The first visits made the editor lay out and style the places it was moved to. Now that
        // it has, six more searches may add one snapshot and its windows, not six snapshots.
        before = try peak()
        start = now()
        for index in [0, 1, 2, 0] {
            search.next(nil)
            _ = try wait("repeated large Find Next completed") { !search.isSearching }
            try require(selected(index), "repeated Find Next reaches match \(index + 1)")
        }
        for index in [2, 1] {
            search.previous(nil)
            _ = try wait("repeated large Find Previous completed") { !search.isSearching }
            try require(selected(index), "repeated Find Previous reaches match \(index + 1)")
        }
        try metric("find72_six_more_moves", since: start, initialPeak: before)
        check(
            try peak() - before <= size + 64 * mib,
            "repeated Find Next and Previous do not accumulate snapshots of the document")
        // The live count the find bar shows.
        let snapshot = editor.utf8Data
        before = try peak()
        start = now()
        let live = try SearchController.preview(
            snapshot, options: SearchOptions(query: marker.lowercased()), openingCaret: 0,
            cancellation: TTSearchCancellation())
        try metric("find72_live_count", since: start, initialPeak: before)
        check(
            live.countText == "1 of 3" && live.selected?.location == starts[0], "the live count works above the limit")
        // Cancel, then a regular expression, which says what to do instead.
        search.queryField.stringValue = "no such token anywhere"
        search.findAll(nil)
        search.cancel(nil)
        _ = try wait("cancelled large search settled") { !search.isSearching }
        check(search.lastOutcome == .cancelled, "a large search can be cancelled")
        search.mode.selectItem(at: SearchOptions.Mode.regularExpression.rawValue)
        search.queryField.stringValue = "Strad+le"
        search.findAll(nil)
        _ = try wait("large Regex refusal settled") { !search.isSearching }
        check(
            search.lastOutcome == .failed(SearchFailure.largeDocumentRegex.localizedDescription)
                && search.status.stringValue.contains("Normal"),
            "a Regex Find above the limit says so in plain words")
        search.mode.selectItem(at: 0)
        search.window?.close()
    }
    /// Fix round 2: a long search text, case-insensitively, in text with no ASCII. The engine
    /// then tries positions one at a time; this pins that it stays inside the large-document
    /// budget (two seconds per 64 MiB), and prints the rate (DS-101).
    private static func longNeedleInCJK() throws {
        let size = 16 * mib
        let line =
            String(repeating: "\u{65e5}\u{672c}\u{8a9e}\u{306e}\u{6587}\u{7ae0}\u{3092}\u{691c}\u{7d22}", count: 7)
            + "\n"
        var data = Data(capacity: size + 16_384)
        let unit = Data(line.utf8)
        while data.count < size { data.append(unit) }
        let needle = String(repeating: "\u{691c}\u{7d22}\u{3059}\u{308b}", count: 750)
        try require(needle.utf16.count == 3_000, "a 3,000-unit search text: above the by-position threshold")
        data.append(Data((needle + "\u{3002}").utf8))
        let budget = SearchCore.largeTimeLimit(bytes: 64 * mib) * Double(data.count) / Double(64 * mib)
        for (name, query, expected) in [("foldcjk_absent", needle + "\u{7121}", 0), ("foldcjk_found", needle, 1)] {
            let before = try peak(), start = now()
            let report = try SearchCore.searchBytes(data, options: SearchOptions(query: query), timeLimit: 600)
            let elapsed = now() - start
            try metric(name, since: start, initialPeak: before)
            print(
                String(
                    format: "SWIFT_PERF %@ mib_per_s=%.1f proportional_budget_s=%.3f", name,
                    Double(data.count) / Double(mib) / elapsed, budget))
            check(
                report.hits.count == expected,
                "\(name): the long case-insensitive search of CJK text finds exactly what is there")
            check(
                elapsed <= budget * budgetScale(),
                "\(name): a long case-insensitive search text in CJK text stays within the large-document budget")
        }
    }
    private static func budgetScale() -> Double {
        let parsed = ProcessInfo.processInfo.environment["TEXTTANK_PERF_BUDGET_SCALE"].flatMap(Double.init) ?? 1
        return parsed > 0 ? parsed : 1
    }
    @MainActor static func main() {
        Checks.run("SwiftPerformanceChecks") {
            let mode = try requireValue(CommandLine.arguments.dropFirst().first, "selected performance workload")
            try require(
                ["open32", "save32", "recovery32", "recovery64", "replace100k", "find72", "foldcjk"].contains(mode),
                "known workload")
            let support = try IsolatedSupportDirectory("SwiftPerformance")
            defer { support.restore() }
            let app = NSApplication.shared
            var effects = RuntimeDependencies()
            effects.readFindText = { "" }
            effects.writeFindText = { _ in }
            effects.generalPasteboard = { nil }
            effects.announce = { _, _ in }
            RuntimeEnvironment.dependencies = effects
            WindowFrames.defaults = UserDefaults(suiteName: "SwiftPerformance-" + UUID().uuidString)!
            LanguageController.bundledCatalogURL = TestPaths.resources.appendingPathComponent("LanguageProfiles.json")
            app.finishLaunching()
            let documents = TextDocumentController(), delegate = AppDelegate()
            delegate.installEditorServices()
            if mode == "replace100k" {
                try replaceAll(using: delegate)
            } else if mode == "find72" {
                try largeFind(using: delegate, in: support.url)
            } else if mode == "foldcjk" {
                try longNeedleInCJK()
            } else {
                try documentCase(mode, in: support.url)
            }
            withExtendedLifetime(documents) {}
            withExtendedLifetime(delegate) {}
        }
    }
}
