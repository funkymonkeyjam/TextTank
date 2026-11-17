import TextTankCore
import EditorBridge
import NativeSearch
import AppKit

/// Each document retains its native window and save lifecycle; only the selected tab is visible.
final class DocumentTabWindow: NSWindow {
    static var documents: [NSWindow] {
        NSDocumentController.shared.documents.flatMap { $0.windowControllers.compactMap { $0.window } }.filter {
            $0 is DocumentTabWindow
        }
    }
    override func becomeMain() {
        super.becomeMain()
        if let controller = windowController as? EditorWindowController {
            EditorServices.current?.noteActiveController(controller)
        }
    }
    // The tabs look like one window, so its red close button closes that whole window: it quits
    // the app, with the usual review of unsaved documents. Closing one tab is the tab's own close
    // button, File > Close and Command-W, which all arrive through performClose.
    private var closingTab = false
    private weak var standardCloseTarget: AnyObject?
    private var standardCloseAction: Selector?
    /// Takes over the red close button once; the button's own behaviour is kept for closing a tab.
    func routeCloseButtonToQuit() {
        guard standardCloseAction == nil, let button = standardWindowButton(.closeButton) else { return }
        standardCloseTarget = button.target
        standardCloseAction = button.action
        button.target = self
        button.action = #selector(closeButtonPressed(_:))
        button.toolTip = "Quit TextTank. Documents with unsaved changes are reviewed first."
    }
    /// True when a press of the red close button quits; false while one tab is being closed.
    var closeButtonQuits: Bool { standardCloseAction != nil && !closingTab }
    @objc private func closeButtonPressed(_ sender: Any?) {
        if closingTab {
            // performClose presses this button on the window's behalf: close just this tab.
            if let action = standardCloseAction { NSApp.sendAction(action, to: standardCloseTarget, from: sender) }
        } else {
            NSApp.terminate(sender)
        }
    }
    override func performClose(_ sender: Any?) {
        closingTab = true
        defer { closingTab = false }
        super.performClose(sender)
    }
    /// The tab to show again when this one closes: set when a background tab is brought forward
    /// only to be closed from its close button, so closing it returns to the tab that was active.
    weak var returnTo: NSWindow?
    override func makeKeyAndOrderFront(_ sender: Any?) {
        // Selecting this tab for any reason ends an earlier, cancelled close-from-background.
        returnTo = nil
        let others = Self.documents.filter { $0 !== self }
        let sharedFrame = others.first(where: { $0.isVisible })?.frame
        // Set the shared geometry before AppKit presents this native window.
        if let sharedFrame { setFrame(sharedFrame, display: false) }
        others.forEach { $0.orderOut(nil) }
        super.makeKeyAndOrderFront(sender)
        contentView?.layoutSubtreeIfNeeded()
        if let sharedFrame { setFrame(sharedFrame, display: true) }
        WindowFrames.didPresent(self)
        (windowController as? EditorWindowController)?.visibilityChanged()
        (windowController as? EditorWindowController)?.refreshStatusDetails()
        if let controller = windowController as? EditorWindowController { makeFirstResponder(controller.activeEditor) }
    }
    override func sendEvent(_ event: NSEvent) {
        // A cancelled close-from-background leaves this tab showing. Once the person works in it
        // (a key or a click that reaches the tab itself, not its review sheet) it is simply the
        // active tab, and closing it later goes to its neighbour.
        if returnTo != nil, attachedSheet == nil,
            [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type)
        {
            returnTo = nil
        }
        super.sendEvent(event)
    }
    // The recurring status refresh runs only while the tab is on screen.
    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        (windowController as? EditorWindowController)?.visibilityChanged()
    }
    override func orderFront(_ sender: Any?) {
        super.orderFront(sender)
        (windowController as? EditorWindowController)?.visibilityChanged()
    }
    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        (windowController as? EditorWindowController)?.visibilityChanged()
    }
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        super.order(place, relativeTo: otherWin)
        (windowController as? EditorWindowController)?.visibilityChanged()
    }
    override func close() {
        let wasVisible = isVisible
        let closingFrame = frame
        // The tab that was active before a close-from-background, otherwise the neighbour: the
        // next tab, or the previous one when this is the last.
        let all = Self.documents
        var next = all.first { $0 !== self }
        if let returnTo, returnTo !== self, all.contains(where: { $0 === returnTo }) {
            next = returnTo
        } else if let index = all.firstIndex(where: { $0 === self }) {
            next = index + 1 < all.count ? all[index + 1] : index > 0 ? all[index - 1] : nil
        }
        returnTo = nil
        super.close()
        if wasVisible {
            next?.setFrame(closingFrame, display: false)
            next?.makeKeyAndOrderFront(nil)
            // Ordering a hidden window can apply AppKit's screen constraints.
            // Restore the shared frame after that layout transition, as on tab selection.
            next?.contentView?.layoutSubtreeIfNeeded()
            next?.setFrame(closingFrame, display: true)
        }
    }
}
private final class DocumentTabButton: NSButton {
    weak var documentWindow: NSWindow?
}
private final class DocumentTabBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
        bounds.fill()
        NSColor.controlAccentColor.setFill()
        NSRect(x: 0, y: isFlipped ? bounds.height - 3 : 0, width: bounds.width, height: 3).fill()
    }
}

