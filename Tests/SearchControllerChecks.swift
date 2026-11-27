@testable import TextTankCore
import AppKit
@testable import TextTankRuntime
import EditorBridge
import NativeSearch
/// Find-window navigation fronts the document window; checks must never put one on screen.
/// `shown` stands for being the visible tab: fronting sets it, and a check clears it by hand
/// where the application would have ordered the other document windows out.
final class OffscreenWindow: NSWindow {
    var shown = false
    override var isVisible: Bool { shown }
    override func makeKeyAndOrderFront(_ sender: Any?) { shown = true }
}
/// Counts how often navigation asks for the document window to be brought forward. It reports
/// itself as showing, like the selected document tab, without being put on screen.
final class CountingWindow: NSWindow {
    var fronted = 0, showing = true
    override var isVisible: Bool { showing }
    override func makeKeyAndOrderFront(_ sender: Any?) { fronted += 1 }
}
/// A real native editor counts only the getters that must not run after an early rejection.
private final class SelectionReadCounterEditor: TTEditor {
    var selectionReads = 0
    override var selectionStart: Int {
        selectionReads += 1
        return super.selectionStart
    }
    override var selectionEnd: Int {
        selectionReads += 1
        return super.selectionEnd
    }
}
/// Record which thread delivers each report and whether any arrive after completion.
final class ProgressTicks: @unchecked Sendable {
    private let lock = NSLock()
    private var reports = 0, reachedEnd = false
    private var finished = false, orderedOnMain = true
    func begin() {
        lock.lock()
        finished = false
        lock.unlock()
    }
    func finish() {
        lock.lock()
        finished = true
        lock.unlock()
    }
    var displayedBeforeCompletion: Bool {
        lock.lock()
        defer { lock.unlock() }
        return reports > 0 && orderedOnMain
    }
    func record(_ done: Int, _ total: Int) {
        lock.lock()
        orderedOnMain = orderedOnMain && Thread.isMainThread && !finished
        reports += 1
        if done == total, total > 0 { reachedEnd = true }
        lock.unlock()
    }
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return reports
    }
    var complete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return reachedEnd
    }
}
@main struct SearchControllerChecks {
    @MainActor static func followUpCancelChecks(_ controller: SearchController, editor: TTEditor) async throws {
        let nativeSearch = controller.searchAfterReplace
        let originalRecorder = controller.onCommand
        defer {
            controller.searchAfterReplace = nativeSearch
            controller.onCommand = originalRecorder
        }
        for cancel in [false, true] {
            var captured: SearchReport?
            var release: CheckedContinuation<Void, Never>?
            var released = false
            var recorded: [String] = []
            func publish() {
                released = true
                release?.resume()
                release = nil
            }
            defer { publish() }
            controller.onCommand = { _, action, _ in recorded.append(action) }
            controller.searchAfterReplace = { text, options, flag, tabWidth in
                let report = try await nativeSearch(text, options, flag, tabWidth)
                captured = report
                if !released { await withCheckedContinuation { release = $0 } }
                return report
            }
            editor.text = "a a"
            editor.resetUndoHistory()
            editor.setSavePoint()
            _ = editor.setSelectionAnchor(0, caret: 1)
            controller.replaceOne(nil)
            let operation = try requireValue(controller.task, "Replace started its search")
            guard await waitUntil("the real follow-up search to reach publication", { release != nil }) else {
                controller.cancel(nil)
                return
            }
            check(
                captured?.hits.map(\.range) == [NSRange(location: 2, length: 1)]
                    && controller.isSearching && recorded == ["replaceOne"],
                "real follow-up result is pending after the replacement was recorded")
            if cancel { controller.cancel(nil) }
            publish()
            await operation.value
            if cancel {
                check(
                    editor.text == "b a" && editor.selectionAnchor == 0 && editor.selectionCaret == 1,
                    "fixture: the search was cancelled after the replacement and before the next match was selected")
                check(
                    controller.lastOutcome == .replaced(changed: 1, stale: 0)
                        && controller.status.stringValue.hasPrefix("Replaced 1 match")
                        && controller.status.stringValue.hasSuffix("Cancelled before the next match was selected.")
                        && !controller.status.stringValue.contains("no pending replacements applied")
                        && !controller.isSearching && recorded == ["replaceOne"],
                    "Cancel during the search that follows a Replace still reports the replacement")
            } else {
                check(
                    editor.text == "b a" && editor.selectionAnchor == 2 && editor.selectionCaret == 3
                        && controller.lastOutcome == .replaced(changed: 1, stale: 0)
                        && controller.status.stringValue.hasSuffix("Selected the next match.")
                        && !controller.isSearching && recorded == ["replaceOne", "next"],
                    "releasing the same real report without Cancel selects and records the next match")
            }
        }
    }

