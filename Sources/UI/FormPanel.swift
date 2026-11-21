import TextTankCore
import EditorBridge
import NativeSearch
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// An owned, resizable form. Opening it never enters an application modal loop.
/// Sheets disable only their parent; ordinary panels leave document commands available.
@MainActor final class FormPanel: NSObject, NSWindowDelegate {
    private static var openForms: [FormPanel] = []
    static var frontWindow: NSWindow? { openForms.last { $0.window.isVisible }?.window }
    static var visible: [FormPanel] { openForms.filter { $0.window.isVisible } }
    let window: ToolPanel
    let body = NSStackView()
    let validation = NSTextField(wrappingLabelWithString: "")
    private let actions = NSStackView()
    private var handlers: [() -> Void] = []
    private var closing = false
    var acceptsActions: Bool { !closing }
    private var presentationOwner: AnyObject?
    func retainPresentationOwner(_ owner: AnyObject) { presentationOwner = owner }
    private weak var markedField: NSView?
    var onClose: (() -> Void)?
    var shouldCloseWindow: (() -> Bool)?
    init(title: String, identifier: String, size: NSSize = NSSize(width: 600, height: 440), layoutContent: Bool = true)
    {
        window = ToolPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable])
        super.init()
        window.title = title
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = NSSize(width: min(size.width, 480), height: min(size.height, 300))
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 12
        validation.setAccessibilityLabel(Strings.formAction("Input needs correction", scope: title))
        validation.textColor = .labelColor
        validation.isHidden = true
        actions.orientation = .horizontal
        actions.spacing = 8
        let root = NSStackView(views: [body, validation, actions])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        if layoutContent {
            content.addSubview(root)
            NSLayoutConstraint.activate([
                root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                root.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
                root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
                body.widthAnchor.constraint(equalTo: root.widthAnchor),
                validation.widthAnchor.constraint(equalTo: root.widthAnchor)
            ])
        }
        WindowFrames.track(window, as: identifier)
    }
    func add(_ view: NSView) {
        body.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
    }
    func note(_ text: String) { add(NSTextField(wrappingLabelWithString: text)) }
    @discardableResult func field(_ title: String, value: String, identifier: String) -> NSTextField {
        let field = NSTextField(string: value)
        field.identifier = NSUserInterfaceItemIdentifier(identifier)
        let caption = NSTextField(labelWithString: title)
        ControlPresentation.label(Strings.formAction(title, scope: window.title), control: field, caption: caption)
        let row = NSStackView(views: [caption, field])
        row.spacing = 12
        caption.widthAnchor.constraint(equalToConstant: 110).isActive = true
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        add(row)
        return field
    }
    @discardableResult func button(
        _ title: String, identifier: String? = nil, cancel: Bool = false, action: @escaping () -> Void
    ) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(performAction(_:)))
        button.bezelStyle = .rounded
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        button.tag = handlers.count
        button.identifier = identifier.map { NSUserInterfaceItemIdentifier($0) }
        button.setAccessibilityLabel(Strings.formAction(title, scope: window.title))
        button.cell?.setAccessibilityLabel(Strings.formAction(title, scope: window.title))
        if cancel { button.keyEquivalent = "\u{1b}" }
        handlers.append(action)
        actions.addArrangedSubview(button)
        return button
    }
    func setActionEnabled(_ identifier: String, _ enabled: Bool) {
        actions.arrangedSubviews.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == identifier }?
            .isEnabled = enabled
    }
    @objc private func performAction(_ button: NSButton) {
        guard !closing, handlers.indices.contains(button.tag) else { return }
        handlers[button.tag]()
    }
    func commitEditing() -> Bool {
        guard window.makeFirstResponder(nil) else {
            showValidation(FormFailure.invalidEditing)
            return false
        }
        return true
    }
    func showValidation(_ error: Error, field: NSView? = nil) {
        if TTAlert.requiresNativePresentation(error) {
            TTAlert.present(error)
            return
        }
        markedField?.setAccessibilityHelp(nil)
        markedField?.toolTip = nil
        markedField = field
        validation.stringValue = error.localizedDescription
        validation.isHidden = false
        field?.setAccessibilityHelp(error.localizedDescription)
        field?.toolTip = error.localizedDescription
        if let field { window.makeFirstResponder(field) }
        Announce.say(error.localizedDescription, from: window)
    }
    func clearValidation() {
        markedField?.setAccessibilityHelp(nil)
        markedField?.toolTip = nil
        markedField = nil
        validation.stringValue = ""
        validation.isHidden = true
    }
    func show(parent: NSWindow? = nil) {
        if !Self.openForms.contains(where: { $0 === self }) { Self.openForms.append(self) }
        if let parent { parent.beginSheet(window) } else { window.makeKeyAndOrderFront(nil) }
        if let field = window.initialFirstResponder { window.makeFirstResponder(field) }
    }
    func close() {
        guard !closing else { return }
        closing = true
        while let sheet = window.attachedSheet {
            if let child = Self.openForms.first(where: { $0.window === sheet }) {
                child.close()
            } else {
                window.endSheet(sheet, returnCode: .cancel)
                sheet.performClose(nil)
            }
        }
        if let parent = window.sheetParent { parent.endSheet(window) }
        window.orderOut(nil)
        window.close()
        let callback = onClose
        onClose = nil
        handlers.removeAll()
        Self.openForms.removeAll { $0 === self }
        callback?()
        presentationOwner = nil
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if shouldCloseWindow?() != false { close() }
        return false
    }
}

enum FormFailure: LocalizedError {
    case changed, busy, invalidEditing, documentChanged
    var errorDescription: String? {
        switch self {
        case .changed:
            return
                "The saved configuration changed while this window was open. Your edits have been kept. Cancel and reopen the window to review the latest saved values."
        case .documentChanged:
            return
                "The document changed or closed while this panel was open. Cancel and reopen the panel to use the current document."
        case .busy:
            return "An operation is still running. Your edits have been kept. Wait for it to finish before saving."
        case .invalidEditing:
            return "Correct the value in the active field before saving. Your edits have been kept."
        }
    }
}

/// This is an in-process working-copy guard, not a multi-process disk compare-and-swap.
/// Stable encoded bytes distinguish NFC/NFD text and every stored field.
enum SavedConfiguration {
    static func bytes<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func requireUnchanged<Value: Encodable>(_ value: Value, since baseline: Data) throws {
        guard try bytes(value) == baseline else { throw FormFailure.changed }
    }
}
