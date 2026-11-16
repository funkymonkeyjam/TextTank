@testable import TextTankCore
import AppKit
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
@main struct SearchControllerChecks {
    @MainActor static func main() async {
        await Checks.run("SearchControllerChecks") {
            let support = try IsolatedSupportDirectory("TextTankSearchControllerChecks")
            defer { support.restore() }
            _ = NSApplication.shared
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
            let originalProvider = AppStorage.sharedDefaultsProvider
            AppStorage.sharedDefaultsProvider = {
                providerCalls += 1
                return protected
            }
            defer {
                AppStorage.sharedDefaultsProvider = originalProvider
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
            let persisted = try FindPreferences.decode(Data(contentsOf: AppStorage.url(.find))).options
            check(
                persisted.query == "([a-z]+)=(\\d+)" && persisted.replacement == "$1:$2"
                    && persisted.mode == .regularExpression,
                "a Find-window action saves its options in the isolated private file")
            check(
                providerCalls == 0 && protected.data(forKey: "TextTank.Search.v1") == Data("sentinel".utf8)
                    && isolated.data(forKey: "TextTank.Search.v1") == nil,
                "private saves never obtain shared legacy defaults or write either protected legacy fixture")
            let reopened = SearchController(defaults: isolated)
            check(
                reopened.queryField.stringValue == "([a-z]+)=(\\d+)" && reopened.replacementField.stringValue == "$1:$2"
                    && reopened.mode.indexOfSelectedItem == 2,
                "a second controller on the same defaults restores the saved options")
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
            load(editor, "a a")
            _ = editor.setSelectionAnchor(0, caret: 1)
            recorded = []
            var cancelQueued = false
            let changeHandler = editor.onChange
            editor.onChange = {
                changeHandler?()
                guard !cancelQueued else { return }
                cancelQueued = true
                // Runs on the main queue after the replacement and before the follow-up search returns.
                DispatchQueue.main.async { controller.cancel(nil) }
            }
            controller.replaceOne(nil)
            await finished()
            editor.onChange = changeHandler
            try await Task.sleep(nanoseconds: 50_000_000)
            check(
                // G374: the replacement of the selected match stays selected.
                cancelQueued && editor.text == "b a" && editor.selectionAnchor == 0 && editor.selectionCaret == 1,
                "fixture: the search was cancelled after the replacement and before the next match was selected")
            check(
                controller.lastOutcome == .replaced(changed: 1, stale: 0)
                    && controller.status.stringValue.hasPrefix("Replaced 1 match")
                    && controller.status.stringValue.hasSuffix("Cancelled before the next match was selected.")
                    && !controller.status.stringValue.contains("no pending replacements applied")
                    && !controller.isSearching && recorded == ["replaceOne"],
                "Cancel during the search that follows a Replace still reports the replacement")
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
                changeCallbacks >= 2 && changeCallbacks <= 5,
                "Replace All of two matches reports only its own inserts and deletes (\(changeCallbacks) callbacks)")
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
            Checks.summary { "PASS SearchControllerChecks: \(Checks.count) assertions" }
        }
    }
}
