// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// Shared app-owned modal layout. macOS may stack NSAlert actions vertically;
/// keep their original response indices while presenting one horizontal row.
final class TTAlert: NSAlert {
    /// States why a command the person chose did nothing. Only for an explicit action, never
    /// from menu validation or a timer.
    static func explain(_ message: String, detail: String = "") {
        let alert = TTAlert()
        alert.messageText = message
        alert.informativeText = detail
        _ = alert.runModal()
    }
    static func explain(_ error: Error) {
        explain(error.localizedDescription, detail: (error as NSError).localizedRecoverySuggestion ?? "")
    }
    private var sizeConstraints: [NSLayoutConstraint] = []
    /// The button Escape presses. By default the one titled "Cancel"; set it for an alert whose
    /// way out has another title.
    var escapeButton: NSButton?
    /// Return never presses a destructive button: when the first button is marked destructive,
    /// Return belongs to the way out instead and the destructive action needs a deliberate click.
    func keyRoles() -> (returnIndex: Int?, escapeIndex: Int?) {
        let escapeIndex = buttons.firstIndex { $0 === escapeButton } ?? buttons.firstIndex { $0.title == "Cancel" }
        if buttons.first?.hasDestructiveAction == true { return (escapeIndex, escapeIndex) }
        return (escapeIndex == 0 ? nil : 0, escapeIndex)
    }
    @objc private func finishHorizontalAction(_ sender: NSButton) {
        window.makeFirstResponder(nil)
        NSApp.stopModal(
            withCode: NSApplication.ModalResponse(
                rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + sender.tag))
    }
    override func runModal() -> NSApplication.ModalResponse {
        NSLayoutConstraint.deactivate(sizeConstraints)
        sizeConstraints.removeAll()
        if buttons.isEmpty { _ = addButton(withTitle: "OK") }
        let modal = window, initialFocus = window.initialFirstResponder
        let accessory = accessoryView
        let accessorySize = accessory?.frame.size ?? .zero
        accessory?.removeFromSuperview()
        let title = NSTextField(wrappingLabelWithString: messageText)
        title.font = .boldSystemFont(ofSize: 15)
        let detail = NSTextField(wrappingLabelWithString: informativeText)
        detail.font = .systemFont(ofSize: 13)
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
                ceil((button.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width) + 30
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
        modal.center()
        modal.initialFirstResponder = initialFocus ?? accessory
        modal.makeKeyAndOrderFront(nil)
        if let initialFocus { modal.makeFirstResponder(initialFocus) }
        defer { modal.orderOut(nil) }
        var monitor: Any?
        if let escapeIndex = roles.escapeIndex, escapeIndex == roles.returnIndex {
            let escape = buttons[escapeIndex]
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak modal] event in
                guard event.window === modal, event.keyCode == 53 else { return event }
                escape.performClick(nil)
                return nil
            }
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        return NSApp.runModal(for: modal)
    }
}
