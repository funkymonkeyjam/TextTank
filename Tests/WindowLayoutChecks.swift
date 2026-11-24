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
        // A sheet: the item goes off when one begins and comes back when it ends. The sheet's
        // presence is supplied to the host here, so none is shown.
        var sheet = true
        host.attachedSheetProbe = { sheet }
        defer { host.attachedSheetProbe = nil }
        NotificationCenter.default.post(name: NSWindow.willBeginSheetNotification, object: window)
        check(
            !layout.isEnabled && !host.groupCommands.commandsAvailable
                && !host.groupCommands.validateMenuItem(offered[0]) && !host.areaFocus.isAvailable,
            "while a sheet is attached Editor Layout, its layouts and Move Focus are disabled together (DS-21)")
        sheet = false
        NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: window)
        check(
            layout.isEnabled && host.groupCommands.validateMenuItem(offered[0]),
            "when the sheet ends the toolbar item is enabled again without any other event")
        host.attachedSheetProbe = nil

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
        let drawn = windowMenu.items.filter { !$0.isSeparatorItem && !$0.isHidden }
        check(
            listed.count == 16 && drawn.count <= 20,
            "DS-23 the Window menu has sixteen items of its own, which leaves room for the windows AppKit lists after them: \(listed.count) own, \(drawn.count) drawn"
        )
        let several = try requireValue(
            try item(["Window", "Close Multiple Tabs"]).submenu, "the commands that close several tabs share a submenu")
        check(
            several.items.compactMap { $0.representedObject as? String } == [
                "closeOthers", "closeLeft", "closeRight", "closeGroup", "closeSaved"
            ]
                && several.items.allSatisfy {
                    $0.target === app && $0.action == #selector(AppDelegate.performTabCommand(_:))
                }
                && windowMenu.items.contains { $0.representedObject as? String == "close" },
            "Close Multiple Tabs holds the five bulk closes with their command identities; Close Tab stays at the top level"
        )
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
        // The whole golden menu tree is the menu bar as built, every menu and every row.
        let listedRows = expected.filter { ($0["position"] ?? "").split(separator: ".").count == 2 }.count
        // AppKit also puts a separator before the windows it lists at the end of the Window menu.
        let liveBar = rows(bar, path: []).filter { $0["action"] != "makeKeyAndOrderFront:" }.filter {
            !($0["action"] == "" && $0["title"] == "" && $0["position"] == "\(windowIndex).\(listedRows)")
        }
        let known = Set(fixture), built = Set(liveBar)
        let stray = liveBar.filter { !known.contains($0) }, absent = fixture.filter { !built.contains($0) }
        if !check(stray.isEmpty && absent.isEmpty, "the whole menu fixture equals the menu bar as built in this host") {
            print(
                "NOTE menu rows not in the fixture: \(stray.prefix(8)); fixture rows not in the menu: \(absent.prefix(8))"
            )
        }

        // Settings > Shortcuts: both commands can be given a key, and their defaults give way.
        let catalog = ShortcutCatalog.catalog(in: bar)
        let nextID = try requireValue(ShortcutCatalog.identifier(for: next), "fixture: Next Area identifier")
        let entries = catalog.entries.filter { $0.item === next || $0.item === previous }
        check(
            entries.map(\.title) == [
                "Window › Move Focus › Move Focus to Next Area", "Window › Move Focus › Move Focus to Previous Area"
            ]
                && entries.allSatisfy { $0.kind == .assignable(yields: true) }
                && entries.map { $0.standard?.displayText ?? "" } == ["F6", "⇧F6"]
                && entries.map { $0.standard?.spokenText ?? "" } == ["F6", "Shift-F6"],
            "the Shortcuts list shows both commands with F6 and Shift-F6, assignable, as defaults that give way: \(entries.map { "\($0.title) \($0.kind) \($0.standard?.displayText ?? "-")" })"
        )
        check(
            aliases.map { alias in catalog.aliases.first { $0.item === alias }?.standard }
                == [WindowAreaFocusController.nextAlternate, WindowAreaFocusController.previousAlternate],
            "their second keys are known to the shortcut model as aliases, which give way to an assigned key")
        check(
            [WindowAreaFocusController.nextAlternate, WindowAreaFocusController.previousAlternate].map(\.spokenText)
                == [
                    "Option-Command-Backtick", "Option-Shift-Command-Backtick"
                ] && MenuShortcut("~", [.command]).spokenText == "Shift-Command-Backtick"
                && MenuShortcut("?", [.command]).spokenText == "Command-?",
            "the second keys are said as the key presses they are; other shifted symbols are said as before: \([WindowAreaFocusController.nextAlternate, WindowAreaFocusController.previousAlternate].map(\.spokenText))"
        )
        let pressF6 = try key(97, f6, [.function], in: window)
        let pressShiftF6 = try key(97, f6, [.function, .shift], in: window)
        check(
            MenuShortcut(pressF6) == WindowAreaFocusController.nextShortcut
                && MenuShortcut(pressShiftF6) == WindowAreaFocusController.previousShortcut
                && ShortcutPolicy.refusal(for: WindowAreaFocusController.nextShortcut) == nil
                && ShortcutPolicy.refusal(for: WindowAreaFocusController.nextAlternate) == nil,
            "a pressed function key is recorded as that key, and none of the four keys is refused")
        var assigned = app.settings.value
        assigned.assignShortcut(MenuShortcut("j", [.command, .control]), to: nextID, in: catalog.context)
        ShortcutCatalog.apply(assigned, to: bar)
        check(
            next.keyEquivalent == "j" && next.keyEquivalentModifierMask == [.command, .control]
                && previous.keyEquivalent == f6 && aliases.map(\.keyEquivalent) == ["`", "~"],
            "a shortcut assigned to Move Focus to Next Area replaces F6 on its item only")
        var taken = app.settings.value
        let upperID = EditorCommand.upper.rawValue
        taken.assignShortcut(
            WindowAreaFocusController.nextShortcut, to: upperID, replacing: [nextID], in: catalog.context)
        ShortcutCatalog.apply(taken, to: bar)
        check(
            next.keyEquivalent.isEmpty && previous.keyEquivalent == f6
                && allItems(bar).contains { $0.representedObject as? String == upperID && $0.keyEquivalent == f6 },
            "F6 given to another command leaves Move Focus to Next Area without it")
        ShortcutCatalog.apply(app.settings.value, to: bar)
        check(
            next.keyEquivalent == f6 && next.keyEquivalentModifierMask == []
                && previous.keyEquivalentModifierMask == [.shift]
                && aliases.map(\.keyEquivalent) == ["`", "~"],
            "fixture: the default keys are back")

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
        let restoreRoom = WorkspaceRoom.grant(host)
        defer { restoreRoom() }
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
        // Escape on a button of the find bar closes the bar, as it does in the Find field (DS-35).
        let findBar = try requireValue(plainTab.findBar, "fixture: find bar")
        let findButton = try requireValue(
            EditorGroupSurface.controls(in: findBar).first, "fixture: a button in the find bar")
        window.makeFirstResponder(findButton)
        check(current() == .findBar, "a button of the find bar is in the find bar's area")
        findButton.keyDown(with: try key(53, "\u{1B}", in: window))
        check(
            !plainTab.findBarVisible && keyboard(in: editor) && snapshot() == shown,
            "Escape there closes the find bar and returns the keyboard to the text")
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
        // The status row's buttons run one command; Return presses them. Position opens Go to Line.
        focus.move(1)
        let position = try requireValue(
            surface.statusControls.first {
                !($0 is NSPopUpButton) && ($0.identifier?.rawValue ?? "").hasPrefix("status.position")
            },
            "the position item is a button among the status row's keyboard stops: \(surface.statusControls.map { $0.accessibilityLabel() ?? "" })"
        )
        check(
            surface.statusControls.contains { $0 is NSPopUpButton },
            "the pull-down fields are keyboard stops too")
        window.makeFirstResponder(position)
        surface.keyDown(with: try key(36, "\r", in: window))
        window.contentView?.layoutSubtreeIfNeeded()
        check(
            plainTab.goToLineBarVisible && kinds() == [.tabs, .goToLine, .text, .status] && current() == .goToLine
                && keyboard(in: plainTab.goToLineBar.field),
            "Return on the position button opens Go to Line, which joins the ring while it is shown: \(kinds())")
        // Round the ring and back into the bar by the command.
        window.makeFirstResponder(plainTab.goToLineBar.cancelButton)
        check(current() == .goToLine, "the bar's buttons belong to its area")
        plainTab.goToLineBar.field.stringValue = "300"
        plainTab.goToLineBar.cancelButton.keyDown(with: try key(53, "\u{1B}", in: window))
        check(
            !plainTab.goToLineBarVisible && keyboard(in: editor) && snapshot() == before,
            "Escape on a button of Go to Line closes it and puts the caret, selection and scroll position back")
        // Leaving Go to Line by Move Focus is not Return: nothing of the previewed line is kept.
        for direction in [1, -1] {
            plainTab.goToLine(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            let field = plainTab.goToLineBar.field
            check(
                plainTab.goToLineBarVisible && keyboard(in: field),
                "fixture: Go to Line is open with the keyboard in its field")
            field.stringValue = "300"
            NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
            let previewed = snapshot() != before
            focus.move(direction)
            settle(0.1)
            check(
                !plainTab.goToLineBarVisible && current() == (direction == 1 ? .text : .tabs) && snapshot() == before,
                "Move Focus \(direction == 1 ? "forward" : "back") out of Go to Line closes it and leaves the caret, selection and scroll as they were before it opened (line 300 was previewed: \(previewed))"
            )
            window.makeFirstResponder(plainTab.keyboardFocusView)
        }
        plainTab.goToLine(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        check(
            kinds() == [.tabs, .goToLine, .text, .status],
            "Go to Line is in the ring while it is shown")
        plainTab.cancelGoToLine(nil)
        window.makeFirstResponder(plainTab.keyboardFocusView)
        check(
            !plainTab.goToLineBarVisible && snapshot() == before,
            "fixture: Go to Line is closed and the editor is as it was")
        // An operation's Cancel button and a follow-up are stops while they are shown.
        let center = StatusOperationCenter.shared
        let delay = center.revealDelay
        center.revealDelay = 0
        let operation = center.begin("Checking the fixture", in: editor, cancelLabel: "Cancel the fixture check") {}
        window.contentView?.layoutSubtreeIfNeeded()
        check(
            surface.statusControls.contains { $0.identifier?.rawValue == StatusBadgeRow.cancelIdentifier },
            "while an operation runs its Cancel button is one of the status row's keyboard stops: \(surface.statusControls.map { $0.identifier?.rawValue ?? "" })"
        )
        center.end(operation)
        center.revealDelay = delay
        window.contentView?.layoutSubtreeIfNeeded()
        var followed = 0
        plainTab.offerStatusFollowUp(
            StatusFollowUp(
                title: "Show Fixture", accessibilityLabel: "Show the fixture's result",
                toolTip: "Shows the fixture's result.",
                run: { followed += 1 }, isCurrent: { true }))
        window.contentView?.layoutSubtreeIfNeeded()
        let withFollowUp = surface.statusControls
        let followUp = try requireValue(
            withFollowUp.first { $0.identifier?.rawValue == StatusBadgeRow.followUpIdentifier },
            "a follow-up button is one of the status row's keyboard stops: \(withFollowUp.map { $0.identifier?.rawValue ?? "" })"
        )
        let followUpAt = try requireValue(withFollowUp.firstIndex { $0 === followUp }, "fixture: follow-up position")
        window.makeFirstResponder(withFollowUp[0])
        for _ in 0..<followUpAt { surface.keyDown(with: try key(124, right, in: window)) }
        check(
            window.firstResponder === followUp && current() == .status && followUp.focusRingType != .none
                && followUp.accessibilityLabel() == "Show the fixture's result",
            "the arrow keys reach the follow-up button, which is named for what it does (DS-70)")
        surface.keyDown(with: try key(36, "\r", in: window))
        check(followed == 1 && snapshot() == before, "Return presses it once and changes nothing else")
        surface.keyDown(with: try key(53, "\u{1B}", in: window))
        check(keyboard(in: editor), "Escape from it returns the keyboard to the text")
        plainTab.offerStatusFollowUp(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        // Narrow: the fields that do not fit move into More, which is the last stop.
        window.setContentSize(NSSize(width: 800, height: 700))
        check(host.setEditorLayout(.twoColumns), "fixture: two columns, so the status row is narrow")
        window.contentView?.layoutSubtreeIfNeeded()
        let narrow = surface.statusControls
        if let more = narrow.first(where: { $0.identifier?.rawValue == StatusBadgeRow.overflowIdentifier }) {
            window.makeFirstResponder(narrow[0])
            for _ in 1..<narrow.count { surface.keyDown(with: try key(124, right, in: window)) }
            check(
                narrow.last === more && window.firstResponder === more && more.focusRingType != .none,
                "in a narrow group the More pull-down is the row's last stop and the arrow keys reach it")
            surface.keyDown(with: try key(36, "\r", in: window))
            check(window.firstResponder === more, "Return does not open a pull-down; Space does")
        } else {
            print("NOTE the status row showed no More pull-down at \(surface.bounds.width) points")
        }
        check(host.setEditorLayout(.single), "fixture: one group again")
        window.setContentSize(NSSize(width: 1400, height: 700))
        window.contentView?.layoutSubtreeIfNeeded()
        window.makeFirstResponder(plainTab.keyboardFocusView)
        check(snapshot() == before, "fixture: the editor is as it was")

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

        // More tabs than fit: the list of open tabs is the strip's last keyboard stop.
        let extras = try (1...9).map { try open("extra-\($0).txt", "extra\n", in: folder).1 }
        host.activate(plainTab)
        window.setContentSize(NSSize(width: 800, height: 700))
        window.contentView?.layoutSubtreeIfNeeded()
        let list = surface.strip.openTabListButton
        check(surface.strip.showsOpenTabList, "fixture: eleven tabs overflow an 800-point strip")
        let crowded = surface.tabControls
        check(
            crowded.last === list && list.accessibilityLabel() == "Open tabs in this group",
            "the list of open tabs is the last keyboard stop of the tab area (DS-70): \(crowded.suffix(2).map { $0.accessibilityLabel() ?? "" })"
        )
        window.makeFirstResponder(crowded[crowded.count - 2])
        surface.keyDown(with: try key(48, "\t", in: window))
        check(
            window.firstResponder === list && current() == .tabs,
            "Tab from the last tab's close button reaches it, still in the tab area")
        surface.keyDown(with: try key(36, "\r", in: window))
        surface.keyDown(with: try key(123, left, in: window))
        let lastTitle = crowded.last {
            ($0.identifier?.rawValue ?? "").hasPrefix("tab.")
                && !($0.identifier?.rawValue ?? "").hasPrefix("tab.viewMode.")
        }
        check(
            window.firstResponder === lastTitle && host.model.activeTab?.id == plainID,
            "Return leaves the pull-down closed; Left Arrow from it moves to the last tab's title, selecting nothing")
        window.makeFirstResponder(list)
        surface.keyDown(with: try key(48, "\t", in: window))
        check(current() == .text, "Tab past it leaves the tab area")
        extras.forEach { ($0.document as? TextDocument)?.close() }
        window.setContentSize(NSSize(width: 1400, height: 700))
        window.contentView?.layoutSubtreeIfNeeded()
        host.activate(plainTab)
        window.makeFirstResponder(plainTab.keyboardFocusView)

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

    // MARK: Empty-group hint

    private static func settle(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }
    static func emptyGroupHint(root: URL, app: AppDelegate, host: WorkspaceWindowController) throws {
        let window = try requireValue(host.window, "fixture: workspace window")
        let bar = try requireValue(NSApp.mainMenu, "fixture: menu bar")
        let folder = root.appendingPathComponent("hint")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let originalSize = window.contentView?.bounds.size ?? NSSize(width: 1080, height: 720)
        let provider = EditorGroupSurface.recentFilesProvider
        let documents = NSDocumentController.shared as? TextDocumentController
        let recorded = documents?.recordsRecentDocuments
        // The owned application must not add a fixture to any list of recent documents.
        documents?.recordsRecentDocuments = false
        window.setContentSize(NSSize(width: 1400, height: 700))
        defer {
            EditorGroupSurface.recentFilesProvider = provider
            if let recorded { documents?.recordsRecentDocuments = recorded }
            NSDocumentController.shared.documents.filter { $0.fileURL?.path.hasPrefix(folder.path) == true }
                .forEach { $0.close() }
            EditorSettingsApplication.applyShortcuts(app.settings.value, to: bar)
            _ = host.setEditorLayout(.single)
            window.setContentSize(originalSize)
        }
        let (_, keptTab) = try open("kept.txt", "kept\n", in: folder)
        host.activate(keptTab)
        check(host.setEditorLayout(.twoColumns), "fixture: two editor groups, the second with no tabs")
        window.contentView?.layoutSubtreeIfNeeded()
        let surface = try requireValue(host.groupSurfaces[.second], "fixture: second group")
        let area = try requireValue(surface.emptyGroupArea, "the group with no tabs shows its placeholder")
        func inside(_ view: NSView) -> Bool {
            !view.isHiddenOrHasHiddenAncestor
                && area.bounds.insetBy(dx: -0.5, dy: -0.5).contains(view.convert(view.bounds, to: area))
        }
        func shownRows() -> [String] { surface.hintRows.filter(inside).map(\.stringValue) }
        func buttons() -> [NSButton] { EditorGroupSurface.controls(in: area).compactMap { $0 as? NSButton } }

        // New and Open stay; the four commands are named with the keys the menu has now.
        check(
            buttons().prefix(2).map(\.title) == ["New", "Open…"]
                && buttons().prefix(2).map { $0.accessibilityLabel() ?? "" } == [
                    "New document in this group", "Open a document in this group"
                ],
            "the empty group keeps its New and Open buttons, named for what they do (DS-70)")
        let commands: [(Selector, String)] = [
            (#selector(AppDelegate.newDocument(_:)), "Press %@ for a new document."),
            (#selector(NSDocumentController.openDocument(_:)), "Press %@ to open a document."),
            (#selector(WorkspaceBrowserController.quickOpen(_:)), "Press %@ for Quick Open, to find a file by name."),
            (NSSelectorFromString("paletteAction"), "Press %@ for the Command Palette.")
        ]
        func menuItem(_ action: Selector, in menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.action == action, !item.isHidden { return item }
                if let found = item.submenu.flatMap({ menuItem(action, in: $0) }) { return found }
            }
            return nil
        }
        let items = try commands.map { try requireValue(menuItem($0.0, in: bar), "fixture: menu item for \($0.0)") }
        let live = zip(commands, items).map { String(format: $0.0.1, ControlPresentation.shortcut(of: $0.1) ?? "?") }
        check(
            live == [
                "Press ⌘N for a new document.", "Press ⌘O to open a document.",
                "Press ⇧⌘O for Quick Open, to find a file by name.",
                "Press ⇧⌘P for the Command Palette."
            ], "fixture: the four commands have their default keys in the menu bar: \(live)")
        check(
            shownRows() == live,
            "the empty group names New, Open, Quick Open and the Command Palette with their keys: \(shownRows())")
        check(
            surface.hintRows.allSatisfy {
                $0.textColor == .secondaryLabelColor && !$0.isEditable && !$0.isSelectable
                    && $0.font?.pointSize == NSFont.smallSystemFontSize
            }, "the rows are labels in secondary label style")
        check(
            surface.hintRows.map { $0.accessibilityLabel() ?? "" } == [
                "Press Command-N for a new document.", "Press Command-O to open a document.",
                "Press Shift-Command-O for Quick Open, to find a file by name.",
                "Press Shift-Command-P for the Command Palette."
            ], "DS-70 VoiceOver reads each row with its key in words")

        // Live keys: a default that gave way to an assigned shortcut, and a key changed in the menu.
        var custom = app.settings.value
        custom.shortcuts[EditorCommand.upper.rawValue] = "O"
        EditorSettingsApplication.applyShortcuts(custom, to: bar)
        surface.refresh()
        window.contentView?.layoutSubtreeIfNeeded()
        check(
            items[2].keyEquivalent.isEmpty && shownRows()[2] == "Choose File > Quick Open… to find a file by name.",
            "when an assigned shortcut takes Quick Open's default key, the row names its menu instead: \(shownRows())")
        EditorSettingsApplication.applyShortcuts(app.settings.value, to: bar)
        let paletteKey = (items[3].keyEquivalent, items[3].keyEquivalentModifierMask)
        items[3].keyEquivalent = "k"
        items[3].keyEquivalentModifierMask = [.command, .control]
        surface.refresh()
        window.contentView?.layoutSubtreeIfNeeded()
        check(
            shownRows() == Array(live.prefix(3)) + ["Press ⌃⌘K for the Command Palette."]
                && surface.hintRows[3].accessibilityLabel()
                    == "Press Control-Command-K for the Command Palette.",
            "a key changed in the menu is the key the row shows next: \(shownRows())")
        (items[3].keyEquivalent, items[3].keyEquivalentModifierMask) = paletteKey
        surface.refresh()
        window.contentView?.layoutSubtreeIfNeeded()
        check(shownRows() == live, "fixture: the default keys are back")
        // A shortcut recorded in Settings > Shortcuts for Quick Open is the key its row shows.
        let context = ShortcutCatalog.catalog(in: bar).context
        let quickOpenID = try requireValue(ShortcutCatalog.identifier(for: items[2]), "fixture: Quick Open identifier")
        var withKey = app.settings.value
        let eighth = MenuShortcut(String(UnicodeScalar(UInt32(NSF8FunctionKey))!), [.shift])
        withKey.assignShortcut(eighth, to: quickOpenID, in: context)
        ShortcutCatalog.apply(withKey, to: bar)
        surface.refresh()
        window.contentView?.layoutSubtreeIfNeeded()
        check(
            eighth.displayText.hasPrefix("⇧") && eighth.spokenText.hasPrefix("Shift-")
                && eighth.displayText.hasSuffix("8")
                && shownRows()[2] == "Press \(eighth.displayText) for Quick Open, to find a file by name."
                && surface.hintRows[2].accessibilityLabel()
                    == "Press \(eighth.spokenText) for Quick Open, to find a file by name.",
            "a function key assigned to Quick Open in the shortcut model is what its row shows: \(shownRows())")
        ShortcutCatalog.apply(app.settings.value, to: bar)
        surface.refresh()
        window.contentView?.layoutSubtreeIfNeeded()
        check(shownRows() == live, "fixture: the default keys are back again")

        // Recent files: none in an isolated host unless the check supplies them.
        check(
            !AppStorage.permitsLegacyDefaults && surface.recentButtons.isEmpty && surface.recentFiles.isEmpty
                && provider().isEmpty,
            "with the support directory isolated, no recent file of the person's is read or listed")
        var names = ["one.txt", "two.md", "three.txt", "four.txt", "five.txt", "six.txt"]
        let existing = try names.map { name -> URL in
            let url = folder.appendingPathComponent(name)
            try Data("\(name)\n".utf8).write(to: url)
            return url
        }
        let gone = folder.appendingPathComponent("gone.txt"), directory = folder.appendingPathComponent("a-folder")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // More candidates than are ever checked: the files that exist are all past the limit.
        let unchecked = (0..<EditorGroupSurface.recentCandidateLimit).map {
            folder.appendingPathComponent("missing-\($0).txt")
        }
        EditorGroupSurface.recentFilesProvider = { unchecked + existing }
        surface.refreshRecentFiles(force: true)
        settle(0.4)
        check(
            surface.recentButtons.isEmpty,
            "only the first \(EditorGroupSurface.recentCandidateLimit) recent files are checked for existence")
        EditorGroupSurface.recentFilesProvider = { [existing[0], gone, existing[1], directory] + existing[2...] }
        surface.refreshRecentFiles(force: true)
        check(
            surface.recentButtons.isEmpty,
            "the existence check does not run on the main thread: nothing is listed until it answers")
        spinUntil("the recent files are listed") { surface.recentButtons.count == EditorGroupSurface.recentLimit }
        window.contentView?.layoutSubtreeIfNeeded()
        names.removeLast()
        check(
            surface.recentButtons.map(\.title) == names && surface.recentFiles == Array(existing.prefix(5)),
            "up to five recent files are listed, newest first; a file that no longer exists and a folder are left out: \(surface.recentButtons.map(\.title))"
        )
        check(
            surface.recentButtons.allSatisfy(inside)
                && surface.recentButtons.map { $0.accessibilityLabel() ?? "" } == names.map { "Open recent file " + $0 }
                && surface.recentButtons.map { $0.toolTip ?? "" } == existing.prefix(5).map(\.path),
            "each is a button named for the file it opens, with the path as its tooltip (DS-70)")
        let all = buttons()
        check(
            all.count == 7 && Array(all.suffix(5)) == surface.recentButtons
                && !all.indices.contains { a in
                    all.indices.contains { b in
                        a < b
                            && all[a].convert(all[a].bounds, to: area).intersects(
                                all[b].convert(all[b].bounds, to: area))
                    }
                },
            "New, Open and the five files are the placeholder's keyboard stops, in reading order, none overlapping")

        // Keyboard: the area command reaches the placeholder; arrows and Tab move; Return opens.
        window.makeFirstResponder(keptTab.keyboardFocusView)
        let focus = host.areaFocus
        focus.move(1)
        focus.move(1)
        check(window.firstResponder === all[0], "fixture: the keyboard is on New in the empty group")
        surface.keyDown(with: try key(125, String(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!), in: window))
        surface.keyDown(with: try key(125, String(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!), in: window))
        check(
            window.firstResponder === surface.recentButtons[0], "Down Arrow moves through Open to the first recent file"
        )
        surface.keyDown(with: try key(48, "\t", in: window))
        check(
            window.firstResponder === surface.recentButtons[1] && surface.recentButtons[1].focusRingType != .none,
            "Tab moves on, and the button with the keyboard draws the standard focus ring")
        let before = NSDocumentController.shared.documents.count
        surface.recentButtons[1].keyDown(with: try key(36, "\r", in: window))
        spinUntil("the recent file opens") {
            NSDocumentController.shared.documents.contains { $0.fileURL?.lastPathComponent == "two.md" }
        }
        let opened = try requireValue(
            NSDocumentController.shared.documents.first { $0.fileURL?.lastPathComponent == "two.md" } as? TextDocument,
            "activating a recent file's row opens that file")
        spinUntil("the opened file is the active tab") { (host.active?.document as? TextDocument) === opened }
        check(
            NSDocumentController.shared.documents.count == before + 1
                && host.model.groups.first { $0.slot == .second }?.tabs.count == 1
                && (host.active?.document as? TextDocument) === opened && opened.editor.text == "two.md\n"
                && surface.emptyGroupArea == nil,
            "it opens once, in the group whose row was activated, and that group is no longer empty")
        opened.close()
        window.contentView?.layoutSubtreeIfNeeded()
        check(surface.emptyGroupArea != nil, "fixture: the second group is empty again")

        // A grid set up in a wide window and then shrunk keeps its columns in line and no group
        // below its minimum (the two rows used to be left at different divider positions).
        window.setContentSize(NSSize(width: 1400, height: 700))
        check(host.setEditorLayout(.grid2x2), "fixture: four groups in a wide window")
        window.contentView?.layoutSubtreeIfNeeded()
        func groupFrames() -> [NSRect] {
            GroupSlot.allCases.compactMap { host.groupSurfaces[$0] }.map { $0.convert($0.bounds, to: nil) }
        }
        func aligned(_ frames: [NSRect]) -> Bool {
            frames.count == 4 && abs(frames[0].width - frames[2].width) < 0.5
                && abs(frames[1].minX - frames[3].minX) < 0.5
                && frames.allSatisfy {
                    $0.width >= CGFloat(TabGroupGeometry.minimumPane.width) - 0.5
                        && $0.height >= CGFloat(TabGroupGeometry.minimumPane.height) - 0.5
                }
        }
        window.setContentSize(NSSize(width: 800, height: 500))
        window.contentView?.layoutSubtreeIfNeeded()
        check(
            aligned(groupFrames()) && abs(groupFrames()[0].width - 400) < 1.5,
            "a grid shrunk from 1400 to 800 points keeps both rows' columns in line, at equal shares, none under 320: \(groupFrames().map { NSStringFromRect($0) })"
        )
        // A divider the person moved keeps its share of the width when the window is resized.
        window.setContentSize(NSSize(width: 1400, height: 700))
        window.contentView?.layoutSubtreeIfNeeded()
        let columns = host.groupContainer.dividers.filter(\.isVertical)
        columns[0].setPosition(1000, ofDividerAt: 0)
        window.contentView?.layoutSubtreeIfNeeded()
        check(
            aligned(groupFrames()) && abs(groupFrames()[0].width - 1000) < 1,
            "moving one row's column divider moves the other row's with it: \(groupFrames().map { NSStringFromRect($0) })"
        )
        window.setContentSize(NSSize(width: 800, height: 500))
        window.contentView?.layoutSubtreeIfNeeded()
        check(
            aligned(groupFrames()) && abs(groupFrames()[1].width - 320) < 1.5,
            "shrunk again, the wide column keeps as much of its share as the other's 320-point minimum allows: \(groupFrames().map { NSStringFromRect($0) })"
        )
        window.setContentSize(NSSize(width: 1400, height: 700))
        window.contentView?.layoutSubtreeIfNeeded()
        check(
            aligned(groupFrames()),
            "and wide again the rows are still in line: \(groupFrames().map { NSStringFromRect($0) })")
        // The window's frame changed in steps, as a drag of its edge does, each step laid out
        // and drawn: the rows are in line after every one, down to the minimum and back.
        var misaligned: [String] = []
        let origin = window.frame.origin
        for width in Array(stride(from: 1400, through: 800, by: -37)) + Array(stride(from: 800, through: 1400, by: 53))
        {
            window.setFrame(
                NSRect(
                    origin: origin,
                    size: window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: CGFloat(width), height: 520)).size),
                display: true)
            window.contentView?.layoutSubtreeIfNeeded()
            if !aligned(groupFrames()) { misaligned.append("\(width): \(groupFrames().map { NSStringFromRect($0) })") }
        }
        check(
            misaligned.isEmpty, "resized in steps, the grid's rows stay in line at every width: \(misaligned.prefix(3))"
        )
        // The rule for a share given up to the minimum: it is not taken back on widening.
        window.setContentSize(NSSize(width: 1400, height: 700))
        window.contentView?.layoutSubtreeIfNeeded()
        columns[1].setPosition(1000, ofDividerAt: 0)
        window.contentView?.layoutSubtreeIfNeeded()
        check(
            aligned(groupFrames()) && abs(groupFrames()[2].width - 1000) < 1,
            "the second row's divider leads the first when it is the one moved: \(groupFrames().map { NSStringFromRect($0) })"
        )
        window.setContentSize(NSSize(width: 800, height: 500))
        window.contentView?.layoutSubtreeIfNeeded()
        let clamped = groupFrames()[0].width / 800
        window.setContentSize(NSSize(width: 1400, height: 700))
        window.contentView?.layoutSubtreeIfNeeded()
        check(
            aligned(groupFrames()) && abs(groupFrames()[0].width / 1400 - clamped) < 0.01
                && groupFrames()[0].width < 900,
            "a divider held at the other column's minimum keeps the share it then had when the window widens: \(groupFrames()[0].width) of 1400"
        )

        // The minimum group size: rows that do not fit are hidden, never clipped (DS-67).
        check(host.setEditorLayout(.single), "fixture: one group before the window shrinks")
        window.setContentSize(NSSize(width: 800, height: 500))
        check(host.setEditorLayout(.grid2x2), "fixture: four groups in a window at its minimum size")
        window.contentView?.layoutSubtreeIfNeeded()
        // The dividers as far as they go: the fourth group is 320 by 200 points, the least a group can be.
        for divider in host.groupContainer.dividers {
            let extent = divider.isVertical ? divider.bounds.width : divider.bounds.height
            let least = CGFloat(
                divider.isVertical ? TabGroupGeometry.minimumPane.width : TabGroupGeometry.minimumPane.height)
            divider.setPosition(extent - divider.dividerThickness - least, ofDividerAt: 0)
        }
        window.contentView?.layoutSubtreeIfNeeded()
        let small = try requireValue(host.groupSurfaces[.fourth], "fixture: fourth group")
        small.refreshRecentFiles(force: true)
        spinUntil("the small group has its recent files") { small.recentFiles.count == EditorGroupSurface.recentLimit }
        window.contentView?.layoutSubtreeIfNeeded()
        let smallArea = try requireValue(small.emptyGroupArea, "fixture: the fourth group's placeholder")
        let everything =
            EditorGroupSurface.controls(in: smallArea) as [NSView] + small.hintRows.filter { !$0.isHidden }
        check(
            abs(small.bounds.width - 320) < 1 && abs(small.bounds.height - 200) < 1,
            "fixture: the group is at its minimum size, 320 by 200: \(NSStringFromSize(small.bounds.size))")
        let frames = everything.map { $0.convert($0.bounds, to: smallArea) }
        check(
            frames.allSatisfy { smallArea.bounds.insetBy(dx: -0.5, dy: -0.5).contains($0) }
                && !frames.indices.contains { a in
                    frames.indices.contains { b in a < b && frames[a].intersects(frames[b]) }
                },
            "at that size everything shown is whole and nothing overlaps: "
                + frames.map { NSStringFromRect($0) }.joined(separator: "; "))
        let shownSmall = small.hintRows.filter { !$0.isHidden }
        check(
            EditorGroupSurface.controls(in: smallArea).prefix(2).map { ($0 as? NSButton)?.title ?? "" } == [
                "New", "Open…"
            ]
                && shownSmall.allSatisfy { $0.frame.width >= ceil($0.intrinsicContentSize.width) - 0.5 }
                && shownSmall.map(\.stringValue) == Array(live.prefix(shownSmall.count)),
            "New and Open stay, and the rows that are shown are the first ones, each with its whole sentence: \(shownSmall.map(\.stringValue))"
        )
        check(
            shownSmall.count == 4,
            "the smallest group still names all four commands: \(shownSmall.count) rows of widths \(small.hintRows.map { ceil($0.intrinsicContentSize.width) }) in \(smallArea.bounds.width) points"
        )
        check(
            small.recentButtons.filter { !$0.isHidden }.count < EditorGroupSurface.recentLimit
                && small.recentButtons.filter { $0.isHidden }.allSatisfy { button in
                    !EditorGroupSurface.controls(in: smallArea).contains { $0 === button }
                },
            "recent files that do not fit are hidden and take no keyboard stop: \(small.recentButtons.filter { !$0.isHidden }.count) shown"
        )
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
