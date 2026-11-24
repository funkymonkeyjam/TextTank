// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import EditorBridge
@testable import TextTankCore
@testable import TextTankRuntime

/// The workspace window's own chrome: the Editor Layout toolbar item that replaced the row above
/// the tab strips (owner decision DS-D12). Driven through the application's own menu bar, toolbar
/// and workspace window. Nothing here needs the window to be key, and no menu, panel, sheet or
/// alert is shown.
@MainActor enum WindowLayoutChecks {
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func frame(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }
    static func item(_ path: [String]) throws -> NSMenuItem {
        var menu = try requireValue(NSApp.mainMenu, "fixture: main menu"), found: NSMenuItem?
        for (index, title) in path.enumerated() {
            menu.delegate?.menuNeedsUpdate?(menu)
            let next = try requireValue(menu.items.first { $0.title == title }, "fixture: menu item \(title)")
            found = next
            if index < path.count - 1 { menu = try requireValue(next.submenu, "fixture: submenu \(title)") }
        }
        return try requireValue(found, "fixture: menu path")
    }
    /// Validates the item the way the menu does before it is drawn, then chooses it.
    static func choose(_ item: NSMenuItem) -> Bool {
        guard let target = item.target as? NSMenuItemValidation, target.validateMenuItem(item), let action = item.action
        else { return false }
        return NSApp.sendAction(action, to: item.target, from: item)
    }
    private static let layoutTitles = ["Single Group", "Two Columns", "Two Rows", "Grid (2 × 2)"]

    // MARK: The Editor Layout toolbar item (DS-D12)

