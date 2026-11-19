// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
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
@main struct CompareControllerChecks {
    @MainActor static func main() async {
        await Checks.run("CompareControllerChecks") {
            let isolated = try IsolatedSupportDirectory("D1Controllers")
            let documents = TextDocumentController()
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            NativeFixtureEnvironment.install()
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
        }
    }
}
