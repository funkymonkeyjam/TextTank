import AppKit
import TextTankCore

/// One command owner for View, the trailing picker and captured tab menus (DS-20-24).
@MainActor final class GroupCommandController: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private unowned let host: WorkspaceWindowController
    private weak var viewMenu: NSMenu?
    private enum Action { case layout(LayoutKind), move, additional, close, focus }
    @MainActor private final class Invocation: NSObject {
        nonisolated let commandID: String
        nonisolated override var description: String { commandID }
        let action: Action
        let target: TabID?
        let source: GroupSlot
        let sourceToken: UUID?
        let members: [TabID]
        let destination: GroupSlot?
        let destinationToken: UUID?
        init(_ action: Action, host: WorkspaceWindowController, target: TabID?, destination: GroupSlot? = nil) {
            switch action {
            case .layout(let layout): commandID = "group.layout." + layout.rawValue
            case .move: commandID = "group.move"
            case .additional: commandID = "group.additional"
            case .close: commandID = "group.close"
            case .focus: commandID = "group.focus"
            }
            self.action = action
            self.target = target
            self.destination = destination
            let sourceSlot =
                host.model.groups.first(where: { $0.tabs.contains { $0.id == target } })?.slot
                ?? host.model.focusedGroup
            source = sourceSlot
            sourceToken = host.groupSurfaces[sourceSlot]?.generation
            let capture = target.flatMap { host.tabCommands.capture($0) }?.members(in: host.model) ?? []
            members =
                host.model.groups.first { $0.slot == sourceSlot }?.tabs.filter { capture.contains($0.id) }.map(\.id)
                ?? []
            destinationToken = destination.flatMap { host.groupSurfaces[$0]?.generation }
        }
    }
    init(host: WorkspaceWindowController) { self.host = host }
    func install(in menu: NSMenu) {
        viewMenu = menu
        menu.delegate = self
        refreshViewMenu()
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === viewMenu {
            refreshViewMenu()
        } else {
            for item in menu.items { item.isEnabled = validateMenuItem(item) }
        }
    }
    func refreshViewMenu() {
        guard let menu = viewMenu else { return }
        for item in menu.items where item.identifier?.rawValue.hasPrefix("groups.") == true { menu.removeItem(item) }
        let separator = NSMenuItem.separator()
        separator.identifier = .init("groups.separator")
        menu.addItem(separator)
        for item in items(target: host.model.activeTab?.id, includeLayout: true, includeFocus: true) {
            menu.addItem(item)
        }
    }
    func contextMenu(for target: TabID) -> NSMenu {
        let menu = NSMenu(title: "Editor Groups")
        items(target: target, includeLayout: false, includeFocus: false).forEach { menu.addItem($0) }
        return menu
    }
    static func title(_ layout: LayoutKind) -> String {
        switch layout {
        case .single: return "Single Group"
        case .twoColumns: return "Two Columns"
        case .twoRows: return "Two Rows"
        case .grid2x2: return "Grid (2 × 2)"
        }
    }
    static func diagram(_ layout: LayoutKind) -> NSImage {
        let image = NSImage(size: NSSize(width: 28, height: 18), flipped: false) { rect in
            NSColor.labelColor.setStroke()
            NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1)).stroke()
            let path = NSBezierPath()
            if layout == .twoColumns || layout == .grid2x2 {
                path.move(to: NSPoint(x: 14, y: 1))
                path.line(to: NSPoint(x: 14, y: 17))
            }
            if layout == .twoRows || layout == .grid2x2 {
                path.move(to: NSPoint(x: 1, y: 9))
                path.line(to: NSPoint(x: 27, y: 9))
            }
            path.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = title(layout)
        return image
    }
    func layoutMenu(picker: Bool = false) -> NSMenu {
        let menu = NSMenu(title: "Editor Group Layout")
        if picker { menu.addItem(withTitle: "Editor Group Layout", action: nil, keyEquivalent: "") }
        for layout in LayoutKind.allCases {
            let item = make(
                Self.title(layout), Invocation(.layout(layout), host: host, target: nil),
                id: "layout." + layout.rawValue)
            item.image = Self.diagram(layout)
            item.state = host.model.layout == layout ? .on : .off
            menu.addItem(item)
        }
        menu.delegate = self
        return menu
    }
    private func make(_ title: String, _ call: Invocation, id: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(invoke(_:)), keyEquivalent: "")
        if case .focus = call.action, let slot = call.destination {
            let key = MenuShortcut.focusGroup(slot)
            item.keyEquivalent = key.key
            item.keyEquivalentModifierMask = key.appKitModifiers
        }
        item.target = self
        item.representedObject = call
        item.identifier = .init("groups." + id)
        item.isEnabled = validateMenuItem(item)
        return item
    }
    private func items(target: TabID?, includeLayout: Bool, includeFocus: Bool) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if includeLayout {
            let item = NSMenuItem(title: "Editor Group Layout", action: nil, keyEquivalent: "")
            item.submenu = layoutMenu()
            item.identifier = .init("groups.layout")
            items.append(item)
        }
        let source = host.model.groups.first { $0.tabs.contains { $0.id == target } }?.slot ?? host.model.focusedGroup
        let capture = target.flatMap { host.tabCommands.capture($0) }?.members(in: host.model) ?? []
        let moveTitle = capture.count > 1 ? String(format: "Move %ld Tabs to Group", capture.count) : "Move to Group"
        for (title, action, id) in [
            (moveTitle, Action.move, "move"), ("Show Tab in Another Group", Action.additional, "additional")
        ] {
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            parent.identifier = .init("groups." + id)
            let submenu = NSMenu(title: title)
            for group in host.model.groups where group.slot != source {
                submenu.addItem(
                    make(
                        host.groupLabel(group.slot),
                        Invocation(action, host: host, target: target, destination: group.slot),
                        id: id + ".\(group.slot.rawValue)"))
            }
            parent.submenu = submenu
            parent.isEnabled = !submenu.items.isEmpty && target != nil
            items.append(parent)
        }
        let next = GroupSlot(rawValue: source.rawValue % host.model.groups.count + 1)!
        let title =
            capture.count > 1 ? String(format: "Move %ld Tabs to Next Group", capture.count) : "Move Tab to Next Group"
        items.append(make(title, Invocation(.move, host: host, target: target, destination: next), id: "next"))
        items.append(make("Close Group", Invocation(.close, host: host, target: target), id: "close"))
        if includeFocus {
            let parent = NSMenuItem(title: "Focus Group", action: nil, keyEquivalent: "")
            parent.identifier = .init("groups.focus")
            let submenu = NSMenu(title: "Focus Group")
            for group in host.model.groups {
                submenu.addItem(
                    make(
                        host.groupLabel(group.slot),
                        Invocation(.focus, host: host, target: nil, destination: group.slot),
                        id: "focus.\(group.slot.rawValue)"))
            }
            parent.submenu = submenu
            items.append(parent)
        }
        return items
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard !CompareCommandScope.blocksWorkspace else { return false }
        guard let call = item.representedObject as? Invocation else { return item.action == nil }
        guard !host.isMutatingGroups, !host.tabCommands.isBusy, !host.tabCommands.isReopening,
            host.window?.attachedSheet == nil
        else { return false }
        if case .layout(let layout) = call.action {
            item.state = host.model.layout == layout ? .on : .off
            return true
        }
        if case .focus = call.action {
            item.state = host.model.focusedGroup == call.destination ? .on : .off
            return call.destination.flatMap { host.groupSurfaces[$0]?.generation } == call.destinationToken
                && call.destinationToken != nil
        }
        guard host.groupSurfaces[call.source]?.generation == call.sourceToken,
            let group = host.model.groups.first(where: { $0.slot == call.source })
        else { return false }
        if case .close = call.action {
            return host.model.layout != .single && (host.model.layout != .grid2x2 || !group.tabs.isEmpty)
        }
        guard let target = call.target, group.tabs.contains(where: { $0.id == target }), host.model.layout != .single,
            let destination = call.destination, destination != call.source,
            host.groupSurfaces[destination]?.generation == call.destinationToken, call.destinationToken != nil
        else { return false }
        if case .move = call.action {
            return !call.members.isEmpty && Set(call.members).isSubset(of: Set(group.tabs.map(\.id)))
        }
        return true
    }
    @objc private func invoke(_ item: NSMenuItem) {
        guard validateMenuItem(item), let call = item.representedObject as? Invocation else { return }
        switch call.action {
        case .layout(let layout): _ = host.setEditorLayout(layout)
        case .focus: if let slot = call.destination { host.focusGroup(slot) }
        case .close: host.closeEditorGroup(call.source)
        case .move:
            if let target = call.target, let slot = call.destination {
                host.moveTabs(call.members, target: target, to: slot)
            }
        case .additional:
            if let target = call.target, let slot = call.destination { _ = host.openView(target, in: slot) }
        }
    }
}
