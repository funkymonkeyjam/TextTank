// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// Persisted format, version 1; see "Persisted formats" in docs/architecture.md. A new field
/// must be Optional or decoded with decodeIfPresent in an extension, or old files stop loading.
struct EditorSettings: Codable, Equatable {
    var version = 1
    var tabWidth = 4
    var useTabs = true
    var wrap = false
    var appearance = "system"
    // Key equivalents use AppKit's uppercase convention for Shift.
    var shortcuts: [String: String] = [:]
    static let commands = EditorCommand.shortcutIdentifiers
    static let reserved: Set<String> = [
        "a", "c", "v", "x", "z", "Z", "s", "S", "n", "o", "w", "q", "p", "f", "F", "g", "G", "P", "m", "[", "]", "+",
        "-", ",", "h", "l"
    ]
    /// Empty/default removes an override; the version-1 wire vocabulary never stores an empty key.
    mutating func setShortcut(_ key: String, for id: String) {
        if key.isEmpty || key == EditorCommand.defaultShortcuts[id] {
            shortcuts.removeValue(forKey: id)
        } else {
            shortcuts[id] = key
        }
    }
    func shortcut(for id: String) -> String { shortcuts[id] ?? EditorCommand.defaultShortcuts[id] ?? "" }
    static func validShortcutKey(_ key: String) -> Bool {
        key.count == 1 && key.unicodeScalars.allSatisfy { $0.isASCII && $0.value > 32 && $0.value < 127 }
    }
    // System Find selection and window cycling are protected even before a main menu exists.
    static let protectedShortcuts = reserved.union(["e", "`"])
    func validate(reservedKeys: Set<String> = Self.protectedShortcuts) throws {
        guard version == 1, (1...32).contains(tabWidth), ["system", "light", "dark"].contains(appearance) else {
            throw SettingsError.invalid
        }
        if let failure = shortcutValidationFailure(reservedKeys: reservedKeys) { throw failure.error }
    }
    /// The same deterministic validation supplies identity to editors and errors to strict saves.
    /// An implicit default cannot be edited in isolation; identify its conflicting explicit override.
    func shortcutValidationFailure(reservedKeys: Set<String>) -> ShortcutValidationFailure? {
        var effective = EditorCommand.defaultShortcuts
        effective.merge(shortcuts) { _, new in new }
        var owners: [String: String] = [:]
        for id in effective.keys.sorted() {
            let key = effective[id] ?? ""
            guard Self.commands.contains(id) else { return .init(command: id, error: .unknownShortcut) }
            guard Self.validShortcutKey(key) else { return .init(command: id, error: .invalidShortcut) }
            guard !reservedKeys.contains(key) else { return .init(command: id, error: .conflict) }
            if let owner = owners[key] {
                let command = shortcuts[id] == nil ? owner : id
                return .init(command: command, error: .duplicateShortcut(first: owner, second: id, key: key))
            }
            owners[key] = id
        }
        return nil
    }
    /// Strict decode remains available to validation/import callers; tolerant startup is explicit.
    static func decode(_ data: Data) throws -> Self {
        try PersistedFormat.check(data, context: "Editor settings")
        let settings = try JSONDecoder().decode(Self.self, from: data)
        try settings.validate()
        return settings
    }
    static func load(_ data: Data, reservedKeys: Set<String>) throws -> (settings: Self, issues: [ShortcutLoadIssue]) {
        try PersistedFormat.check(data, context: "Editor settings")
        return try JSONDecoder().decode(Self.self, from: data).toleratingShortcuts(reservedKeys: reservedKeys)
    }
    func toleratingShortcuts(reservedKeys: Set<String>) throws -> (settings: Self, issues: [ShortcutLoadIssue]) {
        var result = self
        result.shortcuts = [:]
        // Core schema/values are never repaired, guessed or made lenient.
        try result.validate(reservedKeys: reservedKeys)
        var issues: [String: ShortcutLoadIssue] = [:]
        for id in shortcuts.keys.sorted() {
            guard let key = shortcuts[id] else { continue }
            let reason: ShortcutLoadIssue.Reason?
            if !Self.commands.contains(id) {
                reason = .unavailable
            } else if !Self.validShortcutKey(key) {
                reason = .invalid
            } else if reservedKeys.contains(key) {
                reason = .reserved
            } else {
                reason = nil
            }
            if let reason {
                issues[id] = .init(command: id, key: key, reason: reason)
            } else {
                result.shortcuts[id] = key
            }
        }
        // Removing a conflicting override can restore a default key. Re-evaluate until stable;
        // there are only twelve assignable commands, and every iteration removes an override.
        while true {
            var effective = EditorCommand.defaultShortcuts
            effective.merge(result.shortcuts) { _, new in new }
            let groups = Dictionary(grouping: effective.keys, by: { effective[$0] ?? "" })
            var removed = false
            for key in groups.keys.sorted() {
                let ids = (groups[key] ?? []).sorted()
                guard ids.count > 1 else { continue }
                let winner = ids.first { result.shortcuts[$0] == nil } ?? ids[0]
                for id in ids where id != winner {
                    if result.shortcuts.removeValue(forKey: id) != nil {
                        issues[id] = .init(command: id, key: key, reason: .duplicate(winner))
                        removed = true
                    }
                }
            }
            if !removed { break }
        }
        try result.validate(reservedKeys: reservedKeys)
        return (result, issues.values.sorted { $0.command < $1.command })
    }
}
struct ShortcutLoadIssue: Equatable {
    enum Reason: Equatable { case unavailable, invalid, reserved, duplicate(String) }
    let command: String, key: String, reason: Reason
    var message: String {
        let title = EditorCommand(rawValue: command)?.title ?? "Unavailable command"
        switch reason {
        case .unavailable:
            return
                "A saved shortcut for a command that is no longer available was ignored. Other settings remain in use. The settings file has not been changed."
        case .invalid:
            return
                "The saved shortcut for “\(title)” is not one supported printable character and was ignored. Other settings remain in use. The settings file has not been changed."
        case .reserved:
            return
                "The saved shortcut for “\(title)” is reserved for another action and was ignored. Other settings remain in use. The settings file has not been changed."
        case .duplicate(let owner):
            let ownerTitle = EditorCommand(rawValue: owner)?.title ?? "another command"
            return
                "The saved shortcut for “\(title)” conflicts with “\(ownerTitle)” and was ignored. Other settings remain in use. The settings file has not been changed."
        }
    }
}
enum SettingsError: Error, LocalizedError, Equatable {
    case invalid, conflict, unreadable, tabWidth, unknownShortcut, invalidShortcut
    case duplicateShortcut(first: String, second: String, key: String)
    var errorDescription: String? {
        switch self {
        case .tabWidth: return "Tab width must be a whole number from 1 to 32. The settings were not changed."
        case .invalid: return "Unsupported settings version or value. Existing settings have not been replaced."
        case .conflict:
            return
                "That shortcut is reserved for another action. Choose a different key. The settings were not changed."
        case .unknownShortcut: return "This command cannot be assigned a shortcut. The settings were not changed."
        case .invalidShortcut: return "A shortcut must be one printable ASCII character. The settings were not changed."
        case .duplicateShortcut(let first, let second, let key):
            let firstTitle = EditorCommand(rawValue: first)?.title ?? "another command"
            let secondTitle = EditorCommand(rawValue: second)?.title ?? "another command"
            return
                "Command-\(key) is assigned to both “\(firstTitle)” and “\(secondTitle)”. Choose a different shortcut. The settings were not changed."
        case .unreadable: return "The saved settings could not be read. The original file is preserved."
        }
    }
}