final class DocumentTabStrip: NSView {
    private let scroll = NSScrollView()
    private let row = NSView()
    private var signature = ""
    weak var owner: NSWindow?
    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = row
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
    override func layout() {
        super.layout()
        scroll.frame = bounds
    }
    func refresh() {
        guard let owner else { return }
        let windows = DocumentTabWindow.documents
        let key = windows.map { "\(ObjectIdentifier($0)):\($0.title):\($0.isDocumentEdited):\($0 === owner)" }.joined(
            separator: "|")
        guard key != signature else { return }
        signature = key
        row.subviews.forEach { $0.removeFromSuperview() }
        var x: CGFloat = 0
        var activeRect = NSRect.zero
        for window in windows {
            let title = window.title + (window.isDocumentEdited ? "  •" : "")
            let width = min(
                220,
                max(
                    130,
                    ceil((title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width) + 66))
            let button = DocumentTabButton(title: title, target: self, action: #selector(selectTab(_:)))
            button.isBordered = false
            button.font = .systemFont(ofSize: 13, weight: window === owner ? .semibold : .regular)
            button.alignment = .left
            button.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.lineBreakMode = .byTruncatingTail
            button.toolTip = window.title
            button.setAccessibilityLabel(
                window.title + (window.isDocumentEdited ? ", edited" : "")
                    + (window === owner ? ", active tab" : ", tab"))
            button.documentWindow = window
            button.frame = NSRect(x: x + 8, y: 0, width: width - 34, height: 36)
            // The highlighted area includes the close control.
            if window === owner {
                let cell = DocumentTabBackground(frame: NSRect(x: x, y: 0, width: width, height: 36))
                activeRect = cell.frame
                row.addSubview(cell)
            }
            row.addSubview(button)
            let close = DocumentTabButton(
                image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close \(window.title)")!,
                target: self, action: #selector(closeTab(_:)))
            close.isBordered = false
            close.documentWindow = window
            close.frame = NSRect(x: x + width - 26, y: 7, width: 22, height: 22)
            close.toolTip = "Close \(window.title)"
            row.addSubview(close)
            x += width
        }
        // New is a standard toolbar item and remains in File / Command-N when the toolbar is hidden.
        row.frame = NSRect(x: 0, y: 0, width: x, height: 36)
        row.scrollToVisible(activeRect)
    }
    @objc private func selectTab(_ sender: NSButton) {
        guard owner != nil else { return }
        let windows = DocumentTabWindow.documents
        guard let target = (sender as? DocumentTabButton)?.documentWindow, windows.contains(where: { $0 === target })
        else { return }
        target.makeKeyAndOrderFront(nil)
    }
    @objc private func closeTab(_ sender: NSButton) {
        guard owner != nil else { return }
        let windows = DocumentTabWindow.documents
        guard let target = (sender as? DocumentTabButton)?.documentWindow,
            windows.contains(where: { $0 === target })
        else { return }
        // A background tab is brought forward first, so that unsaved changes are reviewed on a
        // visible window; once it has closed, the tab that was active is shown again.
        let active = target === owner ? nil : owner
        target.makeKeyAndOrderFront(nil)
        (target as? DocumentTabWindow)?.returnTo = active
        target.performClose(sender)
    }
}
