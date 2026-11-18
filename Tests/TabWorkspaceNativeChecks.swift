import AppKit
@testable import TextTankCore
@testable import TextTankRuntime
import EditorBridge
import NativeSearch

/// Deliver actual queued AppKit events in the CLI fixture, as NSApplication.run normally does.
@MainActor enum NativeWindowEvents {
    static func pump() {
        for _ in 0..<32 {
            guard let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) else {
                break
            }
            NSApp.sendEvent(event)
        }
        NSApp.updateWindows()
    }
    static func wait(_ label: String, timeout: TimeInterval = 10, _ condition: () -> Bool) {
        spinUntil(timeout: timeout, label) {
            pump()
            return condition()
        }
    }
}

@MainActor private final class WorkspaceCheckApplicationDelegate: NSObject, NSApplicationDelegate {
    var onLaunch: (() -> Void)?
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ notification: Notification) { onLaunch?() }
}

@MainActor private final class WorkspaceCheckApplicationProcess {
    let isolated: IsolatedSupportDirectory
    let documents: TextDocumentController
    let app: NSApplication
    let delegate = WorkspaceCheckApplicationDelegate()
    init() throws {
        isolated = try IsolatedSupportDirectory("TabWorkspaceProcess")
        LanguageController.bundledCatalogURL = TestPaths.resources.appendingPathComponent("LanguageProfiles.json")
        NativeFixtureEnvironment.install()
        documents = TextDocumentController()
        app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.regular)
    }
    func run() -> Never {
        delegate.onLaunch = { [self] in
            // A real AppKit timer callback allows main-queue deliveries in nested RunLoop waits.
            let timer = Timer(timeInterval: 0.01, repeats: false) { [self] _ in
                MainActor.assumeIsolated {
                    Checks.run("TabWorkspaceChecks") {
                        defer {
                            isolated.restore()
                            NativeFixtureEnvironment.restore()
                        }
                        check(
                            NSDocumentController.shared === documents,
                            "tab workspace process owns the document controller")
                        check(app.isRunning, "owned workspace checks run in the actual NSApplication event loop")
                        try TabWorkspaceNativeChecks.run(root: isolated.url)
                        Checks.summary { "PASS TabWorkspaceChecks: \(Checks.count) native assertions" }
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .default)
        }
        withExtendedLifetime(self) { app.run() }
        Checks.fail("The owned application event loop stopped before native completion.", file: #filePath, line: #line)
        Checks.finish("TabWorkspaceChecks")
    }
}

@MainActor enum TabWorkspaceNativeChecks {
    @MainActor private final class Observation { var switched = false }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func runApplicationProcess() -> Never {
        do { try WorkspaceCheckApplicationProcess().run() } catch {
            Checks.fail("Owned native application setup failed: \(error)", file: #filePath, line: #line)
            Checks.finish("TabWorkspaceChecks")
        }
    }
    static func run(root: URL) throws {
        let priorDelegate = NSApp.delegate, priorFront = NSWorkspace.shared.frontmostApplication
        defer {
            NSApp.delegate = priorDelegate
            priorFront?.activate(options: [.activateAllWindows])
        }
        let unstarted = AppDelegate(), windowsBeforeLookup = NSApp.windows.count
        check(
            unstarted.currentEditor == nil && unstarted.currentDocument == nil
                && NSApp.windows.count == windowsBeforeLookup,
            "T0-R7 current-target getters never create a workspace window")
        let services = EditorServices.current
        let composition = AppDelegate()
        composition.installEditorServices()
        NSApp.delegate = composition
        composition.buildMenus()
        defer { EditorServices.current = services }
        let tabMenuActions = [
            #selector(AppDelegate.findNextShared(_:)), #selector(AppDelegate.findPreviousShared(_:)),
            #selector(AppDelegate.nextDocumentTab(_:)), #selector(AppDelegate.previousDocumentTab(_:)),
            #selector(AppDelegate.showDocumentTabs(_:))
        ]
        func menuItem(_ action: Selector) throws -> NSMenuItem {
            func entries(_ menu: NSMenu) -> [NSMenuItem] {
                menu.items.flatMap { [$0] + ($0.submenu.map(entries) ?? []) }
            }
            return try requireValue(
                NSApp.mainMenu.map(entries)?.first { $0.action == action },
                "T0 real menu action " + NSStringFromSelector(action))
        }
        func updateMenus() { NSApp.mainMenu?.items.compactMap(\.submenu).forEach { $0.update() } }
        let windowsBeforeValidation = NSApp.windows.count
        check(
            !unstarted.validateMenuItem(try menuItem(#selector(AppDelegate.findNextShared(_:))))
                && NSApp.windows.count == windowsBeforeValidation,
            "T0-R7 menu validation is a pure lookup without constructing a workspace")
        let cold = DocumentFactory.makeUntitled(display: false)
        check(
            cold.isOpen && cold.editor.window == nil && cold.presentation?.statusTimerActive == false
                && cold.presentation?.statusMetricsCaptureCount == 0,
            "T0-R13 an unmounted first tab is open without visible status work")
        cold.close()
        let a = DocumentFactory.makeUntitled(), b = DocumentFactory.makeUntitled(), c = DocumentFactory.makeUntitled()
        defer {
            [a, b, c].forEach { $0.close() }
            composition.workspaceWindow.window?.orderOut(nil)
        }
        a.displayName = "Workspace A"
        b.displayName = "Workspace B"
        c.displayName = "Workspace C"
        let pa = try requireValue(a.presentation, "T0 A presentation"),
            pb = try requireValue(b.presentation, "T0 B presentation")
        let host = pa.host, window = try requireValue(host.window, "T0 workspace window")
        check(
            host === pb.host && c.presentation?.host === host && a.windowControllers[0].window == nil
                && b.windowControllers[0].window == nil && window.windowController === host && host.document == nil,
            "T0-R5 one native owner and windowless document adapters")
        check(
            NSApp.windows.filter { ($0.windowController as? WorkspaceWindowController) === host }.count == 1,
            "T0-R5 no hidden document windows")
        updateMenus()
        check(
            try tabMenuActions.allSatisfy { try menuItem($0).isEnabled },
            "T0-R7/22 actual menus enable document and tab actions with an active document")
        let closeMenuItem = try menuItem(#selector(NSWindow.performClose(_:)))
        check(
            window.validateMenuItem(closeMenuItem) && window.validateUserInterfaceItem(closeMenuItem),
            "T0-R18 active window Close validation retains its single-tab route")
        let frame = window.frame, editor = a.editor
        a.showWindows()
        pa.clone(nil)
        let clone = try requireValue(pa.secondary, "T0 Clone")
        clone.text = Array(repeating: "line\n", count: 150).joined()
        clone.resetUndoHistory()
        _ = clone.setSelectionAnchor(10, caret: 15)
        window.makeFirstResponder(clone)
        pa.showFind(nil)
        pa.findField.stringValue = "line"
        pa.replaceField.stringValue = "row"
        _ = clone.goToLine(100)
        let scrollLine = clone.firstVisibleLine
        let selection = clone.selectionRanges, last = pa.activeEditor
        b.showWindows()
        check(
            a.editor.window == nil && EditorLifetime.isOpen(a.editor) && !pa.isActiveTab && !pa.statusTimerActive,
            "T0-R13/20 detached inactive document remains open with no status timer")
        let revision = a.editor.revision
        let hits = try SearchCore.search(a.editor.text, options: SearchOptions(query: "line", replacement: "row"))
        check(
            SearchController.highlight(hits.hits, text: a.editor.text, revision: revision, in: a.editor),
            "T0-R20 Find All can mark an inactive registered document")
        let symbol = LanguageSymbol(name: "owned", range: NSRange(location: 0, length: 4), line: 1)
        check(
            LanguageFunctionController.navigate(symbol, text: a.editor.text, revision: revision, editor: a.editor),
            "T0-R20 Function List activates the captured inactive document")
        check(pa.isActiveTab && window.frame == frame, "T0-R21 result activation preserves the same host frame")
        window.makeFirstResponder(clone)
        pa.showFind(nil)
        b.showWindows()
        a.showWindows()
        check(
            a.editor === editor && pa.secondary === clone && clone.selectionRanges == selection
                && clone.firstVisibleLine == scrollLine && pa.activeEditor === last && pa.findBarVisible
                && pa.findField.stringValue == "line"
                && pa.replaceField.stringValue == "row",
            "T0-R14 same editor objects retain Clone, Find, selection and last pane across switches")
        // Real all-open result enumeration must include detached A and select its captured editor.
        b.editor.text = "line B"
        b.showWindows()
        let search = composition.searchController
        search.queryField.stringValue = "line"
        search.scope.selectItem(at: 2)
        search.findAll(nil)
        spinUntil("T0 all-open native results") { !search.isSearching }
        check(
            search.numberOfRows(in: search.table) == 151 && search.activateResult(at: 0) && pa.isActiveTab
                && pa.activeEditor.selectedText == "line",
            "T0-R20 all-open search includes detached A and activates its actual held result")
        search.window?.close()
        let captured = DocumentFactory.makeUntitled()
        captured.editor.text = "captured"
        captured.editor.resetUndoHistory()
        let runner = RunController()
        runner.editor = { captured.activeEditor }
        try runner.start(ConfiguredRun.uppercaseSample)
        b.showWindows()
        var apply: NSButton?
        spinUntil("T0 actual Run completion after switching tabs") {
            apply = NSApp.windows.flatMap { $0.contentView.map(descendants) ?? [] }.compactMap { $0 as? NSButton }.last
            { $0.identifier?.rawValue == "run.apply" }
            return apply != nil
        }
        try runner.applyResult(try requireValue(apply, "T0 Run Apply"))
        check(
            captured.editor.text == "CAPTURED" && b.editor.text == "line B" && pb.isActiveTab,
            "T0-R12/20 actual Run completion applies to captured inactive A without retargeting B")
        captured.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
        check(captured.editor.text == "captured", "captured Run remains one authoritative Undo step")
        NSApp.windows.filter { $0.title == ConfiguredRun.uppercaseSample.name }.forEach { $0.close() }
        captured.editor.text = "- 2 eggs\n"
        captured.editor.resetUndoHistory()
        captured.showWindows()
        var workflow = AutomationDefinition.example
        workflow.id = UUID()
        workflow.name = "Stage 0 captured automation"
        workflow.input = .document
        workflow.output = .editor
        workflow.previewBeforeApply = true
        try composition.automations.persistLibrary(AutomationLibrary(workflows: [workflow]))
        let observation = Observation()
        let previewAction: @MainActor @Sendable () -> Void = {
            guard let modal = NSApp.modalWindow, let content = modal.contentView,
                let apply = descendants(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Apply" })
            else { return }
            b.showWindows()
            observation.switched = pb.isActiveTab
            apply.performClick(nil)
        }
        let previewTimer = Timer(timeInterval: 0.02, repeats: true) { _ in MainActor.assumeIsolated { previewAction() }
        }
        RunLoop.main.add(previewTimer, forMode: .modalPanel)
        RunLoop.main.add(previewTimer, forMode: .common)
        try composition.automations.runSavedAutomation(id: workflow.id)
        previewTimer.invalidate()
        check(
            observation.switched && captured.editor.text == "2 eggs\n" && b.editor.text == "line B" && pb.isActiveTab,
            "T0-R12/20 native automation preview applies only to its captured inactive document")
        captured.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
        check(captured.editor.text == "- 2 eggs\n", "captured automation remains one Undo step")
        captured.close()
        a.showWindows()
        let old = pa.statusRefreshCount
        host.cycle(1)
        check(
            !pa.statusTimerActive && pb.isActiveTab && pa.statusRefreshCount == old,
            "T0-R13 keyboard cycle retires outgoing status timer immediately")
        a.showWindows()
        let nextCG = try requireValue(
            CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: true), "T0 Control-Tab event")
        nextCG.flags = [.maskControl]
        let nextKey = try requireValue(NSEvent(cgEvent: nextCG), "T0 native Control-Tab translation")
        check(
            NSApp.mainMenu?.performKeyEquivalent(with: nextKey) == true && pb.isActiveTab,
            "T0-R11 actual Control-Tab menu routing follows model order")
        let previousCG = try requireValue(
            CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: true), "T0 Control-Shift-Tab event")
        previousCG.flags = [.maskControl, .maskShift]
        let previousKey = try requireValue(NSEvent(cgEvent: previousCG), "T0 native Control-Shift-Tab translation")
        check(
            NSApp.mainMenu?.performKeyEquivalent(with: previousKey) == true && pa.isActiveTab,
            "T0-R11 actual Control-Shift-Tab returns to the prior tab")
        let revert = NSMenuItem(
            title: "Revert to Saved", action: #selector(NSDocument.revertToSaved(_:)), keyEquivalent: "")
        check(
            !pa.validateMenuItem(revert) && !a.validateMenuItem(revert),
            "T0-R7 active adapter preserves native untitled Revert validation")
        // Actual native close choices on captured inactive saved documents.
        for decision in ["Save", "Don't Save", "Cancel"] {
            let closeURL = root.appendingPathComponent(
                "close-" + decision.replacingOccurrences(of: " ", with: "-") + ".txt")
            try Data("original".utf8).write(to: closeURL)
            let closing = try DocumentFactory.openCaptured(
                WorkspaceStore.captureRegularFile(closeURL), from: closeURL, display: false)
            defer { closing.close() }
            closing.editor.text = "owned changed bytes"
            b.showWindows()
            let closeControl = try requireValue(
                descendants(host.tabStrip).compactMap { $0 as? NSButton }.first {
                    $0.toolTip == "Close " + closeURL.lastPathComponent
                }, "T0 native close control")
            closeControl.performClick(nil)
            NativeWindowEvents.wait("T0 native unsaved close review") { window.attachedSheet != nil }
            var decisionButton: NSButton?
            NativeWindowEvents.wait("T0 native close decision " + decision) {
                decisionButton = window.attachedSheet?.contentView.map(descendants)?.compactMap { $0 as? NSButton }
                    .first {
                        $0.title == decision
                            || (decision == "Don't Save" && ["Discard", "Don’t Save"].contains($0.title))
                    }
                return decisionButton != nil
            }
            print(
                "T0 native close review", decision, String(describing: window.attachedSheet),
                window.attachedSheet?.contentView.map(descendants)?.compactMap { ($0 as? NSButton)?.title } ?? [])
            try requireValue(decisionButton, "T0 native close " + decision).performClick(nil)
            NativeWindowEvents.wait("T0 native close decision completion") { window.attachedSheet == nil }
            if decision == "Cancel" {
                check(
                    closing.isOpen && closing.presentation?.isActiveTab == true
                        && closing.editor.text == "owned changed bytes" && b.editor.text == "line B"
                        && (try? Data(contentsOf: closeURL)) == Data("original".utf8),
                    "T0-R4/6 native background Cancel preserves the reviewed document and disk bytes")
                closing.close()
            } else {
                NativeWindowEvents.wait("T0 reviewed document closes") { closing.isClosed }
                print(
                    "T0 native close completion", decision, closing.isOpen, closing.isClosed,
                    String(describing: window.attachedSheet),
                    window.attachedSheet?.contentView.map(descendants)?.compactMap { ($0 as? NSTextField)?.stringValue }
                        ?? [])
                try require(closing.isClosed, "T0 native reviewed close must finish before the next scenario")
                let expected = decision == "Save" ? "owned changed bytes" : "original"
                check(
                    closing.isClosed && pb.isActiveTab && b.editor.text == "line B"
                        && (try? Data(contentsOf: closeURL)) == Data(expected.utf8),
                    "T0-R4/6 native background " + decision + " returns to B with the correct disk bytes")
            }
        }
        a.showWindows()
        let backgroundSplit = DocumentFactory.makeUntitled(), foregroundSplit = DocumentFactory.makeUntitled()
        let backgroundPresentation = try requireValue(backgroundSplit.presentation, "T0 background split presentation")
        let foregroundPresentation = try requireValue(foregroundSplit.presentation, "T0 foreground split presentation")
        backgroundPresentation.clone(nil)
        foregroundPresentation.clone(nil)
        backgroundPresentation.closeSplit(nil)
        let foregroundCloneItem = try requireValue(
            window.toolbar?.items.first { $0.itemIdentifier == EditorToolbarCommand.split.identifier },
            "T0 active Clone toolbar")
        check(
            foregroundPresentation.isActiveTab && foregroundPresentation.secondary != nil
                && foregroundCloneItem.menuFormRepresentation?.state == .on,
            "T0-R14/19 retiring an inactive Clone never overwrites the active tab toolbar state")
        backgroundSplit.close()
        foregroundSplit.close()
        a.showWindows()
        pa.goToLine(nil)
        let lineForm = try requireValue(
            FormPanel.visible.last { $0.window.identifier?.rawValue == "TextTank.GoToLine" }, "T0 captured Go to Line")
        lineForm.window.makeFirstResponder(nil)
        try DesignSettingsChecks.field("goToLine.line", lineForm.window).stringValue = "4"
        b.showWindows()
        try DesignSettingsChecks.button("goToLine.go", lineForm.window).performClick(nil)
        check(
            pa.isActiveTab && clone.statusInfo.line == 4
                && (window.firstResponder as? NSView)?.isDescendant(of: clone) == true,
            "T0-R12 captured Go to Line reveals and focuses A after switching to B")
        let saveTarget = DocumentFactory.makeUntitled()
        saveTarget.editor.text = "Owned unsaved Save As fixture"
        b.showWindows()
        saveTarget.saveAs(nil)
        spinUntil("T0 captured inactive Save As sheet") { window.attachedSheet is NSSavePanel }
        let savePanel = try requireValue(window.attachedSheet as? NSSavePanel, "T0 captured Save As")
        check(
            savePanel.sheetParent === window && saveTarget.presentation?.isActiveTab == true,
            "T0-R6 native Save As attaches to the shared host and reveals its captured inactive document")
        savePanel.cancel(nil)
        spinUntil("T0 captured Save As cancellation") { window.attachedSheet == nil }
        check(
            saveTarget.isOpen && saveTarget.fileURL == nil && saveTarget.editor.text == "Owned unsaved Save As fixture",
            "T0-R6 native Save As Cancel preserves unsaved bytes and document lifetime")
        saveTarget.close()
        a.showWindows()
        let buttons = descendants(host.tabStrip).compactMap { $0 as? NSButton }
        let tab = try requireValue(buttons.first { $0.toolTip == a.displayName }, "T0 stable tab")
        let close = try requireValue(buttons.first { $0.toolTip == "Close Workspace A" }, "T0 close target")
        check(
            tab.accessibilityRole() == .radioButton && tab.accessibilitySubrole()?.rawValue == "AXTabButton"
                && (tab.accessibilityValue() as? NSNumber)?.boolValue == true,
            "T0-R9 native tab role and selected value")
        check(
            host.tabStrip.accessibilityRole() == .tabGroup && host.tabStrip.accessibilityLabel() == "Documents"
                && close.frame.width >= 28 && close.frame.height >= 28 && close.frame.minX - tab.frame.maxX >= 4,
            "T0-R9 tab group and separated 28-point close target")
        window.makeFirstResponder(tab)
        a.displayName = "Workspace A renamed"
        a.updateChangeCount(.changeDone)
        let same = descendants(host.tabStrip).compactMap { $0 as? NSButton }.first { $0.identifier == tab.identifier }
        check(
            same === tab && window.firstResponder === tab && tab.accessibilityLabel() == "Workspace A renamed, edited",
            "T0-R10 metadata updates preserve native tab identity/focus and edited words")
        a.updateChangeCount(.changeCleared)
        NativeWindowEvents.pump()
        let wide = tab.frame.width
        window.setContentSize(NSSize(width: 800, height: 600))
        window.contentView?.layoutSubtreeIfNeeded()
        let extras = (0..<2).map { _ in DocumentFactory.makeUntitled() }
        defer { extras.forEach { $0.close() } }
        window.contentView?.layoutSubtreeIfNeeded()
        NativeWindowEvents.pump()
        print("T0 SHRINK", wide, tab.frame.width, host.tabStrip.bounds.width)
        let stripScroll = try requireValue(
            descendants(host.tabStrip).compactMap { $0 as? NSScrollView }.first, "T0 tab overflow scroll")
        check(
            tab.frame.width < wide && tab.frame.width >= 28
                && stripScroll.documentView!.frame.width <= stripScroll.contentSize.width + 1,
            "T0-R9 five tabs shrink before horizontal overflow")
        let overflowTabs = (0..<3).map { _ in DocumentFactory.makeUntitled() }
        defer { overflowTabs.forEach { $0.close() } }
        window.contentView?.layoutSubtreeIfNeeded()
        check(
            stripScroll.documentView!.frame.width > stripScroll.contentSize.width
                && descendants(host.tabStrip).contains { $0 === tab },
            "T0-R9/10 minimum-width tabs overflow while surviving native controls retain identity")
        (extras + overflowTabs).forEach { $0.close() }
        a.showWindows()
        var terminate = 0
        let prior = RuntimeEnvironment.dependencies
        var effects = RuntimeEnvironment.current
        effects.terminate = { _ in terminate += 1 }
        RuntimeEnvironment.dependencies = effects
        window.standardWindowButton(.closeButton)?.performClick(nil)
        RuntimeEnvironment.dependencies = prior
        check(
            terminate == 1 && [a, b, c].allSatisfy(\.isOpen),
            "T0-R18 red close invokes injected Quit without closing a tab")
        b.close()
        c.close()
        a.close()
        check(
            host.model.activeTab == nil && window.isVisible && host.document == nil && window.title == "TextTank",
            "T0-R22 final close retains usable empty workspace without a new document")
        updateMenus()
        check(
            try tabMenuActions.allSatisfy { try !menuItem($0).isEnabled },
            "T0-R22 actual empty menus disable Find Next/Previous, cycling and Open Documents")
        check(
            try menuItem(EditorToolbarCommand.new.action).isEnabled
                && menuItem(EditorToolbarCommand.open.action).isEnabled,
            "T0-R22 actual empty File menu retains New/Open using native document metadata")
        check(
            !window.validateMenuItem(closeMenuItem) && !window.validateUserInterfaceItem(closeMenuItem),
            "T0-R18/22 empty window disables Close through both native validation protocols")
        check(
            try [
                EditorToolbarCommand.find.action, #selector(NSDocument.saveDocument(_:)),
                #selector(NSDocument.printDocument(_:))
            ].allSatisfy { try !menuItem($0).isEnabled },
            "T0-R22 empty menus disable Find, Save and Print")
        check(
            host.validateToolbarItem(EditorToolbarCommand.new.makeItem())
                && host.validateToolbarItem(EditorToolbarCommand.open.makeItem())
                && !host.validateToolbarItem(EditorToolbarCommand.find.makeItem()),
            "T0-R22 empty host enables New/Open and disables document commands")
        RuntimeEnvironment.dependencies = effects
        window.standardWindowButton(.closeButton)?.performClick(nil)
        RuntimeEnvironment.dependencies = prior
        check(
            terminate == 2 && host.model.activeTab == nil && window.isVisible,
            "T0-R18/22 the empty workspace red close still invokes injected Quit")
        let emptyClone = try requireValue(
            window.toolbar?.items.first { $0.itemIdentifier == EditorToolbarCommand.split.identifier },
            "T0 empty Clone item")
        let emptyAutomations = try requireValue(
            window.toolbar?.items.first { $0.itemIdentifier.rawValue == "TextTank.Automations" },
            "T0 empty Automations item")
        check(
            !host.validateToolbarItem(emptyClone) && emptyClone.menuFormRepresentation?.state == .off
                && host.validateToolbarItem(emptyAutomations),
            "T0-R19 empty workspace clears Clone while retaining global automation management")
        check(
            !EditorLifetime.isOpen(editor) && !EditorLifetime.isOpen(clone),
            "T0-R20 retained closed editors never remain valid")
        let identityURL = root.appendingPathComponent("same-path-runtime-identity.txt")
        try Data("owned identity fixture".utf8).write(to: identityURL)
        let original = try DocumentFactory.openCaptured(
            WorkspaceStore.captureRegularFile(identityURL), from: identityURL, display: false)
        let originalID = original.runtimeID, originalEditor = original.editor
        original.close()
        let reopened = try DocumentFactory.openCaptured(
            WorkspaceStore.captureRegularFile(identityURL), from: identityURL)
        defer { reopened.close() }
        check(
            reopened.runtimeID != originalID && !EditorLifetime.isOpen(originalEditor)
                && reopened.fileURL == identityURL,
            "T0-R20 reopening the same path has fresh runtime identity and never revives a retained old editor")
        // Observe actual system transition notifications, separate from physical input certification.
        let fullWindow = try requireValue(reopened.presentation?.hostWindow, "T0 full-screen host")
        var entered = false, exited = false
        let center = NotificationCenter.default
        let enter = center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: fullWindow, queue: nil)
        { _ in MainActor.assumeIsolated { entered = true } }
        let exit = center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: fullWindow, queue: nil) {
            _ in MainActor.assumeIsolated { exited = true }
        }
        defer {
            center.removeObserver(enter)
            center.removeObserver(exit)
        }
        print("T0 OWNED ACTIVATION", Bundle.main.bundleURL.path, fullWindow.windowNumber)
        fflush(stdout)
        NSApp.activate()
        fullWindow.makeKeyAndOrderFront(nil)
        fullWindow.makeMain()
        NativeWindowEvents.wait("owned native full-screen window becomes key") { fullWindow.isKeyWindow }
        print("T0 full-screen preflight", NSApp.isActive, fullWindow.isKeyWindow, fullWindow.styleMask.rawValue)
        defer {
            if fullWindow.styleMask.contains(.fullScreen) {
                fullWindow.toggleFullScreen(nil)
                NativeWindowEvents.wait("owned full-screen cleanup", timeout: 20) {
                    !fullWindow.styleMask.contains(.fullScreen)
                }
            }
        }
        fullWindow.toggleFullScreen(nil)
        NativeWindowEvents.wait("T0 actual native full-screen entry", timeout: 20) { entered }
        check(
            entered && fullWindow.styleMask.contains(.fullScreen),
            "T0-R16 actual native full-screen entry notification and state")
        if entered {
            let extra = DocumentFactory.makeUntitled()
            let p = try requireValue(extra.presentation, "T0 full-screen tab")
            p.clone(nil)
            p.showFind(nil)
            reopened.showWindows()
            extra.showWindows()
            check(
                p.findBarVisible && p.secondary != nil && fullWindow.styleMask.contains(.fullScreen),
                "T0-R16 full-screen tab switching retains Find/Clone")
            extra.editor.text = "Owned unsaved full-screen fixture"
            extra.updateChangeCount(.changeDone)
            fullWindow.performClose(nil)
            spinUntil("T0 full-screen unsaved review") { fullWindow.attachedSheet != nil }
            if let savePanel = fullWindow.attachedSheet as? NSSavePanel {
                savePanel.cancel(nil)
            } else {
                var cancelButton: NSButton?
                spinUntil("T0 full-screen native Cancel control") {
                    cancelButton = fullWindow.attachedSheet?.contentView.map(descendants)?.compactMap {
                        $0 as? NSButton
                    }.first { $0.title == "Cancel" }
                    return cancelButton != nil
                }
                try requireValue(cancelButton, "T0 full-screen Cancel").performClick(nil)
            }
            spinUntil("T0 full-screen cancelled review") { fullWindow.attachedSheet == nil }
            check(
                extra.isOpen && p.isActiveTab && fullWindow.styleMask.contains(.fullScreen),
                "T0-R16 native dirty-close Cancel keeps its tab and full-screen workspace")
            extra.updateChangeCount(.changeCleared)
            extra.close()
            check(
                reopened.presentation?.isActiveTab == true && fullWindow.styleMask.contains(.fullScreen),
                "T0-R16 closing a full-screen tab retains workspace")
            fullWindow.toggleFullScreen(nil)
            NativeWindowEvents.wait("T0 actual native full-screen exit", timeout: 20) { exited }
            check(
                exited && !fullWindow.styleMask.contains(.fullScreen),
                "T0-R16 actual native full-screen exit notification and state")
        }
        print(
            "T0 physical keyboard/VoiceOver/full-screen interaction: unverified; native API transitions recorded above")
    }
}
