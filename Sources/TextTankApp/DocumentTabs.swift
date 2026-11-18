import TextTankCore
import EditorBridge
import NativeSearch
import AppKit

/// Native workspace chrome. This window never represents a document's lifetime.
final class DocumentTabWindow: NSWindow {
    var host: WorkspaceWindowController? { windowController as? WorkspaceWindowController }
    override func resignKey() {
        super.resignKey()
        host?.tabStrip.cancelReorder()
    }
    override func becomeMain() {
        super.becomeMain()
        if let active = host?.active { EditorServices.current?.noteActiveController(active) }
    }
    private var routed = false
    func routeCloseButtonToQuit() {
        guard !routed, let button = standardWindowButton(.closeButton) else { return }
        routed = true
        button.target = self
        button.action = #selector(closeButtonPressed(_:))
        button.toolTip = "Quit TextTank. Documents with unsaved changes are reviewed first."
    }
    var closeButtonQuits: Bool { routed }
    @objc private func closeButtonPressed(_ sender: Any?) { RuntimeEnvironment.current.terminate(sender) }
    override func performClose(_ sender: Any?) { host?.closeActive(sender) }
    private var hasCloseTarget: Bool {
        host?.tabCommands.state(.close, target: host?.model.activeTab?.id).enabled == true
    }
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(performClose(_:)) { return hasCloseTarget }
        return super.validateMenuItem(item)
    }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(performClose(_:)) { return hasCloseTarget }
        return super.validateUserInterfaceItem(item)
    }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53, host?.tabStrip.isReordering == true {
            host?.tabStrip.cancelReorder()
            return
        }
        if attachedSheet == nil, [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
            host?.endBackgroundCloseReturn()
        }
        super.sendEvent(event)
    }
    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        host?.visibilityChanged()
    }
    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        host?.visibilityChanged()
    }
    override func orderFront(_ sender: Any?) {
        super.orderFront(sender)
        host?.visibilityChanged()
    }
    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        host?.visibilityChanged()
    }
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        super.order(place, relativeTo: otherWin)
        host?.visibilityChanged()
    }
}

private final class DocumentTabButton: NSButton {
    var tabID: TabID?
    weak var strip: DocumentTabStrip?
    override func menu(for event: NSEvent) -> NSMenu? { tabID.flatMap { strip?.contextMenu(for: $0) } }
    var allowsReorder = false
    private var downPoint: NSPoint?
    private var downModifiers: NSEvent.ModifierFlags = []
    private var moving = false
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
            return
        }
        guard allowsReorder else {
            super.mouseDown(with: event)
            return
        }
        downPoint = event.locationInWindow
        downModifiers = event.modifierFlags
        moving = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard allowsReorder, let start = downPoint, let id = tabID, let strip else { return }
        if !moving && hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 4 {
            moving = strip.beginReorder(id)
        }
        if moving { strip.updateReorder(at: strip.convert(event.locationInWindow, from: nil)) }
    }
    override func mouseUp(with event: NSEvent) {
        guard allowsReorder, downPoint != nil, let id = tabID, let strip else {
            super.mouseUp(with: event)
            return
        }
        if moving {
            strip.finishReorder(at: strip.convert(event.locationInWindow, from: nil))
        } else if bounds.contains(convert(event.locationInWindow, from: nil)) {
            strip.clickTab(id, modifiers: downModifiers)
        }
        downPoint = nil
        moving = false
    }
    func updateSelectionActions(selected: Bool, canToggle: Bool) {
        var actions: [NSAccessibilityCustomAction] = []
        if canToggle {
            actions.append(
                NSAccessibilityCustomAction(name: selected ? "Remove from Selection" : "Add to Selection") {
                    [weak self] in
                    guard let self, let id = self.tabID else { return false }
                    return self.strip?.accessibilitySelect(id, gesture: .toggle, expectedSelected: selected) ?? false
                })
        }
        actions.append(
            NSAccessibilityCustomAction(name: "Select Range from Active Tab") { [weak self] in
                guard let self, let id = self.tabID else { return false }
                return self.strip?.accessibilitySelect(id, gesture: .range) ?? false
            })
        setAccessibilityCustomActions(actions)
    }
    override func rightMouseDown(with event: NSEvent) {
        if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
    override func accessibilityPerformShowMenu() -> Bool {
        guard let tabID, let menu = strip?.contextMenu(for: tabID) else { return false }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY), in: self)
        return true
    }
}
private final class DocumentTabBackground: NSView {
    var tabID: TabID?
    weak var strip: DocumentTabStrip?
    override func menu(for event: NSEvent) -> NSMenu? { tabID.flatMap { strip?.contextMenu(for: $0) } }
    var active = false
    override func draw(_ dirtyRect: NSRect) {
        if !active {
            NSColor.selectedControlColor.setFill()
            bounds.fill()
            NSColor.labelColor.setStroke()
            let outline = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 3))
            outline.lineWidth = 1
            outline.stroke()
            return
        }
        NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
        bounds.fill()
        NSColor.controlAccentColor.setFill()
        NSRect(x: 0, y: isFlipped ? bounds.height - 3 : 0, width: bounds.width, height: 3).fill()
    }
}
private final class TabDropIndicator: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.setFill()
        bounds.fill()
    }
}
final class DocumentTabStrip: NSView {
    private let scroll = NSScrollView(), row = NSView()
    @MainActor private final class Controls {
        let background = DocumentTabBackground(), select = DocumentTabButton(), close = DocumentTabButton()
    }
    private var controls: [TabID: Controls] = [:]
    private var order: [TabID] = []
    private struct ReorderCapture {
        let id: TabID
        let tabs: [DocumentTab]
    }
    private var reorder: ReorderCapture?
    private var proposedIndex: Int?
    private let dropIndicator = TabDropIndicator()
    var isReordering: Bool { reorder != nil }
    var dropIndicatorVisible: Bool { !dropIndicator.isHidden }

