// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Darwin
@testable import TextTankCore
@testable import TextTankRuntime
import EditorBridge

private final class CompareCountingEngine: ReviewDiffing, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    func compare(
        _ a: TextSnapshot, _ b: TextSnapshot, policy: ReviewDiffPolicy, token: ReviewCancellation,
        hooks: ReviewDiffHooks
    ) async -> ReviewChangeSet {
        increment()
        return await FirstPartyReviewDiff().compare(a, b, policy: policy, token: token, hooks: hooks)
    }
    private func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
private final class ComparePausedEngine: ReviewDiffing, @unchecked Sendable {
    private let lock = NSLock()
    private var paused = true, entries = 0, inFlight = 0, maximum = 0
    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
    var peak: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximum
    }
    func release() {
        lock.lock()
        paused = false
        lock.unlock()
    }
    private func enter() {
        lock.lock()
        entries += 1
        inFlight += 1
        maximum = max(maximum, inFlight)
        lock.unlock()
    }
    private func leave() {
        lock.lock()
        inFlight -= 1
        lock.unlock()
    }
    private func waiting() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return paused
    }
    func compare(
        _ a: TextSnapshot, _ b: TextSnapshot, policy: ReviewDiffPolicy, token: ReviewCancellation,
        hooks: ReviewDiffHooks
    ) async -> ReviewChangeSet {
        enter()
        defer { leave() }
        while waiting() && !token.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000) }
        return await FirstPartyReviewDiff().compare(a, b, policy: policy, token: token, hooks: hooks)
    }
}
private final class CompareFailingEngine: ReviewDiffing, @unchecked Sendable {
    private let lock = NSLock()
    private var fail = false
    func stopNext() {
        lock.lock()
        fail = true
        lock.unlock()
    }
    private func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let value = fail
        fail = false
        return value
    }
    func compare(
        _ a: TextSnapshot, _ b: TextSnapshot, policy: ReviewDiffPolicy, token: ReviewCancellation,
        hooks: ReviewDiffHooks
    ) async -> ReviewChangeSet {
        if take() {
            return ReviewChangeSet(
                original: a.id, modified: b.id, blocks: [], completeness: .budgetStopped(.work), metrics: .init())
        }
        return await FirstPartyReviewDiff().compare(a, b, policy: policy, token: token, hooks: hooks)
    }
}
@MainActor private final class CompareTickMeasurement {
    var latest = ProcessInfo.processInfo.systemUptime, maximum = 0.0, ticks = 0
    func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        maximum = max(maximum, now - latest)
        latest = now
        ticks += 1
    }
}
@MainActor private final class CompareCheckLaunch: NSObject, NSApplicationDelegate {
    var onLaunch: (() -> Void)?
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ notification: Notification) { onLaunch?() }
}
@main struct CompareControllerChecks {
    @MainActor static func main() {
        do {
            let isolated = try IsolatedSupportDirectory("D1Controllers")
            NativeFixtureEnvironment.install()
            let documents = TextDocumentController()
            let app = NSApplication.shared, launch = CompareCheckLaunch()
            app.setActivationPolicy(.regular)
            app.delegate = launch
            launch.onLaunch = {
                Task { await runChecks(isolated, documents, app) }
            }
            withExtendedLifetime(launch) { app.run() }
            Checks.fail("Owned comparison app stopped before completion", file: #filePath, line: #line)
        } catch { Checks.fail("Comparison process setup: \(error)", file: #filePath, line: #line) }
        Checks.finish("CompareControllerChecks")
    }
    @MainActor static func measuredOutcomeIsExpected(_ result: CompareController) -> Bool {
        if let projection = result.projection {
            return result.readyForMerge && projection.changes.completeness == .complete
        }
        // Both phases have a deadline. Diffing returns an incomplete change set; building
        // a projection throws a typed time limit. Neither can publish a partial comparison.
        let timedOut = "The comparison time limit was reached. No document was changed."
        return result.statusText == timedOut || result.statusText == "Incomplete comparison. " + timedOut
    }
    @MainActor static func runChecks(
        _ isolated: IsolatedSupportDirectory, _ documents: TextDocumentController, _ app: NSApplication
    ) async {
        await Checks.run("CompareControllerChecks") {
            check(
                app.isRunning && NSDocumentController.shared === documents,
                "D1 native checks own the real app event loop and document controller")
            try await SavedVersionChecks.run(in: isolated.url)
            let previous = EditorServices.current, delegate = AppDelegate()
            delegate.installEditorServices()
            LanguageController.bundledCatalogURL = TestPaths.resources.appendingPathComponent("LanguageProfiles.json")
            let host = delegate.workspaceWindow
            var services: [CompareService] = []
            defer {
                services.flatMap(\.windows).forEach { $0.window?.close() }
                host.tabCommands.isTerminating = true
                documents.documents.forEach { $0.close() }
                host.window?.orderOut(nil)
                EditorServices.current = previous
                NativeFixtureEnvironment.restore()
                isolated.restore()
            }
            @MainActor func fresh(_ text: String) -> TextDocument {
                DocumentFactory.makeUntitled(display: false, populate: { $0.editor.text = text })
            }
            @MainActor func input(_ doc: TextDocument, selection: Bool = false) throws -> CompareInput {
                .document(try CompareDocumentInput(doc.editor, selection: selection))
            }
            @MainActor func values(_ text: String) throws -> CompareInput {
                .snapshot(try TextSnapshot(bytes: Data(text.utf8), source: .freeText(UUID()), label: "Owned text"))
            }
            @MainActor func service(_ engine: any ReviewDiffing = FirstPartyReviewDiff()) -> CompareService {
                let value = CompareService(engine: engine)
                value.showWindows = false
                services.append(value)
                return value
            }
            @MainActor func settled(_ controller: CompareController) async throws {
                let end = ProcessInfo.processInfo.systemUptime + 8
                while (controller.isBusy || controller.hasPendingGeometry) && ProcessInfo.processInfo.systemUptime < end
                {
                    controller.window?.displayIfNeeded()
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                check(
                    !controller.isBusy && !controller.hasPendingGeometry, "D1 native controller reaches settled state")
            }
            struct State: Equatable {
                let bytes: Data, revision: UInt, dirty: Bool, selections: [SessionSelection], bookmarks: [NSNumber]
                @MainActor init(_ doc: TextDocument) {
                    bytes = doc.editor.utf8Data
                    revision = doc.editor.revision
                    dirty = doc.editor.modified
                    selections = doc.editor.selectionRanges.map { .init(anchorByte: $0.anchor, caretByte: $0.caret) }
                    bookmarks = doc.editor.bookmarkLines
                }
            }
            let a = fresh("start\nend\n"), b = fresh("start\nnew\nmore\nend\n")
            _ = a.editor.setSelectionAnchor(2, caret: 0)
            _ = a.editor.setBookmarks([0])
            _ = a.editor.setSearchHighlights([TTByteRange(location: 0, length: 4)])
            let sa = State(a), sb = State(b), engine = CompareCountingEngine(), compare = service(engine)
            let window = try await compare.open(original: input(a), modified: input(b))
            try await settled(window)
            check(
                window.projection != nil && window.projection?.changes.blocks.count == 1,
                "D1 two unsaved tabs compare without saving")
            check(
                window.left.editor.utf8Data == sa.bytes && window.right.editor.utf8Data == sb.bytes,
                "D1 exact independent renderer bytes")
            check(
                !window.left.editor.sharesDocument(with: a.editor)
                    && !window.right.editor.sharesDocument(with: b.editor), "D1 renderer is not a source clone")
            check(window.left.editor.readOnly && window.right.editor.readOnly, "D1 both renderers locked")
            check(
                window.left.editor.comparisonY(forByte: 6) + Int(window.left.editor.frame.minY) == window.right.editor
                    .comparisonY(forByte: 15) + Int(window.right.editor.frame.minY),
                "D1 actual controller unequal internal geometry aligns unchanged end")
            let sourceFont = a.editor.comparisonFont
            window.left.editor.comparisonFont = NSFont.monospacedSystemFont(
                ofSize: sourceFont.pointSize + 2, weight: .regular)
            try await Task.sleep(nanoseconds: 30_000_000)
            try await settled(window)
            check(
                window.left.editor.comparisonFont == window.right.editor.comparisonFont
                    && a.editor.comparisonFont == sourceFont,
                "D1 scratch zoom synchronizes peers without changing source font")
            window.window?.setContentSize(NSSize(width: 720, height: 420))
            try await settled(window)
            check(
                window.left.bounds.width >= 240 && window.right.bounds.width >= 240 && window.left.bounds.height > 100,
                "D1 minimum native layout keeps both text panes reachable")
            let count = engine.calls
            window.perform(.next)
            check(window.currentChange == 0, "D1 next navigation selects first block")
            window.perform(.unified)
            check(window.numberOfRows(in: window.unifiedTableView) > 0, "D1 unified table uses actual source rows")
            window.perform(.whitespace)
            try await settled(window)
            window.perform(.sideBySide)
            window.perform(.wrap)
            try await settled(window)
            window.perform(.linked)
            window.left.scroll(by: 2)
            window.perform(.collapse)
            try await settled(window)
            window.perform(.expandAll)
            try await settled(window)
            check(engine.calls == count, "D1 modes/options/navigation never recompute")
            check(State(a) == sa && State(b) == sb, "D1 viewing/options/navigation preserve both inputs")
            check(window.left.editor.selectionIsRectangular == false, "D1 typed stream selection query")
            a.editor.replaceSelection("changed")
            window.pollSources()
            check(window.outOfDate, "D1 completed source edit marks out of date")
            let old = window.projection?.original.id
            window.perform(.refresh)
            try await settled(window)
            check(
                window.projection?.original.id != old && !window.outOfDate,
                "D1 explicit refresh replaces captured generation")
            check(
                window.left.editor.utf8Data == a.editor.utf8Data, "D1 refreshed renderer matches exact current source")
            let nav = NSMenuItem(
                title: "Next", action: #selector(CompareController.performCompareCommand(_:)), keyEquivalent: "")
            nav.representedObject = CompareCommand.next.rawValue
            window.perform(.next)
            check(!window.validateMenuItem(nav), "D1 endpoint disables next without wrapping")
            window.window?.close()
            check(compare.windows.isEmpty, "D1 close releases service window membership")
            check(
                window.left.editor.byteLength == 0 && window.projection == nil,
                "D1 close releases render and projection content")
            let selected = fresh("a👩🏽‍💻b\n")
            _ = selected.editor.setSelectionAnchor(1, caret: 1 + "👩🏽‍💻".utf8.count)
            let selectionInput = try input(selected, selection: true)
            let clipService = service()
            var reads = 0
            check(
                ProcessInfo.processInfo.environment["TEXTTANK_TEST_PASTEBOARD"] == "1",
                "D1 private clipboard capability explicitly enabled")
            let board = NSPasteboard(name: .init("TextTank.D1.Private." + UUID().uuidString))
            board.clearContents()
            board.setString("a clipboard change", forType: .string)
            defer { board.releaseGlobally() }
            clipService.readClipboard = {
                reads += 1
                return (Data((board.string(forType: .string) ?? "").utf8), board.changeCount)
            }
            let selectionWindow = try await clipService.open(original: selectionInput, modified: .clipboard)
            try await settled(selectionWindow)
            check(
                reads == 1 && selectionWindow.original?.snapshot.bytes == Data("👩🏽‍💻".utf8),
                "D1 selection/clipboard captures exact chosen scope once")
            let beforeSelection = State(selected)
            selectionWindow.perform(.unified)
            selectionWindow.perform(.sideBySide)
            selectionWindow.pollSources()
            check(
                reads == 1 && State(selected) == beforeSelection,
                "D1 validation/view polling never rereads clipboard or source selection")
            check(
                selected.editor.setSelectionAnchor(1, caret: 5),
                "D1 fixture selects scalar-aligned portion of a grapheme")
            do {
                _ = try await clipService.capture(try input(selected, selection: true), token: ReviewCancellation())
                check(false, "D1 invalid grapheme refused")
            } catch { check(true, "D1 invalid grapheme refused without publishing") }
            _ = selected.editor.setSelectionAnchor(0, caret: 0)
            rejects("D1 empty selection refused") { _ = try input(selected, selection: true) }
            selectionWindow.window?.close()
            let identity = service()
            identity.currentEditor = { b.editor }
            try identity.mark(a.editor)
            check(
                identity.marked?.capture.snapshot.document?.documentID == a.runtimeID,
                "D1 mark records exact source document")
            check(
                !identity.canCompare(a.editor).0 && identity.canCompare(b.editor).0,
                "D1 same-document validation and distinct target")
            let menu = NSMenu()
            identity.addTabItems(to: menu) { b.editor }
            check(
                menu.items.contains { $0.title == "Select for Compare" }
                    && menu.items.contains { $0.title == "Compare with Selected" },
                "D1 tab menu exposes shared validated commands")
            let marked = identity.marked?.capture.snapshot.bytes
            a.editor.replaceSelection("later")
            check(
                identity.marked?.capture.snapshot.bytes == marked && !identity.canCompare(b.editor).0,
                "D1 marked bytes frozen and stale target needs reselection")
            a.close()
            check(identity.marked == nil, "D1 final close clears selected-for-compare mark")
            let v = service()
            let x = try await v.open(original: values("same\r\n"), modified: values("same\r\n"))
            try await settled(x)
            check(
                x.statusText.contains("Byte-identical text") && x.statusText.contains("encodings"),
                "D1 complete-only equality qualified as decoded text")
            let r = NSMenuItem(
                title: "Refresh", action: #selector(CompareController.performCompareCommand(_:)), keyEquivalent: "")
            r.representedObject = CompareCommand.refresh.rawValue
            check(!x.validateMenuItem(r), "D1 immutable-only comparison offers no invented refresh")
            var metrics = EditorSettings()
            metrics.fontName = "Monaco"
            metrics.fontSize = 18.75
            metrics.defaultZoom = 2
            x.applyFontSettings(metrics)
            try await settled(x)
            check(
                x.left.editor.comparisonFont == x.right.editor.comparisonFont
                    && x.left.editor.comparisonFont.fontName == "Monaco"
                    && x.left.editor.comparisonFont.pointSize == 20.75
                    && x.left.editor.comparisonLineHeight == x.right.editor.comparisonLineHeight,
                "a displayed immutable comparison updates both native row metrics together")
            x.left.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "zoomIn"))
            await waitUntil("the local comparison zoom to reach the other pane") {
                x.right.editor.comparisonFont.pointSize == 21.75
            }
            var bounded = metrics
            bounded.fontSize = 72
            bounded.defaultZoom = 40
            x.applyFontSettings(bounded)
            try await settled(x)
            check(x.left.editor.comparisonFont.pointSize == 96, "comparison display clamps large effective fonts")
            x.applyFontSettings(metrics)
            try await settled(x)
            check(
                x.left.editor.comparisonFont.pointSize == 21.75
                    && x.left.editor.comparisonFont == x.right.editor.comparisonFont,
                "a global round trip through the display limit preserves the independent comparison zoom")
            x.window?.close()
            let files = service(), folder = isolated.url.appendingPathComponent("compare-files", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let utf8 = folder.appendingPathComponent("a.txt"), utf16 = folder.appendingPathComponent("b.txt")
            try FileCodec.encode("\u{feff}exact\0\r\n", format: .init(encoding: .utf8, bom: true)).write(to: utf8)
            try FileCodec.encode("\u{feff}exact\0\r\n", format: .init(encoding: .utf16LE, bom: true)).write(to: utf16)
            let fileWindow = try await files.open(original: .file(utf8), modified: .file(utf16))
            try await settled(fileWindow)
            check(
                fileWindow.projection?.changes.identical == true,
                "D1 encoding/BOM differences do not fabricate text changes")
            check(
                fileWindow.original?.snapshot.format != fileWindow.modified?.snapshot.format,
                "D1 file metadata remains distinct")
            check(
                fileWindow.original?.label.contains("byte-order mark") == true,
                "D1 file metadata visible in captured label")
            let filesBefore = (try Data(contentsOf: utf8), try Data(contentsOf: utf16))
            fileWindow.window?.close()
            check(
                try Data(contentsOf: utf8) == filesBefore.0 && Data(contentsOf: utf16) == filesBefore.1,
                "D1 file comparison never writes disk")
            let malformed = folder.appendingPathComponent("invalid.txt")
            try Data([0xff, 0xfe, 0x00]).write(to: malformed)
            do {
                _ = try await files.open(original: .file(malformed), modified: .file(utf8))
                check(false, "D1 malformed file refusal")
            } catch { check(files.windows.isEmpty, "D1 file refusal opens no result window") }
            let same = service()
            do {
                _ = try await same.open(original: input(b), modified: input(b))
                check(false, "D1 shared entry same source")
            } catch {
                check(error as? CompareOpenFailure == .sameDocument, "D1 shared entry rejects same live document")
            }
            let quota = service(), q1 = try await quota.open(original: values("one"), modified: values("two"))
            let q2 = try await quota.open(original: values("three"), modified: values("four"))
            do {
                _ = try await quota.open(original: values("five"), modified: values("six"))
                check(false, "D1 third admission")
            } catch { check(error as? CompareOpenFailure == .limit, "D1 two-window admission is bounded") }
            q2.cancel(nil)
            q2.window?.close()
            q1.window?.close()

            let paused = ComparePausedEngine(), serial = service(paused)
            let first = try await serial.open(original: values("old"), modified: values("new"))
            let entered = ProcessInfo.processInfo.systemUptime + 2
            while paused.calls == 0 && ProcessInfo.processInfo.systemUptime < entered {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            check(paused.calls == 1, "D1 first queued pipeline entered actual injected engine")
            let second = try await serial.open(original: values("second"), modified: values("result"))
            try await Task.sleep(nanoseconds: 20_000_000)
            check(paused.calls == 1 && second.isBusy, "D1 one active comparison pipeline")
            second.perform(.cancel)
            second.window?.close()
            paused.release()
            try await settled(first)
            check(
                paused.calls == 1 && paused.peak == 1,
                "D1 cancelled queued result never starts and workers do not overlap")
            first.window?.close()

            let stopped = ComparePausedEngine(), stale = service(stopped), changing = fresh("captured\n")
            let running = try await stale.open(original: input(changing), modified: values("candidate\n"))
            changing.editor.replaceSelection("edit")
            running.pollSources()
            stopped.release()
            try await Task.sleep(nanoseconds: 30_000_000)
            check(running.projection == nil && running.outOfDate, "D1 source change during work drops late result")
            check(
                !running.statusText.contains("Byte-identical"),
                "D1 cancelled/stale in-flight result cannot imply equality")
            running.window?.close()

            let failing = CompareFailingEngine(), refreshService = service(failing), ra = fresh("same\n"),
                rb = fresh("same\n")
            let retained = try await refreshService.open(original: input(ra), modified: input(rb))
            try await settled(retained)
            let beforeRefresh = retained.projection?.original.id, oldRight = retained.modified?.snapshot.bytes
            rb.editor.replaceSelection("user change")
            retained.pollSources()
            failing.stopNext()
            retained.perform(.refresh)
            try await settled(retained)
            check(
                retained.projection?.original.id == beforeRefresh && retained.modified?.snapshot.bytes == oldRight,
                "D1 failed refresh keeps complete old pair")
            check(
                retained.outOfDate && retained.statusText.contains("work limit")
                    && !retained.statusText.contains("Byte-identical"),
                "D1 failed refresh has truthful reason and previous-result attribution")
            retained.window?.close()

            let ga = fresh("anchor\nend\n"), gb = fresh("anchor\nother\nend\n"), geometryService = service()
            let previousGeometry = try await geometryService.open(original: input(ga), modified: input(gb))
            try await settled(previousGeometry)
            let previousGeometryID = previousGeometry.projection?.modified.id,
                previousBytes = previousGeometry.modified?.snapshot.bytes
            gb.editor.text = "anchor\n" + String(repeating: "new\n", count: 32761) + "end\n"
            previousGeometry.pollSources()
            previousGeometry.perform(.refresh)
            try await settled(previousGeometry)
            check(
                previousGeometry.projection?.modified.id == previousGeometryID
                    && previousGeometry.modified?.snapshot.bytes == previousBytes,
                "D1 native geometry refusal restores previous captured pair")
            check(
                previousGeometry.outOfDate && previousGeometry.statusText.contains("display limit"),
                "D1 native geometry refusal is explicit, not a partial successful refresh")
            previousGeometry.window?.close()

            let origins = fresh("first selection\nsecond\n")
            origins.presentation?.clone(nil)
            let origin = try requireValue(origins.presentation?.secondary, "D1 selection origin clone")
            _ = origin.setSelectionAnchor(0, caret: 5)
            _ = origins.presentation?.primaryEditor.setSelectionAnchor(16, caret: 22)
            let selectedInput = CompareInput.document(try CompareDocumentInput(origin, selection: true))
            let selectionService = service(),
                bound = try await selectionService.open(original: selectedInput, modified: values("other"))
            try await settled(bound)
            origins.presentation?.closeSplit(nil)
            check(
                bound.original?.canRefresh == false && bound.original?.snapshot.bytes == Data("first".utf8),
                "D1 retired selection origin keeps slice and cannot borrow primary selection")
            let disabled = NSMenuItem(
                title: "Refresh", action: #selector(CompareController.performCompareCommand(_:)), keyEquivalent: "")
            disabled.representedObject = CompareCommand.refresh.rawValue
            check(
                !bound.validateMenuItem(disabled) && disabled.toolTip?.contains("original view") == true,
                "D1 retired-origin Refresh is disabled with a reason")
            bound.window?.close()

            let legacy = folder.appendingPathComponent("legacy.txt")
            try FileCodec.encode("price €\r\n", format: .init(encoding: .windows1252)).write(to: legacy)
            let encodings = service(),
                legacyResult = try await encodings.open(
                    original: .file(legacy, encoding: .windows1252), modified: values("price €\r\n"))
            try await settled(legacyResult)
            check(
                legacyResult.projection?.changes.identical == true
                    && legacyResult.original?.snapshot.format?.encoding == .windows1252,
                "D1 explicit strict legacy encoding uses existing FileCodec")
            legacyResult.window?.close()

            let saved = fresh("disk original\n")
            let disk = folder.appendingPathComponent("saved.txt")
            try Data("disk original\n".utf8).write(to: disk)
            saved.fileURL = disk
            let savedService = service(), parent = try CompareDocumentInput(saved.editor)
            let savedComparison = try await savedService.open(
                original: .document(parent), modified: .savedFile(CompareSavedFileInput(parent)))
            try await settled(savedComparison)
            check(
                savedComparison.projection?.changes.identical == true,
                "D1 Tab and Saved File reads actual owned disk bytes")
            let oldDisk = savedComparison.modified?.snapshot.id
            saved.fileURL = folder.appendingPathComponent("saved-as.txt")
            try Data("new disk content\n".utf8).write(to: saved.fileURL!)
            savedComparison.pollSources()
            check(savedComparison.outOfDate, "D1 saved-file location change invalidates the captured pair")
            savedComparison.perform(.refresh)
            try await settled(savedComparison)
            check(
                savedComparison.modified?.snapshot.id != oldDisk
                    && savedComparison.modified?.snapshot.bytes == Data("new disk content\n".utf8),
                "D1 explicit saved-file Refresh resolves the current pinned saved location")
            savedComparison.window?.close()

            let raced = fresh("raced source\n"), racedURL = folder.appendingPathComponent("raced-saved.txt")
            try Data("raced disk\n".utf8).write(to: racedURL)
            raced.fileURL = racedURL
            let raceService = service(), gate = CompareFileGate(), raceParent = try CompareDocumentInput(raced.editor)
            raceService.fileSnapshot = { url, encoding in
                let captured = try await ReviewSnapshotCapture.file(url, as: encoding)
                await gate.wait()
                return captured
            }
            let raceTask = Task {
                _ = try await raceService.open(
                    original: .document(raceParent), modified: .savedFile(CompareSavedFileInput(raceParent)))
            }
            let raceDeadline = ProcessInfo.processInfo.systemUptime + 8
            while !(await gate.started) && ProcessInfo.processInfo.systemUptime < raceDeadline {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            let readStarted = await gate.started
            check(readStarted, "D1 saved-file read reaches held async boundary")
            raced.fileURL = folder.appendingPathComponent("raced-new-location.txt")
            await gate.release()
            do {
                _ = try await raceTask.value
                check(false, "D1 changed saved location must refuse publication")
            } catch {
                check(
                    error as? ReviewRejection == .bytesChanged && raceService.windows.isEmpty,
                    "D1 saved-location change during actual file read drops whole result")
            }
            for workload in 0..<2 {
                let text =
                    workload == 0
                    ? String(repeating: "x", count: 2 * 1024 * 1024)
                    : String(repeating: "repeated line\r\n", count: 20000)
                let first = try values(text), second = try values(text + "changed"), measure = CompareTickMeasurement()
                let timer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in
                    MainActor.assumeIsolated { measure.tick() }
                }
                let start = ProcessInfo.processInfo.systemUptime, measured = service(),
                    result = try await measured.open(original: first, modified: second)
                try await settled(result)
                let receivedTimerTick = measure.ticks > 0
                measure.tick()
                timer.invalidate()
                var usage = rusage()
                _ = getrusage(RUSAGE_SELF, &usage)
                print(
                    "D1_MEASURE workload=\(workload) inputBytes=\(text.utf8.count) seconds=\(ProcessInfo.processInfo.systemUptime-start) maxMainTickSeconds=\(measure.maximum) ticks=\(measure.ticks) processHighWaterBytes=\(usage.ru_maxrss) complete=\(result.projection != nil) status=\(result.statusText)"
                )
                check(
                    receivedTimerTick && measuredOutcomeIsExpected(result),
                    "D1 default-policy large/long workload remains cancellable with explicit result")
                check(
                    result.left.editor.readOnly && result.right.editor.readOnly
                        && result.left.editor.comparisonPresentation && result.right.editor.comparisonPresentation
                        && result.left.editor.utf8Data == Data(text.utf8)
                        && result.right.editor.utf8Data == Data((text + "changed").utf8),
                    "D1 bounded workload preserves both original source texts and comparison-only panes")
                result.window?.close()
            }
            @MainActor func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let pickerService = service(), pickerDoc = fresh("picker source\n"), pickerOther = fresh("picker other\n")
            let pickerDisk = folder.appendingPathComponent("picker-saved.txt")
            try Data("picker source\n".utf8).write(to: pickerDisk)
            pickerDoc.fileURL = pickerDisk
            pickerService.allEditors = { [pickerDoc.editor, pickerOther.editor] }
            var pickerClipboardReads = 0
            pickerService.readClipboard = {
                pickerClipboardReads += 1
                return (Data("private chosen text\n".utf8), 42)
            }
            for mode in 0..<5 {
                _ = pickerDoc.editor.setSelectionAnchor(0, caret: 6)
                let picker = CompareSourcePicker(service: pickerService, preferred: pickerDoc.editor)
                picker.kind.selectItem(at: mode)
                _ = NSApp.sendAction(picker.kind.action!, to: picker.kind.target, from: picker.kind)
                if mode == 4 {
                    picker.chooseFile(utf8, side: 0)
                    picker.chooseFile(utf16, side: 1)
                }
                let root = try requireValue(picker.window?.contentView, "D1 picker content")
                let button = try requireValue(
                    descendants(root).compactMap { $0 as? NSButton }.first { $0.title == "Compare" },
                    "D1 picker Compare action")
                let reads = pickerClipboardReads
                check(button.isEnabled, "D1 actual picker source variant \(mode) enabled")
                button.performClick(nil)
                let deadline = ProcessInfo.processInfo.systemUptime + 8
                while pickerService.windows.isEmpty && ProcessInfo.processInfo.systemUptime < deadline {
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                let result = try requireValue(pickerService.windows.first, "D1 actual picker variant result")
                try await settled(result)
                check(result.projection != nil, "D1 actual picker variant \(mode) publishes complete captured model")
                check(
                    pickerClipboardReads - reads == ((mode == 2 || mode == 3) ? 1 : 0),
                    "D1 only explicit clipboard picker variants read")
                result.window?.close()
                picker.window?.close()
            }
            let retainedDoc = fresh("whole live text\n")
            retainedDoc.presentation?.clone(nil)
            var retiredView: TTEditor? = retainedDoc.presentation?.secondary
            weak var releasedView = retiredView
            let retainedPicker = CompareSourcePicker(service: pickerService, preferred: retiredView)
            // Include this document before constructing its picker choices.
            retainedPicker.window?.close()
            pickerService.allEditors = { [retiredView ?? retainedDoc.editor, pickerOther.editor] }
            let survivingPicker = CompareSourcePicker(service: pickerService, preferred: retiredView)
            host.window?.makeKeyAndOrderFront(nil)
            retainedDoc.presentation?.closeSplit(nil)
            retiredView = nil
            try await Task.sleep(nanoseconds: 30_000_000)
            survivingPicker.kind.selectItem(at: 2)
            _ = NSApp.sendAction(
                survivingPicker.kind.action!, to: survivingPicker.kind.target, from: survivingPicker.kind)
            let survivingStart = try requireValue(
                descendants(survivingPicker.window!.contentView!).compactMap { $0 as? NSButton }.first {
                    $0.title == "Compare"
                }, "D1 surviving picker Compare")
            check(
                releasedView == nil && survivingStart.isEnabled,
                "D1 whole-document picker survives released original Clone view")
            releasedView = nil
            app.activate(ignoringOtherApps: true)
            _ = NSRunningApplication.current.activate(options: [.activateAllWindows])
            survivingPicker.window?.makeKeyAndOrderFront(nil)
            await waitUntil("comparison source picker to become key") { survivingPicker.window?.isKeyWindow == true }
            let pickerCount = documents.documents.count
            let pickerNew = NSMenuItem(title: "New", action: #selector(AppDelegate.newDocument(_:)), keyEquivalent: "n")
            check(
                survivingPicker.window?.isKeyWindow == true && !delegate.validateMenuItem(pickerNew),
                "D1 key picker blocks workspace New validation")
            delegate.newDocument(nil)
            check(documents.documents.count == pickerCount, "D1 key picker direct New preserves workspace")
            survivingPicker.window?.close()
            let horizontal = service(),
                scrolling = try await horizontal.open(
                    original: values(String(repeating: "wide ", count: 500) + "\n"),
                    modified: values(String(repeating: "wide ", count: 500) + "changed\n"))
            try await settled(scrolling)
            let originalTop = (scrolling.left.top, scrolling.right.top)
            var changes = 0
            let observe = scrolling.left.editor.onComparisonViewportChange
            scrolling.left.editor.onComparisonViewportChange = {
                observe?()
                changes += 1
            }
            scrolling.left.editor.comparisonHorizontalOffset = 160
            await waitUntil("linked horizontal viewport notification") {
                scrolling.window?.displayIfNeeded()
                return changes > 0 && scrolling.left.editor.comparisonHorizontalOffset > 0
                    && scrolling.right.editor.comparisonHorizontalOffset == scrolling.left.editor.comparisonHorizontalOffset
            }
            check(
                scrolling.left.editor.comparisonHorizontalOffset > 0
                    && scrolling.right.editor.comparisonHorizontalOffset == scrolling.left.editor.comparisonHorizontalOffset
                    && (scrolling.left.top, scrolling.right.top) == originalTop,
                "D1 actual horizontal-only viewport notification links peer without vertical movement")
            scrolling.perform(.linked)
            let frozenOffset = scrolling.right.editor.comparisonHorizontalOffset
            let priorChanges = changes
            scrolling.left.editor.comparisonHorizontalOffset = 240
            await waitUntil("unlinked horizontal viewport notification") {
                scrolling.window?.displayIfNeeded()
                return changes > priorChanges
            }
            check(
                scrolling.right.editor.comparisonHorizontalOffset == frozenOffset
                    && scrolling.left.editor.comparisonHorizontalOffset != frozenOffset,
                "D1 link off preserves independent horizontal positions")
            scrolling.window?.close()
            let routing = service(), route = fresh("route source\n"),
                routed = try await routing.open(original: input(route), modified: values("route result\n"))
            try await settled(routed)
            delegate.buildMenus()
            host.window?.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            _ = NSRunningApplication.current.activate(options: [.activateAllWindows])
            routed.window?.makeKeyAndOrderFront(nil)
            _ = routed.window?.makeFirstResponder(routed.left.editor)
            await waitUntil("comparison window to become key") { routed.window?.isKeyWindow == true }
            check(
                routed.window?.isKeyWindow == true && CompareCommandScope.blocksWorkspace,
                "D1 owned comparison is key and blocks workspace scope")
            check(delegate.currentEditor == nil, "D1 current-editor providers cannot leak a background target")
            let newItem = NSMenuItem(title: "New", action: #selector(AppDelegate.newDocument(_:)), keyEquivalent: "n")
            let documentCount = documents.documents.count
            check(!delegate.validateMenuItem(newItem), "D1 New validates disabled behind comparison")
            delegate.newDocument(nil)
            check(
                documents.documents.count == documentCount && routed.window?.isKeyWindow == true,
                "D1 direct New cannot create or focus a background document")
            let openItem = NSMenuItem(
                title: "Open", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
            check(!documents.validateUserInterfaceItem(openItem), "D1 Open validates disabled behind comparison")
            documents.openDocument(nil)
            documents.saveAllDocuments(nil)
            let recent = NSMenuItem(title: "Recent", action: #selector(RecentDocumentsMenu.open(_:)), keyEquivalent: "")
            recent.representedObject = pickerDisk
            delegate.recentDocumentsMenu.open(recent)
            delegate.workspace.saveSession(nil)
            delegate.workspace.openSession(nil)
            delegate.workspaceBrowser.addFolder(nil)
            check(
                documents.documents.count == documentCount && routed.window?.isKeyWindow == true,
                "D1 direct Open/Recent/Save All/session/folder dispatch cannot open sheets or alter workspace")
            let originalFormat = route.format
            let encoding = NSMenuItem(
                title: "Convert", action: #selector(TextDocument.convertEncoding(_:)), keyEquivalent: "")
            encoding.representedObject = "utf16le"
            route.convertEncoding(encoding)
            route.reloadEncoding(encoding)
            route.runPageLayout(nil)
            check(
                route.format == originalFormat && routed.window?.isKeyWindow == true,
                "D1 direct encoding and page setup dispatch preserve captured workspace")
            let routeState = State(route),
                command = NSMenuItem(
                    title: "Duplicate", action: #selector(EditorWindowController.command(_:)), keyEquivalent: "")
            command.representedObject = "duplicateLine"
            let presentation = try requireValue(route.presentation, "D1 route presentation")
            check(!presentation.validateMenuItem(command), "D1 workspace custom command validates disabled")
            presentation.command(command)
            let readonly = NSMenuItem(
                title: "Read Only", action: #selector(TextDocument.toggleReadOnly(_:)), keyEquivalent: "")
            route.toggleReadOnly(readonly)
            check(
                State(route) == routeState && !route.editor.readOnly,
                "D1 actual stale UI dispatch cannot mutate source text/read-only/selection")
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                routed.window?.appearance = NSAppearance(named: appearance)
                routed.window?.setContentSize(NSSize(width: 720, height: 420))
                try await settled(routed)
                let content = try requireValue(routed.window?.contentView, "D1 owned rendered content")
                content.layoutSubtreeIfNeeded()
                content.displayIfNeeded()
                if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    if let png = bitmap.representation(using: .png, properties: [:]) {
                        try png.write(
                            to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(
                                "harness/logs/compare-\(name)-minimum.png"))
                    } else {
                        check(false, "D1 PNG render encoding")
                    }
                } else {
                    check(false, "D1 owned bitmap render")
                }
                print(
                    "D1_LAYOUT \(name) content=\(content.bounds) left=\(routed.left.frame) right=\(routed.right.frame)")
                check(
                    routed.left.frame.width >= 240 && routed.right.frame.width >= 240,
                    "D1 resized minimum keeps both actual pane frames at least240points")
                check(!content.hasAmbiguousLayout, "D1 native comparison layout is determined in \(name)")
            }
            check(
                routed.window?.canBecomeMain == false && routed.window?.windowController?.document == nil,
                "D1 comparison has no document or main-window lifecycle")
            _ = NSApp.sendAction(#selector(NSWindow.performClose(_:)), to: nil, from: nil)
            check(routed.isClosed && route.isOpen, "D1 Command-W path closes comparison, preserving source document")
        }
    }
}
