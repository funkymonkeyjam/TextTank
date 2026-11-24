// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import EditorBridge
@testable import TextTankCore
@testable import TextTankRuntime

/// The docked Workspace Browser (owner decision DS-D11): the View menu toggle and its checkmark,
/// the keyboard, the saved width and visibility, and the layout at the smallest window. Driven
/// through the application's own menu, workspace window and browser. Nothing here needs the
/// window to be key, and no panel, sheet or alert is presented.
@MainActor enum WorkspaceSidebarChecks {
    private static func key(_ code: UInt16, _ characters: String, in window: NSWindow) throws -> NSEvent {
        try requireValue(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                keyCode: code), "fixture: key event")
    }
    private static func open(_ name: String, _ text: String, in folder: URL) throws -> (
        TextDocument, EditorWindowController
    ) {
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        let document = TextDocument()
        document.fileURL = url
        document.fileType = TextDocument.plainTextType
        NSDocumentController.shared.addDocument(document)
        try document.read(from: Data(text.utf8), ofType: TextDocument.plainTextType)
        document.makeWindowControllers()
        document.showWindows()
        return (document, try requireValue(document.presentation, "fixture: tab adapter for \(name)"))
    }
    private static func item(_ path: [String]) throws -> NSMenuItem {
        var menu = try requireValue(NSApp.mainMenu, "fixture: main menu"), found: NSMenuItem?
        for (index, title) in path.enumerated() {
            let next = try requireValue(menu.items.first { $0.title == title }, "fixture: menu item \(title)")
            found = next
            if index < path.count - 1 { menu = try requireValue(next.submenu, "fixture: submenu \(title)") }
        }
        return try requireValue(found, "fixture: menu path")
    }
    /// Validates the item the way the menu does before it is drawn, then chooses it.
    private static func choose(_ item: NSMenuItem) -> Bool {
        guard let target = item.target as? NSMenuItemValidation, target.validateMenuItem(item), let action = item.action
        else { return false }
        return NSApp.sendAction(action, to: item.target, from: item)
    }
    private static func frame(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }
    private static func keyboard(in view: NSView, of host: WorkspaceWindowController) -> Bool {
        (host.window?.firstResponder as? NSView)?.isDescendant(of: view) == true
    }

    // MARK: Saved layout and geometry (Core)

    static func core() throws {
        let tab = WorkspaceLayoutState.Tab(
            documentID: DocumentID(UUID()), isPinned: false, anchorByte: 0, caretByte: 0, firstVisibleLine: 0)
        var state = WorkspaceLayoutState(
            layout: .single, focusedGroup: .first, groups: [.init(slot: .first, activeTabIndex: 0, tabs: [tab])])
        let plain = try state.encoded()
        check(
            !(String(data: plain, encoding: .utf8) ?? "sidebar").contains("sidebar"),
            "a layout whose sidebar was never used is written without sidebar keys, exactly as before")
        let old = try WorkspaceLayoutState.decoded(plain)
        check(old.sidebarShown == nil && old.sidebarWidth == nil, "a layout without the keys reads as no sidebar state")
        let golden = try JSONDecoder().decode(
            WorkspaceSession.self,
            from: Data(
                contentsOf: TestPaths.fixtures.appendingPathComponent("persistence/SessionLayout.texttanksession")))
        check(
            golden.layoutState != nil && golden.layoutState?.sidebarShown == nil
                && golden.layoutState?.sidebarWidth == nil,
            "the golden session layout written before the sidebar existed still loads, with no sidebar state")
        state.sidebarShown = true
        state.sidebarWidth = 333
        check(
            try WorkspaceLayoutState.decoded(state.encoded()) == state,
            "shown and width round-trip through the session format")
        let automatic = try LastSessionLayout(
            files: [.init(id: tab.documentID, url: URL(fileURLWithPath: "/tmp/sidebar-fixture.txt"))], layout: state)
        let reread = try LastSessionLayout.decode(automatic.encoded())
        check(
            reread.layout.sidebarShown == true && reread.layout.sidebarWidth == 333,
            "the automatic launch file keeps the sidebar's state")
        let emptied = try LastSessionLayout.decode(LastSessionLayout(files: [], layout: state).encoded())
        check(
            emptied.layout.sidebarShown == true && emptied.layout.sidebarWidth == 333,
            "and keeps it when no file is open")
        for width in [0.0, -5, 10_001] {
            var bad = state
            bad.sidebarWidth = width
            rejects("a sidebar width of \(width) is rejected") { _ = try bad.encoded() }
        }

        typealias G = WorkspaceSidebarGeometry
        check(
            G.width(preferred: 100, total: 1400, editorMinimum: 800) == G.minimumWidth
                && G.width(preferred: 900, total: 1400, editorMinimum: 800) == G.maximumWidth
                && G.width(preferred: 340, total: 1400, editorMinimum: 800) == 340,
            "the sidebar's width is held between its minimum and maximum")
        check(
            G.width(preferred: 400, total: 1150, editorMinimum: 800) == 349
                && G.width(preferred: 400, total: 1061, editorMinimum: 800) == G.minimumWidth
                && G.width(preferred: 400, total: 900, editorMinimum: 800) == G.minimumWidth,
            "a narrowing window takes width from the sidebar first, down to its minimum, never below it")
        for layout in [LayoutKind.single, .twoColumns, .twoRows, .grid2x2] {
            let editors = TabGroupGeometry.minimumContent(layout)
            check(
                G.minimumContent(layout, sidebarShown: false) == editors
                    && G.minimumContent(layout, sidebarShown: true)
                        == TabGroupExtent(width: editors.width + G.divider + G.minimumWidth, height: editors.height),
                "\(layout): the window minimum grows by the sidebar's minimum only while it is shown")
        }
    }

    // MARK: The sidebar in the workspace window

    static func run(root: URL, app: AppDelegate, host: WorkspaceWindowController) throws {
        try core()
        let window = try requireValue(host.window, "fixture: workspace window")
        let browser = app.workspaceBrowser
        let folder = root.appendingPathComponent("sidebar")
        let originalSize = window.contentView?.bounds.size ?? NSSize(width: 1080, height: 720)
        window.setContentSize(NSSize(width: 1400, height: 700))
        defer {
            browser.hide()
            _ = host.setEditorLayout(.single)
            window.setContentSize(originalSize)
        }
        let lines = (1...400).map { "line \($0)" }.joined(separator: "\n")
        let (plain, plainTab) = try open("plain.txt", lines, in: folder)
        let (notes, notesTab) = try open("notes.md", "# Notes\n\nSome text.\n", in: folder)
        try Data("other\n".utf8).write(to: folder.appendingPathComponent("other.txt"))
        defer {
            NSDocumentController.shared.documents.filter { $0.fileURL?.path.hasPrefix(folder.path) == true }
                .forEach { $0.close() }
        }
        host.activate(plainTab)
        let editor = plainTab.primaryEditor
        _ = editor.replaceSelection("typed ")
        _ = editor.setSelectionAnchor(40, caret: 55)
        editor.restoreClosedTabView(anchor: 40, caret: 55, firstVisibleLine: 120)
        window.contentView?.layoutSubtreeIfNeeded()
        struct Snapshot: Equatable {
            let anchor: Int, caret: Int, line: Int, revision: UInt64, text: String
        }
        func snapshot() -> Snapshot {
            Snapshot(
                anchor: editor.selectionAnchor, caret: editor.selectionCaret, line: editor.firstVisibleLine,
                revision: UInt64(editor.revision), text: editor.text)
        }
        window.makeFirstResponder(plainTab.keyboardFocusView)
        let before = snapshot(), activeBefore = host.model.activeTab?.id
        check(
            before.line == 120 && before.text == "typed " + lines,
            "fixture: the editor is scrolled, has a selection and one edit to undo")
        let windowsBefore = NSApp.windows.count

        // Never shown: nothing is written about it.
        check(
            !host.isSidebarShown && host.sidebarSplit.sidebar == nil && !browser.isShown,
            "the sidebar is hidden until it is asked for")
        check(
            host.captureSessionLayout().sidebarShown == nil && host.captureSessionLayout().sidebarWidth == nil,
            "a workspace that never showed the sidebar captures no sidebar state")
        let untouched = WorkspaceLayoutState(
            layout: .single, focusedGroup: .first,
            groups: [
                .init(slot: .first, activeTabIndex: nil, tabs: [])
            ])
        host.applySidebar(from: untouched)
        check(!host.isSidebarShown, "a saved layout without the keys loads with the sidebar hidden")
        check(
            window.contentMinSize == NSSize(width: 800, height: 500),
            "fixture: the window minimum is the editor groups' own while the sidebar is hidden")

        // The View menu item is a toggle with a checkmark (DS-22).
        let toggle = try item(["View", "Workspace Browser"])
        check(
            toggle.target === browser && toggle.action == #selector(WorkspaceBrowserController.show(_:))
                && toggle.keyEquivalent.isEmpty,
            "View > Workspace Browser is the existing item, with its command identity and no shortcut")
        check(browser.validateMenuItem(toggle) && toggle.state == .off, "the item has no checkmark while hidden")
        check(choose(toggle), "fixture: choose View > Workspace Browser")
        window.contentView?.layoutSubtreeIfNeeded()
        let sidebar = try requireValue(host.sidebarSplit.sidebar, "the sidebar is docked in the workspace window")
        check(
            host.isSidebarShown && browser.isShown && sidebar === browser.sidebarView && sidebar.window === window
                && sidebar.isDescendant(of: window.contentView!),
            "choosing it shows the browser inside the workspace window's content")
        check(browser.validateMenuItem(toggle) && toggle.state == .on, "the checkmark follows: shown")
        check(
            NSApp.windows.count == windowsBefore
                && !NSApp.windows.contains { $0 is NSPanel && $0.isVisible && $0.title == "Workspace" },
            "no floating browser panel is opened")
        check(
            window.firstResponder === browser.outline,
            "asking for the browser by command moves the keyboard to its list")
        check(
            snapshot() == before && host.model.activeTab?.id == activeBefore,
            "showing changes neither the selection, the scroll position, Undo nor the active tab")

        // Accessibility (DS-70) and layout (DS-67).
        check(
            sidebar.isAccessibilityElement() && sidebar.accessibilityRole() == .group
                && sidebar.accessibilityLabel() == "Workspace Browser",
            "the sidebar is a group named Workspace Browser")
        check(
            browser.outline.accessibilityLabel() == "Workspace files" && browser.outline.allowsTypeSelect,
            "its list is a labelled outline that supports type-select")
        let groups = host.groupContainer
        check(
            abs(frame(sidebar).minX) < 0.5 && frame(sidebar).maxX <= frame(groups).minX
                && abs(frame(sidebar).width - CGFloat(WorkspaceSidebarGeometry.defaultWidth)) < 0.5
                && abs(frame(groups).maxX - window.contentView!.bounds.maxX) < 0.5,
            "it sits at the left edge at its default width and the editor groups take the rest")
        check(
            sequence(first: browser.firstKeyView, next: { $0.nextKeyView }).prefix(8).contains {
                $0 === browser.outline
            } && browser.lastKeyView.nextKeyView === plainTab.keyboardFocusView,
            "the sidebar's controls are in key-view order and Tab from the last one reaches the text")
        check(
            window.contentMinSize.width == 800 + 1 + CGFloat(WorkspaceSidebarGeometry.minimumWidth)
                && window.contentMinSize.height == 500,
            "while it is shown the window minimum grows by the sidebar's minimum and its divider")

        // Escape returns the keyboard to the text and leaves the sidebar.
        browser.outline.keyDown(with: try key(53, "\u{1B}", in: window))
        check(
            keyboard(in: plainTab.activeEditor, of: host) && host.isSidebarShown,
            "Escape returns the keyboard to the text; the sidebar stays")
        check(snapshot() == before, "and the editor is as it was")

        // The same command hides it and returns the keyboard.
        check(
            choose(toggle) && !host.isSidebarShown && sidebar.window == nil, "choosing the item again hides the sidebar"
        )
        check(browser.validateMenuItem(toggle) && toggle.state == .off, "the checkmark follows: hidden")
        check(window.contentMinSize == NSSize(width: 800, height: 500), "hiding restores the usual window minimum")
        check(choose(toggle) && window.firstResponder === browser.outline, "fixture: shown again, keyboard in the list")
        check(
            choose(toggle) && !host.isSidebarShown && keyboard(in: plainTab.activeEditor, of: host),
            "hiding while the list has the keyboard returns it to the editor that had it")
        check(
            snapshot() == before && host.model.activeTab?.id == activeBefore,
            "hiding changes neither the selection, the scroll position, Undo nor the active tab")

        // Shown for another reason (Add Folder, Monitor Current File): the keyboard stays put.
        check(
            browser.reveal() && host.isSidebarShown, "a command that only needs the browser visible shows the sidebar")
        check(
            keyboard(in: plainTab.activeEditor, of: host) && NSApp.windows.count == windowsBefore,
            "without moving the keyboard and without a panel")
        browser.hide()
        let monitor = try item(["File", "Monitor Current File"])
        check(choose(monitor) && browser.monitor.document === plain, "fixture: Monitor Current File starts")
        check(
            host.isSidebarShown && keyboard(in: plainTab.activeEditor, of: host)
                && NSApp.windows.count == windowsBefore,
            "Monitor Current File shows the sidebar, not a panel, and leaves the keyboard in the text")
        check(choose(monitor) && browser.monitor.document == nil, "fixture: monitoring stopped")

        // Keyboard: arrows move, Return opens or selects the tab.
        // Add Folder, from the menu or from Quick Open's empty state, ends here once a folder is chosen.
        browser.hide()
        window.makeFirstResponder(plainTab.keyboardFocusView)
        try browser.addChosenFolder(folder)
        let outline = browser.outline
        check(
            browser.store.contains(folder) && host.isSidebarShown && browser.isShown && outline.numberOfRows == 1
                && (outline.item(atRow: 0) as? WorkspaceBrowserNode)?.entry.url.lastPathComponent == "sidebar",
            "a folder added by Add Folder is saved and the docked sidebar shows it under Folders")
        check(
            keyboard(in: plainTab.activeEditor, of: host) && NSApp.windows.count == windowsBefore
                && !NSApp.windows.contains { $0 is NSPanel && $0.isVisible && $0.title == "Workspace" },
            "without a floating panel and without taking the keyboard")
        outline.selectRowIndexes([0], byExtendingSelection: false)
        window.makeFirstResponder(outline)
        outline.keyDown(with: try key(36, "\r", in: window))
        check(outline.numberOfRows == 4, "Return on a folder opens it in place")
        func row(_ name: String) throws -> Int {
            try requireValue(
                (0..<outline.numberOfRows).first {
                    (outline.item(atRow: $0) as? WorkspaceBrowserNode)?.entry.url.lastPathComponent == name
                }, "fixture: row for \(name)")
        }
        outline.keyDown(with: try key(125, String(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!), in: window))
        check(outline.selectedRow == 1, "the Down Arrow key moves the selection")
        outline.selectRowIndexes([try row("other.txt")], byExtendingSelection: false)
        let documentsBefore = NSDocumentController.shared.documents.count
        outline.keyDown(with: try key(36, "\r", in: window))
        let other = try requireValue(
            NSDocumentController.shared.documents.first { $0.fileURL?.lastPathComponent == "other.txt" }
                as? TextDocument,
            "Return on a file opens it")
        check(
            NSDocumentController.shared.documents.count == documentsBefore + 1
                && (host.active?.document as? TextDocument) === other && host.isSidebarShown,
            "the file opened from the sidebar by keyboard is the active tab")
        host.activate(plainTab)
        window.makeFirstResponder(outline)
        outline.selectRowIndexes([try row("other.txt")], byExtendingSelection: false)
        outline.keyDown(with: try key(76, "\u{03}", in: window))
        check(
            NSDocumentController.shared.documents.count == documentsBefore + 1
                && (host.active?.document as? TextDocument) === other,
            "Return on a file that is already open selects its tab")
        other.close()
        host.activate(plainTab)

        // The divider: minimum, maximum, and a width that is remembered.
        let split = host.sidebarSplit
        split.setPosition(340, ofDividerAt: 0)
        check(
            abs(sidebar.frame.width - 340) < 0.5 && abs(split.preferredWidth - 340) < 0.5, "the divider sets the width")
        split.setPosition(60, ofDividerAt: 0)
        check(
            abs(sidebar.frame.width - CGFloat(WorkspaceSidebarGeometry.minimumWidth)) < 0.5,
            "the divider stops at the sidebar's minimum width")
        window.contentView?.layoutSubtreeIfNeeded()
        let buttons = descendants(sidebar).filter { $0 is NSButton }
        check(
            buttons.count == 5
                && buttons.allSatisfy {
                    sidebar.bounds.insetBy(dx: 7.5, dy: 7.5).contains($0.convert($0.bounds, to: sidebar))
                }
                && !buttons.indices.contains { a in
                    buttons.indices.contains { b in a < b && frame(buttons[a]).intersects(frame(buttons[b])) }
                },
            "at that width every control is inside the sidebar and none overlap: "
                + buttons.map { "\(type(of: $0)) \(NSStringFromRect($0.convert($0.bounds, to: sidebar)))" }.joined(
                    separator: "; "))
        split.setPosition(900, ofDividerAt: 0)
        check(
            abs(sidebar.frame.width - CGFloat(WorkspaceSidebarGeometry.maximumWidth)) < 0.5
                && frame(groups).width >= 800,
            "and at its maximum width, with the editor groups keeping theirs")
        split.setPosition(340, ofDividerAt: 0)
        window.setContentSize(NSSize(width: 1500, height: 700))
        window.contentView?.layoutSubtreeIfNeeded()
        check(abs(sidebar.frame.width - 340) < 0.5, "resizing the window keeps the sidebar's width")
        window.setContentSize(NSSize(width: 1400, height: 700))

        // Width and visibility survive a save and restore of the layout.
        let saved = try WorkspaceLayoutState.decoded(host.captureSessionLayout().encoded())
        check(saved.sidebarShown == true && saved.sidebarWidth == 340, "the layout captures shown and the width")
        browser.hide()
        let savedHidden = try WorkspaceLayoutState.decoded(host.captureSessionLayout().encoded())
        check(
            savedHidden.sidebarShown == false && savedHidden.sidebarWidth == 340,
            "a hidden sidebar is captured as hidden, with its width kept")
        split.preferredWidth = CGFloat(WorkspaceSidebarGeometry.defaultWidth)
        window.makeFirstResponder(plainTab.keyboardFocusView)
        host.applySidebar(from: saved)
        window.contentView?.layoutSubtreeIfNeeded()
        check(
            host.isSidebarShown && abs((host.sidebarSplit.sidebar?.frame.width ?? 0) - 340) < 0.5,
            "restoring the saved layout shows the sidebar at its saved width")
        check(
            keyboard(in: plainTab.activeEditor, of: host) && snapshot() == before,
            "a restored sidebar does not take the keyboard or disturb the editor")
        host.applySidebar(from: untouched)
        check(host.isSidebarShown, "a layout without the keys leaves a shown sidebar as it is")
        host.applySidebar(from: savedHidden)
        check(!host.isSidebarShown, "restoring a layout saved with the sidebar hidden hides it")

        // A screen too small for the sidebar: refused, nothing changes.
        check(
            !host.setSidebarShown(true, availableContent: TabGroupExtent(width: 1000, height: 700))
                && !host.isSidebarShown && host.lastTabMessage.contains("cannot fit the Workspace Browser"),
            "a screen that cannot fit the sidebar beside the editors refuses it with a message")
        check(snapshot() == before, "and the editor is as it was")

        // The smallest window: sidebar, two editor groups, source and preview (DS-67).
        check(host.setEditorLayout(.twoColumns), "fixture: two editor groups")
        let notesID = try requireValue(notesTab.tabID, "fixture: notes tab")
        host.moveTabs([notesID], target: notesID, to: .second)
        let moved = try requireValue(
            host.model.groups.first { $0.slot == .second }?.activeTab.flatMap { host.presentation(for: $0) },
            "fixture: notes in the second group")
        check(moved.setViewMode(.both), "fixture: the second group shows Both")
        window.setContentSize(NSSize(width: 800, height: 500))
        check(host.setSidebarShown(true), "fixture: the sidebar is shown in a window at the editors' minimum")
        let minimum = window.contentMinSize
        check(
            minimum.width == 800 + 1 + CGFloat(WorkspaceSidebarGeometry.minimumWidth)
                && (window.contentView?.bounds.width ?? 0) >= minimum.width,
            "showing the sidebar in a window too narrow for it grows the window to the new minimum")
        window.setContentSize(minimum)
        split.preferredWidth = CGFloat(WorkspaceSidebarGeometry.maximumWidth)
        window.contentView?.layoutSubtreeIfNeeded()
        let docked = try requireValue(split.sidebar, "fixture: docked sidebar")
        let first = try requireValue(host.groupSurfaces[.first], "fixture: first group")
        let second = try requireValue(host.groupSurfaces[.second], "fixture: second group")
        let preview = try requireValue(moved.viewContainer.preview, "fixture: preview pane")
        let panes: [(String, NSView, CGFloat)] = [
            ("sidebar", docked, CGFloat(WorkspaceSidebarGeometry.minimumWidth)),
            ("group 1", first, CGFloat(TabGroupGeometry.minimumPane.width)),
            ("source", moved.viewContainer.source, DocumentViewContainer.minimumPaneWidth),
            ("preview", preview, DocumentViewContainer.minimumPaneWidth)
        ]
        let content = window.contentView!.bounds
        check(
            abs(content.width - minimum.width) < 0.5 && panes.allSatisfy { frame($0.1).width >= $0.2 - 0.5 }
                && frame(second).width >= CGFloat(TabGroupGeometry.minimumPane.width) - 0.5,
            "at the minimum window size with two groups and Both, every pane keeps its minimum width: "
                + panes.map { "\($0.0) \(Int(frame($0.1).width))" }.joined(separator: ", "))
        check(
            abs(frame(docked).width - CGFloat(WorkspaceSidebarGeometry.minimumWidth)) < 0.5,
            "the sidebar gives up its extra width first")
        check(
            panes.allSatisfy { content.contains(frame($0.1)) }
                && !panes.indices.contains { a in
                    panes.indices.contains { b in
                        a < b && frame(panes[a].1).insetBy(dx: 0.5, dy: 0.5).intersects(frame(panes[b].1))
                    }
                }
                && frame(second).contains(frame(moved.viewContainer.source)) && frame(second).contains(frame(preview)),
            "and nothing overlaps: sidebar, first group, source and preview are side by side inside the window")
        browser.hide()
        check(
            window.contentMinSize == NSSize(width: 800, height: 500),
            "hiding the sidebar returns the window minimum to the editor groups' own, never lower")
        check(moved.setViewMode(.source), "fixture: back to Source")
        host.moveTabs([try requireValue(moved.tabID, "fixture: moved tab")], target: moved.tabID!, to: .first)
        check(host.setEditorLayout(.single), "fixture: back to one group")
        try browser.store.removeFolder(folder)
        check(
            snapshot().revision == before.revision
                && editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo")) && editor.text == lines,
            "after all of it the document is unedited and Undo still steps back the one edit made before")
        _ = notes
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
