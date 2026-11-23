@testable import TextTankCore
import AppKit
@testable import TextTankRuntime
import EditorBridge
import NativeSearch
@main struct FolderSearchControllerChecks {
    @MainActor static func everyView(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { everyView($0) } }
    @MainActor static func main() {
        // An async CLI main can exit when AppKit's nested modal run loop stops, before
        // replacement continuations resume. Own the outer AppKit loop until Checks finishes.
        Task { await runChecks() }
        NSApplication.shared.run()
        check(false, "the AppKit test host returned before the native suite completed")
        Checks.finish("FolderSearchControllerChecks")
    }
    @MainActor static func runChecks() async {
        await Checks.run("FolderSearchControllerChecks") {
            let isolatedSupport = try IsolatedSupportDirectory("TextTankFolderUIChecks"), support = isolatedSupport.url
            defer { isolatedSupport.restore() }
            NativeFixtureEnvironment.install()
            defer { NativeFixtureEnvironment.restore() }
            _ = NSApplication.shared
            let protectedSuite = "TextTankFolderProtected-" + UUID().uuidString
            let protected = try requireValue(UserDefaults(suiteName: protectedSuite), "fixture: protected defaults")
            protected.set(Data("sentinel".utf8), forKey: "TextTank.FolderSearch.v1")
            var providerCalls = 0
            let provider = RuntimeEnvironment.dependencies
            var effects = RuntimeEnvironment.current
            effects.sharedDefaultsProvider = {
                providerCalls += 1
                return protected
            }
            RuntimeEnvironment.dependencies = effects
            defer {
                RuntimeEnvironment.dependencies = provider
                protected.removePersistentDomain(forName: protectedSuite)
            }
            let implicit = FolderSearchController()
            check(
                implicit.queryField.stringValue.isEmpty && providerCalls == 0,
                "an absolute override skips even obtaining shared folder legacy defaults")
            let url = URL(fileURLWithPath: "/tmp/isolated-folder-result.txt")
            let match = FolderSearchMatch(
                url: url, line: 1, columnUTF16: 4, utf16Range: .init(location: 3, length: 4),
                utf8Range: .init(location: 5, length: 4), preview: "🥑 Test",
                previewMatchRange: .init(location: 3, length: 4), isMatchTruncatedInPreview: false)
            // F52: these checks call the one function Open Result itself uses. They used to call
            // a literal-only validator the app never ran.
            func hits(_ text: String, _ query: String, matchCase: Bool = true, wholeWord: Bool = false) -> [SearchHit]?
            {
                var options = SearchOptions()
                options.query = query
                options.matchCase = matchCase
                options.wholeWord = wholeWord
                return try? SearchCore.search(text, options: options).hits
            }
            @MainActor func select(
                _ match: FolderSearchMatch, _ editor: TTEditor, _ found: [SearchHit]?, snapshot: String? = nil,
                revision: UInt? = nil
            ) -> Bool {
                FolderSearchController.selectResult(
                    match, in: editor, snapshot: snapshot ?? editor.text, revision: revision ?? editor.revision,
                    hits: found)
            }
            let document = TextDocument()
            document.editor.text = "🥑 Test"
            document.makeWindowControllers()
            let editor = document.editor
            let beforeNavigation = editor.revision
            check(select(match, editor, hits("🥑 Test", "Test")), "result navigates current native buffer")
            check(
                editor.selectedText == "Test" && editor.selectionAnchor == 5 && editor.selectionCaret == 9,
                "native selection uses validated UTF8 byte range")
            check(
                editor.revision == beforeNavigation && document.isDocumentEdited,
                "navigation preserves dirty content and revision")
            editor.text = "🥑 TEST"
            _ = editor.setSelectionAnchor(0, caret: 0)
            check(
                select(match, editor, hits("🥑 TEST", "Test", matchCase: false)) && editor.selectedText == "TEST",
                "case insensitive live match validated")
            check(
                !select(match, editor, hits("🥑 TEST", "Test")) && editor.selectedText == "TEST",
                "a result of a case-sensitive search is stale once only the case differs")
            editor.text = "🥑 Tests"
            _ = editor.setSelectionAnchor(0, caret: 4)
            check(
                !select(match, editor, hits("🥑 Tests", "Test", wholeWord: true)) && editor.selectionAnchor == 0
                    && editor.selectionCaret == 4,
                "a whole-word result is stale once the word has grown")
            editor.text = "🥑 changed"
            _ = editor.setSelectionAnchor(0, caret: 4)
            check(
                !select(match, editor, hits("🥑 changed", "Test")) && editor.selectionAnchor == 0
                    && editor.selectionCaret == 4, "stale result leaves native selection unchanged")
            editor.text = "x"
            check(!select(match, editor, hits("x", "Test")), "shorter buffer result rejected")
            editor.text = "🥑 Test"
            _ = editor.setSelectionAnchor(0, caret: 0)
            let current = hits("🥑 Test", "Test")
            check(
                !select(match, editor, current, snapshot: "🥑 Test ")
                    && !select(match, editor, current, revision: editor.revision &- 1)
                    && !select(match, editor, nil) && editor.selectionCaret == 0,
                "a changed buffer, a changed revision or a failed search selects nothing")
            let shifted = FolderSearchMatch(
                url: url, line: 1, columnUTF16: 4, utf16Range: .init(location: 3, length: 4),
                utf8Range: .init(location: 3, length: 4), preview: "🥑 Test",
                previewMatchRange: .init(location: 3, length: 4), isMatchTruncatedInPreview: false)
            check(
                !select(shifted, editor, current) && editor.selectionCaret == 0,
                "a result whose recorded byte range no longer fits the text selects nothing")
            let suite = "TextTankFolderNative-" + UUID().uuidString
            let isolated = try requireValue(UserDefaults(suiteName: suite), "fixture: isolated defaults suite")
            defer { isolated.removePersistentDomain(forName: suite) }
            let controller = FolderSearchController(defaults: isolated)
            check(
                controller.window?.title == "Find in Folder"
                    && controller.status.stringValue.contains("Regular expression ·"),
                "native title and status expose search modes")
            check(
                controller.table.tableColumns.count == 3 && controller.details.isSelectable,
                "native results and skip details selectable")
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            controller.retainReplacementOutcomes([
                FolderReplacementOutcome(
                    url: url, status: .replaced, message: "committed before close",
                    backup: URL(fileURLWithPath: "/tmp/review-backup"),
                    recoveryReport: URL(fileURLWithPath: "/tmp/review-backup.json"))
            ])
            controller.showReplacementReport(nil)
            check(
                controller.lastReplacementOutcomes.count == 1
                    && controller.details.string.contains("committed before close")
                    && controller.details.string.contains("review-backup.json"),
                "replacement completion retained after close with durable report path")
            controller.filterField.stringValue = "*.txt !+\\build"
            controller.extensionField.stringValue = "txt"
            controller.queryField.stringValue = "needle"
            controller.replacementField.stringValue = "replacement"
            controller.mode.selectItem(at: 1)
            controller.scope.selectItem(at: 1)
            controller.hiddenButton.state = .on
            controller.recursiveButton.state = .off
            try controller.saveSettings()
            let restored = FolderSearchController(defaults: isolated)
            check(
                restored.filterField.stringValue == "*.txt !+\\build" && restored.extensionField.stringValue == "txt"
                    && restored.queryField.stringValue == "needle"
                    && restored.replacementField.stringValue == "replacement" && restored.mode.indexOfSelectedItem == 1
                    && restored.scope.indexOfSelectedItem == 1 && restored.hiddenButton.state == .on
                    && restored.recursiveButton.state == .off, "native restart restores all folder search controls")
            let first = support.appendingPathComponent("workspace-one"),
                second = support.appendingPathComponent("workspace-two")
            try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
            try Data("needle".utf8).write(to: first.appendingPathComponent("one.txt"))
            try Data("needle".utf8).write(to: second.appendingPathComponent("two.txt"))
            try Data("needle".utf8).write(to: second.appendingPathComponent("skip.log"))
            restored.workspaceRoots = { [first, second] }
            restored.mode.selectItem(at: 0)
            check(
                NSApp.sendAction(
                    restored.queryField.action!, to: restored.queryField.target, from: restored.queryField),
                "native workspace search action dispatched")
            check(
                restored.isSearching && restored.lastOutcome == nil,
                "a started folder search reports that it is searching")
            await waitUntil("the workspace search to finish") { !restored.isSearching }
            var searchedTwo = false
            if case .searched(matches: 2, filesSearched: 2, skipped: _, cancelled: false, limitReached: false)? =
                restored.lastOutcome
            {
                searchedTwo = true
            } else {
                print("NOTE folder outcome \(String(describing:restored.lastOutcome))")
            }
            check(
                searchedTwo && restored.numberOfRows(in: restored.table) == 2,
                "native saved workspace roots search respects filename filters")
            let corrupt = Data("invalid settings".utf8)
            isolated.set(corrupt, forKey: "TextTank.FolderSearch.v1")
            let invalidURL = support.appendingPathComponent("invalid-preferences.json")
            let invalid = FolderSearchController(defaults: isolated, preferencesURL: invalidURL)
            invalid.queryField.stringValue = "new"
            do {
                try invalid.saveSettings()
                check(false, "corrupt legacy settings latch blocks save")
            } catch { check(true, "corrupt legacy settings latch blocks save") }
            check(
                isolated.data(forKey: "TextTank.FolderSearch.v1") == corrupt
                    && !FileManager.default.fileExists(atPath: invalidURL.path)
                    && providerCalls == 0
                    && protected.data(forKey: "TextTank.FolderSearch.v1") == Data("sentinel".utf8),
                "native corrupt settings stay preserved after attempted save")
            // F111 and G370: while a replacement runs, Return in the query field must not cancel it
            // and a result must not be opened. The first commit is held open to make the window.
            final class CommitGate: @unchecked Sendable {
                private let lock = NSLock(), release = DispatchSemaphore(value: 0)
                private var held = false
                var isHolding: Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    return held
                }
                func holdFirst() {
                    lock.lock()
                    let first = !held
                    held = true
                    lock.unlock()
                    if first { release.wait() }
                }
                func open() { release.signal() }
            }
            let busyRoot = support.appendingPathComponent("busy-flow")
            try FileManager.default.createDirectory(at: busyRoot, withIntermediateDirectories: true)
            let busyFiles = ["a.txt", "b.txt", "c.txt"].map { busyRoot.appendingPathComponent($0) }
            for file in busyFiles { try Data("needle here\n".utf8).write(to: file) }
            try Data([0xFF]).write(to: busyRoot.appendingPathComponent("broken.txt"))
            try Data("needle".utf8).write(to: busyRoot.appendingPathComponent("one.log"))
            try Data("needle".utf8).write(to: busyRoot.appendingPathComponent("two.log"))
            try Data("needle".utf8).write(to: busyRoot.appendingPathComponent(".hidden.txt"))
            let busySuite = "TextTankFolderBusy-" + UUID().uuidString
            let busyDefaults = try requireValue(UserDefaults(suiteName: busySuite), "fixture: isolated defaults suite")
            defer { busyDefaults.removePersistentDomain(forName: busySuite) }
            let busy = FolderSearchController(
                defaults: busyDefaults, preferencesURL: support.appendingPathComponent("busy-preferences.json"))
            busy.workspaceRoots = { [busyRoot] }
            busy.scope.selectItem(at: 1)
            busy.mode.selectItem(at: 0)
            busy.filterField.stringValue = "*.txt"
            busy.queryField.stringValue = "needle"
            busy.replacementField.stringValue = "pin"
            var openedResults: [URL] = [], confirmations: [String] = []
            busy.openResultDocument = { url, completion in
                openedResults.append(url)
                completion(
                    nil,
                    NSError(
                        domain: "TextTank.Checks", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "not opened in checks"]))
            }
            busy.confirmReplacement = { explanation in
                confirmations.append(explanation)
                return true
            }
            let gate = CommitGate()
            busy.replacementBeforeCommit = { _ in gate.holdFirst() }
            @MainActor func pressReturn() -> Bool {
                NSApp.sendAction(busy.queryField.action!, to: busy.queryField.target, from: busy.queryField)
            }
            try require(pressReturn(), "fixture: busy-flow search dispatched")
            await waitUntil("the busy-flow search to finish") { !busy.isSearching }
            try require(busy.numberOfRows(in: busy.table) == 3, "fixture: three files matched on disk")
            // F42: what the filters left out is counted; only the file that could not be read is listed.
            check(
                busy.status.stringValue
                    == "3 matches in 3 files searched. Not searched: 1. Excluded: 3. Status: Complete.",
                "the status separates files that could not be searched from files the filters left out")
            check(
                busy.details.string.contains("Not searched (1):")
                    && busy.details.string.contains("broken.txt: not valid text")
                    && busy.details.string.contains("Excluded by filters or settings (3): 2 filename filter · 1 hidden")
                    && !busy.details.string.contains("one.log") && !busy.details.string.contains(".hidden.txt"),
                "the details list the unreadable file and summarise the exclusions by reason")
            check(
                busy.lastOutcome
                    == .searched(matches: 3, filesSearched: 3, skipped: 4, cancelled: false, limitReached: false),
                "the search outcome still counts every skipped entry")
            var flood = FolderSearchReport()
            for number in 0..<250 {
                flood.skip(URL(fileURLWithPath: "/tmp/unreadable-\(number)"), .unreadable("denied"), listing: false)
            }
            for _ in 0..<60_000 { flood.skip(url, .filenameFiltered, listing: false) }
            let floodLines = FolderSearchController.skipDetails(flood).components(separatedBy: "\n")
            check(
                flood.skipped.count == 250 && floodLines.count == 203 && floodLines[0] == "Not searched (250):"
                    && floodLines[201] == "… and 50 more not listed."
                    && floodLines[202] == "Excluded by filters or settings (60000): 60000 filename filter",
                "sixty thousand filtered files are one line and the problem list is capped")
            busy.activateResult(row: 0)
            await waitUntil("the idle result activation to report") {
                busy.lastOutcome == .failed("not opened in checks")
            }
            check(openedResults.map(\.lastPathComponent) == ["a.txt"], "an idle result opens its file")
            let documentsBefore = NSDocumentController.shared.documents.count
            check(
                NSApp.sendAction(NSSelectorFromString("replaceMatchedFiles:"), to: busy, from: nil)
                    && confirmations.count == 1
                    && confirmations[0].contains("private recovery batch in TextTank Application Support"),
                "Replace Matched Files asks once, with the explanation, through the confirmation seam")
            await waitUntil("the replacement to reach its first commit") { gate.isHolding }
            busy.queryField.stringValue = "other"
            let pressed = pressReturn()
            check(
                pressed && busy.status.stringValue.hasPrefix("Replacement in progress.") && busy.isSearching
                    && busy.numberOfRows(in: busy.table) == 3,
                "Return during a replacement is refused and the results stay")
            check(
                try FolderSearchSettings.decode(
                    Data(contentsOf: support.appendingPathComponent("busy-preferences.json"))
                ).options.query == "needle",
                "a refused Return saves nothing")
            busy.activateResult(row: 1)
            check(
                openedResults.count == 1 && NSDocumentController.shared.documents.count == documentsBefore
                    && busy.status.stringValue == "Replacement in progress; open results after it finishes.",
                "a result is not opened while a replacement is running")
            gate.open()
            await waitUntil("the held replacement to finish") { !busy.isSearching }
            check(
                try busyFiles.allSatisfy { try Data(contentsOf: $0) == Data("pin here\n".utf8) }
                    && busy.lastReplacementOutcomes.count == 3
                    && busy.lastReplacementOutcomes.allSatisfy { $0.status == .replaced },
                "every file is replaced and none is cancelled by the refused Return")
            check(
                busy.lastOutcome == .replaced(replaced: 3, notReplaced: 0)
                    && busy.status.stringValue.hasPrefix("3 files replaced")
                    && busy.details.string.contains("a.txt: Replaced"),
                "the replacement report is shown when the held replacement ends")
            busy.queryField.stringValue = "pin"
            let started = pressReturn(), restarted = pressReturn()
            check(started && restarted && busy.isSearching, "Return while a search is running starts the search again")
            await waitUntil("the restarted search to finish") { !busy.isSearching }
            let privateManifest = try requireValue(
                busy.lastReplacementOutcomes.first?.recoveryReport, "private batch location")
            check(
                try busy.lastOutcome
                    == .searched(matches: 3, filesSearched: 3, skipped: 4, cancelled: false, limitReached: false)
                    && busy.numberOfRows(in: busy.table) == 3
                    && FolderReplacementBatch.read(privateManifest).entries.count == 3
                    && !FileManager.default.contentsOfDirectory(atPath: busyRoot.path).contains {
                        $0.hasPrefix(".texttank-")
                    },
                "the restarted search sees only four fixture exclusions and all three backups are private")
            busy.activateResult(row: 2)
            check(
                openedResults.map(\.lastPathComponent) == ["a.txt", "c.txt"],
                "results open again after the replacement")
            // F111: closing the window during a replacement cancels it, but the controller stays busy
            // until the file being committed is done, so nothing can search or open underneath it.
            let closeGate = CommitGate()
            busy.replacementBeforeCommit = { _ in closeGate.holdFirst() }
            busy.replacementField.stringValue = "tack"
            try require(
                NSApp.sendAction(NSSelectorFromString("replaceMatchedFiles:"), to: busy, from: nil),
                "fixture: second replacement dispatched")
            await waitUntil("the second replacement to reach its first commit") { closeGate.isHolding }
            busy.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            let pressedAfterClose = pressReturn()
            busy.activateResult(row: 0)
            check(
                pressedAfterClose && busy.isSearching
                    && busy.status.stringValue == "Replacement in progress; open results after it finishes."
                    && openedResults.count == 2,
                "closing the window during a replacement does not let a search or a result through")
            closeGate.open()
            await waitUntil("the replacement interrupted by closing to end") { !busy.isSearching }
            check(
                try busy.lastReplacementOutcomes.count == 3 && busy.numberOfRows(in: busy.table) == 0
                    && busyFiles.allSatisfy {
                        let bytes = try Data(contentsOf: $0)
                        return bytes == Data("pin here\n".utf8) || bytes == Data("tack here\n".utf8)
                    },
                "the interrupted replacement keeps its outcomes, drops its stale results and leaves whole files")
            let searchedAgain = pressReturn()
            check(searchedAgain && busy.isSearching, "searching works again once the interrupted replacement ended")
            await waitUntil("the search after the interrupted replacement to finish") { !busy.isSearching }
            // F253: Replace Matched Files through the controller, which is the only place that works
            // out which result files are open. One result is open with unsaved edits.
            let replaceRoot = support.appendingPathComponent("replace-flow")
            try FileManager.default.createDirectory(at: replaceRoot, withIntermediateDirectories: true)
            let closedFile = replaceRoot.appendingPathComponent("closed.txt"),
                openFile = replaceRoot.appendingPathComponent("open.txt")
            try Data("needle closed\n".utf8).write(to: closedFile)
            try Data("needle open\n".utf8).write(to: openFile)
            let openDocument = TextDocument()
            openDocument.fileURL = openFile
            try openDocument.read(from: Data("needle open\n".utf8), ofType: "Plain Text")
            NSDocumentController.shared.addDocument(openDocument)
            _ = openDocument.editor.setSelectionAnchor(0, caret: 0)
            openDocument.editor.replaceSelection("unsaved ")
            let flowSuite = "TextTankFolderReplaceFlow-" + UUID().uuidString
            let flowDefaults = try requireValue(UserDefaults(suiteName: flowSuite), "fixture: isolated defaults suite")
            defer { flowDefaults.removePersistentDomain(forName: flowSuite) }
            let flow = FolderSearchController(
                defaults: flowDefaults, preferencesURL: support.appendingPathComponent("flow-preferences.json"))
            flow.workspaceRoots = { [replaceRoot] }
            flow.scope.selectItem(at: 1)
            flow.mode.selectItem(at: 0)
            flow.filterField.stringValue = "*.txt"
            flow.queryField.stringValue = "needle"
            flow.replacementField.stringValue = "pin"
            check(
                NSApp.sendAction(flow.queryField.action!, to: flow.queryField.target, from: flow.queryField),
                "fixture: replace-flow search dispatched")
            await waitUntil("the replace-flow search to finish") { !flow.isSearching }
            try require(flow.numberOfRows(in: flow.table) == 2, "fixture: both files matched on disk")
            let buttons = everyView(try requireValue(flow.window?.contentView, "folder patch buttons")).compactMap {
                $0 as? NSButton
            }
            let dryRun = try requireValue(
                buttons.first { $0.action == #selector(FolderSearchController.previewFolderPatch(_:)) }, "Preview Patch"
            )
            let export = try requireValue(
                buttons.first { $0.action == #selector(FolderSearchController.exportFolderPatch(_:)) }, "Export Preview"
            )
            dryRun.performClick(nil)
            await waitUntil("replacement patch preview") { !flow.isSearching }
            check(
                export.isEnabled && flow.details.string.contains("+pin closed")
                    && !flow.details.string.contains("+pin open") && flow.status.stringValue.contains("1 open"),
                "actual Preview Patch shows closed-file change and explicitly counts the skipped dirty document")
            flow.choosePatchFile = { _ in nil }
            export.performClick(nil)
            await waitUntil("cancel export") { !flow.isSearching }
            check(
                try flow.status.stringValue.contains("cancelled")
                    && Data(contentsOf: closedFile) == Data("needle closed\n".utf8),
                "save panel cancel leaves staged files unchanged")
            flow.choosePatchFile = { _ in closedFile }
            export.performClick(nil)
            await waitUntil("protect selected source") { !flow.isSearching }
            check(
                try flow.status.stringValue.contains("Could not export")
                    && Data(contentsOf: closedFile) == Data("needle closed\n".utf8),
                "ordinary export refuses a selected source")
            let destination = support.appendingPathComponent("explicit-folder.patch")
            flow.choosePatchFile = { _ in destination }
            export.performClick(nil)
            await waitUntil("export the previewed bytes") { !flow.isSearching }
            check(
                try String(contentsOf: destination, encoding: .utf8) == flow.details.string
                    && Data(contentsOf: openFile) == Data("needle open\n".utf8)
                    && openDocument.editor.text.hasPrefix("unsaved "),
                "Export Preview writes only selected destination while disk originals and dirty editor stay intact")
            var confirmed = false
            let giveUp = Date().addingTimeInterval(10)
            let confirm = Timer(timeInterval: 0.05, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard !confirmed, let modal = NSApp.modalWindow, let content = modal.contentView else { return }
                    if let go = everyView(content).compactMap({ $0 as? NSButton }).first(where: {
                        $0.identifier?.rawValue == "folder.replace.confirm"
                    }) {
                        confirmed = true
                        go.performClick(nil)
                    } else if Date() > giveUp {
                        NSApp.abortModal()
                    }
                }
            }
            RunLoop.main.add(confirm, forMode: .modalPanel)
            let replaceSent = NSApp.sendAction(NSSelectorFromString("replaceMatchedFiles:"), to: flow, from: nil)
            confirm.invalidate()
            check(replaceSent && confirmed, "Replace Matched Files asks for confirmation before changing any file")
            await waitUntil("the folder replacement to finish") { !flow.isSearching }
            let byFile = Dictionary(
                flow.lastReplacementOutcomes.map { ($0.url.lastPathComponent, $0) },
                uniquingKeysWith: { first, _ in first })
            check(
                try Data(contentsOf: closedFile) == Data("pin closed\n".utf8)
                    && byFile["closed.txt"]?.status == .replaced && byFile["closed.txt"]?.backup != nil,
                "the closed result file is replaced and has a backup")
            check(
                try Data(contentsOf: openFile) == Data("needle open\n".utf8) && byFile["open.txt"]?.status == .skipped
                    && byFile["open.txt"]?.backup == nil,
                "a result file that is open in TextTank is skipped on disk and reported as skipped")
            check(
                openDocument.editor.text == "unsaved needle open\n" && openDocument.isDocumentEdited,
                "the open document keeps its unsaved text")
            check(
                flow.lastOutcome == .replaced(replaced: 1, notReplaced: 1) && flow.lastReplacementOutcomes.count == 2
                    && flow.numberOfRows(in: flow.table) == 0,
                "the replacement report counts one replaced and one skipped file and clears the stale results")
            let coldFolder = FolderSearchController(
                preferencesURL: support.appendingPathComponent("reopened-folder.json"))
            let coldWindow = try requireValue(coldFolder.window, "cold folder window")
            let undoButton = try requireValue(
                coldWindow.contentView.flatMap {
                    everyView($0).compactMap { $0 as? NSButton }
                        .first { $0.action == #selector(FolderSearchController.undoLastFolderReplace(_:)) }
                }, "named folder Undo command")
            for shouldRestore in [false, true] {
                undoButton.performClick(nil)
                await waitUntil("the owned folder Undo confirmation to appear") { coldWindow.attachedSheet != nil }
                let sheet = try requireValue(coldWindow.attachedSheet?.contentView, "owned Undo confirmation sheet")
                let buttons = everyView(sheet).compactMap { $0 as? NSButton }
                let confirm = try requireValue(
                    buttons.first { $0.identifier?.rawValue == "folder.undo.confirm" }, "restore choice")
                check(confirm.hasDestructiveAction, "restoring originals requires an explicit destructive choice")
                let cancel = try requireValue(buttons.first { $0.title == "Cancel" }, "cancel choice")
                (shouldRestore ? confirm : cancel).performClick(nil)
                await waitUntil("the owned folder Undo command to finish") { !coldFolder.isSearching }
                let expected = shouldRestore ? "needle closed\n" : "pin closed\n"
                check(
                    try Data(contentsOf: closedFile) == Data(expected.utf8)
                        && openDocument.editor.text == "unsaved needle open\n" && openDocument.isDocumentEdited,
                    shouldRestore
                        ? "a fresh window restores its recorded replacement and preserves the unsaved neighbor"
                        : "Cancel leaves replacement and unsaved neighbor unchanged")
            }
            check(
                coldFolder.lastOutcome == .restored(restored: 1, other: 0)
                    && coldFolder.details.string.contains(closedFile.lastPathComponent),
                "Undo shows its per-file report")
            let manifest = try requireValue(byFile["closed.txt"]?.recoveryReport, "reviewed batch location")
            coldFolder.showRecoveryBatches(nil)
            let history = try requireValue(
                FormPanel.visible.last { $0.window.identifier?.rawValue == "TextTank.FolderReplacementBackups" },
                "actual recovery history window")
            let controls = everyView(try requireValue(history.window.contentView, "history contents"))
            let delete = try requireValue(
                controls.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "folder.backups.delete" },
                "review deletion button")
            let reviewedFiles = try requireValue(
                controls.compactMap { $0 as? NSTextView }.first {
                    $0.accessibilityLabel() == "Files and recovery states"
                },
                "reviewed files view")
            await waitUntil("the fresh history window to read its selected batch") {
                delete.isEnabled && reviewedFiles.string.contains("closed.txt")
            }
            check(
                reviewedFiles.string.contains("restored") && reviewedFiles.string.contains(closedFile.path),
                "actual history displays original path and recovered file state")
            let age: NSPopUpButton = try requireValue(
                controls.compactMap { $0 as? NSPopUpButton }.first { $0.menu?.item(withTag: 90) != nil },
                "retention picker")
            for accept in [false, true] {
                age.selectItem(withTag: 7)
                _ = NSApp.sendAction(age.action!, to: age.target, from: age)
                let content = try requireValue(history.window.attachedSheet?.contentView, "retention confirmation")
                let button = try requireValue(
                    everyView(content).compactMap { $0 as? NSButton }.first {
                        $0.title == (accept ? "Apply Retention" : "Cancel")
                    },
                    "retention choice")
                button.performClick(nil)
                await waitUntil("retention choice to settle") {
                    (try? FolderReplacementHistory.retention()) == (accept ? .week : .keep)
                        && history.window.attachedSheet == nil && age.isEnabled
                }
                check(
                    try FolderReplacementHistory.retention() == (accept ? .week : .keep),
                    "only explicit confirmation changes the stored age policy")
            }
            await waitUntil("review to settle after retention") {
                delete.isEnabled && reviewedFiles.string.contains("closed.txt")
            }
            for accept in [false, true] {
                delete.performClick(nil)
                let content = try requireValue(
                    history.window.attachedSheet?.contentView, "selected batch deletion sheet")
                let button = try requireValue(
                    everyView(content).compactMap { $0 as? NSButton }.first {
                        $0.title == (accept ? "Delete Batch" : "Cancel")
                    },
                    "batch deletion choice")
                button.performClick(nil)
                await waitUntil("private deletion choice to settle") {
                    history.window.attachedSheet == nil
                        && FileManager.default.fileExists(atPath: manifest.path) != accept
                }
                check(
                    try FileManager.default.fileExists(atPath: manifest.path) != accept
                        && Data(contentsOf: closedFile) == Data("needle closed\n".utf8),
                    "deletion confirmation governs only the displayed private batch")
            }
            history.close()
            openDocument.close()
            document.close()
            // Package 21 (F293, G391, G400): Find in Folder is a panel that leaves the document
            // window main, and a listed result opens from the keyboard.
            do {
                let panel = try requireValue(flow.window as? NSPanel, "the Find in Folder window is a panel")
                check(
                    !panel.canBecomeMain && panel.canBecomeKey && !panel.hidesOnDeactivate && !panel.isFloatingPanel
                        && panel.level == .normal && !panel.styleMask.contains(.utilityWindow),
                    "the Find in Folder panel cannot become main, does not float and stays when the application is deactivated"
                )
                check(
                    panel.defaultButtonCell == nil && panel.initialFirstResponder === flow.queryField
                        && flow.queryField.action == NSSelectorFromString("startSearch:")
                        && flow.queryField.target === flow,
                    "Return in the query field still starts the search, once: there is no default button beside it")
                check(
                    flow.table.accessibilityLabel() == "Folder search results", "the result list has a VoiceOver label")
                // DocumentWindowMenuChecks also covers opening a result from the keyboard and Escape.
            }
            Checks.summary { "PASS FolderSearchControllerChecks: \(Checks.count) assertions" }
        }
    }
}
