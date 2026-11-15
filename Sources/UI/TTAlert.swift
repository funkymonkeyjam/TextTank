// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// An app-owned panel for decisions and existing forms, with horizontal actions and stable
/// response indices. It never re-parents NSAlert internals. Native NSError recovery stays in
/// `present(_:)`; icon/suppression customization belongs to NSAlert, not this panel.
final class TTAlert: NSObject, NSWindowDelegate {
    enum ButtonRole { case action, cancel }
    enum Result: Equatable {
        case button(Int), dismissed
        init(_ response: NSApplication.ModalResponse) {
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            self = index >= 0 ? .button(index) : .dismissed
        }
    }
    var messageText = ""
    var informativeText = ""
    var alertStyle: NSAlert.Style = .informational
    var accessoryView: NSView?
    private(set) var buttons: [NSButton] = []
    private var cancelButtons: Set<ObjectIdentifier> = []
    let window = NSPanel(
        contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    private var sheetKeeper: TTAlert?
    private var keyMonitor: Any?
    override init() {
        super.init()
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.delegate = self
    }
    @discardableResult func addButton(withTitle title: String, role: ButtonRole = .action) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(finishHorizontalAction(_:)))
        buttons.append(button)
        if role == .cancel { cancelButtons.insert(ObjectIdentifier(button)) }
        return button
    }
    @discardableResult func run() -> Result { Result(runModal()) }
    /// A dialog declares its choices once, in its visible button order. Unexpected termination
    /// has no choice; callers must never interpret an abort or stop as the first button.
    func choice<Choice>(_ choices: [Choice]) -> Choice? {
        guard choices.count == buttons.count else { return nil }
        guard case .button(let index) = run(), choices.indices.contains(index) else { return nil }
        return choices[index]
    }
    /// Keep the native error alert and its recovery attempter/options intact. All error callers
    /// share this path; flattening the error into strings would discard its recovery behavior.
    static func errorAlert(_ error: Error) -> NSAlert { NSAlert(error: error) }
    static func present(_ error: Error) { _ = errorAlert(error).runModal() }

    /// States why a command the person chose did nothing. Only for an explicit action, never
    /// from menu validation or a timer.
    static func explain(_ message: String, detail: String = "") {
        let alert = TTAlert()
        alert.messageText = message
        alert.informativeText = detail
        _ = alert.runModal()
    }
    static func explain(_ error: Error) { present(error) }
    private var sizeConstraints: [NSLayoutConstraint] = []
    /// The button Escape presses. By default the one titled "Cancel"; set it for an alert whose
    /// way out has another title.
    var escapeButton: NSButton?
    /// Return never presses a destructive button: when the first button is marked destructive,
    /// Return belongs to the way out instead and the destructive action needs a deliberate click.
    func keyRoles() -> (returnIndex: Int?, escapeIndex: Int?) {
        let escapeIndex =
            buttons.firstIndex { $0 === escapeButton }
            ?? buttons.firstIndex { cancelButtons.contains(ObjectIdentifier($0)) }
            // Compatibility for existing dynamically assembled button lists. Production callers
            // can mark a cancel role without relying on the displayed language.
            ?? buttons.firstIndex { $0.title == "Cancel" }
            ?? (buttons.count == 1 && buttons[0].hasDestructiveAction == false ? 0 : nil)
        if buttons.first?.hasDestructiveAction == true { return (escapeIndex, escapeIndex) }
        return (escapeIndex == 0 && buttons.count > 1 ? nil : 0, escapeIndex)
    }
    @objc private func finishHorizontalAction(_ sender: NSButton) {
        finish(
            with: NSApplication.ModalResponse(
                rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + sender.tag))
    }
    private func finish(with response: NSApplication.ModalResponse) {
        // Commit a field editor before the caller reads any control, for modal and sheet paths.
        window.makeFirstResponder(nil)
        if let parent = window.sheetParent {
            parent.endSheet(window, returnCode: response)
        } else {
            NSApp.stopModal(withCode: response)
        }
    }
    private func prepare() {
        NSLayoutConstraint.deactivate(sizeConstraints)
        sizeConstraints.removeAll()
        if buttons.isEmpty { _ = addButton(withTitle: "OK") }
        let modal = window, initialFocus = window.initialFirstResponder
        let accessory = accessoryView
        let accessorySize = accessory?.frame.size ?? .zero
        accessory?.removeFromSuperview()
        let title = NSTextField(wrappingLabelWithString: messageText)
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let detail = NSTextField(wrappingLabelWithString: informativeText)
        detail.font = .systemFont(ofSize: NSFont.systemFontSize)
        // Stack spacing uses alignment rectangles. Older macOS rounded buttons
        // extend their frames beyond those rectangles, so reserve their insets too.
        let actionSpacing: CGFloat = 24
        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.distribution = .fill
        actions.spacing = actionSpacing
        actions.detachesHiddenViews = false
        var actionWidth: CGFloat = 0
        let roles = keyRoles()
        for (index, button) in buttons.enumerated().reversed() {
            button.removeFromSuperview()
            button.translatesAutoresizingMaskIntoConstraints = false
            button.target = self
            button.action = #selector(finishHorizontalAction(_:))
            button.tag = index
            button.bezelStyle = .rounded
            button.controlSize = .regular
            // A button has one key equivalent. Where the way out also takes Return, Escape reaches
            // it through the key monitor below.
            button.keyEquivalent = index == roles.returnIndex ? "\r" : (index == roles.escapeIndex ? "\u{1b}" : "")
            let width = max(
                84,
                ceil(
                    (button.title as NSString).size(withAttributes: [
                        .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)
                    ]).width) + 30
            )
            sizeConstraints.append(button.widthAnchor.constraint(equalToConstant: width))
            actions.addArrangedSubview(button)
            actions.setVisibilityPriority(.mustHold, for: button)
            actionWidth += width
        }
        actionWidth += CGFloat(max(0, buttons.count - 1)) * actionSpacing
        let width = max(420, accessorySize.width, actionWidth)
        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 14
        if alertStyle != .informational,
            let image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Warning")
        {
            let warning = NSImageView(image: image)
            warning.setAccessibilityLabel("Warning")
            body.addArrangedSubview(warning)
        }
        body.addArrangedSubview(title)
        if !informativeText.isEmpty { body.addArrangedSubview(detail) }
        if let accessory {
            accessory.translatesAutoresizingMaskIntoConstraints = false
            sizeConstraints.append(accessory.widthAnchor.constraint(equalToConstant: max(1, accessorySize.width)))
            sizeConstraints.append(accessory.heightAnchor.constraint(equalToConstant: max(1, accessorySize.height)))
            body.addArrangedSubview(accessory)
        }
        let footer = NSView()
        footer.addSubview(actions)
        actions.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            actions.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            actions.topAnchor.constraint(equalTo: footer.topAnchor),
            actions.bottomAnchor.constraint(equalTo: footer.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 32)
        ])
        body.addArrangedSubview(footer)
        let root = NSView()
        root.addSubview(body)
        body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            body.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            body.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
            body.widthAnchor.constraint(equalToConstant: width),
            title.widthAnchor.constraint(equalTo: body.widthAnchor),
            footer.widthAnchor.constraint(equalTo: body.widthAnchor)
        ])
        if !informativeText.isEmpty { detail.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
        NSLayoutConstraint.activate(sizeConstraints)
        modal.contentView = root
        root.layoutSubtreeIfNeeded()
        modal.setContentSize(root.fittingSize)
        modal.title = messageText
        modal.initialFirstResponder = initialFocus ?? accessory
    }
    private func installKeyMonitor() {
        removeKeyMonitor()
        let roles = keyRoles()
        guard let escapeIndex = roles.escapeIndex else { return }
        let escape = buttons[escapeIndex]
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, event.keyCode == 53 else { return event }
            escape.performClick(nil)
            return nil
        }
    }
    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
    @discardableResult func runModal() -> NSApplication.ModalResponse {
        prepare()
        window.center()
        installKeyMonitor()
        window.makeKeyAndOrderFront(nil)
        if let initialFocus = window.initialFirstResponder { window.makeFirstResponder(initialFocus) }
        defer {
            window.makeFirstResponder(nil)
            window.orderOut(nil)
            removeKeyMonitor()
        }
        return NSApp.runModal(for: window)
    }
    func beginSheetModal(
        for parent: NSWindow, completionHandler: ((NSApplication.ModalResponse) -> Void)? = nil
    ) {
        prepare()
        sheetKeeper = self
        installKeyMonitor()
        parent.beginSheet(window) { [self] response in
            removeKeyMonitor()
            window.orderOut(nil)
            completionHandler?(response)
            sheetKeeper = nil
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(with: .abort)
        return false
    }
}