    /// A source of shared Find text that is not the window: stands for a find bar.
    private final class OtherSurface {}
    /// V3: one Find text and one replacement, live; history; captions; DS-21 and DS-45.
    @MainActor static func findStateChecks(_ support: URL) async throws {
        let url = support.appendingPathComponent("find-state.json")
        let editor = TTEditor(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: .titled, backing: .buffered,
            defer: false)
        window.contentView = editor
        let controller = SearchController(preferencesURL: url)
        controller.currentEditor = { editor }
        controller.openEditors = { [editor] }
        controller.onFailureSignal = {}
        @MainActor func finished() async { await waitUntil("the search to finish") { !controller.isSearching } }
        let panel = try requireValue(controller.window, "fixture: the Find and Replace window")
        func inWindow(_ view: NSView) -> Bool { view.window === panel && !view.isHiddenOrHasHiddenAncestor }
        check(
            controller.queryCaption.stringValue == "Find" && controller.replacementCaption.stringValue == "Replace with"
                && inWindow(controller.queryCaption) && inWindow(controller.replacementCaption)
                && inWindow(controller.queryField) && inWindow(controller.replacementField),
            "the window's two fields have visible captions, Find and Replace with")
        panel.layoutIfNeeded()
        check(
            controller.queryCaption.frame.maxX <= controller.queryField.frame.minX
                && controller.replacementCaption.frame.maxX <= controller.replacementField.frame.minX
                && abs(controller.queryCaption.frame.midY - controller.queryField.frame.midY) < 8
                && controller.queryField.frame.width > 400,
            "each caption sits before its own field, on its row")
        check(
            controller.queryField.stringValue.isEmpty && controller.mode.indexOfSelectedItem == 0
                && controller.findHistory == FindHistory(),
            "a first launch has an empty field, Normal mode and no history")
        // Typing in the window is shared as it is typed, without touching the field typed in.
        var changes: [AnyObject?] = []
        controller.sharedTextChanged = { changes.append($0) }
        panel.makeFirstResponder(controller.queryField)
        let typing = try requireValue(panel.firstResponder as? NSTextView, "fixture: the Find field editor")
        typing.string = "needle"
        typing.setSelectedRange(NSRange(location: 2, length: 3))
        let before = controller.reusedResults
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: controller.queryField))
        check(
            controller.sharedQuery == "needle" && changes.count == 1 && changes.first.map { $0 === controller } == true,
            "text typed in the window becomes the shared Find text at once, and names the window as its source")
        check(
            typing.selectedRange() == NSRange(location: 2, length: 3) && panel.firstResponder === typing
                && typing.string == "needle",
            "sharing what is typed leaves the caret and selection of the field typed in alone")
        check(
            !controller.isSearching && controller.lastOutcome == nil && controller.reusedResults == before,
            "sharing text runs no search")
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: controller.queryField))
        check(changes.count == 1, "unchanged text is not announced to the other surfaces again")
        // Typing somewhere else (a find bar) shows in the window at once.
        let bar = OtherSurface()
        controller.setSharedQuery("from the bar", from: bar)
        controller.setSharedReplacement("swap", from: bar)
        check(
            controller.queryField.stringValue == "from the bar" && controller.replacementField.stringValue == "swap"
                && changes.count == 3 && changes.last.map { $0 === bar } == true,
            "text typed in a find bar is in the window's fields as it is typed")
        panel.makeFirstResponder(nil)
        controller.replacementField.stringValue = "typed replacement"
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: controller.replacementField))
        check(controller.sharedReplacement == "typed replacement", "the replacement text is shared the same way")
        // History: the last ten distinct searches, saved privately, offered and never applied.
        editor.text = "one two three one two three"
        for number in 1...12 {
            controller.queryField.stringValue = number % 2 == 0 ? "one" : "word \(number)"
            controller.findAll(nil)
            await finished()
        }
        check(
            controller.findHistory.queries.count == 7 && controller.findHistory.queries.first == "one"
                && controller.findHistory.queries.filter { $0 == "one" }.count == 1,
            "a search repeated is one history entry, moved to the front")
        for number in 20...31 {
            controller.queryField.stringValue = "entry \(number)"
            controller.findAll(nil)
            await finished()
        }
        check(
            controller.findHistory.queries == (22...31).reversed().map { "entry \($0)" }
                && (controller.queryField.objectValues as? [String]) == controller.findHistory.queries
                && controller.queryField.numberOfItems == 10,
            "the Find field offers the last ten distinct searches, newest first")
        check(
            controller.findHistory.replacements.isEmpty && controller.replacementField.numberOfItems == 0,
            "a search that replaces nothing adds no replacement to the history")
        controller.queryField.stringValue = "two"
        controller.replacementField.stringValue = "2"
        controller.replaceAll(nil)
        await finished()
        check(
            editor.text == "one 2 three one 2 three" && controller.findHistory.replacements == ["2"]
                && (controller.replacementField.objectValues as? [String]) == ["2"],
            "a replacement that was used is offered by the Replace with field")
        // Choosing an entry: the pointer picks a row, the arrow keys move through rows.
        changes = []
        controller.queryField.selectItem(at: 3)
        controller.comboBoxSelectionDidChange(
            Notification(name: NSComboBox.selectionDidChangeNotification, object: controller.queryField))
        check(
            controller.sharedQuery == controller.findHistory.queries[3]
                && controller.queryField.stringValue == controller.findHistory.queries[3] && !changes.isEmpty,
            "an entry chosen from the history becomes the shared Find text for every surface")
        check(
            controller.queryField.isButtonBordered && controller.queryField.numberOfVisibleItems == 10
                && controller.queryField.acceptsFirstResponder,
            "the history is a combo box: its arrow button for the pointer, Down Arrow for the keyboard")
        let saved = try FindPreferences.decode(Data(contentsOf: url))
        check(
            saved.history == controller.findHistory && saved.options.query.isEmpty && saved.options.mode == .normal,
            "the history is kept in the private settings file, without the live text")
        check(
            try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600,
            "the settings file with the history is private to the user")
        // Regex mode and a query in force now; the next launch has neither.
        controller.mode.selectItem(at: 2)
        controller.queryField.stringValue = "t(w|h)"
        controller.findAll(nil)
        await finished()
        let relaunched = SearchController(preferencesURL: url)
        check(
            relaunched.queryField.stringValue.isEmpty && relaunched.replacementField.stringValue.isEmpty
                && relaunched.mode.indexOfSelectedItem == 0
                && relaunched.sharedOptions(query: "", replacement: "").mode == .normal,
            "a new launch is in Normal mode with an empty Find field after a Regex search")
        check(
            relaunched.findHistory.queries.first == "t(w|h)" && relaunched.findHistory.queries.count == 10
                && relaunched.findHistory.replacements == ["2"],
            "the new launch offers the earlier searches as history")
        // A find pasteboard left over from before launch is not taken in; a later one is.
        var board = "left over"
        relaunched.readFindText = { board }
        relaunched.adoptFindPasteboard()
        check(
            !relaunched.importFindPasteboard() && relaunched.sharedQuery.isEmpty,
            "find-pasteboard text from before the launch does not fill the Find field")
        board = "searched in another application"
        check(
            relaunched.importFindPasteboard() && relaunched.queryField.stringValue == board
                && !relaunched.importFindPasteboard(),
            "a search made in another application afterwards is taken in, once")
        relaunched.setSharedQuery("typed after that", from: bar)
        check(
            !relaunched.importFindPasteboard() && relaunched.queryField.stringValue == "typed after that",
            "opening the window never replaces newer typed text with the pasteboard it already took")
        // DS-21: Replace All is not offered for a search known to find nothing.
        controller.mode.selectItem(at: 0)
        editor.text = "alpha beta"
        controller.queryField.stringValue = "zebra"
        controller.replacementField.stringValue = "z"
        controller.findAll(nil)
        await finished()
        check(
            controller.lastOutcome == .found(matches: 0, documents: 1, truncated: false)
                && !controller.replaceAllButton.isEnabled && controller.replaceAllButton.toolTip?.isEmpty == false
                && controller.replaceAllButton.title == "Replace All",
            "Replace All is disabled, with the reason, when the last count found nothing")
        controller.windowDidUpdate(Notification(name: NSWindow.didUpdateNotification, object: panel))
        check(!controller.replaceAllButton.isEnabled, "it stays disabled while nothing about the search changed")
        controller.replacementField.stringValue = "y"
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: controller.replacementField))
        check(!controller.replaceAllButton.isEnabled, "a different replacement does not change what is found")
        controller.queryField.stringValue = "alpha"
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: controller.queryField))
        check(
            controller.replaceAllButton.isEnabled && controller.replaceAllButton.toolTip == nil,
            "changing the Find text offers Replace All again")
        controller.queryField.stringValue = "zebra"
        controller.findAll(nil)
        await finished()
        try require(!controller.replaceAllButton.isEnabled, "fixture: Replace All is disabled again")
        editor.text = "alpha zebra"
        controller.windowDidUpdate(Notification(name: NSWindow.didUpdateNotification, object: panel))
        check(controller.replaceAllButton.isEnabled, "editing the document offers Replace All again")
        controller.findAll(nil)
        await finished()
        check(
            controller.lastOutcome == .found(matches: 1, documents: 1, truncated: false)
                && controller.replaceAllButton.isEnabled, "a count that finds a match leaves Replace All enabled")
        controller.queryField.stringValue = "nothing here"
        controller.findAll(nil)
        await finished()
        controller.caseButton.state = .on
        _ = NSApp.sendAction(
            try requireValue(controller.caseButton.action, "fixture"), to: controller, from: controller.caseButton)
        check(controller.replaceAllButton.isEnabled, "changing an option offers Replace All again")
        controller.caseButton.state = .off
        let ranBefore = controller.findHistory
        controller.scope.selectItem(at: 1)
        _ = editor.setSelectionAnchor(0, caret: 0)
        controller.queryField.stringValue = "refused before it ran"
        controller.replacementField.stringValue = "never used"
        controller.replaceAll(nil)
        check(
            controller.lastOutcome == .needsInput && controller.findHistory == ranBefore && !controller.isSearching,
            "a search refused for its scope is not remembered")
        controller.scope.selectItem(at: 0)
        controller.queryField.stringValue = ""
        controller.findAll(nil)
        check(controller.findHistory == ranBefore, "an empty search is not remembered")
        controller.queryField.stringValue = "ran and found nothing"
        controller.findAll(nil)
        check(controller.findHistory == ranBefore, "a search is remembered when it has run, not when it starts")
        await finished()
        check(
            controller.findHistory.queries.first == "ran and found nothing",
            "a search that ran is remembered whatever it found")
        // DS-45: an expression that does not compile marks the field and shows the whole message.
        controller.mode.selectItem(at: 2)
        controller.queryField.stringValue = "(unclosed [group"
        controller.findAll(nil)
        await finished()
        let complaint = controller.status.stringValue
        // Fix round 1, item 5: only a search that ran is remembered.
        check(
            !controller.findHistory.queries.contains("(unclosed [group")
                && (try? FindPreferences.decode(Data(contentsOf: url)))?.history.queries.contains("(unclosed [group")
                    == false,
            "an expression that did not compile is not put in the history or saved")
        check(
            controller.patternIsMarked && controller.patternNotice.stringValue == complaint && complaint.count > 20
                && inWindow(controller.patternNotice) && controller.queryField.accessibilityHelp() == complaint
                && controller.queryField.toolTip == complaint,
            "an invalid pattern marks the Find field, under it and for assistive technology")
        if case .failed(let reason)? = controller.lastOutcome {
            check(reason == complaint, "the outcome carries the same whole message")
        } else {
            check(false, "the outcome carries the same whole message")
        }
        check(
            controller.status.lineBreakMode == .byWordWrapping && controller.status.maximumNumberOfLines == 3
                && controller.patternNotice.maximumNumberOfLines == 0
                && controller.patternNotice.lineBreakMode == .byWordWrapping
                && controller.queryField.stringValue == "(unclosed [group",
            "the whole message is shown, wrapped and not cut off, and what was typed is kept")
        controller.queryField.stringValue = "(closed)"
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: controller.queryField))
        check(
            !controller.patternIsMarked && controller.queryField.accessibilityHelp() == nil,
            "correcting the expression removes the mark")
        controller.queryField.stringValue = "alpha"
        controller.mode.selectItem(at: 0)
        controller.findAll(nil)
        await finished()
        check(!controller.patternIsMarked, "a search that fails for another reason, or succeeds, marks nothing")
        controller.window?.close()
        relaunched.window?.close()
    }
    /// V5: Current document and Selection scope above the engine's limit, with the limit and the
    /// window lowered so that a few hundred bytes are a large document read in many windows.
    @MainActor static func largeDocumentChecks(_ support: URL) async throws {
        let editor = TTEditor(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: .titled, backing: .buffered,
            defer: false)
        window.contentView = editor
        let controller = SearchController(preferencesURL: support.appendingPathComponent("find-large.json"))
        controller.currentEditor = { editor }
        controller.openEditors = { [editor] }
        var signals = 0, recorded: [String] = [], unrecordable = 0
        controller.onFailureSignal = { signals += 1 }
        controller.onCommand = { _, action, _ in recorded.append(action) }
        controller.onUnrecordableCommand = { _ in unrecordable += 1 }
        controller.largeDocumentUnits = 64
        controller.largeChunkBytes = 32
        @MainActor func finished() async { await waitUntil("the search to finish") { !controller.isSearching } }
        let text =
            String(repeating: "caf\u{e9} Na\u{ef}ve \u{1F600} na\u{ef}ve needle\n", count: 12) + "tail NA\u{cf}VE end\n"
        func byteRanges(_ query: String, matchCase: Bool, mode: SearchOptions.Mode = .normal, in source: String) throws
            -> [NSRange]
        {
            let hits = try SearchCore.search(
                source, options: SearchOptions(query: query, mode: mode, matchCase: matchCase)
            )
            .hits
            return try requireValue(SearchCore.byteRanges(hits.map(\.range), in: source), "fixture: byte ranges")
        }
        editor.text = text
        editor.resetUndoHistory()
        try require(controller.largeSnapshot(of: editor) != nil, "fixture: the document is above the lowered limit")
        editor.text = "short"
        check(controller.largeSnapshot(of: editor) == nil, "a document at or under the limit is not copied or counted")
        editor.text = text
        editor.resetUndoHistory()
        let folded = try byteRanges("na\u{ef}ve", matchCase: false, in: text)
        let exact = try byteRanges("na\u{ef}ve", matchCase: true, in: text)
        try require(folded.count == 25 && exact.count == 12, "fixture: 25 folded and 12 exact matches")
        // Count. The same search is a status-row operation: real progress and a Cancel that is
        // this controller's own cancellation.
        let center = StatusOperationCenter.shared
        let usualReveal = center.revealDelay
        center.revealDelay = 0
        defer { center.revealDelay = usualReveal }
        var rowFractions: [Double] = []
        let rowObserver = NotificationCenter.default.addObserver(
            forName: StatusOperationCenter.didChange, object: center, queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                if let fraction = center.operation(for: [editor])?.fraction { rowFractions.append(fraction) }
            }
        }
        defer { NotificationCenter.default.removeObserver(rowObserver) }
        check(center.operations.isEmpty, "fixture: no status-row operation before the search")
        controller.queryField.stringValue = "na\u{ef}ve"
        controller.findAll(nil)
        check(
            controller.isSearching && controller.status.stringValue == "Searching…",
            "a large search starts off the main thread")
        let shown = center.operation(for: [editor])
        check(
            center.operations.count == 1 && shown?.title == "Searching the document"
                && shown?.cancelLabel == "Cancel search" && shown?.fraction == nil
                && center.operation(for: [TTEditor(frame: .zero)]) == nil,
            "SR-3 a large search is a status-row operation on its own document, indeterminate until progress arrives")
        await finished()
        check(
            center.operations.isEmpty && !rowFractions.isEmpty && rowFractions == rowFractions.sorted()
                && rowFractions.allSatisfy { $0 > 0 && $0 <= 1 },
            "SR-3 the row is given the search's real progress and loses the operation when it ends: \(rowFractions.count) steps"
        )
        controller.findAll(nil)
        let running = try requireValue(center.operation(for: [editor]), "fixture: the second search is running")
        center.cancel(running.id)
        check(
            !controller.isSearching && controller.lastOutcome == .cancelled && center.operations.isEmpty
                && controller.status.stringValue == "Cancelled; no pending replacements applied.",
            "SR-3 Cancel in the status row is the search's own cancellation and ends the operation")
        controller.findAll(nil)
        await finished()
        check(
            controller.lastOutcome == .found(matches: 25, documents: 1, truncated: false)
                && controller.numberOfRows(in: controller.table) == 0
                && controller.status.stringValue.hasPrefix("25 matches in 1 document.")
                && controller.status.stringValue.contains("not listed"),
            "Find All / Count above the limit reports the right count, case-insensitively, and says the matches are not listed"
        )
        check(controller.progressReports > 0, "a large search shows real progress while it runs")
        controller.caseButton.state = .on
        controller.findAll(nil)
        await finished()
        check(
            controller.lastOutcome == .found(matches: 12, documents: 1, truncated: false),
            "Match case counts only the exact matches in multi-byte text")
        controller.caseButton.state = .off
        // Next, Previous, wrap.
        _ = editor.setSelectionAnchor(0, caret: 0)
        recorded = []
        unrecordable = 0
        controller.next(nil)
        await finished()
        check(
            editor.selectionStart == folded[0].location && editor.selectionEnd == NSMaxRange(folded[0])
                && controller.lastOutcome == .movedToMatch && signals == 0,
            "Find Next above the limit selects the first match after the caret")
        // Fix round 1: a recorded search is replayed synchronously, and a large search must not
        // hold the window, so it is refused at playback and therefore never recorded.
        check(
            recorded.isEmpty && unrecordable == 1,
            "a search in a large document is not recorded; the recording is told why")
        controller.next(nil)
        await finished()
        controller.next(nil)
        await finished()
        check(
            editor.selectionStart == folded[2].location && editor.selectedText == "Na\u{ef}ve",
            "Find Next again moves on, one match at a time, across windows")
        controller.previous(nil)
        await finished()
        check(
            editor.selectionStart == folded[1].location && recorded.isEmpty && unrecordable == 4,
            "Find Previous goes back to the match before")
        _ = editor.setSelectionAnchor(editor.byteLength, caret: editor.byteLength)
        controller.next(nil)
        await finished()
        check(editor.selectionStart == folded[0].location, "Find Next at the end wraps to the first match")
        _ = editor.setSelectionAnchor(0, caret: 0)
        controller.previous(nil)
        await finished()
        check(
            editor.selectionStart == folded[24].location && editor.selectedText == "NA\u{cf}VE",
            "Find Previous at the start wraps to the last match")
        controller.wrapButton.state = .off
        _ = editor.setSelectionAnchor(editor.byteLength, caret: editor.byteLength)
        signals = 0
        controller.next(nil)
        await finished()
        check(
            controller.lastOutcome == .noFurtherMatches && signals == 1 && editor.selectionStart == editor.byteLength
                && controller.status.stringValue == "No further matches.",
            "with Wrap Around off, Find Next at the end says so and moves nothing")
        controller.wrapButton.state = .on
        // Regex is refused in plain words, with what to do next.
        controller.mode.selectItem(at: 2)
        controller.queryField.stringValue = "n[a\u{e4}]\u{ef}ve"
        _ = editor.setSelectionAnchor(3, caret: 3)
        let regexRevision = editor.revision
        controller.next(nil)
        await finished()
        check(
            controller.lastOutcome == .failed(SearchFailure.largeDocumentRegex.localizedDescription)
                && controller.status.stringValue.contains("too large for a regular expression search")
                && controller.status.stringValue.contains("Selection")
                && controller.status.stringValue.contains("Normal") && editor.selectionStart == 3
                && editor.revision == regexRevision && !controller.patternIsMarked,
            "a Regex Find above the limit says so in plain words and says what to do next")
        // ...and searching a selection is what it says: the selection is searched on its own.
        let half = text.utf8.count / 2 - (text.utf8.count / 2) % 1
        let scopeEnd = try requireValue(
            (0...4).map { half + $0 }.first { editor.setSelectionAnchor(0, caret: $0) && editor.selectionEnd == $0 },
            "fixture: a selection ending on a character boundary")
        controller.largeDocumentUnits = 400
        try require(
            controller.largeSnapshot(of: editor) == nil, "fixture: under a higher limit the document is ordinary")
        controller.largeDocumentUnits = 64
        _ = editor.setSelectionAnchor(0, caret: scopeEnd)
        controller.scope.selectItem(at: 1)
        controller.findAll(nil)
        await finished()
        check(
            controller.lastOutcome == .failed(SearchFailure.largeSelectionRegex.localizedDescription),
            "a selection that is itself above the limit is refused for Regex, saying to select less")
        controller.largeDocumentUnits = 300
        try require(controller.largeSnapshot(of: editor) != nil, "fixture: still a large document")
        let selected = String(decoding: Data(text.utf8).prefix(scopeEnd), as: UTF8.self)
        let inScope = try byteRanges("n[a\u{e4}]\u{ef}ve", matchCase: false, mode: .regularExpression, in: selected)
        controller.findAll(nil)
        await finished()
        check(
            controller.lastOutcome == .found(matches: inScope.count, documents: 1, truncated: false)
                && inScope.count > 4,
            "a Regex search of a selection in a large document counts the matches in the selection")
        controller.next(nil)
        await finished()
        check(
            editor.selectionStart == inScope[0].location && editor.selectionEnd == NSMaxRange(inScope[0]),
            "the first Regex Next in Selection scope selects the first match in the selection")
        controller.next(nil)
        await finished()
        check(
            editor.selectionStart == inScope[1].location,
            "the next press continues inside the remembered scope, not from a new selection")
        controller.mode.selectItem(at: 0)
        controller.queryField.stringValue = "needle"
        _ = editor.setSelectionAnchor(0, caret: scopeEnd)
        controller.findAll(nil)
        await finished()
        check(
            controller.lastOutcome
                == .found(
                    matches: try byteRanges("needle", matchCase: false, in: selected).count, documents: 1,
                    truncated: false),
            "a Normal search of a selection in a large document reads only the selection, in windows")
        controller.scope.selectItem(at: 0)
        controller.largeDocumentUnits = 64
        // Replace: the selected match, one Undo step, then on to the next match.
        let needles = try byteRanges("needle", matchCase: false, in: text)
        controller.replacementField.stringValue = "PIN"
        _ = editor.setSelectionAnchor(needles[0].location, caret: NSMaxRange(needles[0]))
        recorded = []
        controller.replaceOne(nil)
        await finished()
        let afterOne = text.replacingCharacters(in: try requireValue(text.range(of: "needle"), "fixture"), with: "PIN")
        check(
            editor.text == afterOne && controller.lastOutcome == .replaced(changed: 1, stale: 0)
                && controller.status.stringValue.hasSuffix("Selected the next match.")
                && editor.selectedText == "needle"
                && editor.selectionStart == needles[1].location - 3 && recorded.isEmpty,
            "Replace above the limit replaces the selected match and selects the next one")
        editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
        check(editor.text == text, "one Undo restores the single replacement")
        _ = editor.setSelectionAnchor(2, caret: 2)
        recorded = []
        controller.replaceOne(nil)
        await finished()
        check(
            editor.text == text && controller.lastOutcome == .selectedNextMatch && editor.selectedText == "needle"
                && editor.selectionStart == needles[0].location && recorded.isEmpty,
            "Replace with no match selected selects the next match and changes nothing")
        // Replace All is supported above the limit: every match, one bounded Undo step.
        recorded = []
        let undoRevision = editor.revision
        controller.replaceAll(nil)
        await finished()
        check(
            editor.text == text.replacingOccurrences(of: "needle", with: "PIN")
                && controller.lastOutcome == .replaced(changed: 12, stale: 0) && recorded.isEmpty,
            "Replace All above the limit replaces every match")
        editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
        check(
            editor.text == text && editor.revision != undoRevision, "one Undo restores every replacement of Replace All"
        )
        controller.queryField.stringValue = "absent"
        controller.replaceAll(nil)
        await finished()
        check(
            editor.text == text && controller.lastOutcome == .replaced(changed: 0, stale: 0)
                && !controller.replaceAllButton.isEnabled,
            "Replace All that finds nothing changes nothing, and is then disabled")
        controller.queryField.stringValue = "needle"
        // The result cap is the engine's: a truncated result never replaces.
        editor.text = String(repeating: "x", count: 100_001)
        let cappedRevision = editor.revision
        controller.queryField.stringValue = "x"
        controller.replacementField.stringValue = "y"
        controller.replaceAll(nil)
        await finished()
        check(
            controller.lastOutcome == .limitReached && editor.revision == cappedRevision,
            "100,001 matches in a large document reach the result cap and replace nothing")
        controller.findAll(nil)
        await finished()
        check(
            controller.lastOutcome == .found(matches: 100_000, documents: 1, truncated: true),
            "a count at the cap says the limit was reached")
        editor.text = text
        editor.resetUndoHistory()
        controller.queryField.stringValue = "needle"
        // Marks, bookmarks and All open documents are refused in words; nothing changes.
        controller.mark(nil)
        check(
            controller.lastOutcome == .failed(SearchFailure.largeDocumentAction.localizedDescription)
                && !controller.isSearching,
            "Mark Matches is refused in a large document")
        controller.bookmark(nil)
        check(
            controller.lastOutcome == .failed(SearchFailure.largeDocumentAction.localizedDescription)
                && editor.bookmarkLines.isEmpty, "Bookmark Matches is refused in a large document")
        controller.scope.selectItem(at: 2)
        controller.findAll(nil)
        check(
            controller.status.stringValue.contains("too large to search together with the other open documents")
                && !controller.isSearching,
            "All open documents refuses a large document and says to search it on its own")
        controller.scope.selectItem(at: 0)
        // Cancel and revalidation.
        _ = editor.setSelectionAnchor(0, caret: 0)
        controller.next(nil)
        controller.cancel(nil)
        await finished()
        check(
            controller.lastOutcome == .cancelled && editor.selectionStart == 0 && editor.selectionEnd == 0
                && controller.status.stringValue.hasPrefix("Cancelled"),
            "a large search can be cancelled and then selects nothing")
        recorded = []
        controller.next(nil)
        try require(editor.replaceSelection("edit "), "fixture: an edit while the search runs")
        let editedRevision = editor.revision, editedCaret = editor.selectionCaret
        await finished()
        check(
            controller.lastOutcome == .staleResult && editor.revision == editedRevision
                && editor.selectionCaret == editedCaret && recorded.isEmpty,
            "a result for a revision that has changed selects nothing and is not recorded")
        editor.text = text
        controller.replaceAll(nil)
        _ = editor.setSelectionAnchor(5, caret: 5)
        await finished()
        check(
            controller.lastOutcome == .staleResult && editor.text == text,
            "a replacement is not applied after the selection moved while the search ran")
        // The find bar's path: the same planner through performInline, with progress.
        var inlineResult: InlineSearchOutcome?
        let ticks = ProgressTicks()
        @MainActor func inline(_ action: String, _ options: SearchOptions) async {
            inlineResult = nil
            ticks.begin()
            controller.performInline(
                options: options, action: action, on: editor, cancellation: TTSearchCancellation(),
                isCurrent: { true }, progress: { done, total in ticks.record(done, total) },
                completion: {
                    ticks.finish()
                    inlineResult = $0
                })
            await waitUntil("the inline search completion") { inlineResult != nil }
        }
        editor.text = text
        editor.resetUndoHistory()
        _ = editor.setSelectionAnchor(0, caret: 0)
        await inline("next", SearchOptions(query: "NA\u{cf}VE"))
        if case .applied? = inlineResult {
            check(editor.selectionStart == folded[0].location, "the find bar's Next works above the limit")
        } else {
            check(false, "the find bar's Next works above the limit")
        }
        await inline("previous", SearchOptions(query: "NA\u{cf}VE", matchCase: true))
        check(editor.selectedText == "NA\u{cf}VE", "the find bar's Previous works above the limit, with Match case")
        check(ticks.count > 0 && ticks.complete, "the find bar is told real progress for a large search")
        check(ticks.displayedBeforeCompletion, "DS-51 inline progress reaches the main thread before completion")
        await inline("next", SearchOptions(query: "zebra"))
        if case .noMatch? = inlineResult {
            check(true, "no match above the limit is reported as no match")
        } else {
            check(false, "no match above the limit is reported as no match")
        }
        await inline("next", SearchOptions(query: "n.ve", mode: .regularExpression))
        if case .failed(let error)? = inlineResult {
            check(
                error as? SearchFailure == .largeDocumentRegex,
                "the find bar's Regex Find above the limit is refused with the plain message")
        } else {
            check(false, "the find bar's Regex Find above the limit is refused with the plain message")
        }
        _ = editor.setSelectionAnchor(0, caret: 0)
        await inline("replaceAll", SearchOptions(query: "needle", replacement: "PIN"))
        if case .replacedAll(let count)? = inlineResult {
            check(
                count == 12 && editor.text == text.replacingOccurrences(of: "needle", with: "PIN"),
                "the find bar's Replace All works above the limit")
        } else {
            check(false, "the find bar's Replace All works above the limit")
        }
        editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
        check(editor.text == text, "and is one Undo step")
        let cancelled = TTSearchCancellation()
        inlineResult = nil
        controller.performInline(
            options: SearchOptions(query: "needle"), action: "next", on: editor, cancellation: cancelled,
            isCurrent: { true }, completion: { inlineResult = $0 })
        cancelled.cancel()
        await waitUntil("the cancelled inline search") { inlineResult != nil }
        if case .cancelled? = inlineResult {
            check(true, "a large find-bar search can be cancelled")
        } else {
            check(false, "a large find-bar search can be cancelled")
        }
        // The live count: the same publication as below the limit.
        let data = Data(text.utf8)
        for (query, caret, wrap) in [
            ("na\u{ef}ve", 0, true), ("needle", needles[5].location + 1, true), ("NEEDLE", data.count, false),
            ("zebra", 0, true), ("e", folded[3].location, true)
        ] {
            let options = SearchOptions(query: query, wrap: wrap)
            let ordinary = try SearchController.preview(
                data, options: options, openingCaret: caret, cancellation: TTSearchCancellation())
            let large = try SearchController.preview(
                data, options: options, openingCaret: caret, cancellation: TTSearchCancellation(), unitLimit: 64,
                chunkBytes: 32)
            check(
                large.highlights == ordinary.highlights && large.selected == ordinary.selected
                    && large.countText == ordinary.countText && large.foundNothing == (query == "zebra"),
                "the live count above the limit matches the ordinary one for “\(query)”")
        }
        rejects("the live count refuses Regex above the limit", expecting: SearchFailure.largeDocumentRegex) {
            _ = try SearchController.preview(
                data, options: SearchOptions(query: "n.ve", mode: .regularExpression), openingCaret: 0,
                cancellation: TTSearchCancellation(), unitLimit: 64, chunkBytes: 32)
        }
        // Fix round 1, item 1: playback is synchronous, so a recorded search step is refused in
        // a large document, in words and before the document is read. It never searches inline.
        _ = editor.setSelectionAnchor(0, caret: 0)
        let playbackRevision = editor.revision
        for (action, options) in [
            ("next", SearchOptions(query: "needle")), ("previous", SearchOptions(query: "needle")),
            ("replaceOne", SearchOptions(query: "needle", replacement: "PIN")),
            ("replaceAll", SearchOptions(query: "needle", replacement: "PIN"))
        ] {
            rejects("a recorded \(action) is refused in a large document", expecting: SearchFailure.largeDocumentMacro)
            {
                try controller.playRecorded(options: options, action: action, on: editor)
            }
        }
        check(
            editor.revision == playbackRevision && editor.text == text && editor.selectionCaret == 0
                && SearchFailure.largeDocumentMacro.localizedDescription.contains("Find and Replace"),
            "the refused playback changes nothing and says what to use instead")
        // Fix round 2: the message must be true whether or not earlier steps of the macro edited
        // the document, and reads like the other macro stops.
        let refusal = SearchFailure.largeDocumentMacro.localizedDescription
        check(
            refusal.hasPrefix("Macro stopped:") && refusal.hasSuffix("prior edits remain undoable.")
                && refusal.contains("The search changed nothing") && !refusal.contains("Nothing was changed"),
            "the refusal claims only that the search changed nothing, and that prior edits remain undoable")
        // Earlier steps applied, then the search step is refused: their edits stay, each its own Undo step.
        editor.resetUndoHistory()
        _ = editor.setSelectionAnchor(0, caret: 0)
        try require(editor.replaceSelection("first "), "fixture: an earlier macro step typed text")
        _ = editor.setSelectionAnchor(editor.byteLength, caret: editor.byteLength)
        try require(editor.replaceSelection(" second"), "fixture: another earlier step typed text")
        let afterEarlier = editor.text, earlierRevision = editor.revision
        rejects(
            "the search step after earlier edits is refused the same way", expecting: SearchFailure.largeDocumentMacro
        ) {
            try controller.playRecorded(
                options: SearchOptions(query: "needle", replacement: "PIN"), action: "replaceAll", on: editor)
        }
        check(
            editor.text == afterEarlier && editor.revision == earlierRevision
                && afterEarlier == "first " + text + " second",
            "the refused step leaves the earlier steps' edits in place, as its message says")
        editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
        check(editor.text == "first " + text, "Undo takes back the last earlier step alone")
        editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
        check(editor.text == text, "a second Undo takes back the step before it: they remain separate Undo steps")
        _ = editor.setSelectionAnchor(0, caret: 0)
        controller.largeDocumentUnits = SearchCore.maximumTextUnits
        try controller.playRecorded(options: SearchOptions(query: "needle"), action: "next", on: editor)
        check(editor.selectionStart == needles[0].location, "the same recorded step still replays under the limit")
        // Item 4: deciding whether a document is large copies nothing when its length settles it,
        // and otherwise copies once per revision of each document, not once per press.
        let other = TTEditor(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let otherWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: .titled, backing: .buffered,
            defer: false)
        otherWindow.contentView = other
        other.text = text
        controller.openEditors = { [editor, other] }
        controller.scope.selectItem(at: 2)
        controller.queryField.stringValue = "needle"
        controller.largeDocumentUnits = 64
        var copies = controller.largeDecisionCopies
        controller.findAll(nil)
        check(
            controller.status.stringValue.contains("too large to search together") && !controller.isSearching
                && controller.largeDecisionCopies == copies,
            "a document three times over the limit in bytes is known to be large without a copy")
        // Just above the limit in UTF-16 units, and under three times the limit in bytes.
        controller.largeDocumentUnits = text.utf16.count - 10
        try require(
            text.utf8.count / 3 <= controller.largeDocumentUnits, "fixture: the byte length alone does not decide")
        copies = controller.largeDecisionCopies
        for _ in 1...4 {
            controller.findAll(nil)
            check(
                controller.status.stringValue.contains("too large to search together") && !controller.isSearching,
                "All open documents refuses a large document on every press")
        }
        check(
            controller.largeDecisionCopies == copies + 1,
            "four presses decide by one copy of the first large document, not four")
        controller.openEditors = { [other, editor] }
        controller.findAll(nil)
        controller.findAll(nil)
        check(
            controller.largeDecisionCopies == copies + 2,
            "each document's answer is kept, so two large documents cost one copy each")
        _ = other.setSelectionAnchor(0, caret: 0)
        try require(other.replaceSelection("x"), "fixture: an edit")
        controller.findAll(nil)
        check(controller.largeDecisionCopies == copies + 3, "an edited document is decided again, once")
        controller.openEditors = { [editor] }
        controller.scope.selectItem(at: 0)
        controller.window?.close()
        otherWindow.contentView = nil
        try await realSizeChecks(support)
    }
    /// Fix round 1, item 6: the real path, in the default run. A real editor holds 65 MiB, which is
    /// above the engine's real limit, and the controller is left at its real limit and window size.
    @MainActor static func realSizeChecks(_ support: URL) async throws {
        let size = 65 * 1_048_576, marker = "Straddle-\u{c9}\u{dc}\u{1F600}-Mark", length = marker.utf8.count
        let line = String(repeating: "x", count: 63) + "\n"
        let starts = [4 * 1_048_576 - 7, 33 * 1_048_576 + 12_345, size - length]
        var text = ""
        text.reserveCapacity(size)
        var position = 0
        for start in starts {
            let filler = start - position
            text += String(repeating: line, count: filler / 64) + String(repeating: "x", count: filler % 64)
            text += marker
            position = start + length
        }
        let editor = TTEditor(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: .titled, backing: .buffered,
            defer: false)
        window.contentView = editor
        editor.text = text
        text = ""
        editor.resetUndoHistory()
        let controller = SearchController(preferencesURL: support.appendingPathComponent("find-real-size.json"))
        controller.currentEditor = { editor }
        controller.openEditors = { [editor] }
        controller.onFailureSignal = {}
        var recorded = 0
        controller.onCommand = { _, _, _ in recorded += 1 }
        @MainActor func finished() async {
            await waitUntil(timeout: 60, "the real-size search to finish") { !controller.isSearching }
        }
        try require(
            editor.byteLength == size && controller.largeDocumentUnits == SearchCore.maximumTextUnits
                && controller.largeChunkBytes == SearchCore.largeChunkBytes && controller.isLargeDocument(editor),
            "fixture: 65 MiB in a real editor, at the real limit and window size")
        func selected(_ index: Int) -> Bool {
            editor.selectionStart == starts[index] && editor.selectionEnd == starts[index] + length
        }
        controller.queryField.stringValue = marker.uppercased()
        controller.findAll(nil)
        check(controller.isSearching, "the real-size count is handed to another thread")
        await finished()
        check(
            controller.lastOutcome == .found(matches: 3, documents: 1, truncated: false)
                && controller.progressReports > 0,
            "above the real 64 Mi limit a literal Find reports the right count, with progress")
        controller.caseButton.state = .on
        controller.queryField.stringValue = marker
        controller.findAll(nil)
        await finished()
        check(
            controller.lastOutcome == .found(matches: 3, documents: 1, truncated: false),
            "with Match case the real-size count is the same")
        controller.caseButton.state = .off
        _ = editor.setSelectionAnchor(0, caret: 0)
        controller.next(nil)
        await finished()
        check(
            selected(0) && controller.lastOutcome == .movedToMatch,
            "Find Next finds the match that straddles the first real 4 MiB window boundary")
        controller.previous(nil)
        await finished()
        check(selected(2), "Find Previous wraps to the last match of the real-size document")
        controller.findAll(nil)
        controller.cancel(nil)
        await finished()
        check(controller.lastOutcome == .cancelled && selected(2), "the real-size search can be cancelled")
        controller.mode.selectItem(at: 2)
        controller.queryField.stringValue = "Strad+le"
        controller.findAll(nil)
        await finished()
        check(
            controller.lastOutcome == .failed(SearchFailure.largeDocumentRegex.localizedDescription),
            "a Regex Find above the real limit says so in plain words")
        controller.mode.selectItem(at: 0)
        let revision = editor.revision
        rejects("a recorded search is refused at the real size", expecting: SearchFailure.largeDocumentMacro) {
            try controller.playRecorded(options: SearchOptions(query: marker), action: "replaceAll", on: editor)
        }
        rejects("a legacy recorded find is refused at the real size", expecting: SearchFailure.largeDocumentMacro) {
            _ = try SearchController.playLegacyFind(text: marker, matchCase: true, backwards: false, in: editor)
        }
        check(
            editor.revision == revision && recorded == 0 && controller.largeDecisionCopies == 1,
            "refused playback changes nothing; the whole run decided the document's size with one copy")
        controller.window?.close()
        window.contentView = nil
    }

    @MainActor static func main() async {
        await Checks.run("SearchControllerChecks") {
            let support = try IsolatedSupportDirectory("TextTankSearchControllerChecks")
            defer { support.restore() }
            NativeFixtureEnvironment.install()
            defer { NativeFixtureEnvironment.restore() }
            _ = NSApplication.shared
            func preview(_ text: String, _ options: SearchOptions, _ caret: Int = 0) throws
                -> SearchController.InlinePreview
            {
                try SearchController.preview(
                    Data(text.utf8), options: options, openingCaret: caret,
                    cancellation: TTSearchCancellation())
            }
            let graphemes = "😀e\u{301} • e\u{301}\0"
            let accents = try preview(graphemes, SearchOptions(query: "\u{301}", mode: .regularExpression), 7)
            check(
                accents.highlights == [NSRange(location: 5, length: 2), NSRange(location: 13, length: 2)]
                    && accents.selected == accents.highlights.last && accents.countText == "2 of 2",
                "inline preview maps scalar matches inside graphemes to exact UTF-8 offsets")
            rejects("preview refuses a caret inside a UTF-8 scalar") {
                _ = try preview(graphemes, SearchOptions(query: "e"), 6)
            }
            let dense = String(repeating: "a ", count: 400) + "😀e\u{301} a"
            let capped = try preview(dense, SearchOptions(query: "a"), 805)
            check(
                capped.highlights.count == 256 && capped.countText == "256+ matches"
                    && capped.selected == NSRange(location: 808, length: 1)
                    && capped.highlights.last == capped.selected,
                "a later caret finds a visible match beyond the bounded paint set")
            let zero = try preview("aa", SearchOptions(query: "(?=a)", mode: .regularExpression))
            check(
                zero.highlights == [NSRange(location: 0, length: 0), NSRange(location: 1, length: 0)]
                    && zero.countText == "1 of 2", "preview counts zero-width results at native UTF-8 positions")
            let noWrap = try preview("a b", SearchOptions(query: "a", wrap: false), 3)
            check(noWrap.selected == nil && noWrap.highlights.count == 1, "preview respects disabled wrap at the end")
            rejects("an invalid preview regex cannot yield a navigable or paintable result") {
                _ = try preview("sample", SearchOptions(query: "[", mode: .regularExpression))
            }
            let cancelledPreview = TTSearchCancellation()
            cancelledPreview.cancel()
            rejects("a cancelled preview cannot publish a result") {
                _ = try SearchController.preview(
                    Data("a".utf8), options: SearchOptions(query: "a"),
                    openingCaret: 0, cancellation: cancelledPreview)
            }
            let closedEditor = SelectionReadCounterEditor(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
            closedEditor.text = "alpha"
            closedEditor.selectionReads = 0
            rejects("F285 a legacy search rejects a closed native editor") {
                _ = try SearchController.playLegacyFind(
                    text: "alpha", matchCase: true, backwards: false, in: closedEditor)
            }
            check(
                closedEditor.selectionReads == 0,
                "F285 a closed search is rejected before reading or converting editor selections")

            // F255: the controller under test keeps its options in a suite of its own, never in the
            // real defaults domain, so nothing is inherited from an earlier run or left behind.
            let suite = "TextTankSearchControllerChecks-" + UUID().uuidString
            let isolated = try requireValue(UserDefaults(suiteName: suite), "fixture: isolated defaults suite")
            defer { isolated.removePersistentDomain(forName: suite) }
            let protectedSuite = "TextTankProtectedLegacy-" + UUID().uuidString
            let protected = try requireValue(UserDefaults(suiteName: protectedSuite), "fixture: protected defaults")
            protected.set(Data("sentinel".utf8), forKey: "TextTank.Search.v1")
            var providerCalls = 0
            let originalProvider = RuntimeEnvironment.dependencies
            var effects = RuntimeEnvironment.current
            effects.sharedDefaultsProvider = {
                providerCalls += 1
                return protected
            }
            RuntimeEnvironment.dependencies = effects
            defer {
                RuntimeEnvironment.dependencies = originalProvider
                protected.removePersistentDomain(forName: protectedSuite)
            }
            let implicit = SearchController()
            check(
                implicit.queryField.stringValue.isEmpty && providerCalls == 0,
                "an absolute support override skips even obtaining shared legacy defaults")
            check(
                WindowFrames.defaults == nil && providerCalls == 0,
                "implicit frame storage does not obtain shared defaults in an isolated check")
            let editor = TTEditor(frame: NSRect(x: 0, y: 0, width: 600, height: 400)),
                window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: .titled, backing: .buffered,
                    defer: false)
            window.contentView = editor
            let controller = SearchController(defaults: isolated)
            controller.currentEditor = { editor }
            controller.openEditors = { [editor] }
            // F308: failures of Find Next and Find Previous are counted here instead of sounding.
            var signals = 0
            controller.onFailureSignal = { signals += 1 }
            @MainActor func finished() async { await waitUntil("the search to finish") { !controller.isSearching } }
            // Audit27: Boost distinguishes canonically equivalent patterns by scalar sequence.
            editor.text = "é e\u{301}"
            controller.mode.selectItem(at: SearchOptions.Mode.regularExpression.rawValue)
            controller.caseButton.state = .on
            controller.queryField.stringValue = "é"
            controller.next(nil)
            await finished()
            check(editor.selectionStart == 0 && editor.selectionEnd == 2, "NFC regex selects NFC bytes")
            _ = editor.setSelectionAnchor(0, caret: 0)
            let beforeUnicodeReuse = controller.reusedResults
            controller.queryField.stringValue = "e\u{301}"
            controller.next(nil)
            await finished()
            check(
                editor.selectionStart == 3 && editor.selectionEnd == 6
                    && controller.reusedResults == beforeUnicodeReuse,
                "NFD regex gets its own scalar-exact results rather than reusing NFC hits")
            controller.mode.selectItem(at: 0)
            controller.caseButton.state = .off
            controller.queryField.stringValue = ""
            // Navigation reports are distinct from nonoverlapping Find All/Replace All reports.
            editor.text = "aaa"
            controller.queryField.stringValue = "aa"
            controller.replacementField.stringValue = "X"
            controller.caseButton.state = .on
            controller.findAll(nil)
            await finished()
            check(
                controller.lastOutcome == .found(matches: 1, documents: 1, truncated: false),
                "Find All keeps the nonoverlapping literal report")
            let beforePurposeReuse = controller.reusedResults
            _ = editor.setSelectionAnchor(1, caret: 1)
            controller.next(nil)
            await finished()
            check(
                editor.selectionStart == 1 && editor.selectionEnd == 3 && controller.reusedResults == beforePurposeReuse
                    && controller.lastOutcome == .found(matches: 2, documents: 1, truncated: false),
                "advanced Next requests overlapping navigation instead of reusing Find All rows")
            _ = editor.setSelectionAnchor(3, caret: 3)
            controller.previous(nil)
            check(
                !controller.isSearching && editor.selectionStart == 1 && editor.selectionEnd == 3
                    && controller.reusedResults == beforePurposeReuse + 1,
                "advanced Previous reuses the overlapping navigation report")
            controller.replaceAll(nil)
            await finished()
            check(editor.text == "Xa", "Replace All never applies overlapping navigation rows")
            editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
            check(editor.text == "aaa", "nonoverlapping Replace All remains one Undo")
            _ = editor.setSelectionAnchor(3, caret: 1)
            controller.replaceOne(nil)
            await finished()
            check(editor.text == "aX", "strict single Replace accepts an overlapping selected match")
            editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
            check(
                editor.text == "aaa" && editor.selectionAnchor == 3 && editor.selectionCaret == 1,
                "Undo of overlapping single Replace restores its reversed match selection")
            editor.text = "ab"
            _ = editor.setSelectionAnchor(1, caret: 1)
            controller.queryField.stringValue = "ab"
            controller.next(nil)
            await finished()
            check(
                editor.selectionCaret == 1 && controller.lastOutcome == .noFurtherMatches,
                "advanced literal wrap never crosses its original interior caret boundary")
            controller.previous(nil)
            check(
                editor.selectionCaret == 1 && controller.lastOutcome == .noFurtherMatches,
                "backwards literal wrap also excludes the cross-boundary match")
            controller.queryField.stringValue = ""
            controller.replacementField.stringValue = ""
            controller.caseButton.state = .off
            // Audit27: inline scheduling is separate from the Find window's cache/scopes, but
            // applies the same report with exact capture/revalidation and cooperative cancellation.
            var inlineOptions = SearchOptions()
            inlineOptions.query = "alpha"
            inlineOptions.replacement = "X"
            var inlineResult: InlineSearchOutcome?
            @MainActor func inlineFinished() async {
                await waitUntil("the inline search completion") { inlineResult != nil }
            }
            editor.text = "alpha beta"
            _ = editor.setSelectionAnchor(0, caret: 5)
            let capturedInline = editor.revision
            controller.performInline(
                options: inlineOptions, action: "replaceOne", on: editor,
                cancellation: TTSearchCancellation(), isCurrent: { true }, completion: { inlineResult = $0 })
            _ = editor.setSelectionAnchor(6, caret: 10)
            await inlineFinished()
            if case .stale = inlineResult {
                check(true, "selection changes discard pending inline replacement")
            } else {
                check(false, "selection changes discard pending inline replacement")
            }
            check(
                editor.text == "alpha beta" && editor.revision == capturedInline && editor.selectionStart == 6,
                "stale inline replacement preserves bytes, revision and the new selection")
            inlineResult = nil
            _ = editor.setSelectionAnchor(0, caret: 5)
            let cancelInline = TTSearchCancellation()
            controller.performInline(
                options: inlineOptions, action: "replaceOne", on: editor,
                cancellation: cancelInline, isCurrent: { true }, completion: { inlineResult = $0 })
            cancelInline.cancel()
            await inlineFinished()
            if case .cancelled = inlineResult {
                check(true, "inline cancellation reports normal completion without replacement")
            } else {
                check(false, "inline cancellation reports normal completion without replacement")
            }
            check(
                editor.text == "alpha beta" && editor.revision == capturedInline,
                "cancelled inline replacement preserves text and revision")
            inlineResult = nil
            controller.performInline(
                options: inlineOptions, action: "next", on: editor,
                cancellation: TTSearchCancellation(), isCurrent: { false }, completion: { inlineResult = $0 })
            await inlineFinished()
            if case .stale = inlineResult {
                check(true, "caller query-generation guard blocks pending selection")
            } else {
                check(false, "caller query-generation guard blocks pending selection")
            }
            inlineResult = nil
            controller.performInline(
                options: inlineOptions, action: "replaceOne", on: editor,
                cancellation: TTSearchCancellation(), isCurrent: { true }, completion: { inlineResult = $0 })
            editor.text = "edited while searching"
            let editedInlineRevision = editor.revision
            await inlineFinished()
            if case .stale = inlineResult {
                check(true, "document revision changes discard inline replacement")
            } else {
                check(false, "document revision changes discard inline replacement")
            }
            check(
                editor.text == "edited while searching" && editor.revision == editedInlineRevision,
                "stale inline completion never overwrites a concurrent edit")
            inlineResult = nil
            editor.text = "alpha beta"
            _ = editor.setSelectionAnchor(0, caret: 5)
            controller.performInline(
                options: inlineOptions, action: "replaceOne", on: editor,
                cancellation: TTSearchCancellation(), isCurrent: { true }, completion: { inlineResult = $0 })
            window.contentView = nil
            await inlineFinished()
            if case .stale = inlineResult {
                check(true, "a detached editor cannot receive inline replacement")
            } else {
                check(false, "a detached editor cannot receive inline replacement")
            }
            window.contentView = editor
            inlineResult = nil
            editor.text = String(repeating: "a", count: 100_001)
            _ = editor.setSelectionAnchor(0, caret: 0)
            var frequent = SearchOptions()
            frequent.query = "a"
            let frequentRevision = editor.revision
            controller.performInline(
                options: frequent, action: "next", on: editor,
                cancellation: TTSearchCancellation(), isCurrent: { true }, completion: { inlineResult = $0 })
            await inlineFinished()
            if case .failed(let error) = inlineResult {
                check(
                    error as? SearchFailure == .inlineResultLimit,
                    "inline navigation reports the shared 100,000-result limit")
            } else {
                check(false, "inline navigation reports the shared 100,000-result limit")
            }
            check(
                editor.revision == frequentRevision && editor.selectionCaret == 0,
                "truncated shared results never move the inline selection")
            editor.text = "one needle"
            let damagedURL = support.url.appendingPathComponent("damaged-find.json"),
                damagedBytes = Data("keep unreadable settings".utf8)
            try damagedBytes.write(to: damagedURL)
            let degraded = SearchController(preferencesURL: damagedURL)
            degraded.currentEditor = { editor }
            degraded.openEditors = { [editor] }
            degraded.queryField.stringValue = "needle"
            degraded.findAll(nil)
            await waitUntil("search with unreadable preferences to finish") { !degraded.isSearching }
            check(
                degraded.lastOutcome == .found(matches: 1, documents: 1, truncated: false)
                    && degraded.preferenceNotice.isHidden == false
                    && degraded.resetPreferencesButton.isHidden == false,
                "F212 unreadable preferences leave search functional with persistent recovery controls")
            check(
                try Data(contentsOf: damagedURL) == damagedBytes,
                "F212 searching never overwrites unreadable saved preferences")
            let obstructed = support.url.appendingPathComponent("blocked-preference-parent")
            let transient = SearchController(preferencesURL: obstructed.appendingPathComponent("find.json"))
            transient.currentEditor = { editor }
            transient.openEditors = { [editor] }
            try Data("fixture obstruction".utf8).write(to: obstructed)
            transient.queryField.stringValue = "needle"
            transient.findAll(nil)
            await waitUntil("search with a failed preference save to finish") { !transient.isSearching }
            check(
                transient.lastOutcome == .found(matches: 1, documents: 1, truncated: false)
                    && transient.preferenceNotice.isHidden == false,
                "F212 preference write failure is reported without aborting the requested search")
            let fresh0 = SearchOptions()
            check(
                !controller.resetPreferencesButton.isHidden
                    && controller.resetPreferencesButton.superview?.isHidden == false
                    && controller.preferenceNotice.isHidden,
                "F212 healthy saved settings retain a discoverable explicit Reset action")
            check(
                controller.queryField.stringValue == fresh0.query
                    && controller.caseButton.state == (fresh0.matchCase ? .on : .off)
                    && controller.wordButton.state == (fresh0.wholeWord ? .on : .off)
                    && controller.dotButton.state == (fresh0.dotMatchesNewline ? .on : .off)
                    && controller.wrapButton.state == (fresh0.wrap ? .on : .off)
                    && controller.mode.indexOfSelectedItem == fresh0.mode.rawValue,
                "controller on an empty defaults suite starts from default options, not from an earlier run")
            editor.text = "🥑 one=12 two=34"
            editor.resetUndoHistory()
            editor.setSavePoint()
            var o = SearchOptions()
            o.query = "([a-z]+)=(\\d+)"
            o.replacement = "$1:$2"
            o.mode = .regularExpression
            o.matchCase = true
            let original = editor.text, revision = editor.revision, report = try SearchCore.search(original, options: o)
            check(
                SearchController.apply(report.hits, text: original, revision: revision, to: editor),
                "regex replacement applied in native editor")
            check(editor.text == "🥑 one:12 two:34" && editor.modified, "exact captures and dirty state")
            editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
            check(editor.text == original && !editor.modified, "one Undo restores full original and save point")
            // G374: the matches are replaced without using the selection as the edit cursor.
            editor.text = "a1 b22 c333"
            editor.resetUndoHistory()
            editor.setSavePoint()
            var digits = SearchOptions()
            digits.query = "[0-9]+"
            digits.replacement = "#"
            digits.mode = .regularExpression
            let numbered = editor.text, numberedRevision = editor.revision
            let digitHits = try SearchCore.search(numbered, options: digits).hits
            _ = editor.setSelectionAnchor(11, caret: 3)
            check(
                SearchController.apply(digitHits, text: numbered, revision: numberedRevision, to: editor)
                    && editor.text == "a# b# c#" && editor.selectionAnchor == 8 && editor.selectionCaret == 3,
                "replace all keeps the reversed selection around the text it covered")
            editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
            check(
                editor.text == numbered && !editor.modified && editor.selectionAnchor == 11
                    && editor.selectionCaret == 3, "one Undo of replace all restores the text and the selection")
            _ = editor.setSelectionAnchor(9, caret: 9)
            check(
                SearchController.apply(digitHits, text: numbered, revision: editor.revision, to: editor)
                    && editor.selectionAnchor == 7 && editor.selectionCaret == 7,
                "a caret inside a replaced match moves to the start of its replacement")
            editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
            check(
                editor.text == numbered && editor.selectionAnchor == 9 && editor.selectionCaret == 9,
                "Undo returns the caret to where it was inside the match")
            _ = editor.setSelectionAnchor(4, caret: 6)
            check(
                SearchController.apply([digitHits[1]], text: numbered, revision: editor.revision, to: editor)
                    && editor.text == "a1 b# c333" && editor.selectionAnchor == 4 && editor.selectionCaret == 5,
                "replacing the selected match leaves its replacement selected")
            editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
            check(
                editor.text == numbered && editor.selectionAnchor == 4 && editor.selectionCaret == 6,
                "Undo of a single replacement reselects the match")
            let unordered = [digitHits[1], digitHits[0]], unorderedRevision = editor.revision
            check(
                !SearchController.apply(unordered, text: numbered, revision: unorderedRevision, to: editor)
                    && editor.text == numbered && editor.revision == unorderedRevision && editor.selectionAnchor == 4
                    && editor.selectionCaret == 6, "out-of-order matches are refused before any edit")
            editor.text = "changed"
            let changed = editor.text, current = editor.revision
            _ = editor.setSelectionAnchor(1, caret: 2)
            check(
                !SearchController.apply(report.hits, text: original, revision: revision, to: editor)
                    && editor.text == changed && editor.revision == current && editor.selectionStart == 1,
                "stale result preserves text/revision/selection")
            editor.text = original
            editor.resetUndoHistory()
            editor.setSavePoint()
            let fresh = editor.revision
            editor.readOnly = true
            _ = editor.setSelectionAnchor(4, caret: 5)
            check(
                !SearchController.apply(report.hits, text: original, revision: fresh, to: editor)
                    && editor.text == original && editor.selectionStart == 4 && !editor.modified,
                "read-only replacement rejected without selection changes")
            editor.readOnly = false
            window.contentView = nil
            check(
                !SearchController.apply(report.hits, text: original, revision: fresh, to: editor)
                    && editor.text == original, "detached editor replacement rejected")
            window.contentView = editor
            _ = editor.setSelectionAnchor(0, caret: 0)
            try controller.playRecorded(options: o, action: "next", on: editor)
            check(editor.selectedText == "one=12", "recorded regex find selects UTF8 mapped match")
            try controller.playRecorded(options: o, action: "replaceOne", on: editor)
            check(editor.text == "🥑 one:12 two=34", "recorded regex selected replacement")
            editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
            check(editor.text == original, "recorded replacement one Undo")
            editor.text = "ab"
            o.query = "(?=.)|$"
            o.replacement = "_"
            _ = editor.setSelectionAnchor(0, caret: 0)
            try controller.playRecorded(options: o, action: "next", on: editor)
            check(editor.selectionCaret == 0, "first zero match at start")
            try controller.playRecorded(options: o, action: "next", on: editor)
            check(editor.selectionCaret == 1, "successive zero match advances")
            try controller.playRecorded(options: o, action: "replaceAll", on: editor)
            check(editor.text == "_a_b_", "recorded zero-width replace all")
            check(
                controller.mode.numberOfItems == 3 && controller.scope.numberOfItems == 3
                    && controller.table.tableColumns.count == 1, "native options and result controls wired")
            editor.text = "one=12 two=34"
            editor.resetUndoHistory()
            editor.setSavePoint()
            controller.queryField.stringValue = "([a-z]+)=(\\d+)"
            controller.replacementField.stringValue = "old"
            controller.mode.selectItem(at: 2)
            controller.window?.makeFirstResponder(controller.replacementField)
            try requireValue(
                controller.window?.firstResponder as? NSTextView, "fixture: replacement field editor is active"
            ).string = "$1:$2"
            check(
                NSApp.sendAction(#selector(SearchController.replaceAll(_:)), to: controller, from: nil),
                "native replacement action dispatched while replacement field editing")
            await finished()
            check(
                editor.text == "one:12 two:34" && controller.queryField.stringValue == "([a-z]+)=(\\d+)",
                "active shared field editor commits only replacement and preserves regex query")
            // V3: the private file keeps what was searched for as history. The live text and the
            // Regex mode are not carried to the next launch (this replaces the earlier restore).
            let persisted = try FindPreferences.decode(Data(contentsOf: AppStorage.url(.find)))
            check(
                persisted.history.queries.first == "([a-z]+)=(\\d+)" && persisted.history.replacements.first == "$1:$2"
                    && persisted.options.query.isEmpty && persisted.options.replacement.isEmpty
                    && persisted.options.mode == .normal,
                "a Find-window action saves its search and replacement as history in the isolated private file")
            check(
                providerCalls == 0 && protected.data(forKey: "TextTank.Search.v1") == Data("sentinel".utf8)
                    && isolated.data(forKey: "TextTank.Search.v1") == nil,
                "private saves never obtain shared legacy defaults or write either protected legacy fixture")
            let reopened = SearchController(defaults: isolated)
            check(
                reopened.queryField.stringValue.isEmpty && reopened.replacementField.stringValue.isEmpty
                    && reopened.mode.indexOfSelectedItem == 0 && reopened.sharedQuery.isEmpty,
                "a new launch starts in Normal mode with empty fields; nothing is silently restored into Regex")
            check(
                reopened.findHistory.queries.first == "([a-z]+)=(\\d+)"
                    && reopened.findHistory.replacements.first == "$1:$2"
                    && (reopened.queryField.objectValues as? [String]) == reopened.findHistory.queries
                    && (reopened.replacementField.objectValues as? [String]) == reopened.findHistory.replacements,
                "what was searched for before is offered by both fields as history")
            editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
            check(editor.text == "one=12 two=34", "native focused-field replace all one Undo")
            editor.setSavePoint()
            editor.readOnly = true
            _ = editor.setSelectionAnchor(0, caret: 3)
            let markRevision = editor.revision, markSelection = editor.selectionRanges
            controller.mark(nil)
            await finished()
            check(
                controller.lastOutcome == .marked(matches: 2, stale: 0, zeroWidth: 0) && editor.revision == markRevision
                    && !editor.modified && editor.selectionRanges == markSelection,
                "native mark action works read-only without text dirty or selection change")
            controller.clearMarks(nil)
            check(
                controller.lastOutcome == .clearedHighlights(documents: 1) && editor.revision == markRevision
                    && !editor.modified && editor.selectionRanges == markSelection,
                "native clear marks preserves content and selection")
            editor.readOnly = false
            controller.mark(nil)
            editor.text = "changed during search"
            let changedRevision = editor.revision
            await finished()
            check(
                controller.lastOutcome == .marked(matches: 0, stale: 1, zeroWidth: 0)
                    && editor.text == "changed during search" && editor.revision == changedRevision,
                "stale asynchronous mark preserves new content")
            editor.text = "a\r\na\ra\nend"
            editor.resetUndoHistory()
            editor.setSavePoint()
            _ = editor.setBookmarks([3])
            controller.queryField.stringValue = "a"
            controller.mode.selectItem(at: 0)
            controller.scope.selectItem(at: 0)
            controller.bookmark(nil)
            await finished()
            check(
                editor.bookmarkLines.map { $0.intValue } == [0, 1, 2, 3] && !editor.modified,
                "background bookmark lines preserve existing bookmarks and save point")
            _ = editor.setBookmarks([3])
            controller.bookmark(nil)
            controller.cancel(nil)
            // A negative: nothing observable marks the end of a cancelled run, so wait a fixed
            // interval and then require that neither the markers nor the status were overwritten.
            try await Task.sleep(nanoseconds: 50_000_000)
            check(
                editor.bookmarkLines.map { $0.intValue } == [3] && controller.lastOutcome == .cancelled
                    && !controller.isSearching, "cancelled bookmark action preserves existing markers")
            controller.bookmark(nil)
            editor.text = "new content"
            _ = editor.setBookmarks([0])
            await finished()
            check(
                controller.lastOutcome == .bookmarked(stale: 1) && editor.bookmarkLines.map { $0.intValue } == [0],
                "stale bookmark completion preserves current markers")
            // G366: a recorded Next/Previous that finds nothing stops the macro instead of returning normally.
            func stops(_ work: () throws -> Void) -> String? {
                do {
                    try work()
                    return nil
                } catch { return error.localizedDescription }
            }
            var miss = SearchOptions()
            miss.query = "TODO"
            miss.mode = .normal
            miss.matchCase = true
            miss.wrap = false
            editor.text = "TODO one\nTODO two\ntail\n"
            editor.resetUndoHistory()
            editor.setSavePoint()
            let tail = editor.text.utf8.count
            _ = editor.setSelectionAnchor(tail, caret: tail)
            let missRevision = editor.revision
            var message = stops { try controller.playRecorded(options: miss, action: "next", on: editor) }
            check(
                message?.contains("recorded search did not match") == true && editor.selectionAnchor == tail
                    && editor.selectionCaret == tail && editor.text == "TODO one\nTODO two\ntail\n"
                    && editor.revision == missRevision && !editor.modified,
                "recorded Next past the last match stops with selection, text and revision unchanged")
            _ = editor.setSelectionAnchor(0, caret: 0)
            message = stops { try controller.playRecorded(options: miss, action: "previous", on: editor) }
            check(
                message?.contains("recorded search did not match") == true && editor.selectionAnchor == 0
                    && editor.selectionCaret == 0 && editor.revision == missRevision && !editor.modified,
                "recorded Previous before the first match stops with selection and revision unchanged")
            miss.wrap = true
            _ = editor.setSelectionAnchor(tail, caret: tail)
            check(
                stops { try controller.playRecorded(options: miss, action: "next", on: editor) } == nil
                    && editor.selectionStart == 0 && editor.selectedText == "TODO",
                "recorded Next with Wrap on still wraps to the first match")
            _ = editor.setSelectionAnchor(0, caret: 0)
            check(
                stops { try controller.playRecorded(options: miss, action: "previous", on: editor) } == nil
                    && editor.selectionStart == 9 && editor.selectedText == "TODO",
                "recorded Previous with Wrap on still wraps to the last match")
            miss.query = "absent"
            _ = editor.setSelectionAnchor(3, caret: 3)
            message = stops { try controller.playRecorded(options: miss, action: "next", on: editor) }
            check(
                message?.contains("recorded search did not match") == true && editor.selectionCaret == 3
                    && editor.revision == missRevision, "recorded Next with Wrap on and no match anywhere stops")
            miss.replacement = "x"
            check(
                stops { try controller.playRecorded(options: miss, action: "replaceAll", on: editor) } == nil
                    && editor.revision == missRevision && !editor.modified && editor.selectionCaret == 3,
                "recorded Replace All with no match is skipped without an edit")
            check(
                stops { try controller.playRecorded(options: miss, action: "replaceOne", on: editor) } == nil
                    && editor.revision == missRevision && !editor.modified,
                "recorded Replace keeps its saved-macro semantics when the selection is not a match")
            // G366: the Find window records Next/Previous only when it actually moved to a match.
            let offscreen = OffscreenWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: .titled, backing: .buffered,
                defer: false)
            window.contentView = nil
            offscreen.contentView = editor
            var recorded: [String] = []
            controller.onCommand = { _, action, _ in recorded.append(action) }
            func settle() async { await finished() }
            controller.queryField.stringValue = "TODO"
            controller.replacementField.stringValue = ""
            controller.mode.selectItem(at: 0)
            controller.scope.selectItem(at: 0)
            controller.wrapButton.state = .off
            controller.caseButton.state = .on
            _ = editor.setSelectionAnchor(0, caret: 0)
            controller.next(nil)
            await settle()
            check(
                recorded == ["next"] && editor.selectionStart == 0 && editor.selectedText == "TODO",
                "Find-window Next that lands on a match is recorded")
            _ = editor.setSelectionAnchor(tail, caret: tail)
            controller.next(nil)
            await settle()
            check(
                recorded == ["next"] && controller.lastOutcome == .noFurtherMatches && editor.selectionCaret == tail,
                "Find-window Next that finds nothing is not recorded")
            _ = editor.setSelectionAnchor(0, caret: 0)
            controller.previous(nil)
            await settle()
            check(
                recorded == ["next"] && controller.lastOutcome == .noFurtherMatches,
                "Find-window Previous that finds nothing is not recorded")
            _ = editor.setSelectionAnchor(tail, caret: tail)
            controller.previous(nil)
            await settle()
            check(
                recorded == ["next", "previous"] && editor.selectionStart == 9,
                "Find-window Previous that lands on a match is recorded")
            // G372: a Find-window result is acted on, and recorded, only while it is still fresh.
            var unrecordable: [String] = []
            controller.onUnrecordableCommand = { unrecordable.append($0) }
            recorded = []
            _ = editor.setSelectionAnchor(0, caret: 0)
            controller.next(nil)
            await settle()
            check(
                recorded == ["next"] && unrecordable.isEmpty && editor.selectionStart == 0
                    && editor.selectedText == "TODO",
                "a fresh Find-window Next is recorded once and discards nothing")
            recorded = []
            // The held results would answer this Next at once (F223). A changed option makes it
            // search again, so the edit below overtakes a search that is still running.
            controller.caseButton.state = .off
            _ = editor.setSelectionAnchor(0, caret: 0)
            controller.next(nil)
            try require(controller.isSearching, "fixture: this Next is a running search, not held results")
            editor.text = "changed"
            let overtakenRevision = editor.revision, overtakenCaret = editor.selectionCaret
            await settle()
            controller.caseButton.state = .on
            check(
                recorded.isEmpty && unrecordable.count == 1
                    && unrecordable.first?.contains("changed while the search was running") == true,
                "a Next overtaken by an edit is not recorded and reports once that it could not be")
            check(
                controller.lastOutcome == .staleResult && editor.text == "changed"
                    && editor.revision == overtakenRevision && editor.selectionCaret == overtakenCaret,
                "a Next overtaken by an edit says the result is stale and leaves text, revision and caret alone")
            editor.text = "TODO one\nTODO two\ntail\n"
            _ = editor.setSelectionAnchor(0, caret: 0)
            let bystander = TTEditor(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
            controller.next(nil)
            controller.currentEditor = { bystander }
            await settle()
            controller.currentEditor = { editor }
            check(
                recorded.isEmpty && unrecordable.count == 2 && controller.lastOutcome == .staleResult
                    && editor.selectionCaret == 0,
                "a Next whose editor is no longer current is stale, not 'no further matches', and is not recorded")
            // F277: a result row moves the caret with no recordable step.
            unrecordable = []
            controller.findAll(nil)
            await settle()
            controller.open(row: 99)
            check(unrecordable.isEmpty && editor.selectionCaret == 0, "a row that does not exist opens nothing")
            controller.open(row: 1)
            check(
                editor.selectionStart == 9 && editor.selectedText == "TODO" && unrecordable.count == 1
                    && unrecordable.first?.contains("search result") == true,
                "opening a result row reports that the jump cannot be recorded")
            editor.text = "TODO one\nTODO two\ntail\n "
            controller.open(row: 0)
            check(
                unrecordable.count == 1 && controller.lastOutcome == .staleResult,
                "a stale result row moves nothing and reports nothing to the recording")
            controller.onUnrecordableCommand = nil
            recorded = []
            // F43: a recorded search step has the interactive budget, and a step that runs out of
            // time has edited nothing.
            check(
                SearchController.recordedStepTimeLimit == SearchCore.defaultTimeLimit
                    && SearchCore.defaultTimeLimit == 2,
                "macro playback of a search step uses the interactive search budget from the one constant")
            var runaway = SearchOptions()
            runaway.query = "(a+)+$"
            runaway.replacement = "x"
            runaway.mode = .regularExpression
            editor.text = String(repeating: "a", count: 100) + "!"
            editor.resetUndoHistory()
            editor.setSavePoint()
            _ = editor.setSelectionAnchor(3, caret: 5)
            let runawayText = editor.text, runawayRevision = editor.revision
            for action in ["replaceAll", "next"] {
                let stopped = stops {
                    try controller.playRecorded(options: runaway, action: action, on: editor, timeLimit: 0.05)
                }
                check(
                    stopped != nil && editor.text == runawayText && editor.revision == runawayRevision
                        && editor.selectionAnchor == 3 && editor.selectionCaret == 5 && !editor.modified,
                    "a recorded \(action) that exceeds its budget throws with text, revision and selection unchanged")
            }
            // F34: single Replace on a many-hit buffer converts the hits once, and replaces only the selected hit.
            let hitLine = "é needle 0123456789 0123456789 0123456\n", hitCount = 20000, chosenHit = 12345,
                hitBytes = hitLine.utf8.count
            let big = String(repeating: hitLine, count: hitCount)
            editor.text = big
            editor.resetUndoHistory()
            editor.setSavePoint()
            controller.queryField.stringValue = "needle"
            controller.replacementField.stringValue = "pin"
            recorded = []
            _ = editor.setSelectionAnchor(chosenHit * hitBytes + 3, caret: chosenHit * hitBytes + 9)
            let replaceStart = Date()
            controller.replaceOne(nil)
            await waitUntil(timeout: 120, "the many-hit single Replace to finish") { !controller.isSearching }
            let replaceElapsed = Date().timeIntervalSince(replaceStart)
            let expectedBig =
                String(repeating: hitLine, count: chosenHit) + "é pin 0123456789 0123456789 0123456\n"
                + String(repeating: hitLine, count: hitCount - chosenHit - 1)
            check(
                controller.lastOutcome == .replaced(changed: 1, stale: 0) && editor.text == expectedBig
                    && recorded == ["replaceOne", "next"]
                    && editor.selectionStart == (chosenHit + 1) * hitBytes && editor.selectedText == "needle",
                "single Replace on a \(hitCount)-hit buffer replaces exactly the selected hit")
            check(
                replaceElapsed < 10,
                "single Replace on a \(hitCount)-hit buffer stays within its time bound (\(String(format:"%.2f",replaceElapsed)) s)"
            )
            editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
            check(editor.text == big && !editor.modified, "many-hit single Replace is one Undo back to the save point")
            _ = editor.setSelectionAnchor(chosenHit * hitBytes + 3, caret: chosenHit * hitBytes + 8)
            recorded = []
            controller.replaceOne(nil)
            await waitUntil(timeout: 120, "the many-hit single Replace to finish") { !controller.isSearching }
            // F45: this used to be a silent no-op; Replace now behaves as Next when no match is selected.
            check(
                controller.lastOutcome == .selectedNextMatch && editor.text == big && !editor.modified
                    && recorded == ["next"] && editor.selectionStart == (chosenHit + 1) * hitBytes + 3
                    && editor.selectedText == "needle",
                "single Replace with a selection that is not exactly a hit edits nothing and selects the next match")
            // G404: the typed state is set with the status text, and the wording is the product's.
            controller.queryField.stringValue = ""
            controller.findAll(nil)
            check(
                controller.lastOutcome == .needsInput && !controller.isSearching
                    && controller.status.stringValue == "Enter a search expression.",
                "an empty query is reported as needing input without starting a search")
            editor.text = "aa bb aa"
            controller.queryField.stringValue = "aa"
            controller.mode.selectItem(at: 0)
            controller.findAll(nil)
            check(
                controller.isSearching && controller.lastOutcome == nil
                    && controller.status.stringValue.hasPrefix("Searching"),
                "a started search reports that it is searching and has no outcome yet")
            await finished()
            check(
                controller.lastOutcome == .found(matches: 2, documents: 1, truncated: false)
                    && controller.status.stringValue == "2 matches in 1 document.",
                "a finished Find All reports its match and document counts")
            controller.queryField.stringValue = "("
            controller.mode.selectItem(at: 2)
            controller.findAll(nil)
            await finished()
            if case .failed(let reason)? = controller.lastOutcome {
                check(
                    !reason.isEmpty && controller.status.stringValue == reason,
                    "an invalid expression is reported as a failure carrying the shown reason")
            } else {
                check(false, "an invalid expression is reported as a failure carrying the shown reason")
            }
            // G336, G338: a split view. All-open-documents search is given the focused pane, and
            // listed results outlive the pane they were found through.
            do {
                let primary = TTEditor(frame: NSRect(x: 0, y: 0, width: 300, height: 400)),
                    pane = TTEditor(frame: NSRect(x: 300, y: 0, width: 300, height: 400))
                let splitWindow = OffscreenWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: .titled, backing: .buffered,
                    defer: false)
                let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
                splitWindow.contentView = host
                host.addSubview(primary)
                primary.text = "one TODO two TODO three"
                primary.resetUndoHistory()
                primary.setSavePoint()
                pane.shareDocument(with: primary)
                host.addSubview(pane)
                let split = SearchController(defaults: isolated)
                split.currentEditor = { pane }
                split.openEditors = { [pane] }
                split.queryField.stringValue = "TODO"
                split.replacementField.stringValue = "DONE"
                split.mode.selectItem(at: 0)
                split.scope.selectItem(at: 2)
                split.wrapButton.state = .off
                _ = primary.setSelectionAnchor(20, caret: 20)
                _ = pane.setSelectionAnchor(0, caret: 0)
                split.next(nil)
                await waitUntil("the split-view search to finish") { !split.isSearching }
                check(
                    split.lastOutcome != .noFurtherMatches && pane.selectionStart == 4 && pane.selectedText == "TODO"
                        && primary.selectionCaret == 20,
                    "All-open-documents Find Next moves the focused pane's selection and leaves the other pane's alone")
                split.replaceOne(nil)
                await waitUntil("the split-view replace to finish") { !split.isSearching }
                check(
                    split.lastOutcome == .replaced(changed: 1, stale: 0) && primary.text == "one DONE two TODO three",
                    "Replace acts on the match selected in the focused pane, once")
                pane.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
                check(primary.text == "one TODO two TODO three" && !primary.modified, "that replacement is one Undo")
                split.scope.selectItem(at: 0)
                split.findAll(nil)
                await waitUntil("the split-view Find All to finish") { !split.isSearching }
                try require(
                    split.lastOutcome == .found(matches: 2, documents: 1, truncated: false),
                    "fixture: two results listed through the pane")
                pane.retire(inFavorOf: primary)
                pane.removeFromSuperview()
                check(
                    split.activateResult(at: 1) && split.lastOutcome != .staleResult && primary.selectionStart == 13
                        && primary.selectedText == "TODO",
                    "a result listed through a closed pane still selects its match in the remaining view")
                primary.executeCommand(TTEditorCommandIdentifier(rawValue: "selectAll"))
                primary.replaceSelection("edited since")
                check(
                    !split.activateResult(at: 0) && split.lastOutcome == .staleResult,
                    "a result retargeted to the remaining view still goes stale when the document changes")
            }
            // Package 21 (F293, G391, G400): the Find window is a panel that leaves the document
            // window main, Find Next stays in it, and a listed result opens from the keyboard.
            do {
                let text = TTEditor(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
                let host = CountingWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: .titled, backing: .buffered,
                    defer: false)
                host.contentView = text
                text.text = "alpha beta alpha beta alpha"
                let find = SearchController(defaults: isolated)
                find.currentEditor = { text }
                find.openEditors = { [text] }
                @MainActor func done() async { await waitUntil("the panel search to finish") { !find.isSearching } }
                let panel = try requireValue(find.window as? NSPanel, "the Find window is a panel")
                check(
                    !panel.canBecomeMain && panel.canBecomeKey && !panel.hidesOnDeactivate && !panel.isFloatingPanel
                        && panel.level == .normal && panel.styleMask.contains([.titled, .closable, .resizable])
                        && !panel.styleMask.contains(.utilityWindow),
                    "the Find panel cannot become main, does not float and stays when the application is deactivated")
                check(
                    panel.defaultButtonCell == nil && panel.initialFirstResponder === find.queryField,
                    "the Find panel has no default button and starts in the query field")
                find.queryField.stringValue = "alpha"
                find.replacementField.stringValue = ""
                find.mode.selectItem(at: 0)
                find.scope.selectItem(at: 0)
                find.wrapButton.state = .off
                _ = text.setSelectionAnchor(0, caret: 0)
                find.next(nil)
                await done()
                check(
                    text.selectionStart == 0 && text.selectedText == "alpha" && host.fronted == 0,
                    "Find Next selects the match without bringing the document window over the Find panel")
                let action = try requireValue(find.queryField.action, "the query field sends an action on Return")
                check(
                    NSApp.sendAction(action, to: find.queryField.target, from: find.queryField),
                    "fixture: Return in the query field dispatched")
                await done()
                check(
                    text.selectionStart == 11 && text.selectedText == "alpha" && host.fronted == 0,
                    "Return in the query field is Find Next and stays in the Find panel")
                check(find.replacementField.action == nil, "Return in the replacement field does nothing")
                host.showing = false
                find.next(nil)
                await done()
                check(
                    text.selectionStart == 22 && host.fronted == 1,
                    "Find Next brings the document window forward when it is not showing at all")
                host.showing = true
                host.fronted = 0
                find.findAll(nil)
                try require(find.isSearching, "fixture: Find All is running")
                _ = NSApp.sendAction(action, to: find.queryField.target, from: find.queryField)
                await done()
                check(
                    find.lastOutcome == .found(matches: 3, documents: 1, truncated: false)
                        && find.numberOfRows(in: find.table) == 3,
                    "Return in the query field does not cancel a search that is running")
                find.table.selectRowIndexes([2], byExtendingSelection: false)
                let held = text.selectionRanges
                check(
                    find.table.clickedRow == -1
                        && NSApp.sendAction(#selector(SearchController.openResult(_:)), to: find, from: find.table)
                        && text.selectionRanges == held && host.fronted == 0,
                    "a double-click away from the rows does nothing, even with a row selected")
                let returnKey = try requireValue(
                    NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                        characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36),
                    "fixture: a Return key event")
                find.table.keyDown(with: returnKey)
                check(
                    text.selectionStart == 22 && text.selectedText == "alpha" && host.fronted == 1
                        && (host.firstResponder as? NSView)?.isDescendant(of: text) == true,
                    "Return on a selected result selects its match and brings the document forward, focused")
                let enterKey = try requireValue(
                    NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [.numericPad], timestamp: 0, windowNumber: 0,
                        context: nil, characters: "\u{3}", charactersIgnoringModifiers: "\u{3}", isARepeat: false,
                        keyCode: 76), "fixture: an Enter key event")
                find.table.selectRowIndexes([0], byExtendingSelection: false)
                find.table.keyDown(with: enterKey)
                check(
                    text.selectionStart == 0 && text.selectedText == "alpha" && host.fronted == 2,
                    "keypad Enter on a selected result does the same")
                check(find.table.accessibilityLabel() == "Search results", "the result list has a VoiceOver label")
                find.findAll(nil)
                try require(find.isSearching, "fixture: a search is running before Escape")
                panel.cancelOperation(nil)
                check(
                    !find.isSearching && find.lastOutcome == .cancelled,
                    "Escape closes the Find panel, which cancels a running search as closing does")
            }
            // F37: Selection scope searches a range of the document, so Whole word and anchors see
            // the text around the selection, and hits are applied at their document offsets.
            @MainActor func selectionReplaceAll(
                _ text: String, select: NSRange, query: String, regex: Bool = false, whole: Bool = false
            ) async {
                editor.text = text
                editor.resetUndoHistory()
                editor.setSavePoint()
                _ = editor.setSelectionAnchor(select.location, caret: NSMaxRange(select))
                controller.scope.selectItem(at: 1)
                controller.mode.selectItem(at: regex ? 2 : 0)
                controller.caseButton.state = .on
                controller.wordButton.state = whole ? .on : .off
                controller.queryField.stringValue = query
                controller.replacementField.stringValue = "X"
                controller.replaceAll(nil)
                await finished()
            }
            await selectionReplaceAll("foobar foo", select: NSRange(location: 0, length: 3), query: "foo", whole: true)
            check(
                editor.text == "foobar foo" && !editor.modified
                    && controller.lastOutcome == .replaced(changed: 0, stale: 0),
                "Selection scope Whole word does not replace the start of a longer word")
            await selectionReplaceAll("foobar foo", select: NSRange(location: 7, length: 3), query: "foo", whole: true)
            check(
                editor.text == "foobar X" && controller.lastOutcome == .replaced(changed: 1, stale: 0),
                "Selection scope Whole word replaces the selected whole word in place")
            editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
            check(editor.text == "foobar foo" && !editor.modified, "Selection scope replace all is one Undo")
            // "🥑é " is 7 bytes and 4 UTF-16 units: a double-applied or byte offset would miss.
            await selectionReplaceAll(
                "🥑é foo foo foo", select: NSRange(location: 11, length: 7), query: "foo", whole: true)
            check(
                editor.text == "🥑é foo X X" && controller.lastOutcome == .replaced(changed: 2, stale: 0),
                "Selection scope hits after a non-ASCII prefix land on the selected occurrences only")
            await selectionReplaceAll("ax ax", select: NSRange(location: 4, length: 1), query: "^x", regex: true)
            check(editor.text == "ax ax", "Selection scope line-start anchor does not match in the middle of a line")
            await selectionReplaceAll("xa\nxa", select: NSRange(location: 3, length: 1), query: "^x", regex: true)
            check(editor.text == "xa\nXa", "Selection scope line-start anchor matches at a real line start")
            await selectionReplaceAll("ab ab", select: NSRange(location: 4, length: 1), query: "(?<=a)b", regex: true)
            check(editor.text == "ab aX", "Selection scope lookbehind sees the character before the selection")
            await selectionReplaceAll("l1\nl2 foo\nl3 foo\n", select: NSRange(location: 11, length: 6), query: "foo")
            editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
            _ = editor.setBookmarks([])
            _ = editor.setSelectionAnchor(11, caret: 17)
            controller.bookmark(nil)
            await finished()
            check(
                editor.bookmarkLines.map(\.intValue) == [2] && editor.text == "l1\nl2 foo\nl3 foo\n",
                "Selection scope bookmarks the line of the selected hit, not a shifted one")
            _ = editor.setBookmarks([])
            controller.scope.selectItem(at: 0)
            controller.wordButton.state = .off
            controller.caseButton.state = .off
            // ---- Package 10: Find and Replace controller behaviour ----
            @MainActor func load(_ target: TTEditor, _ text: String) {
                target.text = text
                target.resetUndoHistory()
                target.setSavePoint()
            }
            @MainActor func offscreenEditor(_ text: String) -> (TTEditor, OffscreenWindow) {
                let made = TTEditor(frame: NSRect(x: 0, y: 0, width: 600, height: 400)),
                    host = OffscreenWindow(
                        contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: .titled,
                        backing: .buffered, defer: false)
                host.contentView = made
                load(made, text)
                return (made, host)
            }
            @MainActor func next() async {
                controller.next(nil)
                await finished()
            }
            @MainActor func previous() async {
                controller.previous(nil)
                await finished()
            }
            @MainActor func replaceOne() async {
                controller.replaceOne(nil)
                await finished()
            }
            @MainActor func replaceAll() async {
                controller.replaceAll(nil)
                await finished()
            }
            @MainActor func literal(_ query: String, _ replacement: String, scope: Int, wrap: Bool) {
                controller.mode.selectItem(at: 0)
                controller.scope.selectItem(at: scope)
                controller.caseButton.state = .on
                controller.wordButton.state = .off
                controller.wrapButton.state = wrap ? .on : .off
                controller.queryField.stringValue = query
                controller.replacementField.stringValue = replacement
            }
            var recordedOptions: [SearchOptions] = []
            controller.onCommand = { options, action, _ in
                recorded.append(action)
                recordedOptions.append(options)
            }

            // F35: Next and Previous in Selection scope walk the hits of the scope and keep it.
            literal("a", "b", scope: 1, wrap: false)
            load(editor, "xa a a ax")
            _ = editor.setSelectionAnchor(1, caret: 6)
            recorded = []
            var visited: [Int] = []
            let reusedBeforeScope = controller.reusedResults
            for _ in 0..<3 {
                await next()
                visited.append(editor.selectionStart)
            }
            check(
                visited == [1, 3, 5] && editor.selectionEnd == 6 && recorded.isEmpty,
                "Selection scope Next visits each hit inside the selection in order")
            var signalsBefore = signals
            await next()
            check(
                editor.selectionStart == 5 && editor.selectionEnd == 6 && controller.lastOutcome == .noFurtherMatches
                    && controller.status.stringValue == "No further matches." && signals == signalsBefore + 1,
                "Selection scope Next past the last hit in scope stops and never leaves the scope")
            check(
                controller.reusedResults == reusedBeforeScope + 3,
                "Selection scope Next reuses the results of the first press while nothing changed")
            controller.wrapButton.state = .on
            _ = editor.setSelectionAnchor(1, caret: 6)
            visited = []
            for _ in 0..<4 {
                await next()
                visited.append(editor.selectionStart)
            }
            check(visited == [1, 3, 5, 1], "Selection scope Next with Wrap on wraps inside the scope")
            _ = editor.setSelectionAnchor(1, caret: 6)
            visited = []
            for _ in 0..<4 {
                await previous()
                visited.append(editor.selectionStart)
            }
            check(
                visited == [5, 3, 1, 5], "Selection scope Previous starts at the last hit in scope and wraps inside it")
            _ = editor.setSelectionAnchor(6, caret: 9)
            await next()
            check(
                editor.selectionStart == 7 && editor.selectionEnd == 8,
                "a manual selection change after navigating starts a new scope from the live selection")
            load(editor, "xa a a ax")
            _ = editor.setSelectionAnchor(2, caret: 2)
            signalsBefore = signals
            await next()
            check(
                controller.lastOutcome == .needsInput
                    && controller.status.stringValue == "Select one nonempty range first."
                    && editor.selectionCaret == 2 && signals == signalsBefore + 1,
                "Selection scope Next after an edit with nothing selected asks for a selection")
            _ = editor.setSelectionAnchor(1, caret: 6)
            controller.wrapButton.state = .off
            await next()
            await replaceOne()
            check(
                editor.text == "xb a a ax" && controller.lastOutcome == .replaced(changed: 1, stale: 0)
                    && recorded.isEmpty,
                "Selection scope Replace right after a Selection scope Next replaces the selected match")
            editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
            check(editor.text == "xa a a ax" && !editor.modified, "that Selection scope Replace is one Undo")
            literal("a", "b", scope: 0, wrap: false)
            _ = editor.setSelectionAnchor(0, caret: 0)
            visited = []
            for _ in 0..<4 {
                await next()
                visited.append(editor.selectionStart)
            }
            signalsBefore = signals
            await next()
            check(
                visited == [1, 3, 5, 7] && editor.selectionStart == 7 && controller.lastOutcome == .noFurtherMatches
                    && signals == signalsBefore + 1 && recorded == ["next", "next", "next", "next"],
                "Current document Next visits every hit, then stops with Wrap off")
            controller.wrapButton.state = .on
            await next()
            check(editor.selectionStart == 1, "Current document Next with Wrap on returns to the first hit")
            await previous()
            check(editor.selectionStart == 7, "Current document Previous with Wrap on returns to the last hit")

            // F36: single Replace with All open documents edits only the document it was pressed in.
            let (second, secondWindow) = offscreenEditor("x=1 x=2")
            load(editor, "x=1 x=2")
            var open: [TTEditor] = [editor, second]
            var focused: TTEditor? = second
            controller.openEditors = { open }
            controller.currentEditor = { focused }
            literal("x", "y", scope: 2, wrap: false)
            _ = editor.setSelectionAnchor(0, caret: 1)
            _ = second.setSelectionAnchor(0, caret: 1)
            let backgroundRevision = editor.revision
            recorded = []
            await replaceOne()
            check(
                editor.text == "x=1 x=2" && editor.revision == backgroundRevision && !editor.modified,
                "All open documents Replace leaves a background document with a selected match untouched")
            check(
                second.text == "y=1 x=2" && controller.lastOutcome == .replaced(changed: 1, stale: 0)
                    && controller.status.stringValue.hasPrefix("Replaced 1 match") && recorded.isEmpty,
                "All open documents Replace replaces the selected match of the current document")
            second.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
            check(second.text == "x=1 x=2" && !second.modified, "that Replace is one Undo in the current document")
            await replaceAll()
            check(
                editor.text == "y=1 y=2" && second.text == "y=1 y=2"
                    && controller.lastOutcome == .replaced(changed: 4, stale: 0),
                "All open documents Replace All still replaces in every open document")
            editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
            second.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
            check(
                editor.text == "x=1 x=2" && second.text == "x=1 x=2" && !editor.modified && !second.modified,
                "All open documents Replace All is one Undo in each document")

            // F48: All open documents navigation moves between documents, in open order.
            let (third, thirdWindow) = offscreenEditor("zq")
            let (stray, strayWindow) = offscreenEditor("zq zq")
            @MainActor func caretsToStart() {
                for target in [editor, second, third] { _ = target.setSelectionAnchor(0, caret: 0) }
            }
            @MainActor func place() -> String {
                @MainActor func one(_ target: TTEditor) -> String { "\(target.selectionStart)-\(target.selectionEnd)" }
                return [editor, second, third].map(one).joined(separator: " ")
            }
            literal("zq", "", scope: 2, wrap: false)
            load(editor, "none here")
            load(second, "zq zq")
            load(third, "none")
            open = [editor, second, third]
            focused = editor
            caretsToStart()
            await next()
            check(
                place() == "0-0 0-2 0-0"
                    && controller.lastOutcome == .found(matches: 2, documents: 3, truncated: false),
                "All open documents Next moves to the first hit of a later document")
            await next()
            check(
                place() == "0-0 3-5 0-0",
                "a repeated Next continues in that document although the current editor was not updated")
            signalsBefore = signals
            await next()
            check(
                place() == "0-0 3-5 0-0" && controller.lastOutcome == .noFurtherMatches && signals == signalsBefore + 1,
                "All open documents Next after the last hit of the last document stops with Wrap off")
            load(editor, "zq a")
            load(second, "zq zq")
            load(third, "zq")
            caretsToStart()
            controller.wrapButton.state = .on
            var places: [String] = []
            for _ in 0..<5 {
                await next()
                places.append(place())
            }
            check(
                places == ["0-2 0-0 0-0", "0-2 0-2 0-0", "0-2 3-5 0-0", "0-2 3-5 0-2", "0-2 3-5 0-2"]
                    && editor.selectionStart == 0,
                "All open documents Next with Wrap on goes through every document and returns to the first")
            places = []
            for _ in 0..<4 {
                await previous()
                places.append(place())
            }
            check(
                places == ["0-2 3-5 0-2", "0-2 3-5 0-2", "0-2 0-2 0-2", "0-2 0-2 0-2"],
                "All open documents Previous with Wrap on walks the documents backwards")
            load(editor, "zq a")
            load(second, "zq zq")
            load(third, "zq")
            caretsToStart()
            controller.wrapButton.state = .off
            signalsBefore = signals
            await previous()
            check(
                place() == "0-0 0-0 0-0" && controller.lastOutcome == .noFurtherMatches && signals == signalsBefore + 1,
                "All open documents Previous before the first hit of the first document stops with Wrap off")
            await next()
            await next()
            check(place() == "0-2 0-2 0-0", "fixture: navigated from the first document into the second")
            focused = third
            await next()
            check(
                place() == "0-2 0-2 0-2",
                "after the person moves to a third document, Next continues from that document")
            load(editor, "zq a")
            load(second, "zq zq")
            load(third, "zq")
            caretsToStart()
            focused = stray
            await next()
            check(
                place() == "0-2 0-0 0-0" && stray.selectionEnd == 0,
                "a current editor outside the open list counts as before the first document for Next")
            load(editor, "zq a")
            caretsToStart()
            await previous()
            check(
                place() == "0-0 0-0 0-2",
                "a current editor outside the open list counts as after the last document for Previous")

            // F36 with F48: after Next has moved into another document, Replace edits that document
            // although the application's current editor still names the one before.
            literal("a", "b", scope: 2, wrap: false)
            load(editor, "a x")
            load(second, "a a")
            open = [editor, second]
            focused = editor
            caretsToStart()
            recorded = []
            await next()
            await next()
            check(place() == "0-1 0-1 0-0", "fixture: Next selected a match in the first document, then in the second")
            let leftBehindRevision = editor.revision
            await replaceOne()
            check(
                editor.text == "a x" && editor.revision == leftBehindRevision && !editor.modified,
                "Replace after a cross-document Next leaves the document left behind untouched")
            check(
                second.text == "b a" && controller.lastOutcome == .replaced(changed: 1, stale: 0)
                    && controller.status.stringValue.hasPrefix("Replaced 1 match") && recorded.isEmpty,
                "Replace after a cross-document Next replaces the match that Next selected")
            second.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
            check(second.text == "a a" && !second.modified, "that Replace is one Undo in the document navigated to")
            load(editor, "none")
            load(second, "a a")
            caretsToStart()
            await next()
            await replaceOne()
            check(
                editor.text == "none" && !editor.modified && second.text == "b a"
                    && controller.lastOutcome == .replaced(changed: 1, stale: 0),
                "All open documents Next into another document, then Replace, replaces that match")
            // The person goes back: the document left behind is the visible tab again, and the
            // application's current editor is the same object as while it lagged.
            load(second, "a x")
            load(third, "a a")
            open = [second, third]
            focused = second
            caretsToStart()
            await next()
            await next()
            check(place() == "0-0 0-1 0-1", "fixture: Next moved from the second document into the third")
            secondWindow.shown = true
            thirdWindow.shown = false
            let hiddenRevision = third.revision
            await replaceOne()
            check(
                second.text == "b x" && third.text == "a a" && third.revision == hiddenRevision && !third.modified
                    && controller.lastOutcome == .replaced(changed: 1, stale: 0),
                "Replace after the person returned to the earlier document edits it, not the hidden one")
            load(second, "a x")
            load(third, "a a")
            caretsToStart()
            await next()
            await next()
            secondWindow.shown = true
            thirdWindow.shown = false
            await next()
            check(
                place() == "0-0 0-1 0-1",
                "Next after the person returned to the earlier document continues from it, not from the hidden one")
            secondWindow.shown = false
            thirdWindow.shown = true
            await next()
            check(place() == "0-0 0-1 2-3", "fixture: with the third document shown, Next continues in it")
            // A current editor outside the open list, such as a split view: Replace needs a match
            // selected by Next, and then replaces it.
            load(editor, "a x")
            load(second, "a a")
            open = [editor, second]
            focused = stray
            caretsToStart()
            await replaceOne()
            check(
                controller.lastOutcome == .noMatchSelected && editor.text == "a x" && second.text == "a a"
                    && stray.text == "zq zq",
                "All open documents Replace from an unlisted editor with nothing navigated changes nothing")
            await next()
            await replaceOne()
            check(
                editor.text == "b x" && second.text == "a a" && stray.text == "zq zq"
                    && controller.lastOutcome == .replaced(changed: 1, stale: 0),
                "All open documents Next then Replace from an unlisted editor replaces the selected match")
            // The same editor outside the list, with Next crossing into another document: while
            // that document is the visible tab, Replace edits the match Next selected there.
            load(editor, "a x")
            load(second, "a a")
            caretsToStart()
            strayWindow.shown = false
            await next()
            await next()
            check(
                place() == "0-1 0-1 0-0" && secondWindow.shown,
                "fixture: from an unlisted editor, Next selected a match in the first document, then in the second")
            await replaceOne()
            check(
                editor.text == "a x" && second.text == "b a"
                    && controller.lastOutcome == .replaced(changed: 1, stale: 0),
                "Replace after a cross-document Next from an unlisted editor replaces the match in the visible document"
            )
            // The person goes back to the tab with the split view: the unlisted editor is on screen
            // and the document navigated to is hidden, so Replace and Next leave the hidden one alone.
            load(editor, "a x")
            load(second, "a a")
            caretsToStart()
            await next()
            await next()
            check(place() == "0-1 0-1 0-0", "fixture: Next moved from the first document into the second again")
            secondWindow.shown = false
            strayWindow.shown = true
            let hiddenSecondRevision = second.revision
            await replaceOne()
            check(
                controller.lastOutcome == .noMatchSelected && second.text == "a a"
                    && second.revision == hiddenSecondRevision && !second.modified && editor.text == "a x"
                    && stray.text == "zq zq",
                "Replace from an unlisted editor after the person returned to its tab leaves the hidden document untouched"
            )
            await next()
            check(
                place() == "0-1 0-1 0-0" && second.revision == hiddenSecondRevision,
                "Next from an unlisted editor after the person returned does not continue in the hidden document")
            strayWindow.shown = false
            _ = (secondWindow, thirdWindow, strayWindow)
            open = [editor]
            focused = editor

            // F35: a scope kept from Selection scope does not survive navigation in another scope.
            literal("a", "b", scope: 1, wrap: false)
            load(editor, "xa a a ax")
            _ = editor.setSelectionAnchor(1, caret: 6)
            await next()
            controller.scope.selectItem(at: 0)
            for _ in 0..<3 { await next() }
            check(
                editor.selectionStart == 7 && editor.selectionEnd == 8,
                "fixture: Current document Next left the scope selected earlier")
            controller.scope.selectItem(at: 1)
            await next()
            check(
                editor.selectionStart == 7 && editor.selectionEnd == 8
                    && controller.lastOutcome == .found(matches: 1, documents: 1, truncated: false),
                "Selection scope Next after navigating in another scope takes the live selection as its scope")
            controller.scope.selectItem(at: 0)

            // F45: Replace finds the next match when none is selected, and moves on after replacing.
            controller.mode.selectItem(at: 2)
            controller.scope.selectItem(at: 0)
            controller.wrapButton.state = .off
            controller.queryField.stringValue = "([a-z]+)=(\\d+)"
            controller.replacementField.stringValue = "$1:$2"
            load(editor, "one=12 two=34")
            _ = editor.setSelectionAnchor(0, caret: 0)
            recorded = []
            recordedOptions = []
            await replaceOne()
            check(
                editor.text == "one=12 two=34" && !editor.modified && editor.selectedText == "one=12"
                    && controller.lastOutcome == .selectedNextMatch
                    && !controller.status.stringValue.hasPrefix("Replaced 0 matches") && recorded == ["next"],
                "Replace with no match selected selects the next match and edits nothing")
            await replaceOne()
            check(
                editor.text == "one:12 two=34" && editor.selectedText == "two=34"
                    && controller.lastOutcome == .replaced(changed: 1, stale: 0)
                    && controller.status.stringValue.hasPrefix("Replaced 1 match")
                    && controller.status.stringValue.hasSuffix("Selected the next match.")
                    && recorded == ["next", "replaceOne", "next"],
                "Replace on a selected match replaces it, selects the following match and records both steps")
            let (replay, replayWindow) = offscreenEditor("one=12 two=34")
            _ = replay.setSelectionAnchor(0, caret: 0)
            for (options, action) in zip(recordedOptions, recorded) {
                try controller.playRecorded(options: options, action: action, on: replay)
            }
            check(
                replay.text == editor.text && replay.selectionStart == editor.selectionStart
                    && replay.selectionEnd == editor.selectionEnd,
                "the steps recorded by Replace play back to the same text and selection")
            _ = replayWindow
            editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
            check(editor.text == "one=12 two=34" && !editor.modified, "a Replace that moved on is one Undo")
            editor.executeCommand(TTEditorCommandIdentifier(rawValue: "redo"))
            _ = editor.setSelectionAnchor(7, caret: 13)
            recorded = []
            await replaceOne()
            check(
                editor.text == "one:12 two:34" && controller.lastOutcome == .replaced(changed: 1, stale: 0)
                    && controller.status.stringValue.hasSuffix("No further matches.") && editor.selectionCaret == 13
                    && recorded == ["replaceOne"],
                "Replace of the last match reports that no further match follows")
            load(editor, "one=12 two=34")
            _ = editor.setSelectionAnchor(0, caret: 3)
            recorded = []
            controller.scope.selectItem(at: 1)
            await replaceOne()
            check(
                editor.text == "one=12 two=34" && controller.lastOutcome == .noMatchSelected
                    && controller.status.stringValue == "No match is selected; use Next first." && recorded.isEmpty
                    && editor.selectionStart == 0 && editor.selectionEnd == 3,
                "Selection scope Replace with no match selected says so and changes nothing")
            controller.scope.selectItem(at: 2)
            await replaceOne()
            check(
                editor.text == "one=12 two=34" && controller.lastOutcome == .noMatchSelected && recorded.isEmpty
                    && editor.selectionEnd == 3,
                "All open documents Replace with no match selected says so and changes nothing")
            controller.scope.selectItem(at: 0)
            _ = editor.setSelectionAnchor(0, caret: 6)
            controller.replaceOne(nil)
            editor.text = "changed meanwhile"
            await finished()
            check(
                editor.text == "changed meanwhile" && controller.lastOutcome == .replaced(changed: 0, stale: 1)
                    && controller.status.stringValue.contains("1 changed document skipped") && recorded.isEmpty,
                "Replace on a document edited during the search preserves it and reports the skip")
            // F45 with G374: a caret at a zero-width match ends after the text inserted there, as
            // typing would leave it, so the next Replace moves on instead of inserting there again.
            controller.mode.selectItem(at: 2)
            controller.scope.selectItem(at: 0)
            controller.wrapButton.state = .off
            controller.queryField.stringValue = "^"
            controller.replacementField.stringValue = ">"
            load(editor, "ab\ncd")
            _ = editor.setSelectionAnchor(0, caret: 0)
            recorded = []
            await replaceOne()
            check(
                editor.text == ">ab\ncd" && editor.selectionAnchor == 4 && editor.selectionCaret == 4
                    && recorded == ["replaceOne", "next"],
                "Replace at a zero-width match inserts once and moves to the next line's match")
            await replaceOne()
            check(
                editor.text == ">ab\n>cd" && editor.selectionAnchor == 5 && editor.selectionCaret == 5,
                "a second Replace inserts at the next zero-width match, not at the first one again")
            controller.mode.selectItem(at: 0)
            // F45: cancelling while the following match is being looked for does not deny the
            // replacement that was already made.
            literal("a", "b", scope: 0, wrap: false)
            try await followUpCancelChecks(controller, editor: editor)
            editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
            check(editor.text == "a a" && !editor.modified, "that cancelled Replace is one Undo")
            controller.replaceAll(nil)
            controller.cancel(nil)
            try await Task.sleep(nanoseconds: 50_000_000)
            check(
                editor.text == "a a" && controller.lastOutcome == .cancelled
                    && controller.status.stringValue == "Cancelled; no pending replacements applied.",
                "Cancel before any replacement keeps saying that nothing was applied")

            // F46: a match that starts on the LF of a CRLF bookmarks the line that owns the CRLF.
            load(editor, "a\r\nb\r\n")
            _ = editor.setBookmarks([])
            controller.mode.selectItem(at: 1)
            controller.queryField.stringValue = "\\n"
            controller.bookmark(nil)
            await finished()
            check(
                editor.bookmarkLines.map(\.intValue) == [0, 1] && controller.lastOutcome == .bookmarked(stale: 0),
                "Bookmark Matches for an extended \\n in a CRLF document marks the lines that end, not the next ones")
            _ = editor.setBookmarks([])

            // F308: Find Next and Find Previous give an audible signal when they select nothing,
            // with the Find window never shown.
            @MainActor func button(_ title: String) -> NSButton? {
                @MainActor func walk(_ view: NSView) -> NSButton? {
                    if let found = view as? NSButton, found.title == title { return found }
                    for child in view.subviews { if let found = walk(child) { return found } }
                    return nil
                }
                return controller.window?.contentView.flatMap(walk)
            }
            literal("zzz", "", scope: 0, wrap: false)
            load(editor, "plain text here")
            _ = editor.setSelectionAnchor(2, caret: 4)
            let quietRevision = editor.revision
            signalsBefore = signals
            await next()
            check(
                controller.status.stringValue == "No further matches." && signals == signalsBefore + 1
                    && editor.selectionAnchor == 2 && editor.selectionCaret == 4 && editor.revision == quietRevision,
                "Find Next that finds nothing signals once and leaves selection and text alone")
            controller.queryField.stringValue = "text"
            await next()
            check(
                editor.selectedText == "text" && signals == signalsBefore + 1 && controller.window?.isVisible == false
                    && (editor.window?.firstResponder as? NSView)?.isDescendant(of: editor) == true,
                "Find Next that finds a match is silent, keeps the Find window closed and focuses the editor")
            controller.queryField.stringValue = ""
            controller.previous(nil)
            check(
                controller.status.stringValue == "Enter a search expression." && signals == signalsBefore + 2
                    && controller.window?.isVisible == false,
                "Find Previous with no search expression signals")
            controller.findAll(nil)
            check(signals == signalsBefore + 2, "Find All with no search expression stays silent")
            controller.queryField.stringValue = "("
            controller.mode.selectItem(at: 2)
            await next()
            var failedAsExpected = false
            if case .failed? = controller.lastOutcome { failedAsExpected = true }
            check(
                failedAsExpected && signals == signalsBefore + 3 && button("Next")?.isEnabled == true
                    && button("Replace All")?.isEnabled == true,
                "Find Next with an invalid expression signals and leaves the buttons enabled")
            controller.findAll(nil)
            await finished()
            check(signals == signalsBefore + 3, "Find All with an invalid expression stays silent")
            controller.mode.selectItem(at: 0)
            controller.queryField.stringValue = "text"
            focused = nil
            controller.next(nil)
            check(
                controller.status.stringValue == "Open a document first." && signals == signalsBefore + 4,
                "Find Next with no document signals")
            focused = editor
            controller.next(nil)
            editor.text = "zz"
            await finished()
            check(
                controller.lastOutcome == .staleResult && signals == signalsBefore + 5 && editor.text == "zz",
                "Find Next whose document changed during the search signals and selects nothing")

            // F44, F224: a typed replacement outcome, and one batch edit under one undo action.
            var typed = SearchOptions()
            typed.query = "aa"
            typed.replacement = "c"
            typed.matchCase = true
            load(editor, "aa bb aa")
            let typedText = editor.text, typedRevision = editor.revision
            let typedHits = try SearchCore.search(typedText, options: typed).hits
            @MainActor func unedited() -> Bool { editor.text == typedText && !editor.modified }
            @MainActor func untouched() -> Bool { unedited() && editor.revision == typedRevision }
            editor.readOnly = true
            check(
                SearchController.replace(typedHits, text: typedText, revision: typedRevision, in: editor) == .readOnly
                    && untouched(), "a read-only document is reported as read-only and not edited")
            editor.readOnly = false
            check(
                SearchController.replace(typedHits, text: typedText, revision: typedRevision + 1, in: editor) == .stale
                    && untouched(), "a document at another revision is reported as changed and not edited")
            _ = editor.setSelectionRanges([TTSelectionRange(anchor: 0, caret: 0), TTSelectionRange(anchor: 3, caret: 3)]
            )
            check(
                SearchController.replace(typedHits, text: typedText, revision: typedRevision, in: editor)
                    == .multipleSelections && untouched() && editor.selectionCount == 2,
                "a document with multiple selections is reported as such and not edited")
            _ = editor.setSelectionAnchor(4, caret: 4)
            offscreen.contentView = nil
            check(
                SearchController.replace(typedHits, text: typedText, revision: typedRevision, in: editor) == .closed
                    && untouched(), "a document that is no longer in a window is reported as closed and not edited")
            offscreen.contentView = editor
            let shifted = [SearchHit(range: NSRange(location: 7, length: 5), replacement: "c")]
            check(
                SearchController.replace(typedHits + shifted, text: typedText, revision: typedRevision, in: editor)
                    == .stale && untouched() && editor.selectionCaret == 4,
                "one invalid range rejects the whole batch before any edit")
            check(
                SearchController.replace(typedHits, text: typedText, revision: typedRevision, in: editor) == .applied(2)
                    && editor.text == "c bb c" && editor.selectionCount == 1 && editor.selectionAnchor == 3
                    && editor.selectionCaret == 3,
                "a batch replacement reports its count and keeps the caret at the text it was on (G374)")
            editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
            check(unedited(), "a batch replacement is one Undo back to the save point")
            literal("aa", "c", scope: 0, wrap: false)
            editor.readOnly = true
            recorded = []
            await replaceAll()
            check(
                controller.lastOutcome == .replaced(changed: 0, stale: 1)
                    && controller.lastReplaceSkips == ReplaceSkips(readOnly: 1)
                    && controller.status.stringValue.contains("1 read-only") && unedited() && recorded.isEmpty,
                "Replace All on a read-only document says read-only, not changed")
            editor.readOnly = false
            _ = editor.setSelectionRanges([TTSelectionRange(anchor: 0, caret: 0), TTSelectionRange(anchor: 3, caret: 3)]
            )
            await replaceAll()
            check(
                controller.lastOutcome == .replaced(changed: 0, stale: 1)
                    && controller.lastReplaceSkips == ReplaceSkips(multipleSelections: 1)
                    && controller.status.stringValue.contains("1 with multiple selections") && unedited(),
                "Replace All with multiple selections says so and edits nothing")
            _ = editor.setSelectionAnchor(8, caret: 8)
            let revisionBeforeReplacements = editor.revision
            var changeCallbacks = 0
            editor.onChange = { changeCallbacks += 1 }
            await replaceAll()
            editor.onChange = nil
            check(
                editor.text == "c bb c" && controller.lastOutcome == .replaced(changed: 2, stale: 0)
                    && controller.lastReplaceSkips == ReplaceSkips() && editor.selectionAnchor == 6
                    && editor.selectionCaret == 6 && recorded == ["replaceAll"]
                    && controller.status.stringValue
                        == "Replaced 2 matches; 0 changed documents skipped. Undo is per document.",
                "Replace All replaces every match, records once and keeps the caret at the text it was on (G374)")
            check(
                changeCallbacks == 1 && editor.revision == revisionBeforeReplacements + 4,
                "Replace All coalesces two insert/delete pairs into one callback and records all four revisions")
            editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
            check(unedited(), "Replace All is one Undo back to the save point")

            // F223: unchanged editors, revisions and options reuse the held results; revision
            // alone decides staleness.
            literal("aa", "", scope: 0, wrap: true)
            load(editor, "aa bb aa aa")
            _ = editor.setSelectionAnchor(0, caret: 0)
            var reused = controller.reusedResults
            await next()
            check(
                editor.selectionStart == 0 && editor.selectionEnd == 2 && controller.reusedResults == reused,
                "the first Next searches the document")
            controller.next(nil)
            check(
                !controller.isSearching && editor.selectionStart == 6 && controller.reusedResults == reused + 1
                    && controller.lastOutcome == .found(matches: 3, documents: 1, truncated: false),
                "a repeated Next walks the held results without searching again")
            controller.previous(nil)
            check(
                !controller.isSearching && editor.selectionStart == 0 && controller.reusedResults == reused + 2,
                "Previous walks the same held results")
            reused = controller.reusedResults
            controller.caseButton.state = .off
            await next()
            check(
                controller.reusedResults == reused && editor.selectionStart == 6,
                "changing an option searches again instead of reusing results")
            _ = editor.setSelectionAnchor(0, caret: 0)
            _ = editor.replaceSelection("aa ")
            await next()
            check(
                controller.reusedResults == reused && editor.selectionStart == 3 && editor.selectionEnd == 5
                    && controller.lastOutcome == .found(matches: 4, documents: 1, truncated: false),
                "an edit moves the revision, so Next searches the new text")
            controller.findAll(nil)
            await finished()
            let heldRevision = editor.revision
            _ = editor.setSelectionAnchor(0, caret: 2)
            _ = editor.replaceSelection("aa")
            check(
                editor.text == "aa aa bb aa aa" && editor.revision != heldRevision,
                "fixture: an edit that restores the same text still moves the revision")
            let heldHits = try SearchCore.search(editor.text, options: SearchOptions(query: "aa")).hits
            check(
                !SearchController.apply(heldHits, text: editor.text, revision: heldRevision, to: editor)
                    && !SearchController.highlight(heldHits, text: editor.text, revision: heldRevision, in: editor)
                    && editor.text == "aa aa bb aa aa",
                "results from an earlier revision are rejected even when the text reads the same")

            // F122: results hold editors weakly and are dropped when the Find window closes.
            weak var released: TTEditor?
            do {
                let (extra, extraWindow) = offscreenEditor("aa in a document that will close")
                released = extra
                open = [editor, extra]
                controller.scope.selectItem(at: 2)
                controller.findAll(nil)
                await finished()
                check(
                    controller.lastOutcome == .found(matches: 5, documents: 2, truncated: false)
                        && controller.numberOfRows(in: controller.table) == 5,
                    "fixture: All open documents results include the document that will close")
                let lastRow = controller.tableView(controller.table, objectValueFor: nil, row: 4) as? String
                check(
                    lastRow?.hasSuffix(" · 1:1 · aa") == true, "a result row shows its document, line/column and match")
                open = [editor]
                extraWindow.contentView = nil
            }
            await waitUntil("the closed document's editor to be released") { released == nil }
            check(released == nil, "Find results do not keep a closed document's editor alive")
            check(
                controller.numberOfRows(in: controller.table) == 5
                    && controller.tableView(controller.table, objectValueFor: nil, row: 4) as? String
                        == "Document · 1:1 · aa",
                "rows of a closed document stay listed from the one retained snapshot")
            controller.window?.close()
            check(
                controller.numberOfRows(in: controller.table) == 0 && controller.lastOutcome == .cancelled,
                "closing the Find window drops the results and their text snapshots")
            controller.scope.selectItem(at: 0)
            await next()
            check(
                editor.selectedText == "aa" && controller.numberOfRows(in: controller.table) == 4,
                "Find Next still works after the Find window was closed")
            controller.wordButton.state = .off
            controller.caseButton.state = .off
            editor.text = "\t😀e\u{301}x\r\n"
            editor.configureTabWidth(8, useTabs: true)
            controller.currentEditor = { editor }
            controller.openEditors = { [editor] }
            controller.queryField.stringValue = "x"
            controller.mode.selectItem(at: 0)
            controller.scope.selectItem(at: 0)
            controller.findAll(nil)
            await finished()
            check(
                (controller.tableView(controller.table, objectValueFor: nil, row: 0) as? String)?.contains(
                    " · 1:12 · x") == true,
                "G346 actual Find row uses captured native-style Unicode/tab-stop position")
            // Reorder presentation choices; persisted raw mode 0 remains Normal independently of index.
            let normalItem = controller.mode.item(at: 0)!
            controller.mode.menu?.removeItem(normalItem)
            controller.mode.menu?.addItem(normalItem)
            controller.mode.select(normalItem)
            editor.text = "x.x"
            controller.queryField.stringValue = "."
            controller.findAll(nil)
            await finished()
            check(
                controller.lastOutcome == .found(matches: 1, documents: 1, truncated: false),
                "F182 reordered mode display retains represented search identity")
            try await findStateChecks(support.url)
            try await largeDocumentChecks(support.url)
            Checks.summary { "PASS SearchControllerChecks: \(Checks.count) assertions" }
        }
    }
}
