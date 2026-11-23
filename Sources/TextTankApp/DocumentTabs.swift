import TextTankCore
import EditorBridge
import NativeSearch
import AppKit

/// Native workspace chrome. This window never represents a document's lifetime.
final class DocumentTabWindow: NSWindow {
    var host: WorkspaceWindowController? { windowController as? WorkspaceWindowController }
    private var framePress: FrameTextClick?
    private var frameClickTimer: Timer?

    override func resignKey() {
        cancelFrameClick()
        super.resignKey()
        host?.tabStrips.forEach { $0.cancelReorder() }
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
        if event.type == .keyDown, event.keyCode == 53, host?.tabStrips.contains(where: { $0.isReordering }) == true {
            host?.tabStrips.forEach { $0.cancelReorder() }
            return
        }
        if attachedSheet == nil, [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
            host?.endBackgroundCloseReturn()
        }
        switch event.type {
        case .leftMouseDown:
            if event.clickCount == 1 { frameClickTimer?.fire() }
            cancelFrameClick()
            framePress = FrameTextClick(window: self, down: event)
        case .leftMouseDragged:
            cancelFrameClick()
        case .keyDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            frameClickTimer?.fire()
            cancelFrameClick()
        default:
            break
        }
        super.sendEvent(event)
        if let press = framePress, frameClickTimer == nil, let up = frameMouseUp(after: event) {
            guard up.locationInWindow == press.down.locationInWindow else {
                cancelFrameClick()
                return
            }
            // AppKit uses a double-click on this strip to expand the window. Give its
            // second down priority; a single followed by typing is committed above.
            let timer = Timer(
                fireAt: Date(timeIntervalSinceNow: NSEvent.doubleClickInterval), interval: 0,
                target: self, selector: #selector(commitFrameClick(_:)), userInfo: up, repeats: false)
            frameClickTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    private func frameMouseUp(after event: NSEvent) -> NSEvent? {
        if event.type == .leftMouseUp { return event }
        // Some AppKit versions consume the release inside the frame's native resize
        // tracking loop. Use that actual event only if it belongs to this press.
        guard event.type == .leftMouseDown, let up = currentEvent, up.type == .leftMouseUp,
            up.window === self, up.timestamp >= event.timestamp, up.eventNumber == event.eventNumber
        else { return nil }
        return up
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Main-menu shortcuts can run before the keyDown reaches sendEvent.
        if event.type == .keyDown { frameClickTimer?.fire() }
        return super.performKeyEquivalent(with: event)
    }
    @objc private func commitFrameClick(_ timer: Timer) {
        guard timer === frameClickTimer, let press = framePress, let up = timer.userInfo as? NSEvent else { return }
        cancelFrameClick()
        press.placeCaret(in: self, up: up)
    }
    private func cancelFrameClick() {
        framePress = nil
        frameClickTimer?.invalidate()
        frameClickTimer = nil
    }
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let previous = firstResponder
        let accepted = super.makeFirstResponder(responder)
        if firstResponder !== previous { cancelFrameClick() }
        return accepted
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

/// AppKit gives a resizable window's frame first refusal over text in its inside edge.
@MainActor private struct FrameTextClick {
    let down: NSEvent
    private let frame: NSRect
    private let view: NSView
    private let editor: TTEditor
    private let character: Int
    private let revision: UInt
    private enum Selection: Equatable {
        case stream(anchor: Int, caret: Int)
        case other(generation: UInt)
    }
    private let selection: Selection
    private let loadEpoch: UInt?

    init?(window: NSWindow, down: NSEvent) {
        guard down.clickCount == 1, down.modifierFlags.intersection([.control, .option, .command]).isEmpty,
            window.isKeyWindow, window.attachedSheet == nil, NSApp.modalWindow == nil,
            let root = window.contentView, let border = root.superview,
            border.hitTest(border.convert(down.locationInWindow, from: nil)) === border,
            let surface = root.hitTest(border.convert(down.locationInWindow, from: nil))
        else { return nil }
        let hit = (surface as? NSClipView)?.documentView ?? surface
        guard let editor = sequence(first: hit, next: { $0.superview }).first(where: { $0 is TTEditor }) as? TTEditor
        else { return nil }
        let byte = editor.characterByte(atWindowPoint: down.locationInWindow, inTextView: hit)
        guard byte != NSNotFound else { return nil }
        self.down = down
        frame = window.frame
        view = hit
        self.editor = editor
        character = byte
        revision = editor.revision
        // Scintilla may announce an earlier selection during the next repaint.
        // Compare the actual range for a single stream selection. For many ranges
        // keep the conservative generation check without copying them all.
        if editor.selectionCount == 1, editor.commandIsChecked(EditorCommand.streamSelection.nativeIdentifier) {
            selection = .stream(anchor: editor.selectionAnchor, caret: editor.selectionCaret)
        } else {
            selection = .other(generation: editor.selectionGeneration)
        }
        loadEpoch = EditorLifetime.document(for: editor)?.loadEpoch
    }

    func placeCaret(in window: NSWindow, up: NSEvent) {
        guard window.isKeyWindow, window.frame == frame, view.window === window,
            EditorLifetime.isOpen(editor), editor.revision == revision,
            let current = FrameTextClick(window: window, down: down),
            current.view === view, current.character == character, current.loadEpoch == loadEpoch,
            current.selection == selection,
            window.makeFirstResponder(view)
        else { return }
        view.mouseDown(with: down)
        view.mouseUp(with: up)
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
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard strip?.allowsSelection == true else { return [] }
        return super.accessibilityCustomActions()
    }
    /// `viewAction` is the tab's Source, Preview and Both step, named for what it will do. It is
    /// how the mark that appears under the pointer is reached without one (DS-73).
    func updateSelectionActions(
        selected: Bool, canToggle: Bool, viewAction: (name: String, mode: DocumentViewMode)? = nil
    ) {
        var actions: [NSAccessibilityCustomAction] = []
        if let viewAction {
            actions.append(
                NSAccessibilityCustomAction(name: viewAction.name) { [weak self] in
                    guard let self, let id = self.tabID else { return false }
                    return self.strip?.setViewMode(viewAction.mode, for: id) ?? false
                })
        }
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
/// The eye on a tab. It is an ordinary button: a press neither selects the tab nor starts a
/// reorder, because it never reaches the tab's own button.
private final class DocumentTabModeButton: NSButton {
    var tabID: TabID?
    weak var strip: DocumentTabStrip?
    override func menu(for event: NSEvent) -> NSMenu? { tabID.flatMap { strip?.contextMenu(for: $0) } }
    /// A Control-click is a context click here too, as it is on the tab's own button: it opens
    /// the tab's menu and does not change the mode.
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
            return
        }
        super.mouseDown(with: event)
    }
    override func rightMouseDown(with event: NSEvent) {
        if let tabID { strip?.showContextMenu(for: tabID, event: event, from: self) }
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
        let mode = DocumentTabModeButton()
        /// Nil for a document with no preview; otherwise what the tab shows.
        var viewMode: DocumentViewMode?
    }
    /// The tab the pointer is over, which shows its mark even in Source.
    private var hoveredTab: TabID?
    /// Where the pointer was last reported, in the strip's coordinates; nil when it is outside
    /// the strip or the window is not in use. Kept so that the hovered tab can be worked out
    /// again when the tabs move under a pointer that does not.
    private var pointer: NSPoint?
    private var hoverObservers: [NSObjectProtocol] = []
    /// Shows a tab's menu. Checks replace it so that no menu is tracked on the desktop.
    var presentContextMenu: (NSMenu, NSEvent, NSView) -> Void = { menu, event, view in
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
    private var hoverArea: NSTrackingArea?
    /// A tab narrower than this has no room for a mark that only appears under the pointer: its
    /// title would fall below the 82 points a tab at the minimum width has always had. The mark
    /// of a tab in Preview or Both is state, and is shown at every width.
    static let hoverMarkMinimumTabWidth: CGFloat = 162
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
    var groupSlot: GroupSlot = .first
    private var group: EditorGroup? { host?.model.groups.first { $0.slot == groupSlot } }
    var allowsSelection: Bool {
        guard let host else { return false }
        return !host.tabCommands.isBusy && host.window?.attachedSheet == nil
    }
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
        // A narrower tab may have lost the mark it showed under the pointer.
        publishAccessibilityChildren()
    }
    /// `revealingActive` is false for a change that is not about which tab is active (a tab's
    /// mode): the strip then keeps its scroll position.
    func refresh(revealingActive: Bool = true) {
        guard let host else { return }
        let tabs = (group?.tabs ?? []), ids = Set(tabs.map(\.id))
        if let reorder, reorder.tabs != tabs { cancelReorder() }
        for id in Array(controls.keys) where !ids.contains(id) {
            if let c = controls.removeValue(forKey: id) {
                ([c.background, c.select, c.mode, c.close] as [NSView]).forEach { $0.removeFromSuperview() }
            }
        }
        if let hoveredTab, !ids.contains(hoveredTab) { self.hoveredTab = nil }
        order = tabs.map(\.id)
        for tab in tabs {
            guard let presentation = host.presentation(for: tab.id), let doc = presentation.document as? TextDocument
            else { continue }
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
                c.mode.isBordered = false
                c.mode.imagePosition = .imageOnly
                c.mode.target = self
                c.mode.action = #selector(toggleTabViewMode(_:))
                c.mode.tabID = tab.id
                c.mode.strip = self
                c.mode.setAccessibilityParent(self)
                // An image-only, borderless button is otherwise reported without a role.
                c.mode.setAccessibilityElement(true)
                c.mode.setAccessibilityRole(.button)
                c.mode.identifier = NSUserInterfaceItemIdentifier("tab.viewMode." + tab.id.rawValue.uuidString)
                ([c.background, c.select, c.mode, c.close] as [NSView]).forEach { row.addSubview($0) }
            }
            let active = group?.activeTab == tab.id, name = doc.displayName ?? "Untitled"
            let selection = host.tabSelection.selected(in: host.model, group: groupSlot)
            let selected = selection.contains(tab.id)
            c.viewMode = host.tabCommands.viewMode(of: tab.id)
            c.select.updateSelectionActions(
                selected: selected, canToggle: !active || selection.count > 1,
                viewAction: c.viewMode.map { mode in
                    (
                        mode == .source
                            ? Strings.text("tabs.viewMode.action.both", "Show Preview Beside Source")
                            : Strings.text("tabs.viewMode.action.source", "Show Source"),
                        mode == .source ? .both : .source
                    )
                })
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
            // DS-14, DS-84: a tab that shows Preview or Both says so, in one whole label for each
            // combination with pinned and edited.
            if let mode = c.viewMode, mode != .source {
                c.select.setAccessibilityLabel(
                    String(
                        format: Self.viewModeLabel(
                            preview: mode == .preview, pinned: tab.isPinned, edited: doc.isDocumentEdited), name))
            }
            if let notice = doc.externalFile.notice {
                c.select.title += "  ◇"
                c.select.toolTip = name + " — " + notice
                c.select.setAccessibilityLabel((c.select.accessibilityLabel() ?? name) + ", " + notice)
            }
            if EditorServices.current?.compare?.isMarked(doc.runtimeID) == true {
                c.select.title += " ↔"
                c.select.setAccessibilityLabel((c.select.accessibilityLabel() ?? name) + ", selected for comparison")
            }
            // DS-70: the mark names the document and what a press will do; the tooltip says the same.
            let rendered = c.viewMode != nil && c.viewMode != .source
            let markLabel = String(
                format: rendered
                    ? Strings.text("tabs.viewMode.showSource", "Show source for %@")
                    : Strings.text("tabs.viewMode.showBoth", "Show preview beside source for %@"), name)
            c.mode.image = NSImage(systemSymbolName: rendered ? "eye.fill" : "eye", accessibilityDescription: nil)
            c.mode.toolTip = markLabel
            c.mode.setAccessibilityLabel(markLabel)
            c.mode.isEnabled = host.tabCommands.viewModeState(target: tab.id).enabled
            c.select.setAccessibilityHelp(
                "Command-click to change selection. Shift-click to select a range. Selection actions are also in the accessibility Actions menu."
            )
            c.select.identifier = NSUserInterfaceItemIdentifier("tab." + tab.id.rawValue.uuidString)
            c.close.toolTip = String(format: Strings.text("tabs.close", "Close %@"), name)
            c.close.setAccessibilityLabel(c.close.toolTip)
            c.close.isEnabled = host.tabCommands.state(.close, target: tab.id).enabled
        }
        layoutTabs(revealingActive: revealingActive)
        // A tab closed or moved under a still pointer: the tab now under it is the hovered one.
        rehover()
        publishAccessibilityChildren()
    }
    /// Each tab, then its mark while it is shown, then its close button, in the order they are
    /// drawn. A mark that is hidden is not offered: the tab's own actions and menu reach it.
    private func publishAccessibilityChildren() {
        let accessible = order.flatMap { id -> [NSView] in
            guard let c = controls[id] else { return [] }
            return c.mode.isHidden ? [c.select, c.close] : [c.select, c.mode, c.close]
        }
        setAccessibilityChildren(accessible)
        setAccessibilityChildrenInNavigationOrder(accessible)
    }
    private static func viewModeLabel(preview: Bool, pinned: Bool, edited: Bool) -> String {
        switch (preview, pinned, edited) {
        case (true, false, false): return Strings.text("tabs.preview", "%@, showing Preview")
        case (true, false, true): return Strings.text("tabs.previewEdited", "%@, edited, showing Preview")
        case (true, true, false): return Strings.text("tabs.previewPinned", "%@, pinned, showing Preview")
        case (true, true, true):
            return Strings.text("tabs.previewPinnedEdited", "%@, pinned, edited, showing Preview")
        case (false, false, false): return Strings.text("tabs.both", "%@, showing Source and Preview")
        case (false, false, true): return Strings.text("tabs.bothEdited", "%@, edited, showing Source and Preview")
        case (false, true, false): return Strings.text("tabs.bothPinned", "%@, pinned, showing Source and Preview")
        case (false, true, true):
            return Strings.text("tabs.bothPinnedEdited", "%@, pinned, edited, showing Source and Preview")
        }
    }
    /// Whether the tab shows its mark at `width`: always in Preview or Both; in Source only for
    /// a document with a preview, while the pointer is over the tab and the tab has room.
    private func showsMark(_ c: Controls, id: TabID, width: CGFloat) -> Bool {
        guard let mode = c.viewMode else { return false }
        return mode != .source || (hoveredTab == id && width >= Self.hoverMarkMinimumTabWidth)
    }
    /// `revealingActive` is false when only the pointer moved: showing a mark must not scroll
    /// the strip back to the active tab under the person's hand.
    private func layoutTabs(revealingActive: Bool = true) {
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
            // Four points separate the selection and close hit targets (DS-14/70/74). The mark,
            // when shown, is a third 28 by 28 target with the same four points on either side,
            // taken from the title, which truncates at its tail.
            let marked = showsMark(c, id: id, width: width)
            c.mode.isHidden = !marked
            c.select.frame = NSRect(x: x + 8, y: 0, width: width - (marked ? 80 : 48), height: 36)
            c.mode.frame = NSRect(x: x + width - 68, y: 4, width: 28, height: 28)
            c.close.frame = NSRect(x: x + width - 36, y: 4, width: 28, height: 28)
            if group?.activeTab == id { active = c.background.frame }
            x += width
        }
        row.frame = NSRect(x: 0, y: 0, width: max(x, bounds.width), height: 36)
        if revealingActive { row.scrollToVisible(active) }
    }
    func revealOrganizationChange(_ id: TabID) {
        guard let moved = controls[id]?.background.frame, let activeID = group?.activeTab,
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
            (group?.tabs ?? []).contains(where: { $0.id == id })
        else { return false }
        reorder = ReorderCapture(id: id, tabs: (group?.tabs ?? []))
        proposedIndex = nil
        return true
    }
    func updateReorder(at point: NSPoint) {
        guard bounds.contains(point) else {
            cancelReorder()
            return
        }
        guard let capture = reorder, capture.tabs == group?.tabs, bounds.contains(point),
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
        guard let capture, let destination, capture.tabs == group?.tabs else { return }
        host?.reorderTab(capture.id, to: destination)
    }
    func cancelReorder() {
        reorder = nil
        proposedIndex = nil
        dropIndicator.isHidden = true
    }
    // MARK: The mark for Source, Preview and Both

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { pointerMoved(to: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { pointerMoved(to: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { pointerMoved(to: nil) }
    /// `point` is in the strip's coordinates, or nil when the pointer has left the strip.
    func pointerMoved(to point: NSPoint?) {
        pointer = point.flatMap { bounds.contains($0) ? $0 : nil }
        rehover()
    }
    private func tabUnderPointer() -> TabID? {
        guard let pointer else { return nil }
        let p = row.convert(pointer, from: self)
        return order.first { controls[$0]?.background.frame.contains(p) == true }
    }
    /// Works out the hovered tab again from where the pointer was last seen. Called when the
    /// pointer moves and when the tabs move under it: the strip scrolled, a tab closed, tabs
    /// were reordered.
    private func rehover() {
        let over = tabUnderPointer()
        guard over != hoveredTab else { return }
        hoveredTab = over
        layoutTabs(revealingActive: false)
        publishAccessibilityChildren()
    }
    /// The window stopped being the key window, or TextTank stopped being the active app. No
    /// exit event is sent for a pointer that did not move, so the hover is dropped here.
    func pointerLeftWithWindow() { pointerMoved(to: nil) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hoverObservers.forEach(NotificationCenter.default.removeObserver)
        hoverObservers = []
        guard let window else {
            pointerMoved(to: nil)
            return
        }
        let center = NotificationCenter.default
        scroll.contentView.postsBoundsChangedNotifications = true
        hoverObservers = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.pointerLeftWithWindow() }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.pointerLeftWithWindow() }
            },
            center.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.rehover() }
            }
        ]
    }
    /// A Control-click on the mark, or a secondary click, opens the tab's menu.
    fileprivate func showContextMenu(for id: TabID, event: NSEvent, from view: NSView) {
        if let menu = contextMenu(for: id) { presentContextMenu(menu, event, view) }
    }
    /// The mark's own action: a tab in Preview or Both returns to Source, and a tab in Source
    /// shows Both. The tab is not selected.
    @objc private func toggleTabViewMode(_ sender: DocumentTabModeButton) {
        guard let id = sender.tabID, let mode = controls[id]?.viewMode else { return }
        setViewMode(mode == .source ? .both : .source, for: id)
    }
    @discardableResult func setViewMode(_ mode: DocumentViewMode, for id: TabID) -> Bool {
        host?.tabCommands.setViewMode(mode, target: id) ?? false
    }
    /// The frames of a tab's three controls and whether its mark is shown, for layout checks.
    func tabLayout(_ id: TabID) -> (title: NSRect, mark: NSRect, close: NSRect, markShown: Bool)? {
        guard let c = controls[id] else { return nil }
        return (c.select.frame, c.mode.frame, c.close.frame, !c.mode.isHidden)
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
        let chosen = host.tabSelection.selected(in: host.model, group: groupSlot)
        if let expectedSelected {
            guard chosen.contains(id) == expectedSelected,
                !(expectedSelected && chosen.count == 1 && group?.activeTab == id)
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
