import TextTankCore
import EditorBridge
import NativeSearch
import AppKit

/// Finder file URLs open documents through the same controller as File > Open. Read only
/// the declared file flavor; dragging selected text or a web link keeps its native behavior.
@MainActor final class WorkspaceFileDrop {
    private var openAfterDrag: (@MainActor @Sendable () async -> Void)?
    static func containsFiles(_ drag: NSDraggingInfo) -> Bool {
        drag.draggingPasteboard.types?.contains(.fileURL) == true
    }
    static func operation(_ drag: NSDraggingInfo, in view: NSView) -> NSDragOperation {
        guard containsFiles(drag), drag.draggingSourceOperationMask.contains(.copy),
            let host = view.window?.windowController as? WorkspaceWindowController,
            host.acceptsDocumentCreation, host.window?.attachedSheet == nil, NSApp.modalWindow == nil
        else { return [] }
        return .copy
    }
    func capture(_ drag: NSDraggingInfo, in view: NSView) -> Bool {
        guard Self.operation(drag, in: view) == .copy,
            let host = view.window?.windowController as? WorkspaceWindowController,
            let urls = drag.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
            !urls.isEmpty
        else { return false }
        // Capture the group under the pointer; the sidebar and other chrome use the focused group.
        let position = drag.draggingLocation
        let group = host.groupSurfaces.values.first { $0.bounds.contains($0.convert(position, from: nil)) }?.slot
        openAfterDrag = {
            if let group { host.focusGroup(group) }
            for url in urls {
                do { _ = try await NSDocumentController.shared.openDocument(withContentsOf: url, display: true) } catch
                {
                    let failure = error as NSError
                    if failure.domain != NSCocoaErrorDomain || failure.code != NSUserCancelledError {
                        NSApp.presentError(error)
                    }
                }
            }
        }
        return true
    }

    // AppKit has concluded the drop. Only now may opening a document unmount the view under
    // the pointer. Both completion callbacks can arrive; a captured drop is consumed once.
    func finish() {
        guard let open = openAfterDrag else { return }
        openAfterDrag = nil
        RunLoop.main.perform(inModes: [.default]) {
            Task { @MainActor in await open() }
        }
    }
}

