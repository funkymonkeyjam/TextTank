import AppKit
@testable import TextTankCore
@testable import TextTankRuntime
import EditorBridge
import NativeSearch

@MainActor private final class TabCommandCheckDelegate: NSObject, NSApplicationDelegate {
    var launched: (() -> Void)?
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ notification: Notification) { launched?() }
}
@MainActor private final class MenuTrackingContext: NSObject {
    var tracked: NSMenu?
    @objc func beganTracking(_ note: Notification) {
        tracked = note.object as? NSMenu
        let timer = Timer(timeInterval: 0.1, repeats: false) { [self] _ in
            MainActor.assumeIsolated { tracked?.cancelTrackingWithoutAnimation() }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
    }
}
@MainActor private final class TabCommandContext {
    let isolated: IsolatedSupportDirectory
    init() throws { isolated = try IsolatedSupportDirectory("TabCommandProcess") }
}
@MainActor enum TabCommandNativeChecks {
    static func runApplicationProcess() -> Never {
        do {
            let context = try TabCommandContext()
            LanguageController.bundledCatalogURL = TestPaths.resources.appendingPathComponent("LanguageProfiles.json")
            NativeFixtureEnvironment.install()
            let documents = TextDocumentController(), app = NSApplication.shared, delegate = TabCommandCheckDelegate()
            app.setActivationPolicy(.regular)
            app.delegate = delegate
            delegate.launched = {
                let timer = Timer(timeInterval: 0.01, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        Checks.run("TabCommandNativeChecks") {
                            defer {
                                context.isolated.restore()
                                NativeFixtureEnvironment.restore()
                            }
                            check(
                                NSDocumentController.shared === documents && app.isRunning,
                                "T1 owned controller and actual AppKit loop")
                            try run(root: context.isolated.url)
                            Checks.summary { "PASS TabCommandNativeChecks: \(Checks.count) native assertions" }
                        }
                    }
                }
                RunLoop.main.add(timer, forMode: .default)
            }
            withExtendedLifetime(delegate) { app.run() }
        } catch { Checks.fail("T1 native process setup: \(error)", file: #filePath, line: #line) }
        Checks.finish("TabCommandNativeChecks")
    }
    private static func descendants(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(descendants) }
    static func run(root: URL) throws {
        let oldDelegate = NSApp.delegate, oldServices = EditorServices.current,
            front = NSWorkspace.shared.frontmostApplication
        let app = AppDelegate()
        NSApp.delegate = app
        app.installEditorServices()
        app.buildMenus()
        defer {
            NSDocumentController.shared.documents.forEach { $0.close() }
            app.workspaceWindow.tabCommands.clearHistory()
            app.workspaceWindow.window?.orderOut(nil)
            EditorServices.current = oldServices
            NSApp.delegate = oldDelegate
            front?.activate(options: [.activateAllWindows])
        }
        let host = app.workspaceWindow, commands = host.tabCommands, window = try requireValue(host.window, "T1 host")
        NSApp.activate(ignoringOtherApps: true)
        func reset() {
            commands.decisionHandler = nil
            commands.saveHandler = nil
            NSDocumentController.shared.documents.forEach { $0.close() }
            commands.clearHistory()
        }
        func saved(_ name: String, _ text: String = "disk bytes") throws -> TextDocument {
            let url = root.appendingPathComponent(name + ".txt")
            try Data(text.utf8).write(to: url)
            return try DocumentFactory.openCaptured(WorkspaceStore.captureRegularFile(url), from: url)
        }
        func id(_ doc: TextDocument) -> TabID {
            host.model.groups.flatMap(\.tabs).first { $0.documentID == doc.runtimeID }!.id
        }
        func item(_ menu: NSMenu, _ command: TabCommand) throws -> NSMenuItem {
            try requireValue(
                menu.items.first { $0.identifier?.rawValue == "tabs.command." + command.rawValue },
                "T1 menu " + command.rawValue)
        }
        func dispatch(_ item: NSMenuItem) { _ = NSApp.sendAction(item.action!, to: item.target, from: item) }
        func waitClose() { spinUntil("T1 close operation finishes") { !commands.isBusy } }
        func waitOpen() { spinUntil("T1 reopen finishes") { !commands.isReopening } }
        let a = try saved("target-A"), b = try saved("active-B"), c = try saved("other-C")
        b.showWindows()
        window.makeFirstResponder(b.editor)
        let before = window.firstResponder, active = host.model.activeTab?.id
        let select = try requireValue(
            descendants(host.tabStrip).compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == "tab." + id(a).rawValue.uuidString
            }, "T1 target button")
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown, location: select.convert(.zero, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let menu = try requireValue(select.menu(for: event), "T1 actual native right-click menu")
        check(
            host.model.activeTab?.id == active && window.firstResponder === before,
            "T1-R1 right-click menu capture preserves active tab and keyboard focus")
        check(
            select.responds(to: NSSelectorFromString("accessibilityPerformShowMenu")),
            "T1-R1 standard accessibility Show Menu action exists")
        // Close the actual native menu through its tracking run loop, without dispatching an item.
        let menuContext = MenuTrackingContext()
        NotificationCenter.default.addObserver(
            menuContext, selector: #selector(MenuTrackingContext.beganTracking(_:)),
            name: NSMenu.didBeginTrackingNotification, object: nil)
        defer { NotificationCenter.default.removeObserver(menuContext) }
        select.rightMouseDown(with: event)
        check(
            host.model.activeTab?.id == active && window.firstResponder === before,
            "T1 actual right-click tracking preserves inactive target and responder")
        let controlEvent = NSEvent.mouseEvent(
            with: .leftMouseDown, location: select.convert(.zero, to: nil),
            modifierFlags: [.control], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 2, clickCount: 1, pressure: 1)!
        select.mouseDown(with: controlEvent)
        check(
            host.model.activeTab?.id == active && window.firstResponder === before,
            "T1 actual Control-click tracking preserves inactive target and responder")
        check(select.accessibilityPerformShowMenu(), "T1 native AX Show Menu action opens a menu")
        check(
            host.model.activeTab?.id == active && window.firstResponder === before,
            "T1 AX menu tracking preserves editing focus")
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        check(
            titles == TabCommand.allCases.map(\.title),
            "T1 menu exact create-close-location order and no Stage2 commands")
        check(menu.items.allSatisfy { $0.keyEquivalent.isEmpty }, "T1 no new context key equivalents")
        dispatch(try item(menu, .closeOthers))
        waitClose()
        check(
            a.isOpen && b.isClosed && c.isClosed && host.active?.document === a,
            "T1 scenarioA inactive clicked tab survives, prior active closes and target focuses")
        check(
            commands.history.records.map { $0.url.lastPathComponent } == ["active-B.txt", "other-C.txt"],
            "T1 bulk history is pushed in original visible order")
        check(commands.history.records.map(\.index) == [1, 2], "T1 bulk history retains original indices")
        let staleMenu = commands.contextMenu(for: id(a))
        a.close()
        let count = NSDocumentController.shared.documents.count
        dispatch(try item(staleMenu, .newToRight))
        check(
            NSDocumentController.shared.documents.count == count && host.lastTabMessage.contains("no longer open"),
            "T1-R2 stale captured command changes no document and visibly explains")
        check(
            NativeFixtureEnvironment.announcements.last?.contains("no longer open") == true, "T1 stale result announced"
        )
        reset()
        let p = try saved("pinned"), q = try saved("pinned-two"), r = try saved("right-target")
        var pinned = host.model
        pinned.groups[0].tabs[0].isPinned = true
        pinned.groups[0].tabs[1].isPinned = true
        try host.replaceTabModel(pinned)
        r.showWindows()
        let oldID = id(p)
        commands.perform(.newToRight, target: oldID, captured: true)
        check(
            host.model.groups[0].tabs[2].documentID == app.currentDocument?.runtimeID
                && app.currentDocument?.fileURL == nil, "T1 New Right of pin inserts at unpinned boundary and focuses")
        let newDoc = try requireValue(app.currentDocument, "T1 new right doc")
        app.newDocument(nil)
        check(
            host.model.groups[0].tabs.last?.documentID == app.currentDocument?.runtimeID,
            "T1 ordinary File New still appends")
        check(newDoc.editor.text.isEmpty && p.isOpen && q.isOpen, "T1 new right preserves existing documents")
        let pinMenu = commands.contextMenu(for: oldID)
        check(try item(pinMenu, .close).isEnabled, "T1 single pinned Close is enabled")
        var reveal: [URL] = []
        var copied = ""
        commands.revealFiles = { reveal = $0 }
        commands.copyPath = {
            copied = $0
            return true
        }
        commands.perform(.reveal, target: id(r), captured: true)
        commands.perform(.copyPath, target: id(r), captured: true)
        check(
            reveal == [r.fileURL!] && copied == r.fileURL!.path,
            "T1 path effects use captured inactive file; clipboard seam is owned")
        let untitled = try requireValue(app.currentDocument, "T1 untitled")
        let unMenu = commands.contextMenu(for: id(untitled))
        unMenu.update()
        for command in [TabCommand.reveal, .copyPath] {
            let x = try item(unMenu, command)
            check(
                !x.isEnabled && !(x.toolTip ?? "").isEmpty,
                "T1 untitled path command disabled with reason " + command.rawValue)
        }
        check(
            !titles.contains("Locate in Workspace"), "T1-R13 conditional Locate omitted without select-by-URL contract")
        reset()
        let pin = try saved("scenario-B-pin"), leftDirty = try saved("scenario-B-dirty"),
            right = try saved("scenario-B-target")
        var bModel = host.model
        bModel.groups[0].tabs[0].isPinned = true
        try host.replaceTabModel(bModel)
        leftDirty.editor.text = "discard left"
        leftDirty.flushRecovery()
        check(
            try TextDocument.recovery.loadAll().contains { $0.id == leftDirty.recoveryID },
            "T1 owned dirty snapshot exists before bulk close")
        commands.decisionHandler = { _, reply in reply(.discard) }
        commands.perform(.closeLeft, target: id(right))
        waitClose()
        check(
            pin.isOpen && leftDirty.isClosed && right.isOpen && host.active?.document === right,
            "T1 scenarioB directional close keeps pinned tab and honours dirty Discard")
        check(
            try !TextDocument.recovery.loadAll().contains { $0.id == leftDirty.recoveryID },
            "T1 successful bulk close removes existing recovery snapshot")
        reset()
        let draft = DocumentFactory.makeUntitled()
        draft.editor.text = "saved draft"
        commands.decisionHandler = { _, reply in reply(.save) }
        let draftURL = root.appendingPathComponent("saved-untitled.txt")
        commands.saveHandler = { doc, reply in
            doc.save(to: draftURL, ofType: "public.plain-text", for: .saveAsOperation) { reply($0) }
        }
        commands.perform(.closeGroup, target: id(draft))
        waitClose()
        check(
            draft.isClosed && commands.history.latest?.url == draftURL,
            "T1 saved untitled becomes file-backed and receives normal history")
        commands.perform(.reopen, target: nil)
        waitOpen()
        check(app.currentDocument?.editor.text == "saved draft", "T1 saved untitled reopens actual disk bytes")
        reset()
        let d = try saved("cancel-first"), e = try saved("cancel-second"), f = try saved("cancel-focus")
        d.editor.text = "dirty D"
        e.editor.text = "dirty E"
        f.showWindows()
        window.makeFirstResponder(f.editor)
        let responder = window.firstResponder
        var decisions = 0, saves = 0
        commands.decisionHandler = { prompt, reply in
            decisions += 1
            check(
                prompt.name.contains(decisions == 1 ? "cancel-first" : "cancel-second"),
                "T1 every decision names its captured document")
            reply(decisions == 1 ? .save : .cancel)
        }
        commands.saveHandler = { _, reply in
            saves += 1
            reply(nil)
        }
        commands.perform(.closeGroup, target: id(d), captured: true)
        waitClose()
        check(
            decisions == 2 && saves == 0 && [d, e, f].allSatisfy(\.isOpen),
            "T1 Cancel on second prompt saves/closes nothing")
        check(
            host.active?.document === f && window.firstResponder === responder,
            "T1 Cancel restores original active tab and responder")
        check(
            try Data(contentsOf: d.fileURL!) == Data("disk bytes".utf8) && commands.history.records.isEmpty,
            "T1 Cancel preserves disk and history")
        let review = commands.makeReview(TabClosePrompt(documentID: d.runtimeID, name: d.displayName, tabCount: 3))
        check(
            review.messageText.contains(d.displayName) && review.messageText.contains("3 tabs")
                && review.buttons[1].hasDestructiveAction, "T1 DS41/43 review names document/count and marks Discard")
        check(
            review.keyRoles().returnIndex == 0 && review.keyRoles().escapeIndex == 2,
            "T1 Return saves and Escape cancels; neither defaults to Discard")
        reset()
        let s1 = try saved("save-first"), s2 = try saved("save-failure")
        s1.editor.text = "saved first"
        s2.editor.text = "kept dirty"
        commands.decisionHandler = { _, reply in reply(.save) }
        commands.saveHandler = { doc, reply in
            if doc === s2 {
                reply(CocoaError(.fileWriteNoPermission))
            } else {
                doc.save(to: doc.fileURL!, ofType: doc.fileType!, for: .saveOperation) { reply($0) }
            }
        }
        commands.perform(.closeGroup, target: id(s1))
        waitClose()
        check(
            s1.isOpen && s2.isOpen && !s1.isDocumentEdited && s2.isDocumentEdited && commands.history.records.isEmpty,
            "T1 failed second save closes none; earlier save stands and failed doc stays dirty")
        check(
            try Data(contentsOf: s1.fileURL!) == Data("saved first".utf8)
                && Data(contentsOf: s2.fileURL!) == Data("disk bytes".utf8), "T1 save failure disk outcomes are exact")
        check(
            host.lastTabMessage.contains("save-failure") && host.lastTabMessage.contains("Earlier completed saves"),
            "T1 save failure identifies document without promising rollback")
        reset()
        let dirty = try saved("stale-dirty"), clean = try saved("stale-clean")
        dirty.editor.text = "decision"
        commands.decisionHandler = { _, reply in
            clean.editor.text = "newly dirty"
            reply(.discard)
        }
        commands.perform(.closeGroup, target: id(dirty))
        waitClose()
        check(
            dirty.isOpen && clean.isOpen && commands.history.records.isEmpty,
            "T1 clean doc modified during decisions invalidates before removal")
        reset()
        let cancelSave = DocumentFactory.makeUntitled()
        cancelSave.editor.text = "owned unsaved text"
        let survivor = try saved("save-panel-survivor")
        survivor.showWindows()
        commands.decisionHandler = { _, reply in reply(.save) }
        commands.perform(.closeGroup, target: id(cancelSave))
        spinUntil("T1 real untitled Save panel") { window.attachedSheet is NSSavePanel }
        try requireValue(window.attachedSheet as? NSSavePanel, "T1 Save panel").cancel(nil)
        waitClose()
        check(
            cancelSave.isOpen && cancelSave.isDocumentEdited && cancelSave.editor.text == "owned unsaved text"
                && survivor.isOpen, "T1 dismissed native Save panel closes no tabs and preserves dirty bytes")
        check(commands.history.records.isEmpty, "T1 dismissed Save panel records nothing")
        reset()
        let discard = try saved("discard-reopen", "a🙂éZ\n" + Array(repeating: "line\n", count: 120).joined()),
            keep = try saved("discard-keep")
        discard.editor.text = "discarded edits"
        keep.showWindows()
        commands.decisionHandler = { _, reply in reply(.discard) }
        commands.perform(.closeOthers, target: id(keep))
        waitClose()
        check(
            discard.isClosed && commands.history.records.count == 1,
            "T1 file-backed discard actually closes and records")
        commands.perform(.reopen, target: nil)
        waitOpen()
        let reopened = try requireValue(app.currentDocument, "T1 reopened discard")
        check(
            reopened.editor.text.hasPrefix("a🙂éZ") && !reopened.editor.text.contains("discarded edits"),
            "T1 reopen after Discard loads disk, never discarded text")
        check(
            commands.history.records.isEmpty && reopened.runtimeID != discard.runtimeID,
            "T1 reopen consumes record and uses fresh document identity")
        reopened.editor.text = "saved reopen"
        commands.perform(.close, target: id(reopened))
        spinUntil("T1 single native review") { window.attachedSheet != nil }
        let saveButton = try requireValue(
            window.attachedSheet?.contentView.map(descendants)?.compactMap { $0 as? NSButton }.first {
                $0.title == "Save"
            }, "T1 native single Save")
        saveButton.performClick(nil)
        spinUntil("T1 single Save closed") { reopened.isClosed }
        commands.perform(.reopen, target: nil)
        waitOpen()
        check(
            app.currentDocument?.editor.text == "saved reopen", "T1 single native Save route records actual saved bytes"
        )
        reset()
        let old = try saved("history-old", "a🙂éZ"), missing = try saved("history-missing", "gone")
        old.close()
        missing.close()
        try FileManager.default.removeItem(at: missing.fileURL!)
        commands.perform(.reopen, target: nil)
        waitOpen()
        check(
            host.model.activeTab == nil && commands.history.records.count == 1
                && host.lastTabMessage.contains("no longer"),
            "T1 missing consumes newest record, opens no stale bytes and visibly explains")
        commands.perform(.reopen, target: nil)
        waitOpen()
        check(
            app.currentDocument?.fileURL == old.fileURL && app.currentDocument?.editor.text == "a🙂éZ",
            "T1 next reopen reaches next history record")
        let changed = try requireValue(app.currentDocument, "T1 changed file")
        changed.editor.restoreClosedTabView(anchor: 2, caret: 7, firstVisibleLine: 0)
        changed.close()
        // Wait for close fingerprint completion before a deliberate later disk edit.
        spinUntil("T1 captured close fingerprint ready") { commands.history.latest?.fingerprint != nil }
        try Data("a🙂Z".utf8).write(to: changed.fileURL!, options: .atomic)
        commands.perform(.reopen, target: nil)
        waitOpen()
        let fresh = try requireValue(app.currentDocument, "T1 changed reopened")
        check(
            fresh.editor.text == "a🙂Z" && host.lastTabMessage.contains("changed on disk"),
            "T1 external edit opens current disk bytes and reports change")
        check(
            fresh.editor.selectionAnchor == 1 && fresh.editor.selectionCaret == 6,
            "T1 changed shorter text restores clamped UTF8 boundaries")
        fresh.close()
        spinUntil("T1 history fingerprint") { commands.history.latest?.fingerprint != nil }
        let openAgain = try DocumentFactory.openCaptured(
            WorkspaceStore.captureRegularFile(fresh.fileURL!), from: fresh.fileURL!)
        openAgain.editor.text = "keep existing dirty"
        let n = NSDocumentController.shared.documents.count
        commands.perform(.reopen, target: nil)
        waitOpen()
        check(
            app.currentDocument === openAgain && openAgain.editor.text == "keep existing dirty"
                && NSDocumentController.shared.documents.count == n && commands.history.records.isEmpty,
            "T1 existing destination focuses without reload or duplicate")
        reset()
        for i in 0...ClosedTabHistory.capacity {
            let closed = try saved("consumed-job-\(i)")
            closed.close()
            check(commands.pendingFingerprintCount == 1, "T1 close job captured before yielding")
            let live = try DocumentFactory.openCaptured(
                WorkspaceStore.captureRegularFile(closed.fileURL!), from: closed.fileURL!)
            commands.perform(.reopen, target: nil)
            check(
                commands.history.records.isEmpty && commands.pendingFingerprintCount == 0 && live.isOpen,
                "T1 consuming existing-file record cancels and removes fingerprint job")
            commands.isTerminating = true
            live.close()
            commands.isTerminating = false
        }
        reset()
        let mainA = try saved("main-active"), mainB = try saved("main-inactive")
        mainA.showWindows()
        let mainWindow = try requireValue(
            NSApp.mainMenu?.items.first { $0.title == "Window" }?.submenu, "T1 active Window menu")
        mainWindow.update()
        copied = ""
        dispatch(try item(mainWindow, .copyPath))
        check(copied == mainA.fileURL!.path && mainB.isOpen, "T1 main menu shared command acts on active file")
        dispatch(try item(mainWindow, .newToRight))
        check(
            host.model.groups[0].tabs[1].documentID == app.currentDocument?.runtimeID,
            "T1 main-menu New Right shares active-target insertion")
        reset()
        let savedClean = try saved("close-saved"), deleted = try saved("close-saved-deleted"),
            edited = try saved("close-saved-dirty"), untouched = DocumentFactory.makeUntitled()
        edited.editor.text = "dirty"
        try FileManager.default.removeItem(at: deleted.fileURL!)
        savedClean.editor.readOnly = true
        var prompts = 0
        commands.decisionHandler = { _, reply in
            prompts += 1
            reply(.cancel)
        }
        commands.perform(.closeSaved, target: id(edited))
        waitClose()
        check(
            savedClean.isClosed && deleted.isOpen && edited.isOpen && untouched.isOpen && prompts == 0,
            "T1 Close Saved excludes dirty, missing, untitled; includes read-only and never prompts")
        reset()
        let view = try saved("viewport", Array(repeating: "line🙂\n", count: 240).joined())
        view.editor.restoreClosedTabView(anchor: 520, caret: 528, firstVisibleLine: 40)
        let anchor = view.editor.selectionAnchor, caret = view.editor.selectionCaret,
            line = view.editor.firstVisibleLine, index = host.model.groups[0].tabs.firstIndex { $0.id == id(view) }!
        view.close()
        commands.perform(.reopen, target: nil)
        waitOpen()
        let restored = try requireValue(app.currentDocument, "T1 restored view")
        check(
            restored.editor.selectionAnchor == anchor && restored.editor.selectionCaret == caret
                && restored.editor.firstVisibleLine == line, "T1 native reopen restores UTF8 selection and viewport")
        check(
            host.model.groups[0].tabs.firstIndex { $0.documentID == restored.runtimeID } == index,
            "T1 reopen restores recorded index")
        restored.close()
        let recordID = commands.history.latest?.id
        commands.perform(.reopen, target: nil)
        let other = DocumentFactory.makeUntitled()
        NativeWindowEvents.pump()
        check(
            other.isOpen && commands.history.latest?.id == recordID && !commands.isReopening,
            "T1 explicit new document cancels pending reopen without consuming or applying stale result")
        reset()
        let discarded = DocumentFactory.makeUntitled()
        discarded.editor.text = "discard forever"
        commands.decisionHandler = { _, reply in reply(.discard) }
        commands.perform(.closeGroup, target: id(discarded))
        waitClose()
        check(
            discarded.isClosed && commands.history.records.isEmpty, "T1 discarded untitled content has no reopen record"
        )
        let cleanUntitled = DocumentFactory.makeUntitled()
        cleanUntitled.close()
        check(commands.history.records.isEmpty, "T1 clean untitled has no reopen record")
        let windowMenu = try requireValue(
            NSApp.mainMenu?.items.first { $0.title == "Window" }?.submenu, "T1 Window menu")
        windowMenu.update()
        for command in TabCommand.allCases {
            let x = try item(windowMenu, command)
            check(!x.isEnabled && !(x.toolTip ?? "").isEmpty, "T1 empty main menu disabled reason " + command.rawValue)
            check(x.keyEquivalent.isEmpty, "T1 main menu adds no key equivalent " + command.rawValue)
        }
        check(windowMenu.items.filter { !$0.isSeparatorItem }.count <= 20, "T1 Window menu has at most20 commands")
    }
}
