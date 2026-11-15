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
    static let commands: Set<String> = [
        "duplicateLine", "deleteLine", "transposeLine", "upper", "lower", "trimTrailing", "moveLineUp", "moveLineDown",
        "joinLines", "bookmarkToggle", "bookmarkNext", "bookmarkPrevious"
    ]
    static let reserved: Set<String> = [
        "a", "c", "v", "x", "z", "Z", "s", "S", "n", "o", "w", "q", "p", "f", "F", "g", "G", "P", "m", "[", "]", "+",
        "-", ",", "h", "l"
    ]
    func validate() throws {
        guard version == 1, (1...32).contains(tabWidth), ["system", "light", "dark"].contains(appearance) else {
            throw SettingsError.invalid
        }
        var seen = Set<String>()
        var effective = ["duplicateLine": "d"]
        effective.merge(shortcuts) { _, new in new }
        for (id, key) in effective {
            guard Self.commands.contains(id), key.count == 1,
                key.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 32 && $0.value < 127 }),
                !Self.reserved.contains(key), seen.insert(key).inserted
            else { throw SettingsError.conflict }
        }
    }
    static func decode(_ data: Data) throws -> Self {
        try PersistedFormat.check(data, context: "Editor settings")
        let settings = try JSONDecoder().decode(Self.self, from: data)
        try settings.validate()
        return settings
    }
}
enum SettingsError: Error, LocalizedError {
    case invalid, conflict, unreadable, tabWidth
    var errorDescription: String? {
        switch self {
        case .tabWidth: return "Tab width must be a whole number from 1 to 32. The settings were not changed."
        case .invalid: return "Unsupported settings version or value. Existing settings have not been replaced."
        case .conflict:
            return
                "Shortcut conflicts with another action, uses a reserved key, or is not a single printable ASCII character."
        case .unreadable: return "The saved settings could not be read. The original file is preserved."
        }
    }
}
final class SettingsController: NSObject {
    private(set) var value = EditorSettings()
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
            value = try EditorSettings.decode(WorkspaceStore.readRegularFile(self.url, maximumBytes: 1024 * 1024))
        } catch  where error.isFileNotFound {} catch {
            loadError = error
        }
    }
    /// What the user is told at launch when the settings file could not be read. Every load
    /// failure (unsupported value, shortcut conflict, malformed JSON, unreadable file) gets the
    /// same two facts: defaults are in use, and the file on disk has not been changed.
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
        try settings.validate()
        if loadError != nil && !replacingUnreadable { throw SettingsError.unreadable }
        try PrivateFileStore.prepareDirectory(url.deletingLastPathComponent())
        let data = try JSONEncoder().encode(settings)
        let priorError = loadError
        var backup: URL?
        if loadError != nil {
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
                    item.keyEquivalent = value.shortcuts[id] ?? (id == "duplicateLine" ? "d" : "")
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
        let tabs = NSButton(checkboxWithTitle: "Indent with tabs", target: nil, action: nil)
        tabs.state = value.useTabs ? .on : .off
        let wrap = NSButton(checkboxWithTitle: "Wrap lines", target: nil, action: nil)
        wrap.state = value.wrap ? .on : .off
        let appearance = NSPopUpButton()
        appearance.addItems(withTitles: ["system", "light", "dark"])
        appearance.selectItem(withTitle: value.appearance)
        let shortcut = NSPopUpButton()
        shortcut.addItems(withTitles: EditorSettings.commands.sorted())
        let key = NSTextField(string: "")
        key.placeholderString = "Optional shortcut for selected command"
        width.setAccessibilityLabel("Tab width")
        tabs.setAccessibilityLabel("Indent with tabs")
        wrap.setAccessibilityLabel("Wrap lines")
        appearance.setAccessibilityLabel("Appearance")
        shortcut.setAccessibilityLabel("Command shortcut to assign")
        key.setAccessibilityLabel("Shortcut key")
        let stack = NSStackView(views: [
            NSTextField(labelWithString: "Tab width (1–32)"), width, tabs, wrap, appearance,
            NSTextField(labelWithString: "Assign one command shortcut"), shortcut, key
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 420, height: 250)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel", role: .cancel)
        // The ellipsis says a confirmation follows (DS-22); the confirmation holds the destructive button.
        alert.addButton(withTitle: "Reset Defaults…")
        while true {
            let result = alert.runModal()
            guard result == .alertFirstButtonReturn || result == .alertThirdButtonReturn else { return }
            do {
                var updated = value
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
                    guard let tabWidth = Int(width.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
                        (1...32).contains(tabWidth)
                    else { throw SettingsError.tabWidth }
                    updated.tabWidth = tabWidth
                    updated.useTabs = tabs.state == .on
                    updated.wrap = wrap.state == .on
                    updated.appearance = appearance.titleOfSelectedItem ?? "system"
                    if !key.stringValue.isEmpty, let id = shortcut.titleOfSelectedItem {
                        updated.shortcuts[id] = key.stringValue
                    }
                }
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
                switch error {
                case SettingsError.conflict: field = key
                case SettingsError.tabWidth: field = width
                default: field = nil
                }
                alert.showValidation(error, field: field)
            }
        }
    }
}