    static func layoutControl(app: AppDelegate, host: WorkspaceWindowController) throws {
        let window = try requireValue(host.window, "fixture: workspace window")
        let toolbar = try requireValue(window.toolbar, "fixture: toolbar")
        let content = try requireValue(window.contentView, "fixture: window content")
        defer { _ = host.setEditorLayout(.single) }
        check(host.setEditorLayout(.single), "fixture: one editor group")
        content.layoutSubtreeIfNeeded()

        // No row between the toolbar and the tab strips.
        let strip = host.tabStrip
        check(
            abs(frame(strip).maxY - frame(content).maxY) < 0.5 && abs(frame(strip).height - 36) < 0.5,
            "DS-D12 the tab strip is the first row of the window's content, directly under the toolbar: strip top \(frame(strip).maxY), content top \(frame(content).maxY)"
        )
        check(
            !descendants(content).contains { $0 is NSPopUpButton && $0.accessibilityLabel() == "Editor group layout" },
            "DS-D12 the window's content no longer holds a layout pop-up")

        // A standard menu toolbar item, in the default set, customisable like the others (DS-30).
        let identifier = EditorLayoutToolbarItem.identifier
        check(
            host.toolbarDefaultItemIdentifiers(toolbar).contains(identifier)
                && host.toolbarAllowedItemIdentifiers(toolbar).contains(identifier),
            "DS-D12 Editor Layout is in the default toolbar and in the customisation palette")
        let layout = try requireValue(
            toolbar.items.first { $0.itemIdentifier == identifier } as? NSMenuToolbarItem,
            "DS-D12 the toolbar shows Editor Layout as a native menu toolbar item")
        check(
            layout.label == "Editor Layout" && layout.paletteLabel == "Editor Layout" && layout.image != nil
                && layout.view == nil && layout.toolTip?.hasPrefix("Choose how many editor groups") == true
                && layout.image?.accessibilityDescription == layout.toolTip,
            "DS-30/70 it has a symbol, a label, a tooltip and an accessibility description, and no custom view")
        check(
            toolbar.items.filter { $0 is NSMenuToolbarItem }.map(\.itemIdentifier.rawValue).sorted()
                == ["TextTank.Automations", identifier.rawValue].sorted(),
            "DS-D6 Automations stays one drop-down; Editor Layout is the only other menu item in the toolbar")
        host.validateToolbar()
        let exposed = nativeTree(window).contains {
            nativeAttribute($0, "accessibilityLabel") == layout.toolTip
                && ["AXButton", "AXMenuButton"].contains(nativeAttribute($0, "accessibilityRole"))
        }
        check(exposed, "DS-70 the native toolbar element for Editor Layout carries its scoped name")

        // Its menu is the View menu's list: same titles, same checkmark, same validation (DS-20).
        func choices(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.filter { $0.identifier?.rawValue.hasPrefix("groups.layout.") == true }
        }
        func viewChoices() throws -> [NSMenuItem] {
            choices(
                try requireValue(
                    try item(["View", "Editor Groups", "Editor Group Layout"]).submenu, "fixture: View layout submenu"))
        }
        func states(_ items: [NSMenuItem]) -> [Bool] {
            items.map { item in
                _ = host.groupCommands.validateMenuItem(item)
                return item.state == .on
            }
        }
        let offered = choices(layout.menu)
        check(
            offered.map(\.title) == layoutTitles && layout.menu.items.count == 4
                && offered.allSatisfy { $0.image?.accessibilityDescription == $0.title },
            "the toolbar menu lists the four layouts, each with a described diagram and no heading row")
        check(
            try viewChoices().map(\.title) == layoutTitles,
            "View > Editor Groups > Editor Group Layout keeps the same four commands")
        check(
            try states(offered) == [true, false, false, false] && states(viewChoices()) == [true, false, false, false],
            "one group: Single Group is checked in the toolbar menu and in the View menu")
        check(host.validateToolbarItem(layout) && layout.isEnabled, "the item is enabled while a layout can be chosen")

        // The toolbar item changes the layout.
        check(
            choose(offered[1]) && host.model.layout == .twoColumns,
            "choosing Two Columns in the toolbar menu makes two groups")
        check(
            try states(choices(layout.menu)) == [false, true, false, false]
                && states(viewChoices()) == [false, true, false, false],
            "the checkmark follows in both places")
        content.layoutSubtreeIfNeeded()
        check(
            host.model.groups.compactMap { host.groupSurfaces[$0.slot] }.allSatisfy {
                abs(frame($0).maxY - frame(content).maxY) < 0.5
            }, "with two columns both groups still start directly under the toolbar")
        // The View menu still changes it too.
        check(
            choose(try viewChoices()[2]) && host.model.layout == .twoRows
                && states(choices(layout.menu)) == [false, false, true, false],
            "View > Editor Groups changes the layout too, and the toolbar menu's checkmark follows")

        // A layout the screen cannot fit is refused the same way from the toolbar.
        check(
            !host.setEditorLayout(.grid2x2, availableContent: TabGroupExtent(width: 100, height: 100))
                && host.model.layout == .twoRows && host.lastTabMessage.contains("cannot fit that editor layout"),
            "a layout that does not fit is refused with a message and nothing changes")

        // Validation: the one rule the group commands use (DS-20, DS-21).
        check(
            host.validateToolbarItem(layout) == host.groupCommands.commandsAvailable
                && offered.allSatisfy {
                    host.groupCommands.validateMenuItem($0) == host.groupCommands.commandsAvailable
                },
            "the toolbar item and each layout in its menu are enabled by the group commands' own test")

        // Removing the item from the toolbar leaves the menu route.
        let index = try requireValue(
            toolbar.items.firstIndex { $0.itemIdentifier == identifier }, "fixture: Editor Layout position")
        toolbar.removeItem(at: index)
        check(
            !toolbar.items.contains { $0.itemIdentifier == identifier },
            "Editor Layout can be removed from the toolbar like any other item")
        check(
            choose(try viewChoices()[0]) && host.model.layout == .single,
            "with the item removed, View > Editor Groups still changes the layout")
        let palette = app.commandDiscovery.commands(in: try requireValue(NSApp.mainMenu, "fixture: menu bar"))
        check(
            layoutTitles.allSatisfy { title in
                palette.contains {
                    $0.path == "View › Editor Groups › Editor Group Layout › " + title && $0.row.enabled
                }
            }, "and the Command Palette lists every layout")

        // An arrangement made before DS-D12 is offered the item once, never again.
        let suite = "TextTank.WindowLayoutChecks." + UUID().uuidString
        let defaults = try requireValue(UserDefaults(suiteName: suite), "fixture: owned defaults")
        defer { defaults.removePersistentDomain(forName: suite) }
        EditorToolbarPreferences.offerLayoutItemOnce(in: toolbar, defaults: nil)
        check(
            !toolbar.items.contains { $0.itemIdentifier == identifier },
            "an isolated host, which has no defaults, is never given the item behind its back")
        EditorToolbarPreferences.offerLayoutItemOnce(in: toolbar, defaults: defaults)
        let offeredAt = toolbar.items.firstIndex { $0.itemIdentifier == identifier }
        check(
            offeredAt != nil
                && offeredAt
                    == (toolbar.items.lastIndex { $0.itemIdentifier.rawValue == "TextTank.Split" }).map { $0 + 1 },
            "a toolbar arranged before DS-D12 gains Editor Layout once, after the standard commands")
        EditorToolbarPreferences.offerLayoutItemOnce(in: toolbar, defaults: defaults)
        check(
            toolbar.items.filter { $0.itemIdentifier == identifier }.count == 1,
            "offering again adds no second item")
        if let offeredAt { toolbar.removeItem(at: offeredAt) }
        EditorToolbarPreferences.offerLayoutItemOnce(in: toolbar, defaults: defaults)
        check(
            !toolbar.items.contains { $0.itemIdentifier == identifier },
            "once offered, an item the person removed stays removed")
        toolbar.insertItem(withItemIdentifier: identifier, at: index)
        host.validateToolbar()
        check(
            toolbar.items.map(\.itemIdentifier) == host.toolbarDefaultItemIdentifiers(toolbar),
            "fixture: the toolbar is back to its default arrangement")
    }

