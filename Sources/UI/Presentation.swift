import TextTankCore
import EditorBridge
import NativeSearch
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// Presentation-only helpers. Stored identifiers and model validation never depend on these labels.
enum ControlPresentation {
    static func populate(_ popup: NSPopUpButton, choices: [(id: String, title: String)], selected: String) {
        popup.removeAllItems()
        for choice in choices {
            // Adding through NSMenu preserves duplicate display titles as distinct choices.
            let item = NSMenuItem(title: choice.title, action: nil, keyEquivalent: "")
            item.representedObject = choice.id
            popup.menu?.addItem(item)
        }
        popup.selectItem(at: popup.indexOfItem(withRepresentedObject: selected))
    }
    static func shortcut(for action: Selector, in menu: NSMenu?) -> String? {
        guard let menu else { return nil }
        for item in menu.items {
            if item.action == action, !item.keyEquivalent.isEmpty {
                let modifiers = item.keyEquivalentModifierMask
                return (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "")
                    + (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "")
                    + item.keyEquivalent.uppercased()
            }
            if let found = shortcut(for: action, in: item.submenu) { return found }
        }
        return nil
    }
    static func selectedID(_ popup: NSPopUpButton) -> String? { popup.selectedItem?.representedObject as? String }
    static func label(_ title: String, control: NSView, caption: NSTextField? = nil) {
        control.setAccessibilityLabel(title)
        // AppKit exposes native cells for text fields, popups and buttons. Naming
        // only the host leaves those unignored input elements unnamed.
        let cell = (control as? NSControl)?.cell
        cell?.setAccessibilityLabel(title)
        if let caption {
            control.setAccessibilityTitleUIElement(caption)
            if let captionCell = caption.cell {
                cell?.setAccessibilityTitleUIElement(captionCell)
            } else {
                cell?.setAccessibilityTitleUIElement(caption)
            }
        }
    }
}

/// NSNumberFormatter otherwise coerces a malformed string to nil before Save can explain it.
/// Retain all editing strings, format numeric objects with the real locale formatter, and leave
/// full-input validation to the owning action. Cancel never needs a valid numeric draft.
private final class NumericDraftFormatter: Formatter {
    let numbers: NumberFormatter
    init(_ numbers: NumberFormatter) {
        self.numbers = numbers
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    override func string(for obj: Any?) -> String? {
        if let string = obj as? String { return string }
        return numbers.string(for: obj)
    }
    override func getObjectValue(
        _ object: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String,
        errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
        object?.pointee = string as NSString
        return true
    }
}

final class NumericInput: NSObject {
    private static var association = 0
    let locale: Locale
    private init(locale: Locale) { self.locale = locale }
    static func configure(_ field: NSTextField, fractional: Bool = false, locale: Locale = .current) {
        let owner = NumericInput(locale: locale)
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.isLenient = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = fractional ? 340 : 0
        field.formatter = NumericDraftFormatter(formatter)
        objc_setAssociatedObject(field, &association, owner, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    private static func owner(_ field: NSTextField) -> NumericInput? {
        objc_getAssociatedObject(field, &association) as? NumericInput
    }
    static func text(_ field: NSTextField) -> String {
        field.currentEditor()?.string ?? field.stringValue
    }
    static func number(_ field: NSTextField) -> Double? {
        Strings.decimal(text(field), fractional: true, locale: owner(field)?.locale ?? .current)
    }
    static func integer(_ field: NSTextField, signed: Bool = false) -> Int? {
        Strings.integer(text(field), locale: owner(field)?.locale ?? .current, signed: signed)
    }
    static func editable(_ value: Double, locale: Locale = .current) -> String {
        // Shortest round-tripping Double spelling, separate from concise one-decimal status text.
        String(value).replacingOccurrences(of: ".", with: locale.decimalSeparator ?? ".")
    }
}
