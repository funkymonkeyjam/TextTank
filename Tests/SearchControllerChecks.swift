import AppKit
/// Find-window navigation fronts the document window; checks must never put one on screen.
final class OffscreenWindow: NSWindow { override func makeKeyAndOrderFront(_ sender: Any?) {} }
/// Counts how often navigation asks for the document window to be brought forward. It reports
/// itself as showing, like the selected document tab, without being put on screen.
final class CountingWindow: NSWindow {
    var fronted = 0, showing = true
    override var isVisible: Bool { showing }
    override func makeKeyAndOrderFront(_ sender: Any?) { fronted += 1 }
}
@main struct SearchControllerChecks {
    @MainActor static func main() async {
        await Checks.run("SearchControllerChecks") {
            _ = NSApplication.shared
            // F255: the controller under test keeps its options in a suite of its own, never in the
            // real defaults domain, so nothing is inherited from an earlier run or left behind.
            let suite = "TextTankSearchControllerChecks-" + UUID().uuidString
            let isolated = try requireValue(UserDefaults(suiteName: suite), "fixture: isolated defaults suite")
            defer { isolated.removePersistentDomain(forName: suite) }
            let standardBefore = UserDefaults.standard.data(forKey: "TextTank.Search.v1")
            let editor = TTEditor(frame: NSRect(x: 0, y: 0, width: 600, height: 400)),
                window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: .titled, backing: .buffered,
                    defer: false)
            window.contentView = editor
            let controller = SearchController(defaults: isolated)
            controller.currentEditor = { editor }
            controller.openEditors = { [editor] }
            @MainActor func finished() async { await waitUntil("the search to finish") { !controller.isSearching } }
            let fresh0 = SearchOptions()
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
            editor.executeCommand("undo")
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
            editor.executeCommand("undo")
            check(
                editor.text == numbered && !editor.modified && editor.selectionAnchor == 11
                    && editor.selectionCaret == 3, "one Undo of replace all restores the text and the selection")
            _ = editor.setSelectionAnchor(9, caret: 9)
            check(
                SearchController.apply(digitHits, text: numbered, revision: editor.revision, to: editor)
                    && editor.selectionAnchor == 7 && editor.selectionCaret == 7,
                "a caret inside a replaced match moves to the start of its replacement")
            editor.executeCommand("undo")
            check(
                editor.text == numbered && editor.selectionAnchor == 9 && editor.selectionCaret == 9,
                "Undo returns the caret to where it was inside the match")
            _ = editor.setSelectionAnchor(4, caret: 6)
            check(
                SearchController.apply([digitHits[1]], text: numbered, revision: editor.revision, to: editor)
                    && editor.text == "a1 b# c333" && editor.selectionAnchor == 4 && editor.selectionCaret == 5,
                "replacing the selected match leaves its replacement selected")
            editor.executeCommand("undo")
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
            editor.executeCommand("undo")
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
            let persisted = isolated.data(forKey: "TextTank.Search.v1").flatMap {
                try? JSONDecoder().decode(SearchOptions.self, from: $0)
            }
            check(
                persisted?.query == "([a-z]+)=(\\d+)" && persisted?.replacement == "$1:$2"
                    && persisted?.mode == .regularExpression,
                "a Find-window action saves its options in the injected defaults")
            check(
                UserDefaults.standard.data(forKey: "TextTank.Search.v1") == standardBefore,
                "a Find-window action leaves the standard defaults domain untouched")
            let reopened = SearchController(defaults: isolated)
            check(
                reopened.queryField.stringValue == "([a-z]+)=(\\d+)" && reopened.replacementField.stringValue == "$1:$2"
                    && reopened.mode.indexOfSelectedItem == 2,
                "a second controller on the same defaults restores the saved options")
            editor.executeCommand("undo")
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
            _ = editor.setSelectionAnchor(0, caret: 0)
            controller.next(nil)
            editor.text = "changed"
            let overtakenRevision = editor.revision, overtakenCaret = editor.selectionCaret
            await settle()
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
                    && recorded == ["replaceOne"],
                "single Replace on a \(hitCount)-hit buffer replaces exactly the selected hit")
            check(
                replaceElapsed < 10,
                "single Replace on a \(hitCount)-hit buffer stays within its time bound (\(String(format:"%.2f",replaceElapsed)) s)"
            )
            editor.executeCommand("undo")
            check(editor.text == big && !editor.modified, "many-hit single Replace is one Undo back to the save point")
            _ = editor.setSelectionAnchor(chosenHit * hitBytes + 3, caret: chosenHit * hitBytes + 8)
            recorded = []
            controller.replaceOne(nil)
            await waitUntil(timeout: 120, "the many-hit single Replace to finish") { !controller.isSearching }
            check(
                controller.lastOutcome == .replaced(changed: 0, stale: 0) && editor.text == big && !editor.modified
                    && recorded.isEmpty,
                "single Replace with a selection that is not exactly a hit changes and records nothing")
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
                    && controller.status.stringValue == "2 matches in 1 document(s)",
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
                pane.executeCommand("undo")
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
                primary.executeCommand("selectAll")
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
            Checks.summary { "PASS SearchControllerChecks: \(Checks.count) assertions" }
        }
    }
}
