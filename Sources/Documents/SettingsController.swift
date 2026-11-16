import TextTankCore
import EditorBridge
import NativeSearch
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

@MainActor private final class SettingsShortcutEditor: NSObject {
    var draft: SettingsShortcutDraft
    let popup = NSPopUpButton()
    let key = NSTextField(string: "")
    init(_ settings: EditorSettings) {
        draft = .init(settings)
        super.init()
        for command in EditorCommand.allCases.filter(\.isShortcutAssignable).sorted(by: { $0.title < $1.title }) {
            popup.addItem(withTitle: command.title)
            popup.lastItem?.representedObject = command.rawValue
        }
        popup.target = self
        popup.action = #selector(selectCommand(_:))
        ControlPresentation.label("Command shortcut to assign", control: popup)
        popup.identifier = NSUserInterfaceItemIdentifier("settings.shortcut.command")
        key.stringValue = settings.shortcut(for: draft.selected)
        key.placeholderString = "No custom shortcut"
        ControlPresentation.label("Shortcut key", control: key)
        key.identifier = NSUserInterfaceItemIdentifier("settings.shortcut.key")
    }
    @objc func selectCommand(_ sender: NSPopUpButton) {
        sender.window?.makeFirstResponder(sender)
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        if draft.selected != id {
            key.setAccessibilityHelp(nil)
            key.toolTip = nil
        }
        key.stringValue = draft.select(id, committing: key.stringValue)
    }
    @objc func clearShortcut(_ sender: Any?) {
        key.window?.makeFirstResponder(popup)
        key.stringValue = draft.clear()
    }
    func revealValidation(_ failure: ShortcutValidationFailure) -> NSView? {
        guard let item = popup.itemArray.first(where: { $0.representedObject as? String == failure.command }) else {
            return nil
        }
        popup.select(item)
        key.stringValue = draft.select(failure.command, committing: key.stringValue)
        return key
    }
    func settings() -> EditorSettings {
        draft.commit(key.stringValue)
        return draft.settings
    }
}

