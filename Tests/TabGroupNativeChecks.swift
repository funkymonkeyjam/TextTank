import AppKit
@testable import TextTankCore
@testable import TextTankRuntime
import EditorBridge
import NativeSearch
import Darwin

@MainActor private final class GroupCheckContext {
    let isolated: IsolatedSupportDirectory
    init() throws { isolated = try IsolatedSupportDirectory("TabGroupProcess") }
}
@MainActor private final class GroupCheckDelegate: NSObject, NSApplicationDelegate {
    var launched: (() -> Void)?
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ note: Notification) { launched?() }
}
@MainActor private final class RetiredGroupViews {
    weak var primary: TTEditor?
    weak var clone: TTEditor?
    weak var adapter: EditorWindowController?
}
@MainActor private final class RepairPublicationState {
    var called = false, noGlobalTarget = false, noRegistryTarget = false, allBindingsRetired = false,
        dispatchBlocked = false, creationDisabled = false
}
@MainActor enum TabGroupNativeChecks {
    static func runApplicationProcess() -> Never {
        do {
            let context = try GroupCheckContext()
            LanguageController.bundledCatalogURL = TestPaths.resources.appendingPathComponent("LanguageProfiles.json")
            NativeFixtureEnvironment.install()
            let documents = TextDocumentController(), app = NSApplication.shared, delegate = GroupCheckDelegate()
            app.setActivationPolicy(.regular)
            app.delegate = delegate
            delegate.launched = {
                let timer = Timer(timeInterval: 0.01, repeats: false) { _ in
                    MainActor.assumeIsolated { () -> Void in
                        Checks.run("TabGroupNativeChecks") {
                            defer {
                                context.isolated.restore()
                                NativeFixtureEnvironment.restore()
                            }
                            check(
                                NSDocumentController.shared === documents && app.isRunning,
                                "T3 owned actual AppKit controller/loop")
                            try run(root: context.isolated.url)
                            Checks.summary { "PASS TabGroupNativeChecks: \(Checks.count) native assertions" }
                        }
                    }
                }
                RunLoop.main.add(timer, forMode: .default)
            }
            withExtendedLifetime(delegate) { app.run() }
        } catch { Checks.fail("T3 native setup: \(error)", file: #filePath, line: #line) }
        Checks.finish("TabGroupNativeChecks")
    }
    static func run(root: URL) throws {
        let priorDelegate = NSApp.delegate, priorServices = EditorServices.current,
            front = NSWorkspace.shared.frontmostApplication
        let app = AppDelegate()
        NSApp.delegate = app
        app.installEditorServices()
        app.buildMenus()
        let host = app.workspaceWindow, commands = host.tabCommands
        let window = try requireValue(host.window, "T3 owned host")
        NSApp.activate(ignoringOtherApps: true)
        defer {
            commands.isTerminating = true
            NSDocumentController.shared.documents.forEach { $0.close() }
            commands.isTerminating = false
            commands.clearHistory()
            window.orderOut(nil)
            EditorServices.current = priorServices
            NSApp.delegate = priorDelegate
            front?.activate(options: [.activateAllWindows])
        }
        check(
            host.model.groups[0].tabs.isEmpty && NSDocumentController.shared.documents.isEmpty,
            "T3 cold host has no prewarmed document or removed Clone")
        let retired = RetiredGroupViews()
        @MainActor func openSharedAndCloseOriginal(_ document: TextDocument) throws -> TabID {
            let a = try requireValue(document.presentation, "T3 original adapter")
            let aid = try requireValue(host.model.activeTab?.id, "T3 original TabID")
            let initialSettings = app.settings.value
            var disabled = initialSettings
            disabled.autoIndent = false
            disabled.autoPair = true
            EditorSettingsApplication.apply(disabled, replacing: initialSettings)
            defer { EditorSettingsApplication.apply(initialSettings, replacing: disabled) }
            a.clone(nil)
            retired.primary = a.primaryEditor
            retired.clone = a.secondary
            retired.adapter = a
            check(host.setEditorLayout(.twoColumns), "T3 internal two-group layout accepted")
            let bid = try requireValue(host.openView(aid, in: .second), "T3 distinct additional view")
            let b = try requireValue(host.presentation(for: bid), "T3 second adapter")
            b.clone(nil)
            check(
                a.primaryEditor !== b.primaryEditor && b.primaryEditor.sharesDocument(with: a.primaryEditor),
                "T3 distinct primary editors share actual Scintilla document")
            check(
                a.secondary != nil && b.secondary != nil && b.secondary!.sharesDocument(with: a.primaryEditor),
                "T3 both tab-local Clones share document")
            let panes = a.views + b.views
            check(
                panes.count == 4 && panes.allSatisfy { !$0.autoIndentEnabled && $0.autoPairEnabled },
                "both grouped primaries and local Clones inherit disabled auto-indent")
            var enabled = disabled
            enabled.autoIndent = true
            enabled.autoPair = false
            EditorSettingsApplication.apply(enabled, replacing: disabled)
            check(
                panes.allSatisfy { $0.autoIndentEnabled && !$0.autoPairEnabled },
                "a settings change reaches every pane in both groups")
            check(a.isPresented && b.isPresented, "T3 cold release has both real group presentations mounted")
            host.closeTab(aid, sender: nil)
            check(
                document.isOpen && host.model.groups.flatMap(\.tabs).count == 1 && window.attachedSheet == nil,
                "T3 non-final original tab close never prompts or closes document")
            check(document.editor === b.primaryEditor, "T3 surviving primary receives document service ownership")
            return bid
        }
        let (document, bid) = try autoreleasepool {
            let document = DocumentFactory.makeUntitled()
            document.editor.text = "one\ntwo\nthree\n"
            document.presentation?.showWindow(nil)
            return (document, try openSharedAndCloseOriginal(document))
        }
        // Drain setup’s native temporary collections, without prewarming any removal.
        wait("T3 cold original primary Clone and adapter release") {
            retired.primary == nil && retired.clone == nil && retired.adapter == nil
        }
        check(
            retired.primary == nil && retired.clone == nil && retired.adapter == nil,
            "T3 R13 cold original views weak-release without warming or hidden editor")
        let b = try requireValue(host.presentation(for: bid), "T3 surviving adapter")
        let old = b.primaryEditor.text, oldRevision = b.primaryEditor.revision
        b.secondary!.text = "changed through surviving Clone"
        check(
            b.primaryEditor.text == "changed through surviving Clone" && document.editor.text == b.primaryEditor.text
                && document.isDocumentEdited, "T3 surviving Clone edit updates one dirty shared document")
        check(
            b.primaryEditor.revision > oldRevision && b.primaryEditor.revision == b.secondary!.revision,
            "T3 promotion preserves coherent increasing revision")
        b.primaryEditor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
        check(
            b.primaryEditor.text == old && b.secondary!.text == old, "T3 Undo from surviving primary reverts Clone edit"
        )
        check(NSDocumentController.shared.documents.count == 1, "T3 additional views retain exactly one NSDocument")
        let surface = try requireValue(host.groupSurfaces[.second], "T3 second native surface")
        let priorFrame = surface.frame
        surface.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        surface.layoutSubtreeIfNeeded()
        b.showFind(nil)
        // With the Replace row shown: the tallest the bar gets.
        b.setReplaceRow(shown: true)
        surface.layoutSubtreeIfNeeded()
        b.presentationRoot.layoutSubtreeIfNeeded()
        let inlineFind = try requireValue(b.findBar, "T3 mounted Find bar")
        for control in inlineFind.subviews {
            let rect = b.presentationRoot.convert(control.bounds, from: control)
            check(
                b.presentationRoot.bounds.insetBy(dx: -1, dy: -1).contains(rect) && !control.isHidden,
                "T3 all essential Find controls fit 320x200 group: \(type(of:control))")
        }
        print(
            "T3 narrow geometry surface=\(surface.frame) root=\(b.presentationRoot.frame) split=\(b.split.frame) primary=\(b.primaryEditor.frame) clone=\(String(describing:b.secondary?.frame))"
        )
        fflush(stdout)
        check(
            b.split.frame.height >= 30 && b.primaryEditor.frame.width >= 100,
            "T3 minimum pane retains visible editor with Find")
        b.hideFind(nil)
        surface.frame = priorFrame
        surface.layoutSubtreeIfNeeded()
        try groupCases(host: host, app: app, root: root)
        try advancedCases(host: host, app: app, root: root)
        try repair1Cases(host: host, app: app)
        try repair3FocusCases(host: host, app: app)
    }
    private static func wait(_ label: String, _ condition: () -> Bool) {
        spinUntil(label) {
            for _ in 0..<32 {
                guard let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) else {
                    break
                }
                NSApp.sendEvent(event)
            }
            NSApp.updateWindows()
            return condition()
        }
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func groupCases(host: WorkspaceWindowController, app: AppDelegate, root: URL) throws {
        let commands = host.tabCommands, window = host.window!
        func reset() {
            commands.isTerminating = true
            NSDocumentController.shared.documents.forEach { $0.close() }
            commands.isTerminating = false
            commands.clearHistory()
            commands.decisionHandler = nil
            commands.saveHandler = nil
            _ = host.setEditorLayout(.single)
        }
        func saved(_ name: String, _ text: String = "one\ntwo\nthree\n") throws -> TextDocument {
            let url = root.appendingPathComponent(name + ".txt")
            try Data(text.utf8).write(to: url)
            return try DocumentFactory.openCaptured(WorkspaceStore.captureRegularFile(url), from: url)
        }
        func id(_ doc: TextDocument, in slot: GroupSlot? = nil) -> TabID {
            host.model.groups.filter { slot == nil || $0.slot == slot }.flatMap(\.tabs).first {
                $0.documentID == doc.runtimeID
            }!.id
        }
        func item(_ menu: NSMenu, _ identifier: String) throws -> NSMenuItem {
            func all(_ menu: NSMenu) -> [NSMenuItem] { menu.items + menu.items.flatMap { $0.submenu.map(all) ?? [] } }
            return try requireValue(
                all(menu).first { $0.identifier?.rawValue == identifier }, "T3 native item " + identifier)
        }
        func invoke(_ item: NSMenuItem) {
            if let action = item.action { _ = NSApp.sendAction(action, to: item.target, from: item) }
        }
        func nativeDecision(_ tab: TabID, _ choice: String) throws {
            host.closeTab(tab, sender: nil)
            wait("T3 final native review") { window.attachedSheet != nil }
            if choice == "Cancel", let panel = window.attachedSheet as? NSSavePanel {
                panel.cancel(nil)
                wait("T3 untitled native save Cancel") { window.attachedSheet == nil }
                return
            }
            var button: NSButton?
            wait("T3 final native button") {
                button = window.attachedSheet?.contentView.map(descendants)?.compactMap { $0 as? NSButton }.first {
                    $0.title == choice || (choice == "Discard" && ["Don’t Save", "Don't Save"].contains($0.title))
                }
                return button != nil
            }
            try requireValue(button, "T3 native " + choice).performClick(nil)
            wait("T3 final native completion") { window.attachedSheet == nil }
        }
        // The only tab left by the cold fixture has a local Clone: it is still a final tab.
        let original = try requireValue(host.active?.document as? TextDocument, "T3 cold survivor doc")
        let originalID = host.model.activeTab!.id
        try nativeDecision(originalID, "Cancel")
        check(
            original.isOpen && host.presentation(for: originalID)?.secondary != nil,
            "T3 final dirty Cancel preserves surviving primary and Clone")
        original.close()
        check(host.presentations.isEmpty, "T3 owned cold document cleanup removes final view")
        reset()
        let a = try saved("group-A"), aid = id(a)
        let ap = try requireValue(host.presentation(for: aid), "T3 moving adapter")
        ap.clone(nil)
        ap.activeEditor.restoreClosedTabView(anchor: 1, caret: 3, firstVisibleLine: 0)
        host.setPinnedTabs([aid], target: aid, pinned: true)
        let clone = ap.secondary, revision = a.editor.revision
        check(host.setEditorLayout(.twoColumns), "T3 expand columns")
        check(host.model.groups[1].tabs.isEmpty, "T3 expanded group starts empty")
        host.focusGroup(.second)
        check(
            app.currentEditor == nil && app.currentDocument == nil && app.currentDocumentController == nil,
            "T3 known empty focused group has no stale global target")
        let chooserItem = NSMenuItem(
            title: "Open Documents…", action: #selector(AppDelegate.showDocumentTabs(_:)), keyEquivalent: "")
        check(app.validateMenuItem(chooserItem), "T3 chooser remains available from empty group")
        app.newDocument(nil)
        let created = try requireValue(app.currentDocument, "T3 New in empty group")
        let visiblePair = host.visibleComparisonEditors
        check(
            visiblePair?.0 === ap.activeEditor && visiblePair?.1 === created.activeEditor,
            "Compare Two Visible Tabs resolves each mounted group's actual active pane in visual order")
        check(
            host.model.groups[1].tabs.contains { $0.documentID == created.runtimeID }
                && host.model.groups[0].tabs.map(\.id) == [aid], "T3 ordinary New scopes to focused group")
        created.close()
        let move = try item(commands.contextMenu(for: aid), "groups.move.2")
        invoke(move)
        check(
            host.presentation(for: aid) === ap && ap.secondary === clone && host.model.focusedGroup == .second
                && host.model.groups[0].tabs.isEmpty, "T3 native Move retains exact presentation Clone and empty source"
        )
        check(
            host.model.groups[1].tabs.first?.isPinned == true && ap.activeEditor.selectionCaret == 3
                && a.editor.revision == revision, "T3 Move preserves pin viewport and revision")
        let a1 = try requireValue(host.openView(aid, in: .first), "T3 additional view")
        let other = try requireValue(host.presentation(for: a1), "T3 additional primary")
        other.primaryEditor.restoreClosedTabView(anchor: 0, caret: 1, firstVisibleLine: 0)
        check(
            other.primaryEditor !== ap.primaryEditor && other.secondary == nil
                && host.model.groups[0].tabs.first?.isPinned == false,
            "T3 additional view starts unpinned without Clone")
        check(
            host.openView(aid, in: .first) == a1 && host.presentations.count == 2,
            "T3 duplicate Open selects existing destination")
        let rows = app.documentTabChoices(host.presentations)
        check(
            Set(rows.map(\.id)).count == 2 && rows.allSatisfy { $0.title.contains("Group") },
            "T3 chooser lists every exact TabID with group label")
        host.moveTabs([aid], target: aid, to: .first)
        check(
            host.presentation(for: aid) == nil && host.presentation(for: a1) === other
                && other.primaryEditor.selectionCaret == 1 && a.isOpen,
            "T3 duplicate Move keeps destination position and retires source")
        // A menu destination is a live group generation, not a reusable slot.
        let stale = try item(commands.contextMenu(for: a1), "groups.additional.2")
        let oldToken = host.groupSurfaces[.second]!.generation
        check(host.setEditorLayout(.single) && host.setEditorLayout(.twoColumns), "T3 remove then recreate destination")
        check(host.groupSurfaces[.second]!.generation != oldToken, "T3 recreated slot has new generation")
        invoke(stale)
        check(host.model.groups[1].tabs.isEmpty, "T3 stale destination invocation changes nothing")
        let live = try item(commands.contextMenu(for: a1), "groups.additional.2")
        let token = host.groupSurfaces[.second]!.generation
        check(host.setEditorLayout(.twoRows), "T3 orientation transition")
        invoke(live)
        check(
            host.groupSurfaces[.second]!.generation == token && host.model.groups[1].tabs.count == 1,
            "T3 orientation preserves captured destination continuity")
        let beforeRefusal = host.model, minBefore = window.contentMinSize, frameBefore = window.frame
        check(
            !host.setEditorLayout(.grid2x2, availableContent: TabGroupExtent(width: 400, height: 300)),
            "T3 native screen-fit refusal")
        check(
            host.model == beforeRefusal && window.contentMinSize == minBefore && window.frame == frameBefore
                && host.lastTabMessage.contains("cannot fit"),
            "T3 refused layout preserves model frame minimum and explains why")
        // Group-local selection, pin, reorder, cycle, and captured batch target.
        reset()
        let x = try saved("local-X"), xid = id(x)
        _ = host.setEditorLayout(.twoColumns)
        host.focusGroup(.second)
        let y = try saved("local-Y"), yid = id(y), z = try saved("local-Z"), zid = id(z)
        let firstTabs = host.model.groups[0].tabs
        _ = host.selectTab(yid, gesture: .plain)
        _ = host.selectTab(zid, gesture: .toggle)
        let captured = try item(commands.contextMenu(for: yid), "groups.move.1")
        check(captured.title.contains("Group 1"), "T3 native destination number and position")
        _ = host.selectTab(zid, gesture: .plain)
        invoke(captured)
        check(
            host.model.groups[0].tabs.map(\.id) == firstTabs.map(\.id) + [yid, zid]
                && host.model.groups[1].tabs.isEmpty, "T3 captured batch moves original set despite later selection")
        check(
            host.tabSelection.selected(in: host.model, group: .first) == [yid, zid] && host.model.activeTab?.id == yid,
            "T3 destination selects resolved batch and clicked active")
        host.cycle(1)
        check(
            host.model.activeTab?.id == zid && host.tabSelection.selected(in: host.model, group: .first) == [zid],
            "T3 Next cycles and collapses only focused selection")
        // Every Grid position and a global focused winner present in all four groups.
        reset()
        let shared = try saved("collapse-shared", String(repeating: "line\n", count: 80)), g1 = id(shared)
        _ = host.setEditorLayout(.grid2x2)
        let g2 = try requireValue(host.openView(g1, in: .second), "T3 G2"),
            g3 = try requireValue(host.openView(g1, in: .third), "T3 G3"),
            g4 = try requireValue(host.openView(g1, in: .fourth), "T3 G4")
        host.setPinnedTabs([g3], target: g3, pinned: true)
        let winner = try requireValue(host.presentation(for: g4), "T3 G4 winner")
        winner.clone(nil)
        winner.activeEditor.restoreClosedTabView(anchor: 3, caret: 8, firstVisibleLine: 10)
        let winnerEditor = winner.activeEditor, winnerClone = winner.secondary,
            allDocs = NSDocumentController.shared.documents.count, history = commands.history.records.count
        let frames = GroupSlot.allCases.map {
            host.groupSurfaces[$0]!.convert(host.groupSurfaces[$0]!.bounds, to: window.contentView)
        }
        check(
            frames[0].midX < frames[1].midX && frames[0].midY > frames[2].midY && frames[2].midX < frames[3].midX,
            "T3 Grid places 1 top-left 2 top-right 3 bottom-left 4 bottom-right")
        let vertical = host.groupContainer.dividers.filter(\.isVertical)
        if let top = vertical.first, let bottom = vertical.last {
            top.setPosition(350, ofDividerAt: 0)
            check(
                abs(top.subviews[0].frame.width - bottom.subviews[0].frame.width) < 1, "T3 Grid columns remain aligned")
            let position = top.subviews[0].frame.width
            _ = host.setEditorLayout(.grid2x2)
            check(top.subviews[0].frame.width == position, "T3 unchanged layout preserves divider position")
        }
        check(host.setEditorLayout(.single), "T3 collapse Grid")
        check(
            host.model.activeTab?.id == g4 && host.presentation(for: g4) === winner
                && winner.activeEditor === winnerEditor && winner.secondary === winnerClone
                && winnerEditor.selectionCaret == 8,
            "T3 collapse preserves exact focused global winner including Clone and viewport")
        check(
            host.presentations.count == 1 && host.presentation(for: g1) == nil && host.presentation(for: g2) == nil
                && host.presentation(for: g3) == nil && NSDocumentController.shared.documents.count == allDocs
                && commands.history.records.count == history,
            "T3 collapse deduplicates every losing view without close or history")
        // Session capture and polling are per document / visible presentation.
        let session = try app.workspace.capture(name: "Stage 3")
        check(
            session.documents.count == 1 && session.documents[0].selection.caretByte == 8,
            "T3 session deduplicates and captures focused Clone selection")
        _ = host.setEditorLayout(.grid2x2)
        for slot in [GroupSlot.second, .third, .fourth] {
            _ = host.openView(g4, in: slot)
            host.active?.clone(nil)
        }
        check(
            host.presentations.count == 4 && host.presentations.allSatisfy { $0.views.count == 2 && $0.isPresented },
            "T3 Grid mounts four shared presentations and four local Clones")
        let captures = host.presentations.map(\.statusMetricsCaptureCount)
        let started = ProcessInfo.processInfo.systemUptime
        for _ in 0..<20 { host.presentations.forEach { $0.statusTimerTick() } }
        check(
            zip(host.presentations, captures).allSatisfy { $0.0.statusMetricsCaptureCount - $0.1 <= 1 },
            "T3 repeated same-revision Grid ticks start at most one metrics job per presentation")
        print("T3 GRID_TICKS seconds=\(ProcessInfo.processInfo.systemUptime-started) presentations=4 editors=8")
        window.orderOut(nil)
        check(host.presentations.allSatisfy { !$0.statusTimerActive }, "T3 hidden Grid stops every presentation poller")
        window.makeKeyAndOrderFront(nil)
        // Grid Close Group retains the pane; two-pane Close Group normalizes its survivor.
        host.focusGroup(.fourth)
        host.closeEditorGroup(.fourth)
        check(
            host.model.layout == .grid2x2 && host.model.groups[3].tabs.isEmpty && host.model.focusedGroup == .first
                && host.model.activeTab?.documentID == shared.runtimeID,
            "T3 focused Grid Close Group empties pane and focuses resolved destination")
        _ = host.setEditorLayout(.twoColumns)
        func heading(_ slot: GroupSlot) throws -> NSView {
            let surface = try requireValue(host.groupSurfaces[slot], "group surface")
            surface.layoutSubtreeIfNeeded()
            return try requireValue(
                surface.subviews.first { $0.identifier?.rawValue == "groups.heading.\(slot.rawValue)" },
                "group heading")
        }
        check(
            try !heading(.first).isHidden && heading(.first).frame.height == 20,
            "a group among several keeps its heading")
        host.closeEditorGroup(.first)
        check(
            host.model.layout == .single && shared.isOpen && host.model.groups.count == 1,
            "T3 two-pane Close Group consolidates without closing document")
        let only = try requireValue(host.groupSurfaces[.first], "single group surface")
        check(
            try heading(.first).isHidden && only.strip.frame.maxY == only.bounds.height,
            "a single group shows no heading and its tab strip takes the row (DS-10)")
        let layoutToolbar = try requireValue(host.window?.toolbar, "fixture: workspace toolbar")
        let layoutItem = try requireValue(
            host.toolbar(
                layoutToolbar, itemForItemIdentifier: EditorLayoutToolbarItem.identifier,
                willBeInsertedIntoToolbar: false) as? NSMenuToolbarItem, "DS-D12 Editor Layout toolbar item")
        check(
            host.validateToolbarItem(layoutItem) && layoutItem.menu.items.first?.isEnabled == true,
            "DS-D12 the toolbar's Editor Layout item stays enabled, so the control does not look unavailable")
        reset()
        // A non-final saved close records that exact view. Missing disk cannot affect live reopen.
        let liveDoc = try saved("history-live", "é\nabcdef\n"), h1 = id(liveDoc)
        _ = host.setEditorLayout(.twoColumns)
        let h2 = try requireValue(host.openView(h1, in: .second), "T3 history second view")
        let hp = try requireValue(host.presentation(for: h2), "T3 history presentation")
        hp.clone(nil)
        hp.activeEditor.restoreClosedTabView(anchor: 3, caret: 7, firstVisibleLine: 1)
        host.setPinnedTabs([h2], target: h2, pinned: true)
        liveDoc.editor.text = "é\nunsaved live bytes\n"
        hp.activeEditor.restoreClosedTabView(anchor: 3, caret: 7, firstVisibleLine: 1)
        host.closeTab(h2, sender: nil)
        let record = try requireValue(commands.history.latest, "T3 non-final history record")
        check(
            record.group == .second && record.pinned && record.anchor == 3 && record.caret == 7,
            "T3 history captures exact closed Clone offsets and pin")
        try FileManager.default.removeItem(at: liveDoc.fileURL!)
        commands.perform(.reopen, target: nil)
        let reopened = try requireValue(host.active, "T3 live reopened adapter")
        check(
            host.model.focusedGroup == .second && host.model.activeTab?.isPinned == true
                && reopened.primaryEditor.text == "é\nunsaved live bytes\n"
                && reopened.primaryEditor.selectionCaret == 7 && liveDoc.isDocumentEdited
                && !commands.hasPendingDiskRead,
            "T3 missing-file live reopen restores shared dirty bytes pin and viewport without disk read")
        check(
            NSDocumentController.shared.documents.count == 1
                && reopened.primaryEditor.sharesDocument(with: liveDoc.editor),
            "T3 live reopen creates no NSDocument or second text buffer")
        // Group-local bulk close of dirty shared views asks for no decisions.
        var prompts = 0
        commands.decisionHandler = { _, reply in
            prompts += 1
            reply(.cancel)
        }
        commands.perform(.closeGroup, target: host.model.activeTab!.id, captured: true)
        wait("T3 shared bulk close") { !commands.isBusy }
        check(
            prompts == 0 && liveDoc.isOpen && host.model.groups[1].tabs.count == 1,
            "T3 implicit bulk close protects pinned shared tab")
        host.setPinnedTabs([host.model.activeTab!.id], target: host.model.activeTab!.id, pinned: false)
        commands.perform(.closeGroup, target: host.model.activeTab!.id, captured: true)
        wait("T3 non-final unpinned bulk close") { !commands.isBusy }
        check(
            prompts == 0 && liveDoc.isOpen && host.model.groups[1].tabs.isEmpty && host.model.groups[0].tabs.count == 1,
            "T3 group-local dirty shared bulk close retires view without prompt")
        reset()
        // Final save through a surviving additional view follows the native lifecycle.
        let saveDoc = try saved("final-save"), s1 = id(saveDoc)
        _ = host.setEditorLayout(.twoColumns)
        let s2 = try requireValue(host.openView(s1, in: .second), "T3 save view")
        host.closeTab(s1, sender: nil)
        saveDoc.editor.text = "saved through surviving view"
        try nativeDecision(s2, "Cancel")
        check(saveDoc.isOpen && saveDoc.isDocumentEdited, "T3 saved final native Cancel keeps shared dirty document")
        try nativeDecision(s2, "Save")
        wait("T3 saved final closes") { saveDoc.isClosed }
        check(
            (try? String(contentsOf: root.appendingPathComponent("final-save.txt"), encoding: .utf8))
                == "saved through surviving view", "T3 native Save after original retirement writes exact shared bytes")
        reset()
        let discardDoc = try saved("final-discard"), d1 = id(discardDoc)
        _ = host.setEditorLayout(.twoColumns)
        let d2 = try requireValue(host.openView(d1, in: .second), "T3 discard additional view")
        host.closeTab(d1, sender: nil)
        discardDoc.editor.text = "discard these owned bytes"
        try nativeDecision(d2, "Discard")
        wait("T3 final native discard") { discardDoc.isClosed }
        check(
            (try? String(contentsOf: root.appendingPathComponent("final-discard.txt"), encoding: .utf8))
                == "one\ntwo\nthree\n", "T3 final native Discard keeps original disk bytes after first-view retirement")
        reset()
        _ = xid // identities are deliberately retained only as values.
    }

    private static func advancedCases(host: WorkspaceWindowController, app: AppDelegate, root: URL) throws {
        let commands = host.tabCommands, window = host.window!
        func reset() {
            commands.isTerminating = true
            NSDocumentController.shared.documents.forEach { $0.close() }
            commands.isTerminating = false
            commands.clearHistory()
            _ = host.setEditorLayout(.single)
        }
        func saved(_ name: String) throws -> TextDocument {
            let url = root.appendingPathComponent(name + ".txt")
            try Data("owned bytes".utf8).write(to: url)
            return try DocumentFactory.openCaptured(WorkspaceStore.captureRegularFile(url), from: url)
        }
        func id(_ doc: TextDocument) -> TabID {
            host.model.groups.flatMap(\.tabs).first { $0.documentID == doc.runtimeID }!.id
        }
        func holdDisk() -> (Task<Void, Never>, DispatchSemaphore) {
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let task = Task.detached { await TabDiskIO.shared.holdForTabGroupCheck(entered: entered, release: release) }
            wait("T3 owned real disk actor held") { entered.wait(timeout: .now()) == .success }
            return (task, release)
        }
        reset()
        let chooserDoc = try saved("chooser-live"), chooserFirst = id(chooserDoc)
        _ = host.setEditorLayout(.twoColumns)
        app.showDocumentTabs(nil)
        let form = try requireValue(FormPanel.visible.last, "T3 native Open Documents form")
        let content = try requireValue(form.window.contentView, "T3 native chooser content")
        let chooserTable = try requireValue(
            descendants(content).compactMap { $0 as? NSTableView }.first {
                $0.identifier?.rawValue == "TextTank.OpenDocuments.list"
            }, "T3 actual chooser table")
        check(chooserTable.numberOfRows == 1, "T3 actual chooser starts with one live view")
        let chooserSecond = try requireValue(
            host.openView(chooserFirst, in: .second), "T3 view added while chooser remains open")
        app.showDocumentTabs(nil)
        check(
            FormPanel.visible.last === form && chooserTable.numberOfRows == 2,
            "T3 invoking existing chooser refreshes every live view without replacing its panel")
        let filter = try requireValue(
            descendants(content).compactMap { $0 as? NSTextField }.first {
                $0.identifier?.rawValue == "TextTank.OpenDocuments.filter"
            }, "T3 native chooser filter")
        filter.stringValue = "Group 2"
        filter.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: filter))
        let row = chooserTable.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTextField
        check(
            chooserTable.numberOfRows == 1 && row?.identifier?.rawValue == chooserSecond.rawValue.uuidString,
            "T3 actual group filter exposes distinct view identity")
        let choose = try requireValue(
            descendants(content).compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == "TextTank.OpenDocuments.choose"
            }, "T3 native Switch")
        choose.performClick(nil)
        check(host.model.activeTab?.id == chooserSecond, "T3 actual native Switch reveals exact additional view")
        app.showDocumentTabs(nil)
        let cancelForm = try requireValue(FormPanel.visible.last, "T3 chooser Cancel form")
        let cancel = try requireValue(
            cancelForm.window.contentView.map(descendants)?.compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == "TextTank.OpenDocuments.cancel"
            }, "T3 actual chooser Cancel")
        cancel.performClick(nil)
        check(host.model.activeTab?.id == chooserSecond, "T3 actual native chooser Cancel preserves group and view")
        reset()
        // A -> B -> C retirement must follow the current target, never only the initial one.
        let doc = DocumentFactory.makeUntitled(), a = id(doc)
        doc.editor.text = "def one():\n    pass\n\ndef two():\n    pass\n"
        _ = host.setEditorLayout(.grid2x2)
        let pa = host.presentation(for: a)!
        pa.clone(nil)
        let origin = pa.secondary!, text = origin.text, revision = origin.revision
        let profile = try requireValue(app.languages.profile(identifier: "python"), "T3 Python profile")
        let symbols = try LanguageFunctions.symbols(text: text, profile: profile)
        let functions = LanguageFunctionController(editor: origin, text: text, revision: revision, symbols: symbols)
        let output = RunResult(
            stdout: Data("def changed():\n    pass\n".utf8), stderr: Data(), status: 0, reason: .finished)
        app.runner.show(
            .success(output), command: .uppercaseSample, target: origin, revision: revision, selection: false,
            anchor: 0, caret: 0)
        let search = app.searchController
        search.queryField.stringValue = "def"
        search.scope.selectItem(at: 2)
        search.findAll(nil)
        wait("T3 document-dedup search") { !search.isSearching }
        check(
            search.numberOfRows(in: search.table) == 2, "T3 all-open search yields one result population per document")
        let b = try requireValue(host.openView(a, in: .second), "T3 chained B"),
            c = try requireValue(host.openView(a, in: .third), "T3 chained C")
        host.activate(host.presentation(for: b)!)
        host.closeTab(a, sender: nil)
        check(
            functions.editor === host.presentation(for: b)?.primaryEditor,
            "T3 Function List retargets original Clone to surviving B primary")
        host.closeTab(b, sender: nil)
        let pc = host.presentation(for: c)!
        check(functions.editor === pc.primaryEditor, "T3 Function List follows B to C retirement chain")
        check(
            !EditorLifetime.isOpen(origin) && EditorLifetime.document(for: origin) == nil,
            "T3 retained retired Clone stays unavailable")
        let beforeFocus = host.model.focusedGroup
        EditorLifetime.activate(origin)
        check(host.model.focusedGroup == beforeFocus, "T3 stale editor cannot resurrect routing")
        check(
            search.activateResult(at: 1) && host.active === pc && pc.activeEditor.selectedText == "def",
            "T3 held Search results navigate exact surviving C after A-B-C")
        let apply = try requireValue(
            NSApp.windows.flatMap { $0.contentView.map(descendants) ?? [] }.compactMap { $0 as? NSButton }.last {
                $0.identifier?.rawValue == "run.apply"
            }, "T3 chained Run Apply")
        check(apply.isEnabled, "T3 whole-document Run result remains valid through chain")
        app.runner.apply(apply)
        check(
            doc.editor.text == "def changed():\n    pass\n", "T3 chained Run applies through final live shared primary")
        pc.primaryEditor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
        apply.window?.close()
        search.window?.close()
        functions.window?.close()
        // MRU must fall back to the most recently focused surviving view, not group order.
        _ = host.openView(c, in: .first)
        let d = try requireValue(host.openView(c, in: .fourth), "T3 MRU D")
        host.activate(pc)
        pc.primaryEditor.restoreClosedTabView(anchor: 0, caret: 4, firstVisibleLine: 0)
        host.activate(host.presentation(for: d)!)
        host.closeTab(d, sender: nil)
        check(
            doc.activeEditor === pc.primaryEditor,
            "T3 closed document MRU falls back to most recently focused surviving view")
        reset()
        // Pending real disk work cannot block a live-document reopen.
        let live = try saved("held-live"), l1 = id(live)
        _ = host.setEditorLayout(.twoColumns)
        let l2 = try requireValue(host.openView(l1, in: .second), "T3 held history view")
        let (held, release) = holdDisk()
        host.closeTab(l2, sender: nil)
        check(
            commands.pendingFingerprintCount > 0, "T3 closed non-final fingerprint is queued behind actual actor hold")
        commands.perform(.reopen, target: nil)
        check(
            !commands.isReopening && !commands.hasPendingDiskRead && host.model.groups[1].tabs.count == 1
                && host.active?.document === live,
            "T3 live reopen completes synchronously while actual disk actor remains blocked")
        release.signal()
        _ = held
        reset()
        let stay = try saved("busy-stay"), stayID = id(stay), closed = try saved("busy-closed")
        _ = host.setEditorLayout(.twoColumns)
        closed.close()
        let focusView = try requireValue(host.openView(stayID, in: .second), "T3 focus during reopen view")
        host.activate(host.presentation(for: stayID)!)
        wait("T3 fingerprint settles before disk reopen hold") { commands.pendingFingerprintCount == 0 }
        let (busyHeld, busyRelease) = holdDisk()
        commands.perform(.reopen, target: nil)
        wait("T3 queued real closed-document read") { commands.hasPendingDiskRead }
        let busyModel = host.model
        check(
            !host.setEditorLayout(.grid2x2) && host.model == busyModel,
            "T3 direct layout API refuses during active reopen")
        check(
            host.openView(stayID, in: .second) == nil && host.model == busyModel,
            "T3 direct add-view API refuses during active reopen")
        window.makeFirstResponder(host.presentation(for: focusView)!.primaryEditor)
        check(
            !commands.isReopening && host.model.focusedGroup == .second,
            "T3 actual native editor focus cancels stale reopen and updates group target")
        commands.cancelReopen()
        busyRelease.signal()
        _ = busyHeld
        reset()
        // Accessibility and narrow inactive-group organization use the real native controls.
        let local = try saved("scope-1"), first = id(local)
        _ = host.setEditorLayout(.twoColumns)
        host.focusGroup(.second)
        let secondDoc = try saved("scope-2"), second = id(secondDoc), thirdDoc = try saved("scope-3"),
            third = id(thirdDoc)
        let firstGroup = host.model.groups[0]
        host.setPinnedTabs([second], target: second, pinned: true)
        host.reorderTab(third, to: 0)
        check(
            host.model.groups[0] == firstGroup && host.model.groups[1].tabs.map(\.id) == [second, third],
            "T3 second-group pin and reorder keep first group untouched and enforce boundary")
        let strip = host.groupSurfaces[.second]!.strip
        check(strip.beginReorder(third), "T3 second-group native drag capture")
        strip.updateReorder(at: NSPoint(x: -10, y: -10))
        check(
            !strip.isReordering && !strip.dropIndicatorVisible, "T3 cross-strip/outside drag cancels without transfer")
        let secondButton = try requireValue(
            descendants(strip).compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == "tab." + second.rawValue.uuidString
            }, "T3 actual G2 AX button")
        let action = secondButton.accessibilityCustomActions()?.first { $0.name == "Add to Selection" }
        check(
            action?.handler?() == true && host.tabSelection.selected(in: host.model, group: .second) == [second, third]
                && host.model.groups[0] == firstGroup, "T3 native AX selection stays group-local")
        let picker = try requireValue(
            host.toolbar(
                try requireValue(host.window?.toolbar, "fixture: workspace toolbar"),
                itemForItemIdentifier: EditorLayoutToolbarItem.identifier, willBeInsertedIntoToolbar: false)
                as? NSMenuToolbarItem, "T3 Editor Layout toolbar item")
        check(
            picker.view == nil && picker.label == "Editor Layout" && !(picker.toolTip ?? "").isEmpty
                && descendants(strip).compactMap { $0 as? NSPopUpButton }.allSatisfy {
                    $0.identifier?.rawValue == "tabs.openTabs"
                        && !$0.itemArray.contains { $0.identifier?.rawValue.hasPrefix("groups.layout.") == true }
                },
            "T3 the layout choice is a labelled toolbar item, outside the scrolling strips (DS-D12)")
        let choices = picker.menu.items.filter {
            $0.identifier?.rawValue.hasPrefix("groups.layout.") == true
        }
        check(
            choices.count == 4 && choices.allSatisfy { $0.image?.accessibilityDescription != nil }
                && choices.filter { $0.state == .on }.count == 1,
            "T3 four layout diagrams expose descriptions and one selected mark")
        _ = first
        reset()
        // A four-document Grid has eight views, four bounded presentation workers and four recoveries.
        let started = ProcessInfo.processInfo.systemUptime
        _ = host.setEditorLayout(.grid2x2)
        var docs: [TextDocument] = []
        for slot in GroupSlot.allCases {
            host.focusGroup(slot)
            let doc = DocumentFactory.makeUntitled()
            doc.editor.text = String(repeating: "sample line\n", count: 10000)
            host.active?.clone(nil)
            docs.append(doc)
        }
        let captures = host.presentations.map(\.statusMetricsCaptureCount)
        for _ in 0..<20 { host.presentations.forEach { $0.statusTimerTick() } }
        check(
            host.presentations.count == 4 && host.presentations.allSatisfy { $0.views.count == 2 }
                && zip(host.presentations, captures).allSatisfy { $0.0.statusMetricsCaptureCount - $0.1 <= 1 },
            "T3 four-document Grid has no per-Clone or duplicate same-revision metrics job")
        let session = try app.workspace.capture(name: "Grid")
        check(
            session.documents.count == 4 && Set(docs.map(\.recoveryID)).count == 4,
            "T3 Grid capture and recovery identities remain once per document")
        let previousSettings = app.settings.value
        var changedSettings = previousSettings
        changedSettings.wrap = true
        changedSettings.tabWidth = 10
        changedSettings.useTabs = false
        EditorSettingsApplication.apply(changedSettings, replacing: previousSettings)
        check(
            host.presentations.flatMap(\.views).allSatisfy {
                $0.wrap && $0.statusInfo.tabWidth == 10 && !$0.statusInfo.useTabs
            }, "T3 settings fan out across every group primary and Clone")
        for doc in docs { doc.editor.readOnly = true }
        check(
            host.presentations.flatMap(\.views).allSatisfy(\.readOnly),
            "T3 document Read Only is shared by all group and Clone views")
        for doc in docs {
            doc.editor.readOnly = false
            doc.flushRecovery()
        }
        let liveRecoveryIDs = Set(docs.map(\.recoveryID))
        let recovered = try TextDocument.recovery.scan().snapshots.filter { liveRecoveryIDs.contains($0.id) }
        check(
            recovered.count == 4 && Set(recovered.map(\.id)) == liveRecoveryIDs,
            "T3 four-document eight-view Grid writes exactly four recovery snapshots")
        EditorSettingsApplication.apply(previousSettings, replacing: changedSettings)
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print(
            "T3 GRID_FOUR_DOCUMENTS seconds=\(ProcessInfo.processInfo.systemUptime-started) peak_resident_bytes=\(usage.ru_maxrss) presentations=4 editors=8 text_bytes=480000"
        )
        window.orderOut(nil)
        check(host.presentations.allSatisfy { !$0.statusTimerActive }, "T3 four-document hidden Grid stops all polling")
        reset()
        window.makeKeyAndOrderFront(nil)
    }

    private static func repair1Cases(host: WorkspaceWindowController, app: AppDelegate) throws {
        let commands = host.tabCommands, window = host.window!
        func reset() {
            commands.isTerminating = true
            NSDocumentController.shared.documents.forEach { $0.close() }
            commands.isTerminating = false
            commands.clearHistory()
            _ = host.setEditorLayout(.single)
        }
        reset()
        let doc = DocumentFactory.makeUntitled()
        doc.editor.text = String(repeating: "0123456789abcdefghij\n", count: 10)
        let aid = host.model.activeTab!.id, pa = host.presentation(for: aid)!
        _ = host.setEditorLayout(.grid2x2)
        pa.clone(nil)
        let source = try requireValue(pa.secondary, "R1 chosen source Clone")
        source.wrap = false
        source.restoreClosedTabView(anchor: 5, caret: 9, firstVisibleLine: 1)
        source.executeCommand(TTEditorCommandIdentifier(rawValue: "zoomIn"))
        source.executeCommand(TTEditorCommandIdentifier(rawValue: "zoomIn"))
        pa.primaryEditor.wrap = true
        pa.primaryEditor.restoreClosedTabView(anchor: 1, caret: 2, firstVisibleLine: 0)
        let bid = try requireValue(host.openView(aid, in: .second), "R1 focused sibling"),
            pb = host.presentation(for: bid)!
        pb.primaryEditor.wrap = true
        pb.primaryEditor.restoreClosedTabView(anchor: 24, caret: 28, firstVisibleLine: 2)
        pb.primaryEditor.executeCommand(TTEditorCommandIdentifier(rawValue: "zoomOut"))
        host.activate(pb)
        let menu = commands.contextMenu(for: aid)
        func all(_ menu: NSMenu) -> [NSMenuItem] { menu.items + menu.items.flatMap { $0.submenu.map(all) ?? [] } }
        let additional = try requireValue(
            all(menu).first { $0.identifier?.rawValue == "groups.additional.3" },
            "R1 actual captured additional-view command")
        _ = NSApp.sendAction(additional.action!, to: additional.target, from: additional)
        let created = try requireValue(host.active, "R1 created view")
        check(
            created.primaryEditor.selectionAnchor == 5 && created.primaryEditor.selectionCaret == 9
                && !created.primaryEditor.wrap
                && created.primaryEditor.statusInfo.fontSize == source.statusInfo.fontSize,
            "R1 V3-01 seeds inactive clicked tab's exact last Clone viewport and view settings")
        check(
            created.primaryEditor.sharesDocument(with: source) && created.secondary == nil && source.selectionCaret == 9
                && pb.primaryEditor.selectionCaret == 28 && pb.primaryEditor.wrap,
            "R1 V3-01 source sibling positions and one shared document stay unchanged")
        host.focusGroup(.fourth)
        let other = DocumentFactory.makeUntitled()
        other.editor.text = "other document text\n"
        let pd = host.active!
        pd.clone(nil)
        let last = try requireValue(pd.secondary, "R1 Find target last Clone")
        last.restoreClosedTabView(anchor: 2, caret: 6, firstVisibleLine: 0)
        pa.showFind(nil)
        pd.showFind(nil)
        pd.setReplaceRow(shown: true)
        let ranges = last.selectionRanges
        host.activate(pa)
        check(
            window.makeFirstResponder(pd.findField) && pd.findField.currentEditor() != nil,
            "R1 V3-02 native Find begins real field editing")
        check(
            host.model.focusedGroup == .fourth && app.currentDocument === other && pd.activeEditor === last
                && last.selectionRanges == ranges,
            "R1 V3-02 Find focus updates exact group without stealing Clone selection")
        host.activate(pa)
        check(
            window.makeFirstResponder(pd.replaceField) && pd.replaceField.currentEditor() != nil,
            "R1 V3-02 native Replace begins real field editing")
        check(
            host.model.focusedGroup == .fourth && app.currentDocument === other && pd.activeEditor === last
                && last.selectionRanges == ranges,
            "R1 V3-02 Replace focus updates exact group without stealing Clone selection")
        host.activate(pa)
        pd.findOptions.toggle(.matchCase)
        check(
            host.model.focusedGroup == .fourth && app.currentDocument === other && pd.activeEditor === last
                && last.selectionRanges == ranges,
            "R1 V3-02 Match Case interaction focuses its group without changing selection")
        func responderBelongsTo(_ editor: TTEditor) -> Bool {
            (window.firstResponder as? NSView)?.isDescendant(of: editor) == true
        }
        check(responderBelongsTo(last), "R2 V3-04 Match Case moves native typing focus to its saved Clone")
        window.makeFirstResponder(pd.findField)
        let findResponder = window.firstResponder
        pd.findOptions.toggle(.matchCase)
        check(
            window.firstResponder === findResponder && pd.findField.currentEditor() === findResponder,
            "R2 V3-04 Match Case preserves its own Find field editor")
        window.makeFirstResponder(pd.replaceField)
        let replaceResponder = window.firstResponder
        pd.findOptions.toggle(.matchCase)
        check(
            window.firstResponder === replaceResponder && pd.replaceField.currentEditor() === replaceResponder,
            "R2 V3-04 Match Case preserves its own Replace field editor")
        let status = try requireValue(
            pd.presentationRoot.subviews.compactMap { $0 as? StatusBadgeRow }.first,
            "R2 actual target status row")
        host.activate(pa)
        _ = status.menuProvider?(.encoding)
        check(
            host.active === pd && responderBelongsTo(last) && last.selectionRanges == ranges,
            "R2 V3-04 status popup changes global and native typing target without changing Clone selection")
        window.makeFirstResponder(pd.findField)
        let statusResponder = window.firstResponder
        _ = status.menuProvider?(.encoding)
        check(
            window.firstResponder === statusResponder && pd.findField.currentEditor() === statusResponder,
            "R2 V3-04 status popup preserves its own field editor")
        host.activate(pa)
        let observed = RepairPublicationState()
        let token = NotificationCenter.default.addObserver(
            forName: .TTEditorWillRetire, object: pa.primaryEditor, queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                observed.called = true
                observed.noGlobalTarget =
                    app.currentDocumentController == nil && app.currentDocument == nil && app.currentEditor == nil
                observed.noRegistryTarget = host.presentation(for: aid) == nil && host.active == nil
                observed.allBindingsRetired = pa.views.allSatisfy { !EditorLifetime.isOpen($0) }
                observed.dispatchBlocked = !commands.state(.close, target: bid).enabled && !host.acceptsDocumentCreation
                let newItem = NSMenuItem(
                    title: "New", action: #selector(AppDelegate.newDocument(_:)), keyEquivalent: "n")
                observed.creationDisabled = !app.validateMenuItem(newItem)
            }
        }
        host.moveTabs([aid], target: aid, to: .second)
        NotificationCenter.default.removeObserver(token)
        check(
            observed.called && observed.noGlobalTarget && observed.noRegistryTarget,
            "R1 V3-03 synchronous retirement exposes no retired global or registry target")
        check(observed.allBindingsRetired, "R1 V3-03 every editor in retiring tab is unavailable before first callback")
        check(
            observed.dispatchBlocked && observed.creationDisabled,
            "R1 V3-03 conflicting tab and New dispatch is disabled during publication")
        check(
            host.active === pb && doc.isOpen && host.model.groups[1].activeTab == bid,
            "R1 V3-03 publication resolves destination only after retirement boundary")
        try host.model.validate(
            openDocuments: Set(NSDocumentController.shared.documents.compactMap { ($0 as? TextDocument)?.runtimeID }))
        reset()
    }

    /// Native activation regressions remain in Stage 1/2. These replay the observed late
    /// callback boundary across all four mounted groups and verify genuine native focus too.
    private static func repair3FocusCases(host: WorkspaceWindowController, app: AppDelegate) throws {
        let window = host.window!, commands = host.tabCommands
        func reset() {
            commands.isTerminating = true
            NSDocumentController.shared.documents.forEach { $0.close() }
            commands.isTerminating = false
            commands.clearHistory()
            _ = host.setEditorLayout(.single)
        }
        reset()
        defer { reset() }
        check(host.setEditorLayout(.grid2x2), "R3 four-group focus layout")
        let slots: [GroupSlot] = [.first, .second, .third, .fourth]
        var visible: [EditorWindowController] = [], hidden: [EditorWindowController] = []
        var documents: [TextDocument] = []
        for slot in slots {
            host.focusGroup(slot)
            let document = DocumentFactory.makeUntitled()
            document.editor.text = "visible group \(slot.rawValue) bytes"
            let presentation = try requireValue(host.active, "R3 visible presentation")
            presentation.clone(nil)
            visible.append(presentation)
            documents.append(document)
            let background = DocumentFactory.makeUntitled()
            background.editor.text = "hidden group \(slot.rawValue) bytes"
            hidden.append(try requireValue(host.active, "R3 hidden presentation"))
            documents.append(background)
            host.activate(presentation)
        }
        let target = visible[0], targetClone = try requireValue(target.secondary, "R3 target Clone")
        host.activate(target)
        window.makeFirstResponder(targetClone)
        check(
            visible.allSatisfy(\.isPresented) && hidden.allSatisfy { !$0.isPresented },
            "R3 four visible groups retain four hidden tabs")
        let textBefore = documents.map { $0.editor.text }
        for presentation in visible + hidden {
            for editor in presentation.views where editor !== targetClone {
                host.activate(target)
                window.makeFirstResponder(targetClone)
                let responder = window.firstResponder, active = host.model.activeTab?.id
                // Invoke the original callback unchanged, as the independently traced late
                // Scintilla focus deliveries do after a native activation boundary.
                editor.onFocus?()
                check(
                    host.active === target && host.model.activeTab?.id == active
                        && window.firstResponder === responder && app.currentDocumentController === target
                        && target.lastEditor === targetClone,
                    "R3 stale callback cannot retarget from \(presentation.isPresented ? "visible" : "hidden") group")
            }
        }
        check(documents.map { $0.editor.text } == textBefore, "R3 stale callbacks change no document bytes")
        for (index, presentation) in visible.enumerated() {
            let other = visible[(index + 1) % visible.count]
            host.activate(presentation)
            for editor in presentation.views {
                host.activate(other)
                check(
                    window.makeFirstResponder(editor)
                        && (window.firstResponder as? NSView)?.isDescendant(of: editor) == true
                        && host.active === presentation && host.model.focusedGroup == slots[index],
                    "R3 genuine native primary/Clone focus routes visible group \(slots[index].rawValue)")
            }
            presentation.showFind(nil)
            presentation.setReplaceRow(shown: true)
            host.activate(other)
            check(
                window.makeFirstResponder(presentation.findField)
                    && presentation.findField.currentEditor() === window.firstResponder
                    && host.active === presentation,
                "R3 actual Find field focus routes visible group \(slots[index].rawValue)")
            host.activate(other)
            check(
                window.makeFirstResponder(presentation.replaceField)
                    && presentation.replaceField.currentEditor() === window.firstResponder
                    && host.active === presentation,
                "R3 actual Replace field focus routes visible group \(slots[index].rawValue)")
            let status = try requireValue(
                presentation.presentationRoot.subviews.compactMap { $0 as? StatusBadgeRow }.first,
                "R3 actual status row")
            let savedEditor = presentation.activeEditor
            host.activate(other)
            _ = status.menuProvider?(.encoding)
            check(
                host.active === presentation
                    && (window.firstResponder as? NSView)?.isDescendant(of: savedEditor) == true,
                "R3 actual status focus routes saved editor in group \(slots[index].rawValue)")
        }
        host.activate(target)
        window.makeFirstResponder(targetClone)
        let input = try requireValue(window.firstResponder as? NSTextInputClient, "R3 native typing responder")
        input.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        check(
            documents[0].editor.text != textBefore[0]
                && Array(documents.dropFirst()).map { $0.editor.text } == Array(textBefore.dropFirst()),
            "R3 actual native typing reaches only the intended document")
        targetClone.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
        check(documents.map { $0.editor.text } == textBefore, "R3 native typing Undo preserves every document")
    }

}

extension TabDiskIO {
    fileprivate func holdForTabGroupCheck(entered: DispatchSemaphore, release: DispatchSemaphore) {
        entered.signal()
        release.wait()
    }
}
