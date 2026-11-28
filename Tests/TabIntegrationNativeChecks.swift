import AppKit
@testable import TextTankCore
@testable import TextTankRuntime
import EditorBridge
import NativeSearch
import Darwin

@MainActor private final class IntegrationCheckContext {
    let isolated: IsolatedSupportDirectory
    init() throws { isolated = try IsolatedSupportDirectory("TabIntegrationProcess") }
}
@MainActor private final class IntegrationCheckDelegate: NSObject, NSApplicationDelegate {
    var launched: (() -> Void)?
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ note: Notification) { launched?() }
}
@MainActor enum TabIntegrationNativeChecks {
    static func runApplicationProcess() -> Never {
        do {
            let context = try IntegrationCheckContext()
            LanguageController.bundledCatalogURL = TestPaths.resources.appendingPathComponent("LanguageProfiles.json")
            NativeFixtureEnvironment.install()
            let documents = TextDocumentController(), app = NSApplication.shared, delegate = IntegrationCheckDelegate()
            app.setActivationPolicy(.regular)
            app.delegate = delegate
            delegate.launched = {
                let timer = Timer(timeInterval: 0.01, repeats: false) { _ in
                    MainActor.assumeIsolated { () -> Void in
                        Checks.run("TabIntegrationNativeChecks") {
                            defer {
                                context.isolated.restore()
                                NativeFixtureEnvironment.restore()
                            }
                            check(
                                NSDocumentController.shared === documents && app.isRunning,
                                "T4 owned actual AppKit controller/loop")
                            try run(root: context.isolated.url)
                            Checks.summary { "PASS TabIntegrationNativeChecks: \(Checks.count) native assertions" }
                        }
                    }
                }
                RunLoop.main.add(timer, forMode: .default)
            }
            withExtendedLifetime(delegate) { app.run() }
        } catch { Checks.fail("T4 native setup: \(error)", file: #filePath, line: #line) }
        Checks.finish("TabIntegrationNativeChecks")
    }
    @MainActor private static func pasteViews(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(pasteViews)
    }

    @MainActor static func pasteThroughChecks() throws {
        let isolated = try IsolatedSupportDirectory("PasteThroughWorkflow")
        defer { isolated.restore() }
        let doc = DocumentFactory.makeUntitled(display: false, populate: { _ = $0.editor.loadDocumentText("A 雪 B") })
        let neighbor = DocumentFactory.makeUntitled(
            display: false, populate: { _ = $0.editor.loadDocumentText("other") })
        defer {
            doc.close()
            neighbor.close()
        }
        var editor = doc.editor
        let app = AutomationController(editorProvider: { editor }, newDocument: { _ in })
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        app.pasteboard = board
        var workflow = AutomationDefinition.recipeFixture
        workflow.id = UUID()
        workflow.name = "Private clipboard transform"
        workflow.steps = [.init(kind: .replaceLiteral, find: "cat", replacement: "犬")]
        workflow.input = .file
        workflow.output = .newDocument
        workflow.previewBeforeApply = false
        try app.persistLibrary(.init(workflows: [workflow]))
        let store = AppStorage.url(.automations), saved = try Data(contentsOf: store)
        let paste = app.pasteThroughMenu()
        let action = try requireValue(
            paste.items.first { $0.representedObject as? String == workflow.id.uuidString },
            "explicit saved Paste Through menu item")
        let first = try requireValue(action.action, "Paste Through selector")
        let recorder = MacroController(editorProvider: { editor })
        var committed = 0
        app.prepareTransformedPaste = { target in
            let finish = recorder.prepareUnrecordedChange(in: target, reason: "A transformed paste was committed.")
            return { applied in
                if applied { committed += 1 }
                finish?(applied)
            }
        }
        _ = doc.editor.setSelectionAnchor(2, caret: 5)
        doc.editor.resetUndoHistory()
        board.clearContents()
        _ = board.setString("cat\r\n", forType: .string)
        let originalChange = board.changeCount
        check(NSApp.sendAction(first, to: action.target, from: action), "real saved transformation action dispatches")
        check(
            doc.editor.text == "A 犬\r\n B" && neighbor.editor.text == "other" && committed == 1,
            "saved step replaces only the captured multibyte selection")
        _ = doc.editor.executeCommand(.init(rawValue: "undo"))
        check(
            doc.editor.text == "A 雪 B" && board.changeCount == originalChange
                && board.string(forType: .string) == "cat\r\n",
            "one Undo restores bytes and transformed paste never writes the clipboard")
        let fresh = AutomationController(editorProvider: { editor }, newDocument: { _ in })
        check(
            fresh.pasteThroughMenu().items.first { $0.representedObject as? String == workflow.id.uuidString }?.state
                == .on,
            "a fresh controller reads the last successful choice from its separate store")
        check(try Data(contentsOf: store) == saved, "invocation preserves every byte of the saved workflow library")
        _ = doc.editor.setSelectionAnchor(1, caret: 1)
        try app.runSavedAutomation(id: workflow.id, pasteThrough: true)
        check(doc.editor.text == "A犬\r\n 雪 B", "caret-only invocation inserts the same transformed text")
        _ = doc.editor.executeCommand(.init(rawValue: "undo"))
        board.clearContents()
        let emptyBoardCount = board.changeCount
        recorder.startRecording()
        do {
            try app.runSavedAutomation(id: workflow.id, pasteThrough: true)
            check(false, "empty clipboard rejected")
        } catch {}
        do {
            try app.runSavedAutomation(id: UUID(), pasteThrough: true)
            check(false, "missing workflow rejected")
        } catch {}
        check(
            doc.editor.text == "A 雪 B" && board.changeCount == emptyBoardCount && recorder.isRecording(in: doc.editor),
            "empty and missing cases preserve document, clipboard and active macro capture")
        _ = board.setString("cat", forType: .string)
        _ = doc.editor.setSelectionRanges([TTSelectionRange(anchor: 0, caret: 1), TTSelectionRange(anchor: 2, caret: 5)]
        )
        do {
            try app.runSavedAutomation(id: workflow.id, pasteThrough: true)
            check(false, "multiple selections rejected")
        } catch {}
        check(
            doc.editor.text == "A 雪 B" && recorder.isRecording(in: doc.editor), "invalid selection keeps text and macro"
        )
        _ = doc.editor.setSelectionAnchor(0, caret: 0)
        _ = doc.editor.executeCommand(.init(rawValue: "newLine"))
        recorder.stopRecording()
        _ = doc.editor.executeCommand(.init(rawValue: "undo"))
        workflow.previewBeforeApply = true
        try app.persistLibrary(.init(workflows: [workflow]))
        let beforeCancel = try Data(contentsOf: store), originalText = doc.editor.text
        var confirmed = false, didRespond = false, changeDestination = false
        let response = Timer(timeInterval: 0.03, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let content = NSApp.modalWindow?.contentView,
                    let button = pasteViews(content).compactMap({ $0 as? NSButton }).first(where: {
                        $0.title == (confirmed ? "Apply" : "Cancel")
                    })
                else { return }
                editor = neighbor.editor
                if changeDestination { _ = doc.editor.replaceSelection("outside ") }
                if confirmed {
                    app.pasteboard?.clearContents()
                    _ = app.pasteboard?.setString("different clipboard after capture", forType: .string)
                }
                didRespond = true
                button.performClick(nil)
            }
        }
        RunLoop.main.add(response, forMode: .modalPanel)
        defer { response.invalidate() }
        try app.runSavedAutomation(id: workflow.id, pasteThrough: true)
        check(
            try didRespond && doc.editor.text == originalText && neighbor.editor.text == "other"
                && Data(contentsOf: store) == beforeCancel && committed == 2,
            "Cancel after focus moves leaves both editors, saved library and committed-action count intact")
        confirmed = true
        didRespond = false
        editor = doc.editor
        _ = doc.editor.setSelectionAnchor(0, caret: 0)
        try app.runSavedAutomation(id: workflow.id, pasteThrough: true)
        check(
            try didRespond && doc.editor.text == "犬" + originalText && neighbor.editor.text == "other"
                && board.string(forType: .string) == "different clipboard after capture"
                && Data(contentsOf: store) == beforeCancel,
            "confirmed paste uses the frozen input and captured caret even after focus and clipboard change")
        _ = doc.editor.executeCommand(.init(rawValue: "undo"))
        check(doc.editor.text == originalText, "one native Undo reverses the confirmed captured paste")
        editor = doc.editor
        changeDestination = true
        _ = doc.editor.setSelectionAnchor(0, caret: 0)
        do {
            try app.runSavedAutomation(id: workflow.id, pasteThrough: true)
            check(false, "stale captured destination rejected")
        } catch {}
        check(
            try doc.editor.text == "outside " + originalText && neighbor.editor.text == "other"
                && committed == 3 && Data(contentsOf: store) == beforeCancel,
            "confirmed stale paste keeps the external edit")
        editor = doc.editor
        workflow.previewBeforeApply = false
        workflow.steps = [.init(kind: .replaceLiteral, find: "cat", replacement: "")]
        try app.persistLibrary(.init(workflows: [workflow]))
        _ = doc.editor.setSelectionAnchor(0, caret: 7)
        board.clearContents()
        _ = board.setString("cat", forType: .string)
        let selectedText = doc.editor.text, boardCount = board.changeCount
        try app.runSavedAutomation(id: workflow.id, pasteThrough: true)
        check(
            doc.editor.text == selectedText && board.changeCount == boardCount && committed == 3,
            "empty transformed output leaves the selected range and clipboard intact")
    }

    /// File > Open must leave the workspace available to cancel before it publishes a large file.
    private static func cancelLargeOpen(root: URL) throws {
        let controller = NSDocumentController.shared
        let center = StatusOperationCenter.shared
        let previousDelay = center.revealDelay
        center.revealDelay = 0
        defer { center.revealDelay = previousDelay }
        let url = root.appendingPathComponent("large-open-progress.txt")
        var block = Data(repeating: 65, count: 1024 * 1024)
        for index in stride(from: 79, to: block.count, by: 80) { block[index] = 10 }
        try block.write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.seekToEnd()
            for _ in 1..<64 { try handle.write(contentsOf: block) }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        var requested = false
        var delivered = false
        var outcome: Error?
        var opened: NSDocument?
        let observer = NotificationCenter.default.addObserver(
            forName: StatusOperationCenter.didChange, object: center, queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                guard !requested, !delivered, let operation = center.operation(for: []) else { return }
                requested = true
                // The user's next input must be able to run between showing progress and finishing the open.
                DispatchQueue.main.async { center.cancel(operation.id) }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        controller.openDocument(withContentsOf: url, display: true) { document, _, error in
            opened = document
            outcome = error
            delivered = true
        }
        let panel = NSApp.windows.compactMap { $0 as? NSPanel }.first {
            $0.isVisible && $0.title.contains(url.lastPathComponent)
        }
        let controls = panel?.contentView.map(DocumentChecks.descendants) ?? []
        let cancel = controls.compactMap { $0 as? NSButton }.first { $0.keyEquivalent == "\u{1b}" }
        check(
            panel != nil && NSApp.modalWindow == nil && cancel?.accessibilityLabel() == "Cancel opening the document"
                && controls.contains { $0 is NSProgressIndicator },
            "Finder open without an editor presents modeless named progress and keyboard Cancel")
        guard spinUntil("large open completes or reports cancellation", { delivered }) else { return }
        check(requested, "a displayed large open exposes a cancellable workspace status operation")
        check(
            (outcome as? CocoaError)?.code == .userCancelled && opened == nil && controller.document(for: url) == nil,
            "cancelling a large open completes as cancelled without publishing a document")
        check(center.operations.isEmpty, "a completed large open releases its progress")
        opened?.close()
        check(panel?.isVisible == false, "cancelling dismisses the first-window progress panel")
        NotificationCenter.default.removeObserver(observer)

        let neighbor = DocumentFactory.makeUntitled()
        neighbor.editor.replaceSelection("kept draft")
        defer { neighbor.close() }
        var replies: [(NSDocument?, Bool, Error?)] = []
        for _ in 0..<2 {
            controller.openDocument(withContentsOf: url, display: true) { replies.append(($0, $1, $2)) }
        }
        check(
            center.operation(for: [neighbor.editor]) != nil
                && !NSApp.windows.contains {
                    $0 is NSPanel && $0.isVisible && $0.title.contains(url.lastPathComponent)
                },
            "an existing editor uses the status row for overlapping large opens")
        guard spinUntil(timeout: 30, "both displayed opens complete", { replies.count == 2 }),
            let doc = replies[0].0 as? TextDocument
        else {
            check(false, "large file was published")
            return
        }
        defer { doc.close() }
        check(
            replies[0].2 == nil && replies[1].2 == nil && !replies[0].1 && replies[1].1
                && replies[1].0 === doc && controller.document(for: url) === doc,
            "two concurrent opens publish one native document and report which request already had it")
        let expected = try WorkspaceStore.fingerprint(ofRegularFileAt: url, maximumBytes: Int.max)
        check(
            doc.originalDiskFingerprint == expected
                && WorkspaceStore.fingerprint(doc.editor.checkedUTF8Data) == expected
                && !doc.isDocumentEdited && doc.fileModificationDate != nil
                && NSFileCoordinator.filePresenters.contains { ($0 as AnyObject) === doc },
            "the fully read bytes, modification date and native file presenter survive opening")
        check(
            neighbor.editor.text == "kept draft" && neighbor.isDocumentEdited && center.operations.isEmpty,
            "opening a large file preserves an unrelated unsaved document and clears progress")
    }

    static func run(root: URL) throws {
        try pasteThroughChecks()
        let priorDelegate = NSApp.delegate, priorServices = EditorServices.current,
            front = NSWorkspace.shared.frontmostApplication
        let app = AppDelegate()
        NSApp.delegate = app
        app.installEditorServices()
        app.buildMenus()
        let host = app.workspaceWindow, commands = host.tabCommands
        defer {
            commands.isTerminating = true
            NSDocumentController.shared.documents.forEach { $0.close() }
            commands.isTerminating = false
            host.window?.orderOut(nil)
            EditorServices.current = priorServices
            NSApp.delegate = priorDelegate
            front?.activate(options: [.activateAllWindows])
        }
        try cancelLargeOpen(root: root)
        func reset() {
            commands.isTerminating = true
            NSDocumentController.shared.documents.forEach { $0.close() }
            commands.isTerminating = false
            commands.clearHistory()
            _ = host.setEditorLayout(.single)
        }
        func saved(_ name: String, _ text: String = "alpha beta\n") throws -> TextDocument {
            let url = root.appendingPathComponent(name + ".txt")
            try Data(text.utf8).write(to: url)
            return try DocumentFactory.openCaptured(WorkspaceStore.captureRegularFile(url), from: url)
        }
        func id(_ doc: TextDocument, _ slot: GroupSlot? = nil) -> TabID {
            host.model.groups.filter { slot == nil || $0.slot == slot }.flatMap(\.tabs).first {
                $0.documentID == doc.runtimeID
            }!.id
        }
        let automation = try requireValue(EditorServices.current?.automations, "T4 real automation service")
        var workflow = AutomationDefinition(
            id: UUID(), name: "mutable data name", input: .selection,
            steps: [.init(kind: .replaceLiteral, find: "alpha", replacement: "OMEGA")], output: .editor,
            previewBeforeApply: true)
        try automation.persistLibrary(AutomationLibrary(workflows: [workflow]))
        // Actual workflow preview is held while the workspace changes. Every unrelated byte/revision stays fixed.
        for operation in [
            "switch", "focus", "move", "layout", "collapse", "closeOrigin", "secondEdit", "undo", "reload", "reopen"
        ] {
            reset()
            let source = try saved("source-" + operation), sourceID = id(source)
            let other = try saved("other-" + operation, "unrelated\n"), otherID = id(other)
            _ = host.setEditorLayout(.twoColumns)
            let sibling = try requireValue(host.openView(sourceID, in: .second), "T4 additional source view")
            let siblingEditor = try requireValue(host.presentation(for: sibling)?.primaryEditor, "T4 sibling")
            host.activate(host.presentation(for: sourceID)!)
            source.editor.restoreClosedTabView(anchor: 5, caret: 0, firstVisibleLine: 0)
            let unrelatedRevision = other.editor.revision
            var acted = false, timeout = false
            let start = ProcessInfo.processInfo.systemUptime
            let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard let modal = NSApp.modalWindow, !acted else { return }
                    if ProcessInfo.processInfo.systemUptime - start > 8 {
                        timeout = true
                        NSApp.abortModal()
                        return
                    }
                    guard let content = modal.contentView,
                        let apply = DocumentChecks.descendants(content).compactMap({ $0 as? NSButton }).first(where: {
                            $0.title == "Apply"
                        })
                    else { return }
                    acted = true
                    switch operation {
                    case "switch": host.activate(host.presentation(for: otherID)!)
                    case "focus": host.focusGroup(.second)
                    case "move": host.moveTabs([sourceID], target: sourceID, to: .second)
                    case "layout": _ = host.setEditorLayout(.grid2x2)
                    case "collapse":
                        host.focusGroup(.second)
                        _ = host.setEditorLayout(.single)
                    case "closeOrigin": host.closeTab(sourceID, sender: nil)
                    case "secondEdit": siblingEditor.text = "changed through sibling\n"
                    case "undo":
                        siblingEditor.text = "temporary"
                        siblingEditor.executeCommand(.init(rawValue: "undo"))
                    case "reload": try? source.revert(toContentsOf: source.fileURL!, ofType: TextDocument.plainTextType)
                    case "reopen":
                        let url = source.fileURL!
                        source.close()
                        _ = try? DocumentFactory.openCaptured(WorkspaceStore.captureRegularFile(url), from: url)
                    default: break
                    }
                    apply.performClick(nil)
                }
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            let stale = ["secondEdit", "undo", "reload", "reopen"].contains(operation)
            var rejected = false
            do { try automation.runSavedAutomation(id: workflow.id) } catch {
                rejected = true
                check(
                    error.localizedDescription.contains("changed") || error.localizedDescription.contains("closed"),
                    "T4 named stale rejection: \(operation)")
            }
            timer.invalidate()
            check(acted && !timeout, "T4 actual automation held across \(operation)")
            check(rejected == stale, "T4 stale policy \(operation)")
            check(
                other.editor.text == "unrelated\n" && other.editor.revision == unrelatedRevision,
                "T4 unrelated document unchanged \(operation)")
            if !stale {
                check(source.editor.text == "OMEGA beta\n", "T4 exact original document receives result \(operation)")
                source.editor.executeCommand(.init(rawValue: "undo"))
                check(source.editor.text == "alpha beta\n", "T4 one Undo restores whole automation \(operation)")
            } else if source.isOpen {
                check(!source.editor.text.contains("OMEGA"), "T4 stale result never applied \(operation)")
            }
        }
        // Main selection need not be the earliest range. Retiring its view keeps each result paired.
        reset()
        let multi = try saved("multi", "alpha | alpha"), multiID = id(multi)
        _ = host.setEditorLayout(.twoColumns)
        _ = host.openView(multiID, in: .second)
        host.activate(host.presentation(for: multiID)!)
        _ = multi.editor.setSelectionRanges([
            TTSelectionRange(anchor: 13, caret: 8), TTSelectionRange(anchor: 0, caret: 5)
        ])
        var previews = 0
        let multiTimer = Timer(timeInterval: 0.01, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let window = NSApp.modalWindow, let view = window.contentView,
                    let accept = DocumentChecks.descendants(view).compactMap({ $0 as? NSButton }).first(where: {
                        $0.title == "Accept"
                    })
                else { return }
                if previews == 0 { host.closeTab(multiID, sender: nil) }
                previews += 1
                accept.performClick(nil)
            }
        }
        RunLoop.main.add(multiTimer, forMode: .modalPanel)
        defer { multiTimer.invalidate() }
        try automation.runSavedAutomation(id: workflow.id)
        multiTimer.invalidate()
        check(
            previews == 2 && multi.editor.text == "OMEGA | OMEGA",
            "T4 retired reversed-order multiple selections apply with paired outputs")
        multi.editor.executeCommand(.init(rawValue: "undo"))
        check(multi.editor.text == "alpha | alpha", "T4 retired multiselection one Undo")
        reset()
        let direct = try saved("direct"), directID = id(direct)
        _ = host.setEditorLayout(.grid2x2)
        let directView = try requireValue(host.openView(directID, in: .fourth), "T4 fourth group view")
        let directEditor = host.presentation(for: directView)!.primaryEditor
        directEditor.restoreClosedTabView(anchor: 0, caret: 5, firstVisibleLine: 0)
        workflow.previewBeforeApply = false
        workflow.name = "renamed workflow, same UUID"
        try automation.persistLibrary(AutomationLibrary(workflows: [workflow]))
        try automation.runSavedAutomation(id: workflow.id)
        check(
            direct.editor.text == "OMEGA beta\n" && NSApp.modalWindow == nil,
            "T4 direct apply in fourth group has no new dialog; name is data")
        directEditor.readOnly = true
        rejects("T4 read-only target rejection names document", message: direct.displayName) {
            try automation.runSavedAutomation(id: workflow.id)
        }
        directEditor.readOnly = false
        // Source-bound external results must not outlive or apply stale source bytes.
        // Read-only whole-document sources may export, and caret-only changes are irrelevant.
        for operation in [
            "documentClose", "selectionClose", "edit", "undo", "reload", "selectionDrift", "caret", "readOnly",
            "clipboard"
        ] {
            reset()
            let source = try saved("external-" + operation), sourceID = id(source)
            let bystander = try saved("external-other-" + operation, "unrelated\n")
            let unrelatedRevision = bystander.editor.revision, sourceRevision = source.editor.revision
            host.activate(host.presentation(for: sourceID)!)
            _ = source.editor.setSelectionAnchor(5, caret: 0)
            if operation == "readOnly" { source.editor.readOnly = true }
            var export = workflow
            export.input = operation == "selectionClose" || operation == "selectionDrift" ? .selection : .document
            export.output = .newDocument
            export.previewBeforeApply = true
            if operation == "clipboard" {
                export.input = .clipboard
                let board = NSPasteboard.withUniqueName()
                board.setString("alpha from private board", forType: .string)
                automation.pasteboard = board
            }
            try automation.persistLibrary(AutomationLibrary(workflows: [export]))
            var acted = false, timedOut = false
            let started = ProcessInfo.processInfo.systemUptime
            let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard let modal = NSApp.modalWindow, !acted else { return }
                    if ProcessInfo.processInfo.systemUptime - started > 8 {
                        timedOut = true
                        NSApp.abortModal()
                        return
                    }
                    guard let content = modal.contentView,
                        let apply = DocumentChecks.descendants(content).compactMap({ $0 as? NSButton }).first(where: {
                            $0.title == "Apply"
                        })
                    else { return }
                    acted = true
                    switch operation {
                    case "documentClose", "selectionClose", "clipboard": source.close()
                    case "edit": source.editor.text = "later source edit"
                    case "undo":
                        source.editor.text = "temporary"
                        source.editor.executeCommand(.init(rawValue: "undo"))
                    case "reload": try? source.revert(toContentsOf: source.fileURL!, ofType: TextDocument.plainTextType)
                    case "selectionDrift", "caret": _ = source.editor.setSelectionAnchor(3, caret: 3)
                    default: break
                    }
                    apply.performClick(nil)
                }
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            var error: Error?
            do { try automation.runSavedAutomation(id: export.id) } catch let failure { error = failure }
            timer.invalidate()
            automation.pasteboard = nil
            let stale = !["caret", "readOnly", "clipboard"].contains(operation)
            check(acted && !timedOut && (error != nil) == stale, "T4 external source validation \(operation)")
            let after = NSDocumentController.shared.documents.compactMap { $0 as? TextDocument }
            let originals: Set<DocumentID> =
                source.isOpen ? [source.runtimeID, bystander.runtimeID] : [bystander.runtimeID]
            let results = after.filter { !originals.contains($0.runtimeID) }
            check(
                bystander.editor.text == "unrelated\n" && bystander.editor.revision == unrelatedRevision,
                "T4 external output never mutates unrelated document \(operation)")
            if stale {
                check(
                    results.isEmpty && Set(after.map(\.runtimeID)) == originals,
                    "T4 stale external output creates no result or revived document \(operation)")
                check(
                    error?.localizedDescription.contains(source.displayName) == true,
                    "T4 stale external rejection names source \(operation)")
            } else {
                let expected = operation == "clipboard" ? "OMEGA from private board" : "OMEGA beta\n"
                check(
                    results.count == 1 && results[0].editor.text == expected,
                    "T4 current external snapshot exports correctly \(operation)")
                check(
                    !source.isOpen
                        || (source.editor.text == "alpha beta\n" && source.editor.revision == sourceRevision),
                    "T4 allowed external output preserves source bytes/revision \(operation)")
            }
        }
        try automation.persistLibrary(AutomationLibrary(workflows: [workflow]))
        // A modeless palette captures at Run, after a genuine focused-group change.
        reset()
        let paletteA = try saved("palette-A"), paletteAID = id(paletteA)
        let paletteB = try saved("palette-B"), paletteBID = id(paletteB)
        _ = host.setEditorLayout(.twoColumns)
        host.moveTabs([paletteBID], target: paletteBID, to: .second)
        host.activate(host.presentation(for: paletteAID)!)
        _ = paletteA.editor.setSelectionAnchor(0, caret: 5)
        _ = paletteB.editor.setSelectionAnchor(0, caret: 5)
        automation.showPalette()
        let palette = try requireValue(
            FormPanel.visible.first { $0.window.identifier?.rawValue == "automation.palette" }, "T4 actual palette")
        host.focusGroup(.second)
        let run = try requireValue(
            DocumentChecks.descendants(palette.window.contentView!).compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == "automation.palette.choose"
            }, "T4 actual palette Run")
        run.performClick(nil)
        check(
            paletteA.editor.text == "alpha beta\n" && paletteB.editor.text == "OMEGA beta\n",
            "T4 palette Run chooses current focused view, not opening view")
        reset()
        let a = try saved("snapshot-A", "é\nalpha\n"), aid = id(a)
        let b = try saved("snapshot-B", "other\n"), bid = id(b)
        _ = host.setEditorLayout(.grid2x2)
        host.setPinnedTabs([aid], target: aid, pinned: true)
        let a2 = try requireValue(host.openView(aid, in: .second), "T4 session shared view")
        host.presentation(for: aid)!.primaryEditor.restoreClosedTabView(anchor: 0, caret: 2, firstVisibleLine: 0)
        host.presentation(for: a2)!.primaryEditor.restoreClosedTabView(anchor: 3, caret: 8, firstVisibleLine: 1)
        host.activate(host.presentation(for: bid)!)
        host.focusGroup(.second)
        a.editor.text = "é\n" + (0..<80).map { "line \($0) alphabet" }.joined(separator: "\n")
        host.presentation(for: aid)!.primaryEditor.restoreClosedTabView(anchor: 3, caret: 8, firstVisibleLine: 3)
        host.presentation(for: a2)!.primaryEditor.restoreClosedTabView(anchor: 8, caret: 3, firstVisibleLine: 30)
        a.flushRecovery()
        let captured = try app.workspace.capture(name: "Stage4")
        check(
            captured.documents.count == 2 && captured.layoutState?.groups.flatMap(\.tabs).count == 3,
            "T4 capture stores text once and three views")
        check(captured.layoutState?.groups[0].tabs[0].isPinned == true, "T4 capture pin prefix")
        let recovery = try TextDocument.recovery.scan().snapshots.filter { $0.id == a.recoveryID }
        check(recovery.count == 1, "T4 shared document writes one recovery snapshot")
        let encoded = try captured.encoded()
        check(!String(decoding: encoded, as: UTF8.self).contains("history"), "T4 session contains no closed history")
        // Actual save/read/restore uses new independent runtime and recovery identities.
        let url = root.appendingPathComponent("layout.texttanksession")
        try WorkspaceStore.save(captured, to: url)
        let loaded = try WorkspaceStore.load(from: url)
        reset()
        let restored = try app.workspace.restore(loaded)
        check(
            restored.count == 2 && host.model.layout == .grid2x2 && host.model.focusedGroup == .second,
            "T4 scenario H restores layout and focus")
        check(
            Set(restored.map(\.runtimeID)).isDisjoint(with: [a.runtimeID, b.runtimeID])
                && Set(restored.map(\.recoveryID)).isDisjoint(with: Set(captured.documents.map(\.id))),
            "T4 restores fresh runtime and recovery identities")
        let savedLayout = try requireValue(captured.layoutState, "T4 saved layout")
        for (savedGroup, actualGroup) in zip(savedLayout.groups, host.model.groups) {
            check(
                savedGroup.tabs.map(\.isPinned) == actualGroup.tabs.map(\.isPinned), "T4 restored pin flags and order")
            check(
                savedGroup.activeTabIndex == actualGroup.tabs.firstIndex { $0.id == actualGroup.activeTab },
                "T4 restored per-group active index")
            for (savedTab, actualTab) in zip(savedGroup.tabs, actualGroup.tabs) {
                let editor = host.presentation(for: actualTab.id)!.primaryEditor
                check(
                    editor.selectionAnchor == savedTab.anchorByte && editor.selectionCaret == savedTab.caretByte,
                    "T4 exact per-view oriented UTF8 selection restored")
                check(editor.firstVisibleLine == savedTab.firstVisibleLine, "T4 exact per-view scroll restored")
            }
        }
        let av = host.presentations.filter { ($0.document as? TextDocument) === restored[0] }
        check(
            av.count == 2 && av[0].primaryEditor.sharesDocument(with: av[1].primaryEditor),
            "T4 restored views share authoritative Scintilla")
        av[0].primaryEditor.text = "shared edit"
        check(av[1].primaryEditor.text == "shared edit", "T4 restored shared edits")
        av[1].primaryEditor.executeCommand(.init(rawValue: "undo"))
        check(av[0].primaryEditor.text == captured.documents[0].text, "T4 restored shared Undo")
        check(restored.allSatisfy { $0.fileURL == nil && $0.isDocumentEdited }, "T4 all snapshots remain unsaved")
        _ = host.setEditorLayout(.single)
        check(
            NSDocumentController.shared.documents.count == 2 && host.presentations.count == 2,
            "T4 restored collapse deduplicates views without documents")
        // Persisted view coordinates are advisory, clamped independently from strict snapshot selection.
        var clamp = loaded
        clamp.layoutState!.groups[0].tabs[0].anchorByte = 1 // continuation byte of é
        clamp.layoutState!.groups[0].tabs[0].caretByte = Int.max
        clamp.layoutState!.groups[0].tabs[0].firstVisibleLine = Int.max
        reset()
        let clamped = try app.workspace.restore(clamp)
        let clampEditor = host.presentation(for: host.model.groups[0].tabs[0].id)!.primaryEditor
        check(
            clampEditor.selectionAnchor == 0 && clampEditor.selectionCaret == clamped[0].editor.byteLength,
            "T4 out-of-range and mid-UTF8 view coordinates clamp")
        check(clampEditor.firstVisibleLine < 100, "T4 extreme scroll clamped")
        // Empty focused pane wins over the legacy activeDocument field.
        var emptyFocus = loaded
        emptyFocus.layoutState!.focusedGroup = .fourth
        reset()
        _ = try app.workspace.restore(emptyFocus)
        check(
            host.model.focusedGroup == .fourth && host.active == nil,
            "T4 saved empty focus obeyed over legacy active document")
        // Unfit / invalid explicit layouts fall back only in an empty workspace.
        for invalid in [false, true] {
            reset()
            var session = loaded
            if invalid { session.layoutState!.groups[0].tabs[0].documentID = DocumentID() }
            _ = try app.workspace.restore(session, availableContent: TabGroupExtent(width: 100, height: 100))
            check(
                host.model.layout == .single && host.presentations.count == 2 && host.model.groups[0].tabs.count == 2,
                "T4 empty fallback keeps every document once")
            check(host.lastTabMessage.contains("will not be applied"), "T4 fallback notice visible and announced")
            reset()
            let existing = try saved("existing-\(invalid)"), existingID = id(existing)
            _ = host.setEditorLayout(.grid2x2)
            host.focusGroup(.third)
            _ = try app.workspace.restore(session, availableContent: TabGroupExtent(width: 100, height: 100))
            check(
                host.model.layout == .grid2x2 && host.model.groups[0].tabs[0].id == existingID
                    && host.model.groups[2].tabs.count == 2,
                "T4 nonempty safety preserves Grid and appends to captured group")
            check(
                existing.editor.text == "alpha beta\n" && host.lastTabMessage.contains("Existing tabs"),
                "T4 merge keeps originals and announces policy")
        }
        reset()
        let old = try WorkspaceStore.load(
            from: TestPaths.fixtures.appendingPathComponent("persistence/Session.texttanksession"))
        _ = host.setEditorLayout(.twoColumns)
        host.focusGroup(.second)
        let legacy = try app.workspace.restore(old)
        check(
            legacy.count == 1 && host.model.layout == .twoColumns && host.model.groups[1].tabs.count == 1,
            "T4 legacy absent layout restores as before in focused group")
        reset()
        if let snapshot = recovery.first {
            let recovered = try TextDocument.openRecovered(snapshot)
            check(host.presentations.count == 1, "T4 recovery opens one document/view without layout")
            let copies = try app.workspace.restore(loaded)
            check(
                copies.count == 2 && copies.allSatisfy { $0 !== recovered }
                    && NSDocumentController.shared.documents.count == 3,
                "T4 explicit session intentionally creates independent copies beside recovery")
        }
    }
}
