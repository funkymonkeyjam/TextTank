import AppKit
@testable import TextTankCore
@testable import TextTankRuntime
import EditorBridge
import NativeSearch

@MainActor private final class OrganizationCheckContext {
    let isolated: IsolatedSupportDirectory
    init() throws { isolated = try IsolatedSupportDirectory("TabOrganizationProcess") }
}
@MainActor private final class OrganizationCheckDelegate: NSObject, NSApplicationDelegate {
    var launched: (() -> Void)?
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ notification: Notification) { launched?() }
}
@MainActor enum TabOrganizationNativeChecks {
    static func runApplicationProcess() -> Never {
        do {
            let context = try OrganizationCheckContext()
            LanguageController.bundledCatalogURL = TestPaths.resources.appendingPathComponent("LanguageProfiles.json")
            NativeFixtureEnvironment.install()
            let documents = TextDocumentController(), app = NSApplication.shared, delegate = OrganizationCheckDelegate()
            app.setActivationPolicy(.regular)
            app.delegate = delegate
            delegate.launched = {
                let timer = Timer(timeInterval: 0.01, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        Checks.run("TabOrganizationNativeChecks") {
                            defer {
                                context.isolated.restore()
                                NativeFixtureEnvironment.restore()
                            }
                            check(
                                NSDocumentController.shared === documents && app.isRunning,
                                "T2 owned controller and actual AppKit loop")
                            try run(root: context.isolated.url)
                            Checks.summary { "PASS TabOrganizationNativeChecks: \(Checks.count) native assertions" }
                        }
                    }
                }
                RunLoop.main.add(timer, forMode: .default)
            }
            withExtendedLifetime(delegate) { app.run() }
        } catch { Checks.fail("T2 native process setup: \(error)", file: #filePath, line: #line) }
        Checks.finish("TabOrganizationNativeChecks")
    }
    private static func descendants(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(descendants) }
    static func run(root: URL) throws {
        let priorDelegate = NSApp.delegate, priorServices = EditorServices.current,
            front = NSWorkspace.shared.frontmostApplication
        let app = AppDelegate()
        NSApp.delegate = app
        app.installEditorServices()
        app.buildMenus()
        let host = app.workspaceWindow, commands = host.tabCommands
        let window = try requireValue(host.window, "T2 owned host")
        NSApp.activate(ignoringOtherApps: true)
        func reset() {
            commands.decisionHandler = nil
            commands.saveHandler = nil
            commands.isTerminating = true
            NSDocumentController.shared.documents.forEach { $0.close() }
            commands.isTerminating = false
            commands.clearHistory()
        }
        defer {
            reset()
            window.orderOut(nil)
            EditorServices.current = priorServices
            NSApp.delegate = priorDelegate
            front?.activate(options: [.activateAllWindows])
        }
        func saved(_ name: String, _ text: String = "disk") throws -> TextDocument {
            let url = root.appendingPathComponent(name + ".txt")
            try Data(text.utf8).write(to: url)
            return try DocumentFactory.openCaptured(WorkspaceStore.captureRegularFile(url), from: url)
        }
        func id(_ d: TextDocument) -> TabID {
            host.model.groups.flatMap(\.tabs).first { $0.documentID == d.runtimeID }!.id
        }
        func ids() -> [TabID] { host.model.groups[0].tabs.map(\.id) }
        func button(_ d: TextDocument) throws -> NSButton {
            try requireValue(
                descendants(host.tabStrip).compactMap { $0 as? NSButton }.first {
                    $0.identifier?.rawValue == "tab." + id(d).rawValue.uuidString
                }, "T2 actual tab button")
        }
        func item(_ menu: NSMenu, _ command: TabCommand) throws -> NSMenuItem {
            try requireValue(
                menu.items.first { $0.identifier?.rawValue == "tabs.command." + command.rawValue },
                "T2 menu " + command.rawValue)
        }
        func invoke(_ menu: NSMenu, _ command: TabCommand) throws {
            let x = try item(menu, command)
            check(x.isEnabled, "T2 invoked menu item enabled " + command.rawValue)
            _ = NSApp.sendAction(x.action!, to: x.target, from: x)
        }
        func waitClose() { spinUntil("T2 close completes") { !commands.isBusy } }
        func waitOpen() { spinUntil("T2 reopen completes") { !commands.isReopening } }
        let a = try saved("pin-A"), b = try saved("active-B"), c = try saved("move-C")
        b.showWindows()
        window.makeFirstResponder(b.editor)
        let active = host.model.activeTab?.id, responder = window.firstResponder
        let rev = a.editor.revision, text = a.editor.text, dirty = a.isDocumentEdited
        let aButton = try button(a), cButton = try button(c)
        try invoke(commands.contextMenu(for: id(a)), .pin)
        check(
            host.model.groups[0].tabs.first?.id == id(a) && host.model.groups[0].tabs.first?.isPinned == true,
            "T2 native Pin command puts inactive target in prefix")
        check(
            host.model.activeTab?.id == active && window.firstResponder === responder,
            "T2 pin preserves active editor focus")
        check(
            a.editor.revision == rev && a.editor.text == text && a.isDocumentEdited == dirty,
            "T2 pin changes no bytes revision or dirty state")
        check(
            try button(a) === aButton && aButton.image?.accessibilityDescription == "Pinned"
                && aButton.accessibilityLabel()?.contains("pinned") == true,
            "T2 visible pin image and actual native accessibility description")
        let pinMenu = commands.contextMenu(for: id(a))
        check(
            try item(pinMenu, .pin).title == "Unpin Tab" && item(pinMenu, .pin).state == .on,
            "T2 Unpin title and checkmark")
        a.showWindows()
        let main = try requireValue(NSApp.mainMenu?.items.first { $0.title == "Window" }?.submenu, "T2 Window menu")
        main.update()
        check(
            try item(main, .pin).title == "Unpin Tab" && item(main, .pin).state == .on,
            "T2 main menu shares dynamic pin state")
        try invoke(main, .pin)
        check(!host.model.groups[0].tabs.first!.isPinned, "T2 main-menu Unpin works")
        a.editor.restoreClosedTabView(anchor: 0, caret: 0, firstVisibleLine: 0)
        check(a.editor.replaceSelection("edit"), "T2 create meaningful undo")
        let editRevision = a.editor.revision
        try invoke(commands.contextMenu(for: id(a)), .pin)
        check(a.editor.revision == editRevision && a.isDocumentEdited, "T2 pin does not consume or create a text edit")
        check(
            a.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo")) && a.editor.text == text,
            "T2 pre-pin edit remains undoable")
        try invoke(commands.contextMenu(for: id(a)), .pin)
        b.showWindows()
        window.makeFirstResponder(b.editor)
        let beforeDrag = ids(), beforeFocus = window.firstResponder
        check(host.tabStrip.beginReorder(id(c)), "T2 synthetic strip reorder begins")
        host.tabStrip.updateReorder(at: NSPoint(x: 4, y: 18))
        check(
            ids() == beforeDrag && host.tabStrip.dropIndicatorVisible,
            "T2 drag preview shows position without model mutation")
        host.tabStrip.finishReorder(at: NSPoint(x: 4, y: 18))
        check(
            ids() == [id(c), id(a), id(b)] && host.model.activeTab?.id == id(b)
                && window.firstResponder === beforeFocus, "T2 drop uses shared core and preserves active responder")
        check(try button(c) === cButton && button(a) === aButton, "T2 reorder retains actual control identities")
        let axOrder = (host.tabStrip.accessibilityChildren() ?? []).compactMap { $0 as? NSButton }.filter {
            $0.identifier?.rawValue.hasPrefix("tab.") == true
        }
        check(
            axOrder.map { $0.identifier!.rawValue } == ids().map { "tab." + $0.rawValue.uuidString },
            "T2 actual accessibility child order follows visible order")
        check(
            NativeFixtureEnvironment.announcements.last?.contains("tab 1 of 3") == true,
            "T2 reorder announces actual position")
        let unchanged = ids()
        _ = host.tabStrip.beginReorder(id(a))
        host.tabStrip.updateReorder(at: NSPoint(x: -20, y: 18))
        host.tabStrip.finishReorder(at: NSPoint(x: 4, y: 18))
        check(
            ids() == unchanged && !host.tabStrip.isReordering && !host.tabStrip.dropIndicatorVisible,
            "T2 outside drag cancels without partial order")
        _ = host.tabStrip.beginReorder(id(a))
        let escape = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        window.sendEvent(escape)
        check(
            ids() == unchanged && !host.tabStrip.isReordering && window.firstResponder === beforeFocus,
            "T2 Escape cancels local drag without changing editor")
        _ = host.tabStrip.beginReorder(id(a))
        a.close()
        let afterClose = ids()
        host.tabStrip.finishReorder(at: NSPoint(x: 4, y: 18))
        check(ids() == afterClose && !host.tabStrip.isReordering, "T2 stale drag source cannot reorder another tab")
        check(
            RuntimeEnvironment.current.generalPasteboard() == nil,
            "T2 native drag checks have no general pasteboard capability")
        reset()
        let pinned = try saved("history-pin"), ordinary = try saved("history-ordinary")
        commands.perform(.pin, target: id(pinned))
        let pinnedID = id(pinned)
        pinned.close()
        check(commands.history.latest?.pinned == true, "T2 actual closed file records pin state")
        commands.perform(.reopen, target: nil)
        waitOpen()
        let reopened = try requireValue(app.currentDocument, "T2 reopened pinned file")
        check(
            host.model.groups[0].tabs.first?.documentID == reopened.runtimeID
                && host.model.groups[0].tabs.first?.isPinned == true && id(reopened) != pinnedID && ordinary.isOpen,
            "T2 reopened pin restores leading region even when no pins remain")
        let newDoc = DocumentFactory.makeUntitled()
        check(
            host.model.groups[0].tabs.last?.documentID == newDoc.runtimeID
                && host.model.groups[0].tabs.last?.isPinned == false, "T2 standard New stays unpinned after pins")
        commands.perform(.newToRight, target: id(reopened))
        check(
            host.model.groups[0].tabs[1].documentID == app.currentDocument?.runtimeID
                && host.model.groups[0].tabs[1].isPinned == false, "T2 New Right of pin starts ordinary region")
        reset()
        for choice in [TabCloseDecision.save, .discard, .cancel] {
            let pin = try saved("scenario-B-pin-\(choice)"), dirtyDoc = try saved("scenario-B-dirty-\(choice)"),
                right = try saved("scenario-B-right-\(choice)")
            commands.perform(.pin, target: id(pin))
            dirtyDoc.editor.text = "modified"
            right.showWindows()
            commands.decisionHandler = { _, reply in reply(choice) }
            commands.saveHandler = { doc, reply in
                doc.save(to: doc.fileURL!, ofType: doc.fileType!, for: .saveOperation) { reply($0) }
            }
            commands.perform(.closeLeft, target: id(right))
            waitClose()
            check(
                pin.isOpen && host.model.groups[0].tabs.first?.isPinned == true && right.isOpen,
                "T2 scenarioB pinned exclusion " + String(describing: choice))
            check(
                choice == .cancel ? dirtyDoc.isOpen && dirtyDoc.isDocumentEdited : dirtyDoc.isClosed,
                "T2 scenarioB dirty lifecycle " + String(describing: choice))
            check(
                try Data(contentsOf: dirtyDoc.fileURL!) == Data((choice == .save ? "modified" : "disk").utf8),
                "T2 scenarioB exact disk bytes " + String(describing: choice))
            reset()
        }
        var crowded: [TextDocument] = []
        for _ in 0..<14 { crowded.append(DocumentFactory.makeUntitled()) }
        let activeDoc = crowded.last!, moved = crowded[crowded.count - 2]
        activeDoc.showWindows()
        window.contentView?.layoutSubtreeIfNeeded()
        window.makeFirstResponder(activeDoc.editor)
        host.reorderTab(id(moved), to: 0)
        check(
            host.tabStrip.isTabHorizontallyVisible(id(activeDoc)) && host.active?.document === activeDoc
                && window.firstResponder === activeDoc.editor,
            "T2 owner decision keeps active tab visible when both cannot fit")
        check(
            NativeFixtureEnvironment.announcements.last?.contains("tab 1 of 14") == true,
            "T2 offscreen move still announces position")
        reset()
        main.update()
        for command in [TabCommand.pin, .moveLeft, .moveRight] {
            let x = try item(main, command)
            check(
                !x.isEnabled && !(x.toolTip ?? "").isEmpty && x.keyEquivalent.isEmpty,
                "T2 empty organisation command disabled with reason and no shortcut " + command.rawValue)
        }
        check(main.items.filter { !$0.isSeparatorItem }.count <= 20, "T2 Window command budget unchanged")
    }
}
