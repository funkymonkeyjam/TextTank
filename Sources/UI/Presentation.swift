import TextTankCore
import EditorBridge
import NativeSearch
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// Presentation-only helpers. Stored identifiers and model validation never depend on these labels.
@MainActor enum ControlPresentation {
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
            if item.action == action, let text = shortcut(of: item) { return text }
            if let found = shortcut(for: action, in: item.submenu) { return found }
        }
        return nil
    }
    /// The key equivalent a menu item has now, written the way the menu bar draws it, or nil
    /// when it has none. It reads the item itself, so a shortcut assigned in Settings, a default
    /// that gave way to one and a macro's own key are all shown as they currently are (DS-20).
    static func shortcut(of item: NSMenuItem) -> String? {
        var key = item.keyEquivalent
        guard !key.isEmpty else { return nil }
        var modifiers = item.keyEquivalentModifierMask.intersection([.control, .option, .shift, .command])
        // AppKit reads an uppercase letter as that letter with Shift.
        if key.count == 1, key != key.lowercased() { modifiers.insert(.shift) }
        if let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1 {
            switch scalar.value {
            case 0xF704...0xF726: key = "F\(scalar.value - 0xF703)"
            case 0xF700: key = "↑"
            case 0xF701: key = "↓"
            case 0xF702: key = "←"
            case 0xF703: key = "→"
            case 0xF729: key = "↖"
            case 0xF72B: key = "↘"
            case 0xF72C: key = "⇞"
            case 0xF72D: key = "⇟"
            case 0xF728: key = "⌦"
            case 0x09: key = "⇥"
            case 0x19:
                key = "⇥"
                modifiers.insert(.shift)
            case 0x0D, 0x03: key = "↩"
            case 0x08, 0x7F: key = "⌫"
            case 0x1B: key = "⎋"
            case 0x20: key = "Space"
            default: key = key.uppercased()
            }
        } else {
            key = key.uppercased()
        }
        return (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "")
            + (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "") + key
    }
    /// The same key equivalent in words, for assistive technology (DS-70).
    static func spokenShortcut(of item: NSMenuItem) -> String? {
        guard let text = shortcut(of: item) else { return nil }
        let names: [Character: String] = [
            "⌃": "Control", "⌥": "Option", "⇧": "Shift", "⌘": "Command", "↑": "Up Arrow", "↓": "Down Arrow",
            "←": "Left Arrow", "→": "Right Arrow", "↖": "Home", "↘": "End", "⇞": "Page Up", "⇟": "Page Down",
            "⌦": "Forward Delete", "⇥": "Tab", "↩": "Return", "⌫": "Delete", "⎋": "Escape"
        ]
        var parts: [String] = [], rest = ""
        for character in text {
            if rest.isEmpty, let name = names[character] { parts.append(name) } else { rest.append(character) }
        }
        if !rest.isEmpty { parts.append(rest) }
        return parts.joined(separator: "-")
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

@MainActor final class NumericInput: NSObject {
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
    nonisolated static func editable(_ value: Double, locale: Locale = .current) -> String {
        // Shortest round-tripping Double spelling, separate from concise one-decimal status text.
        String(value).replacingOccurrences(of: ".", with: locale.decimalSeparator ?? ".")
    }
}
