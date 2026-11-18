import TextTankCore
import EditorBridge
import NativeSearch
import AppKit

/// Native workspace chrome. This window never represents a document's lifetime.
final class DocumentTabWindow: NSWindow {
    var host: WorkspaceWindowController? { windowController as? WorkspaceWindowController }
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
    private var hasCloseTarget: Bool { (host?.active?.document as? TextDocument)?.isOpen == true }
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(performClose(_:)) { return hasCloseTarget }
        return super.validateMenuItem(item)
    }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(performClose(_:)) { return hasCloseTarget }
        return super.validateUserInterfaceItem(item)
    }
    override func sendEvent(_ event: NSEvent) {
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

private final class DocumentTabButton: NSButton { var tabID: TabID? }
private final class DocumentTabBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
        bounds.fill()
        NSColor.controlAccentColor.setFill()
        NSRect(x: 0, y: isFlipped ? bounds.height - 3 : 0, width: bounds.width, height: 3).fill()
    }
}
final class DocumentTabStrip: NSView {
    private let scroll = NSScrollView(), row = NSView()
    @MainActor private final class Controls {
        let background = DocumentTabBackground(), select = DocumentTabButton(), close = DocumentTabButton()
    }
    private var controls: [TabID: Controls] = [:]
    private var order: [TabID] = []
    weak var host: WorkspaceWindowController?
    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = row
        addSubview(scroll)
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
                c.select.setAccessibilityRole(.radioButton)
                c.select.setAccessibilitySubrole(NSAccessibility.Subrole(rawValue: "AXTabButton"))
                c.close.isBordered = false
                c.close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
                c.close.target = self
                c.close.action = #selector(closeTab(_:))
                c.close.tabID = tab.id
                ([c.background, c.select, c.close] as [NSView]).forEach { row.addSubview($0) }
            }
            let active = host.model.activeTab?.id == tab.id, name = doc.displayName ?? "Untitled"
            c.background.isHidden = !active
            c.select.title = name + (doc.isDocumentEdited ? "  •" : "")
            c.select.font = .systemFont(ofSize: NSFont.systemFontSize, weight: active ? .semibold : .regular)
            c.select.toolTip = name
            c.select.setAccessibilityValue(NSNumber(value: active))
            c.select.setAccessibilityLabel(
                doc.isDocumentEdited ? String(format: Strings.text("tabs.edited", "%@, edited"), name) : name)
            c.select.identifier = NSUserInterfaceItemIdentifier("tab." + tab.id.rawValue.uuidString)
            c.close.toolTip = String(format: Strings.text("tabs.close", "Close %@"), name)
            c.close.setAccessibilityLabel(c.close.toolTip)
        }
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
    @objc private func selectTab(_ sender: DocumentTabButton) {
        guard let host, let id = sender.tabID,
            let tab = host.model.groups.flatMap(\.tabs).first(where: { $0.id == id }),
            let presentation = host.presentations.first(where: {
                ($0.document as? TextDocument)?.runtimeID == tab.documentID
            })
        else { return }
        host.activate(presentation)
    }
    @objc private func closeTab(_ sender: DocumentTabButton) {
        if let id = sender.tabID { host?.closeTab(id, sender: sender) }
    }
}