struct ShortcutValidationFailure: LocalizedError {
    let command: String
    let error: SettingsError
    var errorDescription: String? {
        let title = EditorCommand(rawValue: command)?.title ?? "Unavailable command"
        switch error {
        case .invalidShortcut:
            return "The shortcut for “\(title)” must be one printable ASCII character. The settings were not changed."
        case .conflict:
            return
                "The shortcut for “\(title)” is reserved for another action. Choose a different key. The settings were not changed."
        default: return error.localizedDescription
        }
    }
}

/// A working copy keeps edits made for earlier popup rows; selection is never inferred from a title.
struct SettingsShortcutDraft {
    private(set) var settings: EditorSettings
    private(set) var selected: String
    init(_ settings: EditorSettings) {
        self.settings = settings
        selected =
            EditorCommand.allCases.filter(\.isShortcutAssignable).sorted { $0.title < $1.title }.first?.rawValue ?? ""
    }
    mutating func select(_ id: String, committing key: String) -> String {
        settings.setShortcut(key, for: selected)
        selected = id
        return settings.shortcut(for: id)
    }
    mutating func commit(_ key: String) { settings.setShortcut(key, for: selected) }
    mutating func clear() -> String {
        settings.setShortcut("", for: selected)
        return settings.shortcut(for: selected)
    }
}
private final class SettingsShortcutEditor: NSObject {
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
        popup.setAccessibilityLabel("Command shortcut to assign")
        popup.identifier = NSUserInterfaceItemIdentifier("settings.shortcut.command")
        key.stringValue = settings.shortcut(for: draft.selected)
        key.placeholderString = "No custom shortcut"
        key.setAccessibilityLabel("Shortcut key")
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

final class SettingsController: NSObject {
    private(set) var value = EditorSettings()
    private(set) var ignoredShortcutBindings: [ShortcutLoadIssue] = []
    var shortcutLoadNotice: String? {
        ignoredShortcutBindings.isEmpty ? nil : ignoredShortcutBindings.map(\.message).joined(separator: "\n\n")
    }
    /// Before a menu exists the historical fallback is available. Once built, every fixed
    /// Command/Command-Shift item is reserved, including non-editor and newly added actions.
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
    func reconcileShortcuts(with menu: NSMenu) {
        guard loadError == nil else { return }
        do {
            let loaded = try value.toleratingShortcuts(reservedKeys: Self.reservedShortcuts(in: menu))
            value = loaded.settings
            ignoredShortcutBindings += loaded.issues
        } catch { loadError = error }
    }
    let loadState: StoreLoadState
    private(set) var loadError: Error? {
        get { loadState.error }
        set { loadState.error = newValue }
    }
    let url: URL
    init(url: URL? = nil) {
        self.url = url ?? AppStorage.url(.settings)
        loadState = StoreLoadState(url: self.url, displayName: "Editor settings")
        super.init()
        do {
            let loaded = try EditorSettings.load(
                WorkspaceStore.readRegularFile(self.url, maximumBytes: 1024 * 1024),
                reservedKeys: Self.reservedShortcuts(in: NSApp?.mainMenu))
            value = loaded.settings
            ignoredShortcutBindings = loaded.issues
        } catch  where error.isFileNotFound {} catch {
            loadError = error
        }
    }
    /// What the user is told at launch when the settings file could not be read. Every load
    /// schema/security failure gets the same two facts: defaults are in use and the file has
    /// not been changed. Tolerated shortcut-only issues have a separate notice and retained values.
    var loadFailureMessage: String? {
        loadError.map {
            "The saved settings could not be read, so default settings are in use. The settings file has not been changed.\n\nReason: \($0.localizedDescription)\n\nFile: \(url.path)"
        }
    }
    /// Never overwrites a settings file that failed to load unless the caller has the user's
    /// explicit confirmation. With confirmation the unread file is first moved aside, intact,
    /// under a unique sibling name; it is renamed rather than copied because the load may have
    /// failed on size or permissions. Returns the backup location when one was made.
    @discardableResult func save(_ settings: EditorSettings, replacingUnreadable: Bool = false) throws -> URL? {
        try settings.validate(reservedKeys: Self.reservedShortcuts(in: NSApp?.mainMenu))
        if loadError != nil && !replacingUnreadable { throw SettingsError.unreadable }
        try PrivateFileStore.prepareDirectory(url.deletingLastPathComponent())
        let data = try JSONEncoder().encode(settings)
        let priorError = loadError
        var backup: URL?
        if loadError != nil || !ignoredShortcutBindings.isEmpty {
            // A tolerant load never rewrites implicitly. The first explicit repair save retains
            // the original file with the same strict no-link and rollback guarantees.
            do { backup = try loadState.moveAside(allowSymbolicLink: false, tag: "unreadable") } catch PrivateFileError
                .unsafeLocation
            { throw WorkspaceError.unsafeLocation }
        }
        do { try PrivateFileStore.write(data, to: url, maximumBytes: 1024 * 1024, temporaryPrefix: ".settings-") } catch
        {
            // Put the original back so a failed replacement leaves the folder as it was.
            if let backup { _ = renamex_np(backup.path, url.path, UInt32(RENAME_EXCL)) }
            loadError = priorError
            throw error
        }
        let previous = value
        value = settings
        loadError = nil
        ignoredShortcutBindings = []
        apply(replacing: previous)
        return backup
    }
    func apply(to editor: TTEditor) {
        editor.configureTabWidth(value.tabWidth, useTabs: value.useTabs)
        editor.wrap = value.wrap
    }
    /// Carries a changed default to an open view only where that view still had the old default.
    /// Indentation chosen for one document, or wrapping chosen for one view, in the status bar is
    /// the person's own choice and a later Settings save leaves it alone.
    private func carry(from previous: EditorSettings, to editor: TTEditor) {
        let info = editor.statusInfo
        if previous.tabWidth != value.tabWidth || previous.useTabs != value.useTabs,
            info["tabWidth"]?.intValue == previous.tabWidth, info["useTabs"]?.boolValue == previous.useTabs
        {
            editor.configureTabWidth(value.tabWidth, useTabs: value.useTabs)
        }
        if previous.wrap != value.wrap, editor.wrap == previous.wrap { editor.wrap = value.wrap }
    }
    /// `previous` is the settings a save replaced; nil at launch, when every view takes the defaults.
    func apply(replacing previous: EditorSettings? = nil) {
        NSApp.appearance =
            value.appearance == "system" ? nil : NSAppearance(named: value.appearance == "dark" ? .darkAqua : .aqua)
        for doc in NSDocumentController.shared.documents.compactMap({ $0 as? TextDocument }) {
            let clones = doc.windowControllers.compactMap { ($0 as? EditorWindowController)?.secondary }
            for editor in [doc.editor] + clones {
                if let previous { carry(from: previous, to: editor) } else { apply(to: editor) }
            }
        }
        func update(_ menu: NSMenu) {
            for item in menu.items {
                if let id = item.representedObject as? String, EditorSettings.commands.contains(id) {
                    item.keyEquivalent = value.shortcuts[id] ?? EditorCommand.defaultShortcuts[id] ?? ""
                }
                if let child = item.submenu { update(child) }
            }
        }
        if let menu = NSApp.mainMenu { update(menu) }
    }
    @objc func showSettings(_ sender: Any?) {
        let alert = TTAlert()
        alert.messageText = "Editor Settings"
        alert.informativeText =
            "Applies to new views, and to open views that still use the previous defaults. Indentation or wrapping you chose for one document in the status bar is kept. Shortcut keys use Command; uppercase adds Shift."
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
        clear.identifier = NSUserInterfaceItemIdentifier("settings.shortcut.clear")
        width.setAccessibilityLabel("Tab width")
        tabs.setAccessibilityLabel("Indent with tabs")
        wrap.setAccessibilityLabel("Wrap lines")
        appearance.setAccessibilityLabel("Appearance")
        shortcut.setAccessibilityLabel("Command shortcut to assign")
        key.setAccessibilityLabel("Shortcut key")
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
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel", role: .cancel)
        // The ellipsis says a confirmation follows (DS-22); the confirmation holds the destructive button.
        alert.addButton(withTitle: "Reset Defaults…")
        while true {
            let result = alert.runModal()
            guard result == .alertFirstButtonReturn || result == .alertThirdButtonReturn else { return }
            do {
                var updated = shortcuts.settings()
                if result == .alertThirdButtonReturn {
                    let confirm = TTAlert()
                    confirm.messageText = "Reset all editor settings to their defaults?"
                    confirm.informativeText =
                        "Tab width, indentation, wrapping, appearance and every assigned shortcut return to their defaults. Documents are not changed."
                    confirm.addButton(withTitle: "Cancel", role: .cancel)
                    confirm.addButton(withTitle: "Reset Defaults").hasDestructiveAction = true
                    guard confirm.runModal() == .alertSecondButtonReturn else { return }
                    updated = EditorSettings()
                } else {
                    guard let tabWidth = NumericInput.integer(width),
                        (1...32).contains(tabWidth)
                    else { throw SettingsError.tabWidth }
                    updated.tabWidth = tabWidth
                    updated.useTabs = tabs.state == .on
                    updated.wrap = wrap.state == .on
                    updated.appearance = ControlPresentation.selectedID(appearance) ?? "system"
                }
                // Validate every retained draft before any modal recovery can move saved data aside.
                try updated.validate(reservedKeys: Self.reservedShortcuts(in: NSApp?.mainMenu))
                let replacing = false
                if loadError != nil {
                    // Save and Reset Defaults both arrive here; neither may silently replace the unread file.
                    guard try StoreRecovery.ensureWritable(loadState, allowSymbolicLink: false) else { return }
                }
                if let backup = try save(updated, replacingUnreadable: replacing) {
                    let message =
                        "Settings replaced. The previous settings file was kept as “\(backup.lastPathComponent)”."
                    (NSApp.mainWindow?.windowController as? EditorWindowController)?.showTransientStatus(message)
                    Announce.say(message)
                }
                return
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
                alert.showValidation(presentedError, field: field)
            }
        }
    }
}
