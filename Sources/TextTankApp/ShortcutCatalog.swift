// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import TextTankCore

extension MenuShortcut {
    /// The key a menu item answers to now. Nil when it has none.
    @MainActor init?(_ item: NSMenuItem) {
        guard !item.keyEquivalent.isEmpty else { return nil }
        var modifiers: Set<Modifier> = []
        let mask = item.keyEquivalentModifierMask
        if mask.contains(.command) { modifiers.insert(.command) }
        if mask.contains(.option) { modifiers.insert(.option) }
        if mask.contains(.control) { modifiers.insert(.control) }
        if mask.contains(.shift) { modifiers.insert(.shift) }
        self.init(item.keyEquivalent, modifiers)
    }
    /// The shortcut a key press asks for, in the form menus use. Nil for a press with no key.
    @MainActor init?(_ event: NSEvent) {
        guard event.type == .keyDown, let characters = event.charactersIgnoringModifiers, characters.count == 1
        else { return nil }
        var modifiers: Set<Modifier> = []
        let flags = event.modifierFlags
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        var key = characters
        switch key {
        case "\u{19}": // Shift-Tab arrives as backtab
            key = "\t"
            modifiers.insert(.shift)
        case "\u{7f}": key = "\u{8}" // the Delete key; menus call it backspace
        case "\u{f728}": key = "\u{7f}" // Forward Delete
        default:
            if key != key.lowercased() {
                key = key.lowercased()
                modifiers.insert(.shift)
            } else if modifiers.contains(.shift), EditorSettings.validShortcutKey(key), key.uppercased() == key,
                key.rangeOfCharacter(from: .decimalDigits) == nil
            {
                // A shifted symbol, such as the question mark, already says Shift.
                modifiers.remove(.shift)
            }
        }
        self.init(key, modifiers)
    }
}