@MainActor final class SettingsController: NSObject {
    private let store: SettingsStore
    var value: EditorSettings { store.value }
    var ignoredShortcutBindings: [ShortcutLoadIssue] { store.ignoredShortcutBindings }
    var shortcutLoadNotice: String? { store.shortcutLoadNotice }
    var loadState: StoreLoadState { store.loadState }
    var loadError: Error? { store.loadError }
    var url: URL { store.url }
    var loadFailureMessage: String? { store.loadFailureMessage }
    private let onApply: (EditorSettings, EditorSettings?) -> Void
    private let onStatus: (String) -> Void
    init(
        url: URL? = nil, onApply: @escaping (EditorSettings, EditorSettings?) -> Void = { _, _ in },
        onStatus: @escaping (String) -> Void = { _ in }
    ) {
        store = SettingsStore(url: url, reservedKeys: Self.reservedShortcuts(in: NSApp?.mainMenu))
        self.onApply = onApply
        self.onStatus = onStatus
        super.init()
    }
    func reconcileShortcuts(with menu: NSMenu) {
        store.reconcileShortcuts(reservedKeys: Self.reservedShortcuts(in: menu))
    }
    @discardableResult func save(_ settings: EditorSettings, replacingUnreadable: Bool = false) throws -> URL? {
        let previous = value
        let backup = try store.save(
            settings, replacingUnreadable: replacingUnreadable,
            reservedKeys: Self.reservedShortcuts(in: NSApp?.mainMenu))
        apply(replacing: previous)
        return backup
    }
    func apply(to editor: TTEditor) {
        editor.configureTabWidth(value.tabWidth, useTabs: value.useTabs)
        editor.wrap = value.wrap
    }
    /// The composition root applies this synchronous change to open documents and menus.
    func apply(replacing previous: EditorSettings? = nil) { onApply(value, previous) }
    static func reservedShortcuts(in menu: NSMenu?) -> Set<String> {
        var keys = EditorSettings.protectedShortcuts
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                let modifiers = item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
                let assignable = (item.representedObject as? String).map(EditorSettings.commands.contains) ?? false
                if !assignable && !item.keyEquivalent.isEmpty
                    && (modifiers == .command || modifiers == [.command, .shift])
                {
                    keys.insert(modifiers.contains(.shift) ? item.keyEquivalent.uppercased() : item.keyEquivalent)
                }
                if let child = item.submenu { walk(child) }
            }
        }
        if let menu { walk(menu) }
        return keys
    }
    private var settingsForm: FormPanel?
    @objc func showSettings(_ sender: Any?) {
        if let settingsForm {
            settingsForm.window.makeKeyAndOrderFront(nil)
            return
        }
        let baseline: Data
        do { baseline = try SavedConfiguration.bytes(value) } catch {
            TTAlert.present(error)
            return
        }
        let form = FormPanel(title: "Settings", identifier: "TextTank.Settings", size: NSSize(width: 600, height: 560))
        settingsForm = form
        form.onClose = { [weak self] in self?.settingsForm = nil }
        form.note(
            "Changes apply when you save. Indentation and wrapping chosen for an individual document are kept. Shortcut keys use Command; uppercase adds Shift."
        )
        let width = NSTextField(string: String(value.tabWidth))
        NumericInput.configure(width)
        let tabs = NSButton(checkboxWithTitle: "Indent with tabs", target: nil, action: nil)
        tabs.state = value.useTabs ? .on : .off
        let wrap = NSButton(checkboxWithTitle: "Wrap lines", target: nil, action: nil)
        wrap.state = value.wrap ? .on : .off
        let appearance = NSPopUpButton()
        ControlPresentation.populate(
            appearance, choices: [("system", "System"), ("light", "Light"), ("dark", "Dark")],
            selected: value.appearance)
        let shortcuts = SettingsShortcutEditor(value)
        let shortcut = shortcuts.popup, key = shortcuts.key
        let clear = NSButton(
            title: "Clear Custom Shortcut", target: shortcuts,
            action: #selector(SettingsShortcutEditor.clearShortcut(_:)))
        clear.setAccessibilityLabel("Clear the selected command's custom shortcut")
        clear.cell?.setAccessibilityLabel("Clear the selected command's custom shortcut")
        clear.identifier = NSUserInterfaceItemIdentifier("settings.shortcut.clear")
        ControlPresentation.label("Tab width", control: width)
        ControlPresentation.label("Indent with tabs", control: tabs)
        ControlPresentation.label("Wrap lines", control: wrap)
        ControlPresentation.label("Appearance", control: appearance)
        ControlPresentation.label("Command shortcut to assign", control: shortcut)
        ControlPresentation.label("Shortcut key", control: key)
        let stack = NSStackView(views: [
            NSTextField(labelWithString: "Tab width (1–32)"), width, tabs, wrap, appearance,
            NSTextField(labelWithString: "Command shortcuts (Command; uppercase adds Shift)"), shortcut, key, clear
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 420, height: 290)
        if let notice = shortcutLoadNotice {
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 96))
            text.string = notice
            text.isEditable = false
            text.font = .systemFont(ofSize: NSFont.systemFontSize)
            text.setAccessibilityLabel("Ignored saved shortcuts; the original settings file is preserved")
            text.autoresizingMask = [.width]
            let scroll = NSScrollView(frame: text.frame)
            scroll.documentView = text
            scroll.hasVerticalScroller = true
            stack.addArrangedSubview(scroll)
            scroll.widthAnchor.constraint(equalToConstant: 420).isActive = true
            scroll.heightAnchor.constraint(equalToConstant: 96).isActive = true
            stack.frame.size.height += 104
        }
        form.add(stack)
        func submit(reset: Bool) {
            guard form.commitEditing() else { return }
            do {
                var updated = shortcuts.settings()
                if reset {
                    let confirm = TTAlert()
                    confirm.messageText = "Reset all editor settings to their defaults?"
                    confirm.informativeText =
                        "Tab width, indentation, wrapping, appearance and every assigned shortcut return to their defaults. Documents are not changed."
                    confirm.addButton(withTitle: "Cancel", role: .cancel)
                    confirm.addButton(withTitle: "Reset Defaults").hasDestructiveAction = true
                    guard confirm.runModal() == .alertSecondButtonReturn else { return }
                    updated = EditorSettings()
                } else {
                    guard let tabWidth = NumericInput.integer(width), (1...32).contains(tabWidth) else {
                        throw SettingsError.tabWidth
                    }
                    updated.tabWidth = tabWidth
                    updated.useTabs = tabs.state == .on
                    updated.wrap = wrap.state == .on
                    updated.appearance = ControlPresentation.selectedID(appearance) ?? "system"
                }
                try updated.validate(reservedKeys: Self.reservedShortcuts(in: NSApp?.mainMenu))
                try SavedConfiguration.requireUnchanged(value, since: baseline)
                if loadError != nil {
                    guard try StoreRecovery.ensureWritable(loadState, allowSymbolicLink: false) else { return }
                }
                try SavedConfiguration.requireUnchanged(value, since: baseline)
                if let backup = try save(updated) {
                    let message =
                        "Settings replaced. The previous settings file was kept as “\(backup.lastPathComponent)”."
                    onStatus(message)
                    Announce.say(message)
                }
                form.close()
            } catch {
                let field: NSView?
                var presentedError = error
                switch error {
                case SettingsError.conflict, SettingsError.invalidShortcut, SettingsError.unknownShortcut,
                    SettingsError.duplicateShortcut:
                    if let failure = shortcuts.draft.settings.shortcutValidationFailure(
                        reservedKeys: Self.reservedShortcuts(in: NSApp?.mainMenu))
                    {
                        field = shortcuts.revealValidation(failure)
                        presentedError = failure
                    } else {
                        field = nil
                    }
                case SettingsError.tabWidth: field = width
                default: field = nil
                }
                form.showValidation(presentedError, field: field)
            }
        }
        form.button("Save", identifier: "settings.save") { submit(reset: false) }.keyEquivalent = "\r"
        form.button("Cancel", identifier: "settings.cancel", cancel: true) { form.close() }
        form.button("Reset Defaults…", identifier: "settings.reset") { submit(reset: true) }
        form.window.initialFirstResponder = width
        form.show()
    }
}