/// AppKit picks the nearest registered destination above the hit view. This fallback covers
/// the empty workspace, tab chrome, sidebar, and margins. A source editor handles its own drops.
class WorkspaceFileDropView: NSView {
    private let fileDrop = WorkspaceFileDrop()
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        WorkspaceFileDrop.operation(sender, in: self)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        fileDrop.capture(sender, in: self)
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { fileDrop.finish() }
    override func draggingEnded(_ sender: NSDraggingInfo) { fileDrop.finish() }
}

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
    // An incoming drag from another app is negotiated out of band. Ordinary mouse events
    // that the workspace actually dispatches must always reach the web content underneath.
    private(set) var dispatchingPointerEvent = false
    override func sendEvent(_ event: NSEvent) {
        let previous = dispatchingPointerEvent
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp,
            .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged, .mouseMoved,
            .mouseEntered, .mouseExited, .scrollWheel, .cursorUpdate, .pressure, .magnify, .rotate, .swipe:
            dispatchingPointerEvent = true
        default:
            break
        }
        defer { dispatchingPointerEvent = previous }

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
    /// Called when the button gains or loses the keyboard. The close button of an edited tab
    /// shows its cross while it has the keyboard, as it does under the pointer.
    var keyboardFocusChanged: ((Bool) -> Void)?
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { keyboardFocusChanged?(true) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { keyboardFocusChanged?(false) }
        return resigned
    }
    private var downPoint: NSPoint?
    private var downModifiers: NSEvent.ModifierFlags = []
    private var moving = false
    /// The state symbol a press began on, when it did not begin on the title itself.
    private weak var pressOrigin: NSView?
    /// A press on one of the tab's state symbols: a click selects the tab and a drag reorders it,
    /// exactly as on the title.
    func mouseDown(with event: NSEvent, from symbol: NSView) {
        mouseDown(with: event)
        if downPoint != nil { pressOrigin = symbol }
    }
    override func mouseDown(with event: NSEvent) {
        pressOrigin = nil
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
        let pressed: NSView = pressOrigin ?? self
        if moving {
            strip.finishReorder(at: strip.convert(event.locationInWindow, from: nil))
        } else if pressed.bounds.contains(pressed.convert(event.locationInWindow, from: nil)) {
            strip.clickTab(id, modifiers: downModifiers)
        }
        downPoint = nil
        pressOrigin = nil
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
        if let tabID { strip?.showContextMenu(for: tabID, event: event, from: self) }
    }
    override func accessibilityPerformShowMenu() -> Bool {
        guard let tabID, let strip, let menu = strip.contextMenu(for: tabID) else { return false }
        strip.presentAccessibilityMenu(menu, self)
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
/// A symbol beside a tab's title for a state the title used to carry as a character: the file
/// changed outside TextTank, or the document is selected for comparison. It is a shape with a
/// tooltip, so the state is not carried by colour (DS-62). A press on it is a press on its tab's
/// title: a click selects the tab and a drag reorders it. It is not an accessibility element:
/// the tab's own label says the same thing in words (DS-14, DS-84).
private final class DocumentTabStateMark: NSImageView {
    var tabID: TabID?
    weak var strip: DocumentTabStrip?
    /// The tab's own button, which owns the click and the reorder gesture.
    weak var title: DocumentTabButton?
    private var forwarding = false
    override func menu(for event: NSEvent) -> NSMenu? { tabID.flatMap { strip?.contextMenu(for: $0) } }
    override func mouseDown(with event: NSEvent) {
        forwarding = !event.modifierFlags.contains(.control)
        if forwarding { title?.mouseDown(with: event, from: self) } else { rightMouseDown(with: event) }
    }
    override func mouseDragged(with event: NSEvent) {
        if forwarding { title?.mouseDragged(with: event) }
    }
    override func mouseUp(with event: NSEvent) {
        guard forwarding else { return }
        forwarding = false
        title?.mouseUp(with: event)
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
/// Block observers are not removed when their owner goes; this removes them.
private final class ObserverBag {
    var tokens: [NSObjectProtocol] = []
    func removeAll() {
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = []
    }
    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}
final class DocumentTabStrip: NSView {
    private let scroll = NSScrollView(), row = NSView()
    /// The list of this group's open tabs, shown only while the tabs overflow the strip. It sits
    /// at the trailing end, outside the scrolling area, as a 28 by 28 target four points from the
    /// tabs (DS-14, DS-74).
    private let overflow = NSPopUpButton(frame: .zero, pullsDown: true)
    /// The width a tab never goes below; the strip scrolls instead.
    static let minimumTabWidth: CGFloat = 130
    /// What the list of open tabs takes from the strip while it is shown: the 28-point button
    /// with four points on either side.
    static let overflowReserve: CGFloat = 36
    /// True while the tabs do not fit at the minimum width, so the strip scrolls.
    private var overflowing: Bool { CGFloat(order.count) * Self.minimumTabWidth > bounds.width }
    var showsOpenTabList: Bool { !overflow.isHidden }
    var openTabListFrame: NSRect { overflow.frame }
    var openTabListButton: NSPopUpButton { overflow }
    @MainActor private final class Controls {
        let background = DocumentTabBackground(), select = DocumentTabButton(), close = DocumentTabButton()
        let mode = DocumentTabModeButton()
        let outsideChange = DocumentTabStateMark(), comparison = DocumentTabStateMark()
        /// Nil for a document with no preview; otherwise what the tab shows.
        var viewMode: DocumentViewMode?
        var edited = false, changedOutside = false, compared = false
        /// What the close button draws: nil until it is first laid out.
        var closeShowsEditedDot: Bool?
        var views: [NSView] { [background, select, outsideChange, comparison, mode, close] }
    }
    /// What a tab draws, for checks: its title, its tooltip, whether the close button shows the
    /// edited dot instead of the cross, and its state symbols with their frames when shown.
    struct TabAppearance {
        let title: String
        let toolTip: String?
        let accessibilityLabel: String?
        let closeShowsEditedDot: Bool
        let outsideChange: (frame: NSRect, toolTip: String?, isAccessibilityElement: Bool)?
        let comparison: (frame: NSRect, toolTip: String?, isAccessibilityElement: Bool)?
    }
    func tabAppearance(_ id: TabID) -> TabAppearance? {
        guard let c = controls[id] else { return nil }
        func mark(_ view: DocumentTabStateMark) -> (frame: NSRect, toolTip: String?, isAccessibilityElement: Bool)? {
            view.isHidden
                ? nil
                : (
                    view.frame, view.toolTip,
                    view.isAccessibilityElement() || view.cell?.isAccessibilityElement() == true
                )
        }
        return TabAppearance(
            title: c.select.title, toolTip: c.select.toolTip, accessibilityLabel: c.select.accessibilityLabel(),
            closeShowsEditedDot: c.closeShowsEditedDot == true,
            outsideChange: mark(c.outsideChange), comparison: mark(c.comparison))
    }
    /// The tab whose close button has the keyboard.
    private var closeWithKeyboard: TabID?
    /// With a state symbol beside it, a title keeps at least this much: what a tab at the minimum
    /// width keeps beside the eye of a tab in Preview or Both.
    static let minimumTitleWidthBesideComparisonMark: CGFloat = 50
    /// The width a tab in Source keeps for its title when the pointer brings up its eye.
    private static let titleWidthBesideHoverMark: CGFloat = 82
    /// The tab the pointer is over, which shows its mark even in Source.
    private var hoveredTab: TabID?
    /// Where the pointer was last reported, in the strip's coordinates; nil when it is outside
    /// the strip or the window is not in use. Kept so that the hovered tab can be worked out
    /// again when the tabs move under a pointer that does not.
    private var pointer: NSPoint?
    /// Notification observers that end with the strip, and those that end when it leaves its
    /// window. Each bag removes what it holds when it is emptied and when it is released.
    private let lifetimeObservers = ObserverBag(), windowObservers = ObserverBag()
    /// How many notification observers the strip has registered, for checks.
    var observerCount: Int { lifetimeObservers.tokens.count + windowObservers.tokens.count }
    var observerBags: [AnyObject] { [lifetimeObservers, windowObservers] }
    /// Shows a tab's menu. Checks replace it so that no menu is tracked on the desktop.
    var presentContextMenu: (NSMenu, NSEvent, NSView) -> Void = { menu, event, view in
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
    /// Shows a tab's menu for the accessibility Show Menu action, below the tab. Checks replace
    /// it for the same reason.
    var presentAccessibilityMenu: (NSMenu, NSView) -> Void = { menu, view in
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY), in: view)
    }
    /// Where the pointer is now, in the window's coordinates, or nil when it is not over this
    /// window. Checks replace it; otherwise the window is asked while it is the key window of the
    /// active application, the only time the strip tracks the pointer at all.
    var pointerLocationInWindow: (() -> NSPoint?)?
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
        // No scroller. With "Show scroll bars: Always" (and on a Mac with no trackpad) a scroller is
        // not an overlay: it would take its height from a 36-point strip and cut the tabs off.
        // The strip still scrolls with the wheel or trackpad, selecting a tab reveals it, and
        // the list of open tabs reaches every tab.
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.documentView = row
        addSubview(scroll)
        scroll.contentView.postsBoundsChangedNotifications = true
        lifetimeObservers.tokens.append(
            NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.rehover() } })
        dropIndicator.isHidden = true
        dropIndicator.setAccessibilityElement(false)
        row.addSubview(dropIndicator)
        // DS-11: a system pull-down, drawn as its symbol alone.
        overflow.isBordered = false
        overflow.imagePosition = .imageOnly
        (overflow.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        let title = NSMenuItem()
        title.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(title)
        overflow.menu = menu
        let label = Strings.text("tabs.openTabs", "Open tabs in this group")
        overflow.toolTip = label
        overflow.setAccessibilityLabel(label)
        overflow.setAccessibilityParent(self)
        overflow.identifier = NSUserInterfaceItemIdentifier("tabs.openTabs")
        overflow.isHidden = true
        addSubview(overflow)
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Documents")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
    override func layout() {
        super.layout()
        layoutTabs()
        // The tabs moved or changed width under a pointer that did not.
        repoint()
        // A narrower tab may have lost the mark it showed under the pointer.
        publishAccessibilityChildren()
    }
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        let moved = newOrigin != frame.origin
        super.setFrameOrigin(newOrigin)
        if moved { repoint() }
    }
    /// The strip moved or was laid out again without the pointer moving: the sidebar or the group
    /// layout changed from the keyboard. The remembered position is in the strip's coordinates
    /// and is now wrong, so the pointer is asked for again. A window that is not the key window
    /// of the active application has no hover to correct.
    private func repoint() {
        if let location = pointerLocationInWindow {
            pointerMoved(to: location().map { convert($0, from: nil) })
        } else if let window, window.isKeyWindow, NSApp.isActive {
            pointerMoved(to: convert(window.mouseLocationOutsideOfEventStream, from: nil))
        } else {
            rehover()
        }
    }
    /// `revealingActive` is false for a change that is not about which tab is active (a tab's
    /// mode): the strip then keeps its scroll position.
    func refresh(revealingActive: Bool = true) {
        guard let host else { return }
        let tabs = (group?.tabs ?? []), ids = Set(tabs.map(\.id))
        if let reorder, reorder.tabs != tabs { cancelReorder() }
        for id in Array(controls.keys) where !ids.contains(id) {
            if let c = controls.removeValue(forKey: id) {
                c.views.forEach { $0.removeFromSuperview() }
            }
        }
        if let hoveredTab, !ids.contains(hoveredTab) { self.hoveredTab = nil }
        if let closeWithKeyboard, !ids.contains(closeWithKeyboard) { self.closeWithKeyboard = nil }
        // A click pair that spans a change of tabs is not a double-click on the empty strip.
        if order != tabs.map(\.id) { forgetEmptyPress() }
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
                c.close.target = self
                c.close.action = #selector(closeTab(_:))
                c.close.tabID = tab.id
                c.close.strip = self
                c.close.keyboardFocusChanged = { [weak self, weak close = c.close] focused in
                    guard let self, let close else { return }
                    if focused {
                        self.closeWithKeyboard = close.tabID
                    } else if self.closeWithKeyboard == close.tabID {
                        self.closeWithKeyboard = nil
                    }
                    self.layoutTabs(revealingActive: false)
                }
                for (mark, symbol) in [
                    (c.outsideChange, "exclamationmark.triangle"), (c.comparison, "arrow.left.arrow.right")
                ] {
                    mark.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                    mark.imageScaling = .scaleProportionallyDown
                    // DS-60, DS-61: the label colour, so the symbol has the contrast of the title.
                    mark.contentTintColor = .labelColor
                    mark.tabID = tab.id
                    mark.strip = self
                    mark.title = c.select
                    mark.isHidden = true
                    // 2: not an element. The tab's own label carries the state, so it is said
                    // once, and the strip's published children stay the whole of what is offered.
                    mark.setAccessibilityElement(false)
                    mark.cell?.setAccessibilityElement(false)
                }
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
                c.views.forEach { row.addSubview($0) }
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
            // The title is the name alone. Edited is the dot in the close button's place; an outside
            // change and a selection for comparison are symbols beside the title (DS-62).
            let notice = doc.externalFile.notice
            let compared = EditorServices.current?.compare?.isMarked(doc.runtimeID) == true
            c.edited = doc.isDocumentEdited
            c.changedOutside = notice != nil
            c.compared = compared
            c.select.title = name
            c.select.font = .systemFont(ofSize: NSFont.systemFontSize, weight: active ? .semibold : .regular)
            c.select.toolTip = Self.tabToolTip(name: name, path: doc.fileURL?.path, notice: notice)
            c.select.setAccessibilityValue(NSNumber(value: selected))
            c.select.setAccessibilitySelected(selected)
            c.select.image = NSImage(
                systemSymbolName: tab.isPinned ? "pin.fill" : "doc.text",
                accessibilityDescription: tab.isPinned ? "Pinned" : nil)
            // DS-14, DS-84: one whole label for each combination of what the tab shows, pinned and
            // edited, and one whole sentence around it for an outside change and for comparison.
            let stateLabel = String(
                format: Self.tabLabel(mode: c.viewMode ?? .source, pinned: tab.isPinned, edited: doc.isDocumentEdited),
                name)
            switch (notice, compared) {
            case (nil, false): c.select.setAccessibilityLabel(stateLabel)
            case (let notice?, false):
                c.select.setAccessibilityLabel(
                    String(format: Strings.text("tabs.label.outsideChange", "%1$@. %2$@."), stateLabel, notice))
            case (nil, true):
                c.select.setAccessibilityLabel(
                    String(format: Strings.text("tabs.label.compared", "%@. Selected for comparison."), stateLabel))
            case (let notice?, true):
                c.select.setAccessibilityLabel(
                    String(
                        format: Strings.text(
                            "tabs.label.outsideChangeCompared", "%1$@. %2$@. Selected for comparison."),
                        stateLabel, notice))
            }
            // DS-70, DS-85: each symbol says what it means and what to do about it.
            let outsideText = String(
                format: Strings.text("tabs.mark.outsideChange", "%1$@: %2$@. Select this tab to choose what to do."),
                name, notice ?? "")
            c.outsideChange.toolTip = notice == nil ? nil : outsideText
            let comparedText = String(
                format: Strings.text(
                    "tabs.mark.compared",
                    "%@ is selected for comparison. Choose Compare with Selected on another tab to compare them."),
                name)
            c.comparison.toolTip = compared ? comparedText : nil
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
        let accessible =
            order.flatMap { id -> [NSView] in
                guard let c = controls[id] else { return [] }
                return c.mode.isHidden ? [c.select, c.close] : [c.select, c.mode, c.close]
            } + (overflow.isHidden ? [] : [overflow])
        setAccessibilityChildren(accessible)
        setAccessibilityChildrenInNavigationOrder(accessible)
    }
    private static func tabLabel(mode: DocumentViewMode, pinned: Bool, edited: Bool) -> String {
        switch (mode, pinned, edited) {
        case (.source, false, false): return "%@"
        case (.source, false, true): return Strings.text("tabs.edited", "%@, edited")
        case (.source, true, false): return Strings.text("tabs.pinned", "%@, pinned")
        case (.source, true, true): return Strings.text("tabs.pinnedEdited", "%@, pinned, edited")
        case (.preview, false, false): return Strings.text("tabs.preview", "%@, showing Preview")
        case (.preview, false, true): return Strings.text("tabs.previewEdited", "%@, edited, showing Preview")
        case (.preview, true, false): return Strings.text("tabs.previewPinned", "%@, pinned, showing Preview")
        case (.preview, true, true):
            return Strings.text("tabs.previewPinnedEdited", "%@, pinned, edited, showing Preview")
        case (.both, false, false): return Strings.text("tabs.both", "%@, showing Source and Preview")
        case (.both, false, true): return Strings.text("tabs.bothEdited", "%@, edited, showing Source and Preview")
        case (.both, true, false): return Strings.text("tabs.bothPinned", "%@, pinned, showing Source and Preview")
        case (.both, true, true):
            return Strings.text("tabs.bothPinnedEdited", "%@, pinned, edited, showing Source and Preview")
        }
    }
    /// What competes for a tab's width, and who wins. From the trailing edge: the close button,
    /// always (it is also the edited dot); the eye of a tab in Preview or Both, always, because it
    /// is state; the outside-change symbol, always, because it warns that saving may overwrite
    /// someone else's work; the comparison symbol, while the title keeps
    /// `minimumTitleWidthBesideComparisonMark`; and last the eye a tab in Source shows under the
    /// pointer, while the title keeps the 82 points a tab at the minimum width has always had. So
    /// a 130-point tab shows close and at most one of its two symbols, the outside change first;
    /// in Preview or Both it shows close, the eye and the outside change only. What is not drawn
    /// is still in the tab's tooltip, its accessibility label and the list of open tabs.
    private func layoutMarks(_ c: Controls, id: TabID, width: CGFloat) -> (title: CGFloat, eye: Bool, comparison: Bool)
    {
        var title = width - 48
        var eye = c.viewMode != nil && c.viewMode != .source
        if eye { title -= 32 }
        if c.changedOutside { title -= 20 }
        let comparison = c.compared && title - 20 >= Self.minimumTitleWidthBesideComparisonMark
        if comparison { title -= 20 }
        if !eye, c.viewMode != nil, hoveredTab == id, title - 32 >= Self.titleWidthBesideHoverMark {
            eye = true
            title -= 32
        }
        return (max(0, title), eye, comparison)
    }
    /// `revealingActive` is false when only the pointer moved: showing a mark must not scroll
    /// the strip back to the active tab under the person's hand.
    private func layoutTabs(revealingActive: Bool = true) {
        // The list of open tabs appears exactly when the tabs are at the minimum width and still
        // do not fit; the scrolling area gives it room. Tabs that fit never show it.
        let listed = overflowing
        overflow.isHidden = !listed
        overflow.frame = NSRect(x: bounds.width - 32, y: 4, width: 28, height: 28)
        scroll.frame = NSRect(
            x: 0, y: 0, width: max(0, bounds.width - (listed ? Self.overflowReserve : 0)), height: bounds.height)
        guard !order.isEmpty else {
            row.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 36)
            return
        }
        let preferred: CGFloat = 220, minimum = Self.minimumTabWidth
        let width = max(minimum, min(preferred, bounds.width / CGFloat(order.count)))
        var x: CGFloat = 0, active = NSRect.zero
        for id in order {
            guard let c = controls[id] else { continue }
            c.background.frame = NSRect(x: x, y: 0, width: width, height: 36)
            // Four points separate the selection and close hit targets (DS-14/70/74). The mark,
            // when shown, is a third 28 by 28 target with the same four points on either side,
            // taken from the title, which truncates at its tail. A state symbol is 16 points wide
            // with the same four points on either side.
            let marks = layoutMarks(c, id: id, width: width)
            c.mode.isHidden = !marks.eye
            c.select.frame = NSRect(x: x + 8, y: 0, width: marks.title, height: 36)
            c.mode.frame = NSRect(x: x + width - 68, y: 4, width: 28, height: 28)
            c.close.frame = NSRect(x: x + width - 36, y: 4, width: 28, height: 28)
            var next = x + width - 36 - (marks.eye ? 32 : 0)
            for (mark, shown) in [(c.comparison, marks.comparison), (c.outsideChange, c.changedOutside)] {
                mark.isHidden = !shown
                guard shown else { continue }
                mark.frame = NSRect(x: next - 20, y: 10, width: 16, height: 16)
                next -= 20
            }
            // An edited tab shows a filled dot where its close button is. Under the pointer, or
            // while the button has the keyboard, it shows the cross: the same button, so a press
            // on either closes through the same review and an edited tab never looks uncloseable.
            let dot = c.edited && hoveredTab != id && closeWithKeyboard != id
            if c.closeShowsEditedDot != dot {
                c.closeShowsEditedDot = dot
                c.close.image = NSImage(systemSymbolName: dot ? "circle.fill" : "xmark", accessibilityDescription: nil)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(scale: dot ? .small : .medium))
            }
            if group?.activeTab == id { active = c.background.frame }
            x += width
        }
        row.frame = NSRect(x: 0, y: 0, width: max(x, scroll.frame.width), height: 36)
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
    private func tabUnderPointer() -> TabID? { pointer.flatMap { tab(at: $0) } }
    /// The tab at `point`, in the strip's coordinates; nil for the empty part of the strip.
    private func tab(at point: NSPoint) -> TabID? {
        guard scroll.frame.contains(point) else { return nil }
        let p = row.convert(point, from: self)
        return order.first { controls[$0]?.background.frame.contains(p) == true }
    }

    // MARK: The list of open tabs

    /// Fills the list with this group's tabs in strip order: a checkmark on the active tab, and
    /// each title saying, in words, whether the tab is pinned or edited (DS-62). The first item
    /// is the pull-down's own face and is kept.
    func openTabListItems() -> [NSMenuItem] {
        guard let menu = overflow.menu, let host else { return [] }
        while menu.items.count > 1 { menu.removeItem(at: menu.items.count - 1) }
        let selectable = allowsSelection
        for tab in group?.tabs ?? [] {
            guard let doc = host.presentation(for: tab.id)?.document as? TextDocument else { continue }
            let name = doc.displayName ?? "Untitled"
            let item = NSMenuItem(
                title: String(
                    format: Self.tabLabel(mode: .source, pinned: tab.isPinned, edited: doc.isDocumentEdited), name),
                action: #selector(chooseOpenTab(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tab.id
            item.state = group?.activeTab == tab.id ? .on : .off
            item.image = NSImage(
                systemSymbolName: tab.isPinned ? "pin.fill" : "doc.text",
                accessibilityDescription: tab.isPinned ? "Pinned" : nil)
            item.toolTip = Self.tabToolTip(name: name, path: doc.fileURL?.path, notice: doc.externalFile.notice)
            item.isEnabled = selectable
            menu.addItem(item)
        }
        return Array(menu.items.dropFirst())
    }
    /// Selects the chosen tab, as a click on it would, and scrolls it into view.
    @objc private func chooseOpenTab(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? TabID, controls[id] != nil else { return }
        clickTab(id)
        if let frame = controls[id]?.background.frame { row.scrollToVisible(frame) }
    }

    // MARK: Tooltip, the other mouse button and a double-click on the empty strip

    /// A tab's tooltip: the file's full path with the home folder written as "~", or the name of
    /// a document that has no file yet; then, on its own line, the notice when there is one.
    static func tabToolTip(name: String, path: String?, notice: String?, home: String = NSHomeDirectory()) -> String {
        var shown = name
        if let path {
            let home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
            if path == home {
                shown = "~"
            } else if home.count > 1, path.hasPrefix(home + "/") {
                shown = "~" + path.dropFirst(home.count)
            } else {
                shown = path
            }
        }
        return notice.map { shown + "\n" + $0 } ?? shown
    }
    /// The tab the other mouse button went down on. A tab's own controls do not handle that
    /// button, so its events arrive here from whichever of them was under the pointer.
    private var otherPress: TabID?
    override func otherMouseDown(with event: NSEvent) {
        otherPress = tab(at: convert(event.locationInWindow, from: nil))
        if otherPress == nil { super.otherMouseDown(with: event) }
    }
    /// A click with the other (middle) mouse button closes the tab it was pressed and released on,
    /// through the close button's own route, so unsaved changes get the same review (DS-12).
    override func otherMouseUp(with event: NSEvent) {
        guard let pressed = otherPress else {
            super.otherMouseUp(with: event)
            return
        }
        otherPress = nil
        if tab(at: convert(event.locationInWindow, from: nil)) == pressed { host?.closeTab(pressed, sender: self) }
    }
    /// When the first press of a click pair landed on the empty part of the strip; nil when the
    /// last first press landed elsewhere or the tabs have changed since.
    private var emptyFirstPress: TimeInterval?
    /// True from the second press of a pair whose two presses were both on the empty strip, with
    /// the same tabs, until its release.
    private var emptyPair = false
    private func forgetEmptyPress() {
        emptyFirstPress = nil
        emptyPair = false
    }
    /// Whether `point` (in the strip's coordinates) is the empty part of the strip and a click
    /// there is the strip's to act on. The window's frame has first refusal over its inside edge,
    /// where a double-click belongs to AppKit's own handling (see `FrameTextClick`): a point the
    /// frame claims is never treated as empty strip.
    private func isEmptyStrip(_ point: NSPoint) -> Bool {
        guard bounds.contains(point), tab(at: point) == nil, !isReordering else { return false }
        if let border = window?.contentView?.superview {
            if border.hitTest(border.convert(convert(point, to: nil), from: nil)) === border { return false }
        }
        guard let hit = hitTest(superview?.convert(point, from: self) ?? point) else { return false }
        return hit === self || hit === row || hit === scroll || hit === scroll.contentView
    }
    override func mouseDown(with event: NSEvent) {
        // The second press counts only if the first was also a press on the empty strip. The
        // first click of a pair that closed the last tab (its close button, the other mouse
        // button), ended a reorder or chose from the list of open tabs never reached this view,
        // or changed the tabs, and so leaves nothing to pair with.
        let empty = isEmptyStrip(convert(event.locationInWindow, from: nil))
        emptyPair =
            empty && event.clickCount == 2
            && emptyFirstPress.map { event.timestamp >= $0 && event.timestamp - $0 <= NSEvent.doubleClickInterval }
                == true
        emptyFirstPress = empty && event.clickCount == 1 ? event.timestamp : nil
        // The group still takes the click, which focuses it.
        super.mouseDown(with: event)
    }
    /// A double-click on the empty part of the strip is File > New, in this group. A tab's own
    /// controls take their clicks themselves, so a double-click on a tab never arrives here, and
    /// a reorder ends on the tab it began on.
    override func mouseUp(with event: NSEvent) {
        let pressed = emptyPair
        emptyPair = false
        guard pressed, event.clickCount == 2, allowsSelection, isEmptyStrip(convert(event.locationInWindow, from: nil))
        else {
            super.mouseUp(with: event)
            return
        }
        if host?.model.focusedGroup != groupSlot { host?.focusGroup(groupSlot) }
        EditorServices.current?.newDocument(self)
    }
    /// Works out the hovered tab again from where the pointer was last seen. Called when the
    /// pointer moves and when the tabs move under it: a tab closed, tabs were reordered or the
    /// strip scrolled. A strip only scrolls once its tabs are at the minimum width, where no eye
    /// depends on the pointer, but an edited tab's dot and cross still do.
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
        windowObservers.removeAll()
        guard let window else {
            pointerMoved(to: nil)
            return
        }
        let center = NotificationCenter.default
        windowObservers.tokens = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.pointerLeftWithWindow() }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.pointerLeftWithWindow() }
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
extension DocumentTabStrip: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) { _ = openTabListItems() }
}