/// The commands of the menu bar as the shortcut model sees them, and the one place a saved
/// shortcut is put on a menu item (DS-20).
///
/// A command is known by its action, its explicit target's type and its represented object,
/// never by its title or its place in the menu bar, so a saved shortcut follows the command
/// when the menus are rearranged. These identifiers are stored in the settings file.
@MainActor enum ShortcutCatalog {
    struct Entry {
        enum Kind: Equatable {
            /// A key can be recorded for it. A yielding default gives way without a question.
            case assignable(yields: Bool)
            /// One of the shortcuts that keep their meaning in every Mac app (DS-25).
            case system(String)
            /// Listed, but its key is set somewhere else; the text says where.
            case fixed(String)
        }
        let id: String
        /// Where the menu bar lists the command, as the Command Palette writes it.
        let title: String
        let item: NSMenuItem
        let standard: MenuShortcut?
        let kind: Kind
    }
    struct Catalog {
        /// Every command a person can see in the menu bar, in menu order.
        var entries: [Entry] = []
        /// Hidden second shortcuts of a command; each gives way to an assigned shortcut.
        var aliases: [(item: NSMenuItem, standard: MenuShortcut)] = []
        var context = ShortcutContext(commands: [:], fixed: [:], isComplete: true)
    }
    /// A saved Run command's own identifier begins with this; see `ShortcutContext.transientPrefixes`.
    static let transientPrefixes = ["RunController.run:/"]
    private static var defaultKey = 0
    private final class DefaultRecord: NSObject {
        let shortcut: MenuShortcut?
        init(_ shortcut: MenuShortcut?) { self.shortcut = shortcut }
    }
    /// The key the item had when the menu was built. It is recorded the first time the item is
    /// read here, which is always before `apply` has changed it.
    static func standardShortcut(of item: NSMenuItem) -> MenuShortcut? {
        if let fallback = item as? DefaultShortcutItem { return fallback.shortcut }
        if let record = objc_getAssociatedObject(item, &defaultKey) as? DefaultRecord { return record.shortcut }
        var shortcut = MenuShortcut(item)
        if let id = item.representedObject as? String, EditorSettings.commands.contains(id) {
            // A version-1 command's default is the catalogue's, whatever the item was built with.
            shortcut = EditorCommand.defaultShortcuts[id].flatMap(MenuShortcut.init(storedText:))
        }
        objc_setAssociatedObject(item, &defaultKey, DefaultRecord(shortcut), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return shortcut
    }
    static func identifier(for item: NSMenuItem) -> String? {
        let object = item.representedObject
        if let raw = object as? String, EditorSettings.commands.contains(raw) { return raw }
        guard let action = item.action else { return nil }
        let selector = NSStringFromSelector(action)
        // Editor commands and transforms keep the catalogue identifiers they already have.
        if selector == "command:", let raw = object as? String, !raw.isEmpty { return raw }
        var id = item.target.map { String(describing: type(of: $0)) + "." + selector } ?? selector
        switch object {
        case nil: break
        case let text as String: if !text.isEmpty { id += "/" + text }
        case let values as [String: String]:
            id += "/" + values.keys.sorted().map { $0 + "=" + (values[$0] ?? "") }.joined(separator: "&")
        default: return nil
        }
        if item.tag != 0 { id += "#\(item.tag)" }
        return id
    }
    /// Why the commands of a menu that its owner rebuilds cannot be given a key here.
    private static func fixedNote(for delegate: NSMenuDelegate?) -> String? {
        switch delegate {
        case is AutomationController:
            return "An automation's shortcut is set in Tools › Automations › Manage Automations…."
        case is MacroController:
            let record = MenuShortcut.recordMacro.spokenText, again = MenuShortcut.playMacroAgain.spokenText
            return "Macro keys are fixed: \(record) starts and stops recording, and \(again) plays the macro again."
        case is LanguageController: return "A syntax language cannot be given a shortcut."
        case is GroupCommandController:
            return "Editor group keys are fixed: Control-Command-1 to 4 move to a group."
        default: return nil
        }
    }
    static func catalog(in bar: NSMenu) -> Catalog {
        var catalog = Catalog()
        var commands: [String: ShortcutContext.Command] = [:], fixed: [String: String] = [:]
        var listed: Set<String> = [], primary: [String: String] = [:]
        func reserve(_ item: NSMenuItem, _ title: String) {
            if let current = MenuShortcut(item) { fixed[current.identity] = title }
        }
        func collect(_ menu: NSMenu, path: [String], note inherited: String?) {
            guard menu !== NSApp.servicesMenu else { return }
            let note = inherited ?? fixedNote(for: menu.delegate)
            for item in menu.items where !item.isSeparatorItem {
                let route = path + [item.title], title = route.joined(separator: " › ")
                if let child = item.submenu {
                    // Recently opened files are documents, not commands.
                    if !(child.delegate is RecentDocumentsMenu)
                        && item.title != WorkspaceBrowserController.recentFilesTitle
                    {
                        collect(child, path: route, note: note)
                    }
                    continue
                }
                let standard = standardShortcut(of: item)
                let legacy = (item.representedObject as? String).map(EditorSettings.commands.contains) ?? false
                if item.isHidden || item.isAlternate || item.title.isEmpty {
                    // A second key for a command that is listed elsewhere.
                    if !legacy, let fallback = item as? DefaultShortcutItem {
                        catalog.aliases.append((item, fallback.shortcut))
                    } else if !legacy {
                        reserve(item, title)
                    }
                    if !legacy { continue }
                }
                guard legacy || item.action.map({ !NSStringFromSelector($0).hasPrefix("_") }) == true else {
                    reserve(item, title)
                    continue
                }
                let stable = identifier(for: item)
                var kind: Entry.Kind
                if legacy {
                    kind = .assignable(yields: item is DefaultShortcutItem)
                } else if let note {
                    kind = .fixed(note)
                } else if (item as? DefaultShortcutItem)?.shortcut == .saveAll {
                    kind = .fixed(
                        "Save All keeps Option-Command-S unless an automation uses that key. It cannot be changed here."
                    )
                } else if stable == nil {
                    kind = .fixed("This command's shortcut cannot be changed here.")
                } else if let standard, let refusal = ShortcutPolicy.refusal(for: standard), refusal.kind == .system {
                    kind = .system(refusal.reason)
                } else {
                    kind = .assignable(yields: item is DefaultShortcutItem)
                }
                var id = stable ?? "", repeated = false
                if case .assignable = kind {
                    // A command listed twice is one command; its first listing carries the key.
                    if let first = primary[id] {
                        kind = .fixed("This command is also listed as “\(first)”. Change its shortcut there.")
                        repeated = true
                    } else {
                        primary[id] = title
                    }
                }
                // A row that cannot change is never stored, so its place in the menus names it.
                if case .assignable = kind {} else { id = "listed:" + title }
                guard listed.insert(id).inserted else {
                    reserve(item, title)
                    continue
                }
                catalog.entries.append(Entry(id: id, title: title, item: item, standard: standard, kind: kind))
                switch kind {
                case .assignable(let yields):
                    commands[id] = .init(title: title, standard: standard, yields: yields)
                case .fixed: if !repeated { reserve(item, title) }
                case .system: break
                }
            }
        }
        collect(bar, path: [], note: nil)
        catalog.context = ShortcutContext(
            commands: commands, fixed: fixed, isComplete: true, transientPrefixes: transientPrefixes)
        return catalog
    }
    /// Before the menu bar exists only the version-1 rules can be applied; see `ShortcutContext`.
    static func context(in bar: NSMenu?) -> ShortcutContext {
        bar.map { catalog(in: $0).context } ?? ShortcutContext(reservedKeys: EditorSettings.protectedShortcuts)
    }
    private static func set(_ shortcut: MenuShortcut?, on item: NSMenuItem) {
        let key = shortcut?.key ?? "", mask = shortcut?.appKitModifiers ?? [.command]
        if item.keyEquivalent != key { item.keyEquivalent = key }
        if item.keyEquivalentModifierMask != mask { item.keyEquivalentModifierMask = mask }
    }
    /// Puts every command's current shortcut on its menu item. A default is restored exactly
    /// as the menu was built with it.
    static func apply(_ settings: EditorSettings, to bar: NSMenu) {
        let catalog = catalog(in: bar)
        for entry in catalog.entries {
            guard case .assignable = entry.kind else { continue }
            set(settings.effectiveShortcut(for: entry.id, in: catalog.context), on: entry.item)
        }
        for alias in catalog.aliases {
            set(settings.isAssigned(alias.standard) ? nil : alias.standard, on: alias.item)
        }
    }
}