    weak var host: WorkspaceWindowController?
    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = row
        addSubview(scroll)
        dropIndicator.isHidden = true
        dropIndicator.setAccessibilityElement(false)
        row.addSubview(dropIndicator)
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Documents")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
    override func layout() {
        super.layout()
        scroll.frame = bounds
        layoutTabs()
    }
    func refresh() {
        guard let host else { return }
        let tabs = host.model.groups.flatMap(\.tabs), ids = Set(tabs.map(\.id))
        if let reorder, reorder.tabs != tabs { cancelReorder() }
        for id in Array(controls.keys) where !ids.contains(id) {
            if let c = controls.removeValue(forKey: id) {
                ([c.background, c.select, c.close] as [NSView]).forEach { $0.removeFromSuperview() }
            }
        }
        order = tabs.map(\.id)
        for (tab, presentation) in zip(tabs, host.presentations) {
            guard let doc = presentation.document as? TextDocument else { continue }
            let c: Controls
            if let existing = controls[tab.id] {
                c = existing
            } else {
                c = Controls()
                controls[tab.id] = c
                c.select.isBordered = false
                c.select.alignment = .left
                c.select.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
                c.select.imagePosition = .imageLeading
                c.select.lineBreakMode = .byTruncatingTail
                c.select.target = self
                c.select.action = #selector(selectTab(_:))
                c.select.tabID = tab.id
                c.select.strip = self
                c.select.allowsReorder = true
                c.select.setAccessibilityParent(self)
                c.close.setAccessibilityParent(self)
                c.background.tabID = tab.id
                c.background.strip = self
                c.select.setAccessibilityRole(.radioButton)
                c.select.setAccessibilitySubrole(NSAccessibility.Subrole(rawValue: "AXTabButton"))
                c.close.isBordered = false
                c.close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
                c.close.target = self
                c.close.action = #selector(closeTab(_:))
                c.close.tabID = tab.id
                c.close.strip = self
                ([c.background, c.select, c.close] as [NSView]).forEach { row.addSubview($0) }
            }
            let active = host.model.activeTab?.id == tab.id, name = doc.displayName ?? "Untitled"
            let selection = host.tabSelection.selected(in: host.model, group: host.model.focusedGroup)
            let selected = selection.contains(tab.id)
            c.select.updateSelectionActions(selected: selected, canToggle: !active || selection.count > 1)
            c.background.active = active
            c.background.isHidden = !selected
            c.background.needsDisplay = true
            c.select.title = name + (doc.isDocumentEdited ? "  •" : "")
            c.select.font = .systemFont(ofSize: NSFont.systemFontSize, weight: active ? .semibold : .regular)
            c.select.toolTip = name
            c.select.setAccessibilityValue(NSNumber(value: selected))
            c.select.setAccessibilitySelected(selected)
            c.select.setAccessibilityLabel(
                doc.isDocumentEdited ? String(format: Strings.text("tabs.edited", "%@, edited"), name) : name)
            c.select.image = NSImage(
                systemSymbolName: tab.isPinned ? "pin.fill" : "doc.text",
                accessibilityDescription: tab.isPinned ? "Pinned" : nil)
            if tab.isPinned {
                c.select.setAccessibilityLabel(
                    doc.isDocumentEdited
                        ? String(format: Strings.text("tabs.pinnedEdited", "%@, pinned, edited"), name)
                        : String(format: Strings.text("tabs.pinned", "%@, pinned"), name))
            }
            c.select.setAccessibilityHelp(
                "Command-click to change selection. Shift-click to select a range. Selection actions are also in the accessibility Actions menu."
            )
            c.select.identifier = NSUserInterfaceItemIdentifier("tab." + tab.id.rawValue.uuidString)
            c.close.toolTip = String(format: Strings.text("tabs.close", "Close %@"), name)
            c.close.setAccessibilityLabel(c.close.toolTip)
            c.close.isEnabled = host.tabCommands.state(.close, target: tab.id).enabled
        }
        let accessible = order.flatMap { id -> [NSView] in
            guard let c = controls[id] else { return [] }
            return [c.select, c.close]
        }
        setAccessibilityChildren(accessible)
        setAccessibilityChildrenInNavigationOrder(accessible)
        layoutTabs()
    }
    private func layoutTabs() {
        guard !order.isEmpty else {
            row.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 36)
            return
        }
        let preferred: CGFloat = 220, minimum: CGFloat = 130
        let width = max(minimum, min(preferred, bounds.width / CGFloat(order.count)))
        var x: CGFloat = 0, active = NSRect.zero
        for id in order {
            guard let c = controls[id] else { continue }
            c.background.frame = NSRect(x: x, y: 0, width: width, height: 36)
            // Four points separate the selection and close hit targets (DS-14/70/74).
            c.select.frame = NSRect(x: x + 8, y: 0, width: width - 48, height: 36)
            c.close.frame = NSRect(x: x + width - 36, y: 4, width: 28, height: 28)
            if host?.model.activeTab?.id == id { active = c.background.frame }
            x += width
        }
        row.frame = NSRect(x: 0, y: 0, width: max(x, bounds.width), height: 36)
        row.scrollToVisible(active)
    }
    func revealOrganizationChange(_ id: TabID) {
        guard let moved = controls[id]?.background.frame, let activeID = host?.model.activeTab?.id,
            let active = controls[activeID]?.background.frame
        else { return }
        let combined = moved.union(active)
        row.scrollToVisible(combined.width <= scroll.contentView.bounds.width ? combined : active)
    }
    func isTabHorizontallyVisible(_ id: TabID) -> Bool {
        guard let rect = controls[id]?.background.frame else { return false }
        let visible = scroll.contentView.bounds
        return rect.minX >= visible.minX - 1 && rect.maxX <= visible.maxX + 1
    }
    @discardableResult func beginReorder(_ id: TabID) -> Bool {
        guard let host, host.tabCommands.state(.pin, target: id).enabled,
            host.model.groups.flatMap(\.tabs).contains(where: { $0.id == id })
        else { return false }
        reorder = ReorderCapture(id: id, tabs: host.model.groups.flatMap(\.tabs))
        proposedIndex = nil
        return true
    }
    func updateReorder(at point: NSPoint) {
        guard bounds.contains(point) else {
            cancelReorder()
            return
        }
        guard let capture = reorder, capture.tabs == host?.model.groups.flatMap(\.tabs), bounds.contains(point),
            let old = capture.tabs.firstIndex(where: { $0.id == capture.id })
        else {
            proposedIndex = nil
            dropIndicator.isHidden = true
            return
        }
        let p = row.convert(point, from: self)
        let slot = order.prefix { (controls[$0]?.background.frame.midX ?? 0) < p.x }.count
        let raw = slot > old ? slot - 1 : slot
        let prefix = capture.tabs.prefix { $0.isPinned }.count
        let lower = capture.tabs[old].isPinned ? 0 : prefix
        let upper = capture.tabs[old].isPinned ? prefix - 1 : capture.tabs.count - 1
        let final = min(upper, max(lower, raw))
        proposedIndex = final
        let insertion = final > old ? final + 1 : final
        let x =
            insertion == order.count
            ? (order.last.flatMap { controls[$0]?.background.frame.maxX } ?? 0)
            : (controls[order[insertion]]?.background.frame.minX ?? 0)
        dropIndicator.frame = NSRect(x: x - 1, y: 0, width: 2, height: 36)
        row.addSubview(dropIndicator, positioned: .above, relativeTo: nil)
        dropIndicator.isHidden = false
    }
    func finishReorder(at point: NSPoint) {
        updateReorder(at: point)
        let capture = reorder, destination = proposedIndex
        cancelReorder()
        guard let capture, let destination, capture.tabs == host?.model.groups.flatMap(\.tabs) else { return }
        host?.reorderTab(capture.id, to: destination)
    }
    func cancelReorder() {
        reorder = nil
        proposedIndex = nil
        dropIndicator.isHidden = true
    }
    func contextMenu(for id: TabID) -> NSMenu? { host?.tabCommands.contextMenu(for: id) }
    func clickTab(_ id: TabID, modifiers: NSEvent.ModifierFlags = []) {
        let gesture: TabSelectionGesture =
            modifiers.contains(.shift) ? .range : modifiers.contains(.command) ? .toggle : .plain
        host?.selectTab(id, gesture: gesture)
    }
    func accessibilitySelect(
        _ id: TabID, gesture: TabSelectionGesture, expectedSelected: Bool? = nil
    ) -> Bool {
        guard let host, host.presentation(for: id) != nil else { return false }
        let chosen = host.tabSelection.selected(in: host.model, group: host.model.focusedGroup)
        if let expectedSelected {
            guard chosen.contains(id) == expectedSelected,
                !(expectedSelected && chosen.count == 1 && host.model.activeTab?.id == id)
            else { return false }
        }
        return host.selectTab(id, gesture: gesture)
    }
    @objc private func selectTab(_ sender: DocumentTabButton) {
        if let id = sender.tabID { clickTab(id) }
    }
    @objc private func closeTab(_ sender: DocumentTabButton) {
        if let id = sender.tabID { host?.closeTab(id, sender: sender) }
    }
}
