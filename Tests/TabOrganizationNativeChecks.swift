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
        // Native selection and immutable menu capture, using the actual tab controls.
        let sa = try saved("selected-A"), sb = try saved("selected-B"), sc = try saved("selected-C"),
            sd = try saved("selected-D"), se = try saved("selected-E")
        sc.showWindows()
        let selectionResponder = window.firstResponder
        let revision = sc.editor.revision
        func selectedIDs() -> Set<TabID> { host.tabSelection.selected(in: host.model, group: .first) }
        func click(_ doc: TextDocument, _ modifiers: NSEvent.ModifierFlags = []) {
            host.tabStrip.clickTab(id(doc), modifiers: modifiers)
        }
        click(sa, .command)
        click(se, .command)
        check(selectedIDs() == [id(sa), id(sc), id(se)], "T2 native Command noncontiguous selection")
        check(
            host.active?.document === sc && window.firstResponder === selectionResponder,
            "T2 selecting inactive tabs preserves actual editing responder")
        check(
            sc.editor.revision == revision && !sc.isDocumentEdited && sc.editor.text == "disk",
            "T2 selection leaves revision text and dirty unchanged")
        let selectedButton = try button(sa), unselectedButton = try button(sb)
        check(
            (selectedButton.accessibilityValue() as? NSNumber)?.boolValue == true
                && selectedButton.isAccessibilitySelected() && !unselectedButton.isAccessibilitySelected(),
            "T2 actual AX selected value distinguishes inactive selection")
        let addAction = unselectedButton.accessibilityCustomActions()?.first { $0.name == "Add to Selection" }
        check(
            addAction?.handler?() == true && selectedIDs() == [id(sa), id(sb), id(sc), id(se)]
                && window.firstResponder === selectionResponder,
            "T2 native AX Add action creates keyboard-accessible selection without focus change")
        check(addAction?.handler?() == false, "T2 stale AX Add intent cannot toggle a now-selected tab off")
        let removeAction = unselectedButton.accessibilityCustomActions()?.first { $0.name == "Remove from Selection" }
        check(
            removeAction?.handler?() == true && selectedIDs() == [id(sa), id(sc), id(se)],
            "T2 native AX Remove action uses same selection core")
        let rangeAction = unselectedButton.accessibilityCustomActions()?.first {
            $0.name == "Select Range from Active Tab"
        }
        check(
            rangeAction?.handler?() == true && selectedIDs() == [id(sb), id(sc)]
                && host.active?.document === sc && window.firstResponder === selectionResponder,
            "T2 native AX Range action preserves active anchor and focus")
        click(sc)
        check(
            try button(sc).accessibilityCustomActions()?.map(\.name) == ["Select Range from Active Tab"],
            "T2 sole active tab exposes no impossible Remove action")
        click(sa, .command)
        click(se, .command)
        let retired = try saved("AX-retired-target")
        click(sc)
        click(sa, .command)
        click(se, .command)
        let retiredButton = try button(retired)
        let retiredAction = retiredButton.accessibilityCustomActions()?.first { $0.name == "Add to Selection" }
        retired.close()
        let priorRetiredAttempt = selectedIDs()
        check(
            retiredAction?.handler?() == false && selectedIDs() == priorRetiredAttempt,
            "T2 native AX action refuses retired target without retargeting selection")
        let selectionSheet = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        let beforeSheet = selectedIDs()
        let heldSelectionAction = unselectedButton.accessibilityCustomActions()?.first { $0.name == "Add to Selection" }
        window.beginSheet(selectionSheet)
        check(
            unselectedButton.accessibilityCustomActions()?.isEmpty == true,
            "T2 unavailable selection actions disappear while native sheet is attached")
        check(
            heldSelectionAction?.handler?() == false && selectedIDs() == beforeSheet,
            "T2 held selection callback refuses native sheet race")
        window.endSheet(selectionSheet)
        NativeWindowEvents.wait("T2 selection fixture sheet ends") { window.attachedSheet == nil }
        selectionSheet.orderOut(nil)
        check(
            unselectedButton.accessibilityCustomActions()?.isEmpty == false,
            "T2 selection actions return after native sheet without stale refresh")
        let selectedBackground = descendants(host.tabStrip).first {
            $0 !== selectedButton && $0.frame.minX == selectedButton.frame.minX - 8
                && $0.frame.width == selectedButton.frame.width + 48
        }
        check(selectedBackground?.isHidden == false, "T2 selected inactive background is exposed for noncolour outline")
        let capturedMenu = commands.contextMenu(for: id(sa))
        check(
            try item(capturedMenu, .close).title == "Close 3 Tabs" && item(capturedMenu, .pin).title == "Pin 3 Tabs",
            "T2 selection context counts")
        main.update()
        check(
            try item(main, .close).title == "Close 3 Tabs" && item(main, .pin).title == "Pin 3 Tabs",
            "T2 main selection counts match context")
        let outsideMenu = commands.contextMenu(for: id(sb))
        check(
            try item(outsideMenu, .close).title == "Close Tab" && item(outsideMenu, .pin).title == "Pin Tab"
                && selectedIDs() == [id(sa), id(sc), id(se)],
            "T2 outside context is single and does not change selection")
        commands.perform(.pin, target: id(sa))
        let mixedMenu = commands.contextMenu(for: id(sc))
        check(
            try item(mixedMenu, .pin).title == "Pin 2 Tabs" && item(mixedMenu, .pin).state == .mixed,
            "T2 mixed pin counts only views that change")
        try invoke(mixedMenu, .pin)
        let allPinned = commands.contextMenu(for: id(sc))
        check(
            try item(allPinned, .pin).title == "Unpin 3 Tabs" && item(allPinned, .pin).state == .on,
            "T2 all pinned selection checks and counts")
        check(
            host.model.groups[0].tabs.prefix(3).map(\.id) == [id(sa), id(sc), id(se)]
                && selectedIDs() == [id(sa), id(sc), id(se)] && window.firstResponder === selectionResponder,
            "T2 multi pin keeps visible order selection and editor focus")
        try invoke(allPinned, .pin)
        click(sc)
        click(se, .shift)
        check(
            selectedIDs() == [id(sc), id(se)] && host.active?.document === sc,
            "T2 Shift range follows current order and preserves active anchor")
        click(sc, .command)
        check(
            selectedIDs() == [id(se)] && host.active?.document === se,
            "T2 Command active chooses other selected actual document")
        click(sa, .command)
        click(sc, .command)
        host.cycle(-1)
        check(selectedIDs() == [host.model.activeTab!.id], "T2 Next Previous clears selection")
        click(sc)
        click(sa, .command)
        click(se, .command)
        // Changing the selection after a menu is built cannot broaden its target set.
        click(sb)
        try invoke(capturedMenu, .pin)
        check(
            host.model.groups[0].tabs.filter(\.isPinned).map(\.id) == [id(sa), id(sc), id(se)]
                && selectedIDs() == [id(sb)], "T2 old menu pins captured identities rather than later selection")
        let outsideBefore = commands.contextMenu(for: id(sd))
        click(sc)
        click(sa, .command)
        let keepMenu = commands.contextMenu(for: id(sd))
        try invoke(keepMenu, .closeOthers)
        waitClose()
        check(
            sa.isOpen && sc.isOpen && se.isOpen && sd.isOpen && sb.isClosed,
            "T2 outside Close Other keeps captured selection clicked target and excluded pin")
        check(selectedIDs() == [id(sa), id(sc)], "T2 Close Other preserves selected survivors")
        // A removed member is pruned; the clicked target disappearing disables the whole set.
        let staleMembers = commands.contextMenu(for: id(sa))
        sc.close()
        check(selectedIDs() == [host.model.activeTab!.id], "T2 selected disappearance collapses selection")
        _ = commands.validateMenuItem(try item(staleMembers, .close))
        check(try item(staleMembers, .close).title == "Close Tab", "T2 captured selection prunes gone member count")
        sa.close()
        check(
            !commands.validateMenuItem(try item(staleMembers, .close)), "T2 gone clicked target disables captured set")
        _ = outsideBefore
        reset()
        // Pinned selected close is explicit and transactional across dirty documents.
        for decision in [TabCloseDecision.save, .discard, .cancel] {
            let x = try saved("multi-pin-\(decision)"), y = try saved("multi-dirty-\(decision)"),
                keep = try saved("multi-keep-\(decision)")
            commands.perform(.pin, target: id(x))
            x.editor.text = "pin changed"
            y.editor.text = "other changed"
            click(y)
            click(x, .command)
            let selection = selectedIDs(), originalActive = host.model.activeTab?.id, focus = window.firstResponder
            var reviews: [DocumentID] = []
            commands.decisionHandler = { prompt, reply in
                reviews.append(prompt.documentID)
                reply(decision)
            }
            commands.saveHandler = { doc, reply in
                doc.save(to: doc.fileURL!, ofType: doc.fileType!, for: .saveOperation) { reply($0) }
            }
            let menu = commands.contextMenu(for: id(x))
            check(try item(menu, .close).title == "Close 2 Tabs", "T2 selected explicit close counts pin")
            try invoke(menu, .close)
            waitClose()
            if decision == .cancel {
                check(
                    x.isOpen && y.isOpen && keep.isOpen && selectedIDs() == selection
                        && host.model.activeTab?.id == originalActive && window.firstResponder === focus,
                    "T2 selected close Cancel retains every tab selection active and responder")
                check(reviews == [x.runtimeID], "T2 Cancel stops review without saves")
            } else {
                check(
                    x.isClosed && y.isClosed && keep.isOpen && reviews == [x.runtimeID, y.runtimeID],
                    "T2 selected close reviews and closes pinned plus ordinary only")
                check(selectedIDs() == [id(keep)], "T2 successful selected close collapses to surviving active")
            }
            check(
                try Data(contentsOf: x.fileURL!) == Data((decision == .save ? "pin changed" : "disk").utf8)
                    && Data(contentsOf: y.fileURL!) == Data((decision == .save ? "other changed" : "disk").utf8),
                "T2 selected close exact disk bytes \(decision)")
            reset()
        }
        for failSave in [false, true] {
            let first = try saved("selected-atomic-first-\(failSave)"),
                second = try saved("selected-atomic-second-\(failSave)"),
                outside = try saved("selected-atomic-outside-\(failSave)")
            commands.perform(.pin, target: id(first))
            first.editor.text = "first changed"
            second.editor.text = "second changed"
            click(second)
            click(first, .command)
            let selection = selectedIDs(), focus = window.firstResponder
            var decisions = 0, saves = 0
            let heldBusyAction = try button(outside).accessibilityCustomActions()?.first {
                $0.name == "Add to Selection"
            }
            let busyButton = try button(outside)
            commands.decisionHandler = { _, reply in
                decisions += 1
                check(
                    busyButton.accessibilityCustomActions()?.isEmpty == true
                        && heldBusyAction?.handler?() == false && selectedIDs() == selection,
                    "T2 busy selection actions are unavailable and retained callback is guarded")
                reply(!failSave && decisions == 2 ? .cancel : .save)
            }
            commands.saveHandler = { doc, reply in
                saves += 1
                if doc === second {
                    reply(CocoaError(.fileWriteNoPermission))
                } else {
                    doc.save(to: doc.fileURL!, ofType: doc.fileType!, for: .saveOperation) { reply($0) }
                }
            }
            try invoke(commands.contextMenu(for: id(first)), .close)
            waitClose()
            check(
                first.isOpen && second.isOpen && outside.isOpen && selectedIDs() == selection
                    && window.firstResponder === focus && host.active?.document === second,
                "T2 selected second Cancel or save failure closes none and restores selection focus")
            check(
                decisions == 2 && saves == (failSave ? 2 : 0) && commands.history.records.isEmpty,
                "T2 all decisions precede saves and failed selected close adds no history")
            check(
                try Data(contentsOf: first.fileURL!) == Data((failSave ? "first changed" : "disk").utf8)
                    && Data(contentsOf: second.fileURL!) == Data("disk".utf8),
                "T2 failed selected close retains earlier saves only")
            let beforeOutside = selectedIDs()
            outside.close()
            check(selectedIDs() == beforeOutside, "T2 unrelated disappearance preserves multi-selection")
            reset()
        }
        let returnA = try saved("selected-return-A"), returnB = try saved("selected-return-B"),
            returnC = try saved("selected-return-C")
        click(returnA)
        click(returnB, .command)
        let returnAID = id(returnA), returnBID = id(returnB)
        let selectedClose = try requireValue(
            descendants(host.tabStrip).compactMap { $0 as? NSButton }.first {
                $0.toolTip == "Close " + returnB.fileURL!.lastPathComponent
            }, "T2 selected background close control")
        selectedClose.performClick(nil)
        check(
            returnB.isClosed && returnA.isOpen && returnC.isOpen && host.model.activeTab?.id == returnAID
                && selectedIDs() == [returnAID] && !ids().contains(returnBID),
            "T2 selected background X closes only target and collapses to final restored active")
        reset()
        // Main menu and File Close differ intentionally in scope (DS-D2).
        let mx = try saved("main-close-X"), my = try saved("main-close-Y"), mz = try saved("main-close-Z")
        click(my)
        click(mx, .command)
        let mxID = id(mx), myID = id(my)
        host.closeActive(nil)
        check(
            my.isClosed && mx.isOpen && mz.isOpen && !ids().contains(myID) && ids().contains(mxID),
            "T2 File Close remains single even with selection")
        click(mx)
        click(mz, .command)
        main.update()
        check(try item(main, .close).title == "Close 2 Tabs", "T2 main close carries current selected count")
        try invoke(main, .close)
        waitClose()
        check(
            mx.isClosed && mz.isClosed && host.model.groups[0].tabs.isEmpty,
            "T2 main selected Close uses same bulk path")
        reset()
        for decision in ["Save", "Don't Save", "Cancel"] {
            let closing = try saved("own-pin-" + decision), peer = try saved("own-pin-peer-" + decision)
            commands.perform(.pin, target: id(closing))
            closing.editor.text = "owned pin edits"
            click(peer)
            let control = try requireValue(
                descendants(host.tabStrip).compactMap { $0 as? NSButton }.first {
                    $0.toolTip == "Close " + closing.fileURL!.lastPathComponent
                }, "T2 pinned own close control")
            control.performClick(nil)
            NativeWindowEvents.wait("T2 pinned native dirty review") { window.attachedSheet != nil }
            var choiceButton: NSButton?
            NativeWindowEvents.wait("T2 pinned decision button") {
                choiceButton = window.attachedSheet?.contentView.map(descendants)?.compactMap { $0 as? NSButton }.first
                {
                    $0.title == decision || (decision == "Don't Save" && ["Discard", "Don’t Save"].contains($0.title))
                }
                return choiceButton != nil
            }
            try requireValue(choiceButton, "T2 pinned close decision").performClick(nil)
            NativeWindowEvents.wait("T2 pinned decision completes") { window.attachedSheet == nil }
            if decision == "Cancel" {
                check(
                    closing.isOpen && closing.isDocumentEdited && host.model.activeTab?.isPinned == true,
                    "T2 pinned own close Cancel preserves edited pin and reviewed active")
            } else {
                NativeWindowEvents.wait("T2 pinned own close retires") { closing.isClosed }
                check(
                    closing.isClosed && peer.isOpen && host.active?.document === peer,
                    "T2 pinned own close returns to prior active " + decision)
            }
            check(
                try Data(contentsOf: closing.fileURL!) == Data((decision == "Save" ? "owned pin edits" : "disk").utf8),
                "T2 pinned own close exact native lifecycle bytes " + decision)
            reset()
        }
        let stableA = try saved("stable-A"), stableB = try saved("stable-B"), stableC = try saved("stable-C")
        commands.perform(.pin, target: id(stableA))
        host.reorderTab(id(stableC), to: 1)
        let stableOrder = ids()
        stableB.editor.text = "saved metadata"
        host.metadataChanged()
        stableB.showWindows()
        let renamed = root.appendingPathComponent("stable-renamed.txt")
        var saveDone = false, saveError: Error?
        stableB.save(to: renamed, ofType: "public.plain-text", for: .saveAsOperation) {
            saveError = $0
            saveDone = true
        }
        spinUntil("T2 stable Save As completion") { saveDone }
        try require(saveError == nil, "T2 owned Save As succeeds")
        try Data("external current bytes".utf8).write(to: renamed)
        try stableB.revert(toContentsOf: renamed, ofType: "public.plain-text")
        host.metadataChanged()
        check(
            ids() == stableOrder && stableB.editor.text == "external current bytes"
                && host.model.groups[0].tabs.first?.isPinned == true,
            "T2 dirty title Save As activation reload refresh never reorder or unpin")
        let selectStable = try button(stableC), stableActive = host.model.activeTab?.id,
            stableFocus = window.firstResponder
        let point = selectStable.convert(NSPoint(x: 10, y: 10), to: nil)
        let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 10, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 11, clickCount: 1, pressure: 0)!
        selectStable.mouseDown(with: down)
        check(
            host.model.activeTab?.id == stableActive && window.firstResponder === stableFocus,
            "T2 actual mouse down defers selection until click or drag resolved")
        selectStable.mouseUp(with: up)
        check(
            selectedIDs() == [id(stableB), id(stableC)] && host.model.activeTab?.id == stableActive
                && window.firstResponder === stableFocus, "T2 actual Command mouse click toggles without focus change")
        commands.perform(.newToRight, target: id(stableC))
        let inserted = try requireValue(app.currentDocument, "T2 post-reorder inserted doc")
        check(
            ids()[2] == id(inserted) && !host.model.groups[0].tabs[2].isPinned,
            "T2 New Right uses reordered visible index")
        commands.perform(.closeRight, target: id(stableC))
        waitClose()
        check(
            inserted.isClosed && stableB.isClosed && stableA.isOpen && stableC.isOpen,
            "T2 directional close uses reordered index and excludes pin")
        reset()
        let readOnly = try saved("organisation-readonly"), untitled = DocumentFactory.makeUntitled()
        readOnly.editor.readOnly = true
        click(readOnly)
        click(untitled, .command)
        let readonlyRevision = readOnly.editor.revision
        try invoke(commands.contextMenu(for: id(readOnly)), .pin)
        host.reorderTab(id(untitled), to: 0)
        check(
            host.model.groups[0].tabs.allSatisfy(\.isPinned) && readOnly.editor.revision == readonlyRevision
                && readOnly.editor.readOnly && !readOnly.isDocumentEdited && !untitled.isDocumentEdited,
            "T2 read-only and untitled pin reorder selection are view-only")
        let untitledID = id(untitled)
        untitled.close()
        check(
            !ids().contains(untitledID) && commands.history.records.isEmpty,
            "T2 closed clean untitled pin creates no history record")
        reset()
        var crowded: [TextDocument] = []
        for _ in 0..<14 { crowded.append(DocumentFactory.makeUntitled()) }
        let activeDoc = crowded.last!, moved = crowded[crowded.count - 2]
        activeDoc.showWindows()
        window.contentView?.layoutSubtreeIfNeeded()
        window.makeFirstResponder(activeDoc.editor)
        let crowdedResponder = window.firstResponder
        check(
            (crowdedResponder as? NSView)?.isDescendant(of: activeDoc.editor) == true,
            "T2 crowded fixture has actual editor focus before reorder")
        host.reorderTab(id(moved), to: 0)
        check(
            host.tabStrip.isTabHorizontallyVisible(id(activeDoc)) && host.active?.document === activeDoc
                && window.firstResponder === crowdedResponder,
            "T2 owner decision keeps active tab visible and preserves editor responder when both cannot fit")
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
