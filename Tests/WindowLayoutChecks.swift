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