    // MARK: Window > Move Focus (DS-73)

    static func key(
        _ code: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags = [], in window: NSWindow
    ) throws -> NSEvent {
        try requireValue(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code), "fixture: key event")
    }
    static func open(_ name: String, _ text: String, in folder: URL) throws -> (TextDocument, EditorWindowController) {
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
    private static let left = String(UnicodeScalar(UInt32(NSLeftArrowFunctionKey))!)
    private static let right = String(UnicodeScalar(UInt32(NSRightArrowFunctionKey))!)

    static func focusAreas(root: URL, app: AppDelegate, host: WorkspaceWindowController) throws {
        typealias Kind = WindowAreaFocusController.Kind
        let window = try requireValue(host.window, "fixture: workspace window")
        let browser = app.workspaceBrowser, focus = host.areaFocus
        let folder = root.appendingPathComponent("areas")
        let originalSize = window.contentView?.bounds.size ?? NSSize(width: 1080, height: 720)
        window.setContentSize(NSSize(width: 1400, height: 700))
        defer {
            browser.hide()
            NSDocumentController.shared.documents.filter { $0.fileURL?.path.hasPrefix(folder.path) == true }
                .forEach { $0.close() }
            _ = host.setEditorLayout(.single)
            window.setContentSize(originalSize)
        }
        check(host.setEditorLayout(.single), "fixture: one editor group")
        let lines = (1...400).map { "line \($0)" }.joined(separator: "\n")
        let (_, plainTab) = try open("plain.txt", lines, in: folder)
        let (_, notesTab) = try open("notes.md", "# Notes\n\nSome text.\n", in: folder)
        let plainID = try requireValue(plainTab.tabID, "fixture: plain tab")
        let notesID = try requireValue(notesTab.tabID, "fixture: notes tab")
        host.activate(plainTab)
        let editor = plainTab.primaryEditor
        _ = editor.setSelectionAnchor(40, caret: 55)
        editor.restoreClosedTabView(anchor: 40, caret: 55, firstVisibleLine: 120)
        window.contentView?.layoutSubtreeIfNeeded()
        struct Snapshot: Equatable {
            let anchor: Int, caret: Int, line: Int, revision: UInt64
            let active: [TabID?], selected: Set<TabID>
        }
        func snapshot() -> Snapshot {
            Snapshot(
                anchor: editor.selectionAnchor, caret: editor.selectionCaret, line: editor.firstVisibleLine,
                revision: UInt64(editor.revision), active: host.model.groups.map(\.activeTab),
                selected: host.tabSelection.selected(in: host.model, group: .first))
        }
        func responder() -> NSView? {
            if let text = window.firstResponder as? NSText, text.isFieldEditor { return text.delegate as? NSView }
            return window.firstResponder as? NSView
        }
        func keyboard(in view: NSView?) -> Bool { view.map { responder()?.isDescendant(of: $0) == true } ?? false }
        func kinds() -> [Kind] { focus.areas().map(\.kind) }
        func current() -> Kind? {
            let ring = focus.areas()
            return focus.currentArea(in: ring).map { ring[$0].kind }
        }
        let surface = try requireValue(host.groupSurfaces[.first], "fixture: first group")
        window.makeFirstResponder(plainTab.keyboardFocusView)
        let before = snapshot()
        check(
            before.line == 120 && before.anchor == 40 && before.caret == 55,
            "fixture: a selection and a scroll position")

        // The commands and their keys.
        let next = try item(["Window", "Move Focus", "Move Focus to Next Area"])
        let previous = try item(["Window", "Move Focus", "Move Focus to Previous Area"])
        let f6 = String(UnicodeScalar(UInt32(NSF6FunctionKey))!)
        check(
            next is DefaultShortcutItem && previous is DefaultShortcutItem && next.target === focus
                && previous.target === focus && next.keyEquivalent == f6 && next.keyEquivalentModifierMask == []
                && previous.keyEquivalent == f6 && previous.keyEquivalentModifierMask == [.shift],
            "DS-73 Window > Move Focus lists both commands, with F6 and Shift-F6 as yielding defaults")
        let moveMenu = try requireValue(try item(["Window", "Move Focus"]).submenu, "fixture: Move Focus submenu")
        let aliases = moveMenu.items.filter(\.isHidden)
        check(
            aliases.map(\.keyEquivalent) == ["`", "~"]
                && aliases.allSatisfy {
                    $0.allowsKeyEquivalentWhenHidden && $0.keyEquivalentModifierMask == [.command, .option]
                        && $0 is DefaultShortcutItem
                } && aliases.map(\.action) == [next.action, previous.action],
            "each has a second key that needs no function key: Option-Command-` and Shift-Option-Command-`")
        func allItems(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(allItems) ?? []) } }
        let bar = try requireValue(NSApp.mainMenu, "fixture: menu bar")
        let sameKeys = allItems(bar).filter { [f6, "`", "~"].contains($0.keyEquivalent) }
        check(
            sameKeys.count == 4 && sameKeys.allSatisfy { $0.action == next.action || $0.action == previous.action },
            "no other menu command uses F6 or the backtick key")
        let windowMenu = try requireValue(bar.items.first { $0.title == "Window" }?.submenu, "fixture: Window menu")
        let listed = windowMenu.items.filter {
            !$0.isSeparatorItem && !$0.isHidden && $0.action != #selector(NSWindow.makeKeyAndOrderFront(_:))
        }
        check(listed.count <= 20, "DS-23 the Window menu still lists no more than twenty items: \(listed.count)")
        // The fixture's Window rows are the menu as built: position, title, action, key, target.
        func rows(_ menu: NSMenu, path: [Int]) -> [[String: String]] {
            menu.items.enumerated().flatMap { index, item -> [[String: String]] in
                let position = path + [index]
                let row: [String: String] = [
                    "position": position.map(String.init).joined(separator: "."), "title": item.title,
                    "action": item.action.map(NSStringFromSelector) ?? "", "key": item.keyEquivalent,
                    "modifiers": String(item.keyEquivalentModifierMask.rawValue),
                    "target": item.target == nil ? "responder" : "explicit",
                    "object": item.representedObject.map { String(describing: $0) } ?? ""
                ]
                return [row] + (item.submenu.map { rows($0, path: position) } ?? [])
            }
        }
        let fixture =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: TestPaths.fixtures.appendingPathComponent("menu-tree.json")))
            as! [[String: String]]
        let windowIndex = try requireValue(bar.items.firstIndex { $0.title == "Window" }, "fixture: Window position")
        let expected = fixture.filter { $0["position"]?.hasPrefix("\(windowIndex).") == true }
        // AppKit appends the open windows to this menu while the application runs.
        let actual = rows(windowMenu, path: [windowIndex]).filter { $0["action"] != "makeKeyAndOrderFront:" }
        if !check(
            Array(actual.prefix(expected.count)) == expected
                && actual.dropFirst(expected.count).allSatisfy { $0["action"] == "" },
            "the menu fixture's Window rows are the Window menu as built, the two commands and their second keys included"
        ) {
            print("NOTE Window rows not in the fixture: \(actual.filter { !expected.contains($0) })")
        }
        let palette = app.commandDiscovery.commands(in: bar)
        check(
            [WindowAreaFocusController.nextTitle, WindowAreaFocusController.previousTitle].allSatisfy { title in
                palette.filter { $0.path == "Window › Move Focus › " + title && $0.row.enabled }.count == 1
            }, "the Command Palette lists both commands once each")

        // One group, one tab showing Source: tabs, text, status.
        check(
            kinds() == [.tabs, .text, .status] && current() == .text,
            "the areas of one group are its tabs, text and status row")
        let said = NativeFixtureEnvironment.announcements.count
        check(choose(next) && current() == .status, "Move Focus to Next Area moves from the text to the status row")
        let statusControls = surface.statusControls
        check(
            !statusControls.isEmpty && window.firstResponder === statusControls.first
                && statusControls.allSatisfy { $0.focusRingType != .none },
            "the first status item has the keyboard, with the standard focus ring")
        check(
            focus.lastAnnouncement == "Document status."
                && NativeFixtureEnvironment.announcements.dropFirst(said).contains("Document status."),
            "DS-72 the area reached is announced")
        check(snapshot() == before, "the selection, the scroll position, the text and the active tab are unchanged")
        check(choose(next) && current() == .tabs, "then round to the tab strip")
        let plainTitle = try requireValue(surface.tabTitle(plainID), "fixture: plain.txt tab title")
        let notesTitle = try requireValue(surface.tabTitle(notesID), "fixture: notes.md tab title")
        check(
            window.firstResponder === plainTitle && plainTitle.focusRingType != .none
                && focus.lastAnnouncement == "Tabs.",
            "the active tab's title has the keyboard and the standard focus ring")
        check(choose(next) && current() == .text && keyboard(in: editor), "and back to the text")
        check(focus.lastAnnouncement == "Text of plain.txt.", "the text is announced by its document's name (DS-71)")
        check(snapshot() == before, "a whole round changes nothing")
        check(
            choose(previous) && current() == .tabs && choose(previous) && current() == .status && choose(previous)
                && current() == .text && snapshot() == before,
            "Move Focus to Previous Area visits the same areas in the opposite order")

        // With the sidebar and the find bar shown: sidebar, tabs, find bar, text, status.
        check(host.setSidebarShown(true, browser: browser), "fixture: the Workspace Browser is shown")
        plainTab.showFind(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        window.makeFirstResponder(plainTab.keyboardFocusView)
        check(
            kinds() == [.sidebar, .tabs, .findBar, .text, .status],
            "the sidebar and the find bar join the ring while they are shown: \(kinds())")
        let shown = snapshot()
        var visited: [Kind] = []
        for _ in 0..<5 {
            focus.move(1)
            if let kind = current() { visited.append(kind) }
        }
        check(
            visited == [.status, .sidebar, .tabs, .findBar, .text] && snapshot() == shown,
            "Next visits each area that is present, in order, and returns to the text: \(visited)")
        visited = []
        for _ in 0..<5 {
            focus.move(-1)
            if let kind = current() { visited.append(kind) }
            if current() == .sidebar {
                check(window.firstResponder === browser.outline, "in the sidebar the list has the keyboard")
            }
            if current() == .findBar {
                check(keyboard(in: plainTab.findField), "in the find bar the Find field has it")
            }
        }
        check(
            visited == [.findBar, .tabs, .sidebar, .status, .text] && snapshot() == shown,
            "Previous visits them in the opposite order: \(visited)")
        // Escape in the sidebar returns to the text.
        focus.move(1)
        focus.move(1)
        check(current() == .sidebar, "fixture: the keyboard is in the sidebar")
        browser.outline.keyDown(with: try key(53, "\u{1B}", in: window))
        check(keyboard(in: editor) && host.isSidebarShown, "Escape in the sidebar returns the keyboard to the text")
        browser.hide()
        plainTab.hideFind(nil)
        window.makeFirstResponder(plainTab.keyboardFocusView)
        check(kinds() == [.tabs, .text, .status], "hidden again, they leave the ring")

        // In the tab strip: arrows move between tabs, Tab reaches the close button, Return selects.
        focus.move(-1)
        check(window.firstResponder === plainTitle, "fixture: the keyboard is on the active tab's title")
        plainTitle.keyDown(with: try key(124, right, in: window))
        check(
            window.firstResponder === notesTitle && snapshot() == before,
            "Right Arrow moves the keyboard to the next tab without selecting it")
        notesTitle.keyDown(with: try key(124, right, in: window))
        check(window.firstResponder === notesTitle, "at the last tab Right Arrow stays")
        notesTitle.keyDown(with: try key(123, left, in: window))
        check(window.firstResponder === plainTitle, "Left Arrow moves back")
        plainTitle.keyDown(with: try key(48, "\t", in: window))
        let closePlain = window.firstResponder as? NSButton
        check(
            closePlain != nil && closePlain !== plainTitle && closePlain?.accessibilityLabel() == "Close plain.txt"
                && closePlain?.focusRingType != NSFocusRingType.none,
            "Tab reaches the tab's close button, which is named for its document (DS-70)")
        closePlain?.keyDown(with: try key(124, right, in: window))
        check(window.firstResponder === notesTitle, "from a close button Right Arrow moves to the next tab")
        notesTitle.keyDown(with: try key(48, "\u{19}", [.shift], in: window))
        check(window.firstResponder === closePlain, "Shift-Tab steps back through the controls")
        closePlain?.keyDown(with: try key(48, "\u{19}", [.shift], in: window))
        check(
            window.firstResponder === plainTitle && snapshot() == before,
            "back to the first title; nothing was closed or selected")
        // The mark of a tab that shows its preview is reached the same way.
        check(notesTab.setViewMode(.both, movingFocus: false), "fixture: notes.md shows Both")
        window.contentView?.layoutSubtreeIfNeeded()
        let withMark = surface.tabControls
        check(
            withMark.count == 5 && withMark[3].accessibilityLabel() == "Show source for notes.md",
            "the mark of a tab in Both is one of the strip's keyboard stops: \(withMark.map { $0.accessibilityLabel() ?? "" })"
        )
        check(notesTab.setViewMode(.source, movingFocus: false), "fixture: notes.md shows Source again")
        window.makeFirstResponder(plainTitle)
        plainTitle.keyDown(with: try key(124, right, in: window))
        notesTitle.keyDown(with: try key(36, "\r", in: window))
        check(
            host.model.activeTab?.id == notesID && keyboard(in: notesTab.activeEditor),
            "Return on a tab's title selects that tab and puts the keyboard in its text")
        focus.move(-1)
        check(window.firstResponder === notesTitle, "fixture: back on the notes.md title")
        notesTitle.keyDown(with: try key(123, left, in: window))
        plainTitle.keyDown(with: try key(49, " ", in: window))
        check(
            host.model.activeTab?.id == plainID && keyboard(in: editor) && snapshot() == before,
            "Space on a tab's title selects it too; its selection and scroll position are as they were")
        // Escape from the tab strip and from the status row.
        focus.move(-1)
        plainTitle.keyDown(with: try key(53, "\u{1B}", in: window))
        check(keyboard(in: editor) && snapshot() == before, "Escape in the tab strip returns the keyboard to the text")

        // In the status row: arrows and Tab move between items.
        focus.move(1)
        let items = surface.statusControls
        check(
            items.count >= 3 && window.firstResponder === items[0], "fixture: the keyboard is on the first status item")
        check(
            items.allSatisfy { ($0.accessibilityLabel() ?? "").isEmpty == false },
            "DS-70 every status item that takes the keyboard has a name")
        surface.keyDown(with: try key(124, right, in: window))
        check(window.firstResponder === items[1], "Right Arrow moves to the next status item")
        surface.keyDown(with: try key(48, "\t", in: window))
        check(window.firstResponder === items[2], "Tab moves on")
        surface.keyDown(with: try key(123, left, in: window))
        surface.keyDown(with: try key(48, "\u{19}", [.shift], in: window))
        check(window.firstResponder === items[0] && snapshot() == before, "Left Arrow and Shift-Tab move back")
        window.makeFirstResponder(items[items.count - 1])
        surface.keyDown(with: try key(124, right, in: window))
        check(window.firstResponder === items[items.count - 1], "at the last item Right Arrow stays")
        surface.keyDown(with: try key(48, "\t", in: window))
        check(current() == .tabs, "Tab at the last item leaves the row for the next area")
        focus.move(-1)
        check(current() == .status, "fixture: back in the status row")
        surface.keyDown(with: try key(53, "\u{1B}", in: window))
        check(keyboard(in: editor) && snapshot() == before, "Escape in the status row returns the keyboard to the text")

        // With nothing holding the keyboard the first move reaches the text.
        window.makeFirstResponder(nil)
        check(
            focus.move(1) && current() == .text && keyboard(in: editor),
            "with the keyboard nowhere, the first move reaches the text")

        // Source, Preview and Both.
        host.activate(notesTab)
        check(notesTab.setViewMode(.both), "fixture: notes.md shows Both")
        window.contentView?.layoutSubtreeIfNeeded()
        window.makeFirstResponder(notesTab.activeEditor)
        check(kinds() == [.tabs, .text, .preview, .status], "in Both the source is followed by the preview")
        check(
            focus.move(1) && current() == .preview && keyboard(in: notesTab.previewCoordinator?.pane)
                && focus.lastAnnouncement == "Preview of notes.md.",
            "Next moves from the source to the preview, and says so")
        check(
            focus.move(-1) && current() == .text && keyboard(in: notesTab.activeEditor),
            "and Previous back to the source")
        check(notesTab.setViewMode(.preview), "fixture: notes.md shows Preview alone")
        window.contentView?.layoutSubtreeIfNeeded()
        check(
            kinds() == [.tabs, .preview, .status],
            "a tab that shows Preview alone offers the preview, not its hidden source")
        for _ in 0..<3 { focus.move(1) }
        check(
            notesTab.viewMode == .preview && current() == .preview,
            "a whole round leaves the tab in Preview: the hidden source never took the keyboard")
        check(notesTab.setViewMode(.source), "fixture: notes.md shows Source")
        host.activate(plainTab)

        // Two groups: the second group's areas follow the first group's.
        check(host.setEditorLayout(.twoColumns), "fixture: two editor groups")
        host.focusGroup(.first)
        window.contentView?.layoutSubtreeIfNeeded()
        let second = try requireValue(host.groupSurfaces[.second], "fixture: second group")
        window.makeFirstResponder(plainTab.keyboardFocusView)
        check(
            kinds() == [.tabs, .text, .status, .emptyGroup],
            "a group with no tabs is one area, after the first group's: \(kinds())")
        let twoGroups = snapshot()
        focus.move(1)
        focus.move(1)
        check(
            current() == .emptyGroup && (window.firstResponder as? NSButton)?.title == "New"
                && host.model.focusedGroup == .second && focus.lastAnnouncement == "Group 2, Right, empty.",
            "the empty group's New button takes the keyboard, the group is focused and named")
        check(snapshot() == twoGroups, "nothing else changed")
        second.keyDown(with: try key(53, "\u{1B}", in: window))
        check(
            keyboard(in: editor) && host.model.focusedGroup == .first,
            "Escape in a group with no tabs returns the keyboard to the text of the group that has some")
        host.moveTabs([notesID], target: notesID, to: .second)
        let moved = try requireValue(
            host.model.groups.first { $0.slot == .second }?.activeTab.flatMap { host.presentation(for: $0) },
            "fixture: notes.md in the second group")
        host.activate(plainTab)
        window.contentView?.layoutSubtreeIfNeeded()
        window.makeFirstResponder(plainTab.keyboardFocusView)
        check(
            kinds() == [.tabs, .text, .status, .tabs, .text, .status]
                && focus.areas().map(\.slot) == [
                    .first, .first, .first, .second, .second, .second
                ], "with tabs in both groups each group contributes its tabs, text and status row")
        let both = snapshot()
        focus.move(1)
        focus.move(1)
        check(
            keyboard(in: second.strip) && host.model.focusedGroup == .second
                && focus.lastAnnouncement == "Tabs in Group 2, Right.",
            "after the first group's status row comes the second group's tab strip, announced with its group")
        check(snapshot() == both, "each group's active tab, and the first group's selection and scroll, are unchanged")
        focus.move(1)
        check(
            keyboard(in: moved.activeEditor) && focus.lastAnnouncement == "Text of notes.md in Group 2, Right.",
            "then the second group's text")
        focus.move(1)
        focus.move(1)
        check(
            keyboard(in: surface.strip) && host.model.focusedGroup == .first && snapshot() == both,
            "and round to the first group again")
        focus.move(1)
        check(keyboard(in: editor), "fixture: the keyboard is back in the first group's text")
        host.moveTabs([try requireValue(moved.tabID, "fixture: moved tab")], target: moved.tabID!, to: .first)
        check(host.setEditorLayout(.single), "fixture: back to one group")
    }

    static func nativeAttribute(_ element: Any, _ name: String) -> String {
        guard let object = element as? NSObject, object.responds(to: NSSelectorFromString(name)) else { return "" }
        return object.perform(NSSelectorFromString(name))?.takeUnretainedValue() as? String ?? ""
    }
    static func nativeTree(_ root: Any, depth: Int = 0) -> [Any] {
        guard depth < 12, let object = root as? NSObject else { return [] }
        let selector = NSSelectorFromString("accessibilityChildren")
        let children =
            object.responds(to: selector)
            ? (object.perform(selector)?.takeUnretainedValue() as? [Any] ?? []) : []
        return [root] + children.flatMap { nativeTree($0, depth: depth + 1) }
    }
}
