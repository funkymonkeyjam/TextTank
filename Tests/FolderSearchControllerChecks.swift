import AppKit
@main struct FolderSearchControllerChecks {
    @MainActor static func main() async {
        await Checks.run("FolderSearchControllerChecks") {
            let isolatedSupport = try IsolatedSupportDirectory("TextTankFolderUIChecks"), support = isolatedSupport.url
            defer { isolatedSupport.restore() }
            _ = NSApplication.shared
            let url = URL(fileURLWithPath: "/tmp/isolated-folder-result.txt")
            let match = FolderSearchMatch(
                url: url, line: 1, columnUTF16: 4, utf16Range: .init(location: 3, length: 4),
                utf8Range: .init(location: 5, length: 4), preview: "🥑 Test",
                previewMatchRange: .init(location: 3, length: 4), isMatchTruncatedInPreview: false)
            check(
                FolderSearchController.validatedRange(match, text: "🥑 Test", query: "Test", matchCase: true)
                    == NSRange(location: 5, length: 4), "Unicode UTF8 selection validated")
            check(
                FolderSearchController.validatedRange(match, text: "🥑 TEST", query: "Test", matchCase: false) != nil,
                "case insensitive live match validated")
            check(
                FolderSearchController.validatedRange(match, text: "🥑 changed", query: "Test", matchCase: true) == nil,
                "changed buffer result rejected")
            check(
                FolderSearchController.validatedRange(match, text: "x", query: "Test", matchCase: true) == nil,
                "shorter buffer result rejected")
            let document = TextDocument()
            document.editor.text = "🥑 Test"
            document.makeWindowControllers()
            let beforeNavigation = document.editor.revision
            check(
                FolderSearchController.selectResult(match, in: document, query: "Test", matchCase: true),
                "result navigates current native buffer")
            check(document.editor.selectedText == "Test", "native selection uses validated UTF8 byte range")
            check(
                document.editor.revision == beforeNavigation && document.isDocumentEdited,
                "navigation preserves dirty content and revision")
            document.editor.text = "🥑 changed"
            _ = document.editor.setSelectionAnchor(0, caret: 4)
            check(
                !FolderSearchController.selectResult(match, in: document, query: "Test", matchCase: true)
                    && document.editor.selectionAnchor == 0 && document.editor.selectionCaret == 4,
                "stale result leaves native selection unchanged")
            let suite = "TextTankFolderNative-" + UUID().uuidString
            let isolated = try requireValue(UserDefaults(suiteName: suite), "fixture: isolated defaults suite")
            defer { isolated.removePersistentDomain(forName: suite) }
            let controller = FolderSearchController(defaults: isolated)
            check(
                controller.window?.title == "Find in Folder" && controller.status.stringValue.contains("Boost regex"),
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
            let invalid = FolderSearchController(defaults: isolated)
            invalid.queryField.stringValue = "new"
            try invalid.saveSettings()
            check(
                isolated.data(forKey: "TextTank.FolderSearch.v1") == corrupt,
                "native corrupt settings stay preserved after attempted save")
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
            let flow = FolderSearchController(defaults: flowDefaults)
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
            @MainActor func everyView(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { everyView($0) } }
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
                // Opening a result from the keyboard, and Escape, are checked in document-checks
                // (DocumentWindowMenuChecks.swift): they wait for asynchronous work, and waiting on
                // the top-level run loop of this asynchronous main after the confirmation above is
                // not safe (see the note left for later units in the package 21 result).
            }
            Checks.summary { "PASS FolderSearchControllerChecks: \(Checks.count) assertions" }
        }
    }
}
