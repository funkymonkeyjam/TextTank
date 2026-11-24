// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The shortcut model for any command: how a key with its modifiers is stored, shown and
/// compared, which keys can never be assigned, and what the commands of the menu bar are when
/// saved shortcuts are checked. Foundation only; the menu bar itself is read by the Runtime.

extension MenuShortcut {
    /// Keys that are stored by name. `key` is the character AppKit's menus use for them.
    private static let namedKeys: [(name: String, key: String, glyph: String, spoken: String)] =
        [
            ("up", "\u{f700}", "↑", "Up Arrow"), ("down", "\u{f701}", "↓", "Down Arrow"),
            ("left", "\u{f702}", "←", "Left Arrow"), ("right", "\u{f703}", "→", "Right Arrow"),
            ("home", "\u{f729}", "↖", "Home"), ("end", "\u{f72b}", "↘", "End"),
            ("pageup", "\u{f72c}", "⇞", "Page Up"), ("pagedown", "\u{f72d}", "⇟", "Page Down"),
            ("delete", "\u{8}", "⌫", "Delete"), ("forwarddelete", "\u{7f}", "⌦", "Forward Delete"),
            ("tab", "\t", "⇥", "Tab"), ("backtab", "\u{19}", "⇤", "Backtab"), ("return", "\r", "↩", "Return"),
            ("enter", "\u{3}", "⌅", "Enter"), ("escape", "\u{1b}", "⎋", "Escape"), ("space", " ", "Space", "Space"),
            ("plus", "+", "+", "Plus")
        ]
        + (1...20).map { number in
            ("f\(number)", String(UnicodeScalar(0xf703 + UInt32(number))!), "F\(number)", "F\(number)")
        }
    private static let modifierOrder: [(modifier: Modifier, name: String, glyph: String, spoken: String)] = [
        (.control, "ctrl", "⌃", "Control"), (.option, "opt", "⌥", "Option"), (.shift, "shift", "⇧", "Shift"),
        (.command, "cmd", "⌘", "Command")
    ]
    /// A US keyboard's shifted symbols and the keys they are on, used only to compare shortcuts:
    /// Command-Plus and Shift-Command-Equals are one key press.
    private static let shiftedSymbols: [Character: Character] = Dictionary(
        uniqueKeysWithValues: zip("~!@#$%^&*()_+{}|:\"<>?", "`1234567890-=[]\\;',./"))

    private var named: (name: String, key: String, glyph: String, spoken: String)? {
        Self.namedKeys.first { $0.key == key }
    }
    /// A function key, the only kind of key that needs no modifier.
    package var isFunctionKey: Bool { named?.name.hasPrefix("f") == true && named?.name != "forwarddelete" }
    /// A key that types a character when pressed alone.
    package var typesCharacter: Bool { named == nil || key == " " || key == "+" }

    /// The version-1 form: one printable ASCII character, Command, and Shift for an uppercase
    /// letter. Anything else is the version-2 form: modifier names and a key name joined by
    /// plus signs, as in `ctrl+opt+k`, `shift+f9` or `ctrl+cmd+up`.
    package init?(storedText text: String) {
        if EditorSettings.validShortcutKey(text) {
            self.init(text, [.command])
            return
        }
        var parts = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let name = parts.popLast(), !name.isEmpty else { return nil }
        var modifiers: Set<Modifier> = []
        for part in parts {
            guard let known = Self.modifierOrder.first(where: { $0.name == part }),
                modifiers.insert(known.modifier).inserted
            else { return nil }
        }
        if let named = Self.namedKeys.first(where: { $0.name == name }) {
            self.init(named.key, modifiers)
        } else if name.count == 1, name.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value != 127 }),
            name == name.lowercased()
        {
            // A letter is stored in lowercase; Shift is always named.
            self.init(name, modifiers)
        } else {
            return nil
        }
    }
    /// Lowercase letter with Shift named, so that `K` with Command and `k` with Shift-Command,
    /// which AppKit treats as one shortcut, are also one value here.
    package var normalized: MenuShortcut {
        guard key.count == 1, key != key.lowercased() else { return self }
        return MenuShortcut(key.lowercased(), modifiers.union([.shift]))
    }
    package var storedText: String {
        let value = normalized
        if value.modifiers == [.command], EditorSettings.validShortcutKey(value.key) { return value.key }
        if value.modifiers == [.command, .shift], value.key.count == 1, value.key != value.key.uppercased(),
            EditorSettings.validShortcutKey(value.key.uppercased())
        {
            return value.key.uppercased()
        }
        return value.longText
    }
    private var longText: String {
        (Self.modifierOrder.filter { modifiers.contains($0.modifier) }.map(\.name) + [named?.name ?? key])
            .joined(separator: "+")
    }
    /// Equal for two shortcuts that are the same key press.
    package var identity: String {
        var value = normalized
        if value.key.count == 1, let base = Self.shiftedSymbols[Character(value.key)] {
            value = MenuShortcut(String(base), value.modifiers.union([.shift]))
        }
        if value.key == "\u{19}" { value = MenuShortcut("\t", value.modifiers.union([.shift])) }
        return value.longText
    }
    /// The one way a shortcut is shown: in Settings, in the Command Palette and in messages
    /// (DS-20). Modifiers are in the order the menu bar draws them.
    package var displayText: String {
        let value = normalized
        return Self.modifierOrder.filter { value.modifiers.contains($0.modifier) }.map(\.glyph).joined()
            + (value.named?.glyph ?? value.key.uppercased())
    }
    /// The same shortcut in words, for sentences and assistive technology.
    package var spokenText: String {
        var value = normalized
        // The tilde is Shift with the backtick key, and is said as that key press.
        if value.key == "~" { value = MenuShortcut("`", value.modifiers.union([.shift])) }
        let key: String
        if let named = value.named {
            key = named.spoken
        } else {
            switch value.key {
            case ",": key = "Comma"
            case ".": key = "Period"
            case "`": key = "Backtick"
            case "-": key = "Minus"
            default: key = value.key.uppercased()
            }
        }
        return (Self.modifierOrder.filter { value.modifiers.contains($0.modifier) }.map(\.spoken) + [key])
            .joined(separator: "-")
    }
}

/// Why a key cannot be given to a command. `reason` is whole sentences for the person.
package struct ShortcutRefusal: Equatable, Sendable {
    package enum Kind: Sendable { case typesText, system }
    package let kind: Kind
    package let reason: String
}

package enum ShortcutPolicy {
    /// DS-25: these keep their meaning in every Mac app. The standard editing keys are here too,
    /// because every text field in every window relies on the menu for them.
    private static let system: [(shortcut: MenuShortcut, meaning: String)] = [
        (.init("q"), "Command-Q quits TextTank."), (.init("w"), "Command-W closes the tab or the window."),
        (.init("h"), "Command-H hides TextTank."),
        (.init("h", [.command, .option]), "Option-Command-H hides the other applications."),
        (.init("m"), "Command-M minimizes the window."), (.init(","), "Command-Comma opens Settings."),
        (.init("`"), "Command-Backtick moves to the next window."),
        (.init("`", [.command, .shift]), "Shift-Command-Backtick moves to the previous window."),
        (.init("f"), "Command-F opens Find."), (.init("g"), "Command-G finds the next match."),
        (.init("g", [.command, .shift]), "Shift-Command-G finds the previous match."),
        (.init("e"), "Command-E uses the selection for Find."), (.init("z"), "Command-Z is Undo in every text field."),
        (.init("z", [.command, .shift]), "Shift-Command-Z is Redo in every text field."),
        (.init("x"), "Command-X is Cut in every text field."), (.init("c"), "Command-C is Copy in every text field."),
        (.init("v"), "Command-V is Paste in every text field."),
        (.init("a"), "Command-A is Select All in every text field."),
        (.init("\t"), "Command-Tab switches between applications."),
        (.init("\t", [.command, .shift]), "Shift-Command-Tab switches between applications."),
        (.init(" "), "Command-Space is used by macOS."),
        (.init("\u{1b}", [.command, .option]), "Option-Command-Escape opens Force Quit."),
        (.init("q", [.command, .shift]), "Shift-Command-Q logs out of macOS."),
        (.init("q", [.command, .control]), "Control-Command-Q locks the screen.")
    ]
    private static let systemMeanings: [String: String] = Dictionary(
        uniqueKeysWithValues: system.map { ($0.shortcut.identity, $0.meaning) })

    package static func isSystem(_ shortcut: MenuShortcut) -> Bool { systemMeanings[shortcut.identity] != nil }
    /// Nil when the key may be given to a command.
    package static func refusal(for shortcut: MenuShortcut) -> ShortcutRefusal? {
        if let meaning = systemMeanings[shortcut.identity] {
            return .init(
                kind: .system,
                reason: meaning
                    + " It keeps that meaning and cannot be given to another command. Choose a different shortcut.")
        }
        let value = shortcut.normalized
        guard !value.isFunctionKey, value.modifiers.isDisjoint(with: [.command, .control]) else { return nil }
        let spoken = value.spokenText
        return .init(
            kind: .typesText,
            reason: value.typesCharacter
                ? "\(spoken) would type text instead of running a command. Add Command or Control, or use a function key."
                : "\(spoken) already moves or edits text. Add Command or Control, or use a function key.")
    }
}

/// What saved shortcuts are checked against: the commands that can be given a key, their
/// defaults, and the keys that belong to commands that cannot change.
package struct ShortcutContext: Sendable {
    package struct Command: Sendable, Equatable {
        package init(title: String, standard: MenuShortcut? = nil, yields: Bool = false) {
            self.title = title
            self.standard = standard
            self.yields = yields
        }
        /// Where the menu bar lists the command, as in "File › Save".
        package var title: String
        /// The default. Nil when the command has none.
        package var standard: MenuShortcut?
        /// A default that gives way, without a question, to a shortcut the person assigned.
        package var yields: Bool
    }
    package var commands: [String: Command]
    /// Keys of commands that cannot be changed here, by `MenuShortcut.identity`, with the
    /// title of the command that has each one.
    package var fixed: [String: String]
    /// False until the menu bar exists. A version-2 shortcut for a command that is not listed
    /// is then kept, to be judged when the menu bar is known.
    package var isComplete: Bool
    /// Commands that come and go with the person's own saved items. A shortcut for one that is
    /// not there now is kept and does nothing; it is never reported as a damaged entry.
    package var transientPrefixes: [String]

    package init(
        commands: [String: Command], fixed: [String: String], isComplete: Bool, transientPrefixes: [String] = []
    ) {
        self.commands = Self.legacyCommands.merging(commands) { _, listed in listed }
        self.fixed = fixed
        self.isComplete = isComplete
        self.transientPrefixes = transientPrefixes
    }
    /// The version-1 rules: the twelve editor commands, and reserved keys in the version-1 form.
    package init(reservedKeys: Set<String>) {
        commands = Self.legacyCommands
        fixed = Dictionary(
            reservedKeys.compactMap { key in MenuShortcut(storedText: key).map { ($0.identity, "another action") } },
            uniquingKeysWith: { first, _ in first })
        isComplete = false
        transientPrefixes = []
    }
    package static let legacyCommands: [String: Command] = Dictionary(
        uniqueKeysWithValues: EditorCommand.allCases.filter(\.isShortcutAssignable).map { command in
            (
                command.rawValue,
                Command(
                    title: command.title,
                    standard: EditorCommand.defaultShortcuts[command.rawValue].flatMap(MenuShortcut.init(storedText:)))
            )
        })
    package func title(_ id: String) -> String {
        commands[id]?.title ?? EditorCommand(rawValue: id)?.title ?? "Unavailable command"
    }
    package func isTransient(_ id: String) -> Bool {
        commands[id] == nil && transientPrefixes.contains { id.hasPrefix($0) }
    }
}

extension EditorSettings {
    /// Commands the menu bar no longer lists, each with the command that took its place.
    /// `closeSplit:` was View › Close Split View until 23 November 2026 (DS-D13); View › Split
    /// Tab View is now the one toggle that splits and closes.
    static package let retiredShortcutCommands: [String: String] = ["closeSplit:": "clone:"]
    /// A saved shortcut for a retired command becomes its successor's, unless the successor has
    /// an entry of its own, which then stays and the retired entry is dropped. Either way the
    /// retired entry is never reported as damaged. The file itself is rewritten only when the
    /// person next changes a shortcut.
    static package func adoptingRetiredShortcuts(_ shortcuts: [String: String]) -> [String: String] {
        var result = shortcuts
        for (retired, successor) in retiredShortcutCommands.sorted(by: { $0.key < $1.key }) {
            guard let text = result.removeValue(forKey: retired) else { continue }
            if result[successor] == nil, !text.isEmpty { result[successor] = text }
        }
        return result
    }
    /// Version 1 holds a shortcut only for one of the twelve editor commands, as one printable
    /// character. Any other command, modifier or key, and a default that was taken away, need
    /// version 2. A version-1 reader refuses a version-2 file and leaves it as it is.
    package var requiredVersion: Int {
        shortcuts.allSatisfy { Self.commands.contains($0.key) && Self.validShortcutKey($0.value) } ? 1 : 2
    }
    /// A saved entry as a shortcut. `.some(nil)` is an entry that says the command has none.
    private func parsed(_ id: String) -> MenuShortcut?? {
        guard let text = shortcuts[id] else { return nil }
        if text.isEmpty { return version >= 2 ? .some(nil) : nil }
        return version >= 2 || Self.validShortcutKey(text) ? MenuShortcut(storedText: text).map { .some($0) } : nil
    }
    /// The shortcut the person assigned, without regard to defaults.
    package func assignedShortcut(for id: String) -> MenuShortcut? { parsed(id) ?? nil }
    /// True when the command has an entry of its own, including one that removes its default.
    package func hasShortcutOverride(for id: String) -> Bool { shortcuts[id] != nil }
    /// The key that runs the command now: its own entry, or its default unless that default
    /// has given way to another command's entry.
    package func effectiveShortcut(for id: String, in context: ShortcutContext) -> MenuShortcut? {
        if shortcuts[id] != nil { return assignedShortcut(for: id) }
        guard let command = context.commands[id], let standard = command.standard else { return nil }
        return command.yields && isAssigned(standard, exceptTo: id) ? nil : standard
    }
    /// Whether any command's own entry uses this key. A hidden second shortcut of a command,
    /// which has no entry of its own, gives way on the same test.
    package func isAssigned(_ shortcut: MenuShortcut, exceptTo id: String? = nil) -> Bool {
        let identity = shortcut.identity
        return shortcuts.keys.contains { $0 != id && assignedShortcut(for: $0)?.identity == identity }
    }
    /// The commands that hold this key and do not give way: by an entry of their own, or by a
    /// default that does not yield. Sorted by identifier.
    package func holders(of shortcut: MenuShortcut, in context: ShortcutContext, except id: String? = nil) -> [String] {
        let identity = shortcut.identity
        return Set(context.commands.keys).union(shortcuts.keys).filter { other in
            guard other != id, context.commands[other] != nil || !context.isComplete else { return false }
            if shortcuts[other] != nil { return assignedShortcut(for: other)?.identity == identity }
            guard let command = context.commands[other], !command.yields else { return false }
            return command.standard?.identity == identity
        }.sorted()
    }
    /// Gives `id` this shortcut, or none for nil. Each command in `replacing` loses the key.
    /// Assigning a command its own default removes its entry. The version follows what the
    /// entries need.
    mutating package func assignShortcut(
        _ shortcut: MenuShortcut?, to id: String, replacing: [String] = [], in context: ShortcutContext
    ) {
        let standard = context.commands[id]?.standard
        // Entries are written in the wider vocabulary while they are edited; `version` is
        // brought back down below when every entry still fits version 1.
        version = 2
        for other in replacing where other != id {
            if context.commands[other]?.standard == nil {
                shortcuts.removeValue(forKey: other)
            } else {
                shortcuts[other] = ""
            }
        }
        if let shortcut {
            // A saved shortcut for something that is not there now would take this key back later.
            let identity = shortcut.identity
            for other in shortcuts.keys
            where other != id && context.isTransient(other) && assignedShortcut(for: other)?.identity == identity {
                shortcuts.removeValue(forKey: other)
            }
        }
        if shortcut?.identity == standard?.identity {
            shortcuts.removeValue(forKey: id)
        } else {
            shortcuts[id] = shortcut?.storedText ?? ""
        }
        version = requiredVersion
    }
    /// The shortcut check for every command the menu bar lists. Version-1 entries are held to
    /// the version-1 rules, so an older file means exactly what it meant.
    package func shortcutValidationFailure(context: ShortcutContext) -> ShortcutValidationFailure? {
        for id in shortcuts.keys.sorted() {
            guard let text = shortcuts[id] else { continue }
            if version < 2 {
                guard Self.commands.contains(id) else { return .init(command: id, error: .unknownShortcut) }
                guard Self.validShortcutKey(text) else { return .init(command: id, error: .invalidShortcut) }
            } else if context.commands[id] == nil {
                if context.isTransient(id) || !context.isComplete { continue }
                return .init(command: id, error: .unknownShortcut, title: context.title(id))
            }
            if text.isEmpty { continue }
            guard let shortcut = MenuShortcut(storedText: text) else {
                return .init(command: id, error: .invalidShortcut, title: context.title(id))
            }
            if let refusal = ShortcutPolicy.refusal(for: shortcut) {
                return .init(
                    command: id, error: refusal.kind == .system ? .conflict : .invalidShortcut,
                    title: context.title(id), detail: refusal.reason)
            }
            if context.fixed[shortcut.identity] != nil {
                return .init(command: id, error: .conflict, title: context.title(id))
            }
        }
        // Defaults are checked with the entries: an entry may not take a default that does not
        // give way. The entry is the one to correct, never the default.
        var owners: [String: String] = [:]
        for id in Set(context.commands.keys).union(shortcuts.keys).sorted() {
            guard !context.isTransient(id), let shortcut = effectiveShortcut(for: id, in: context) else { continue }
            if shortcuts[id] == nil, context.commands[id]?.yields == true { continue }
            if let owner = owners[shortcut.identity] {
                // Two defaults on one key are the menu bar's own business, not a saved entry's.
                if shortcuts[id] == nil, shortcuts[owner] == nil { continue }
                let command = shortcuts[id] == nil ? owner : id
                // The command that has the key by default is named first.
                let (first, second) = shortcuts[id] == nil ? (id, owner) : (owner, id)
                return .init(
                    command: command,
                    error: .shortcutClash(
                        first: context.title(first), second: context.title(second), shortcut: shortcut.spokenText))
            }
            owners[shortcut.identity] = id
        }
        return nil
    }
    package func validate(context: ShortcutContext) throws {
        guard (1...2).contains(version), (1...32).contains(tabWidth), ["system", "light", "dark"].contains(appearance)
        else { throw SettingsError.invalid }
        if let fontName {
            guard !fontName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, fontName.utf8.count <= 200,
                fontName.rangeOfCharacter(from: .controlCharacters) == nil
            else { throw SettingsError.invalidFont }
        }
        guard basePointSize.isFinite, (6...72).contains(basePointSize), (-10...60).contains(initialZoom)
        else { throw SettingsError.invalidFont }
        if let failure = shortcutValidationFailure(context: context) { throw failure.error }
    }
    static package func load(_ data: Data, context: ShortcutContext) throws -> (
        settings: Self, issues: [ShortcutLoadIssue]
    ) {
        try PersistedFormat.check(data, context: "Editor settings")
        return try JSONDecoder().decode(Self.self, from: data).toleratingShortcuts(context: context)
    }
    /// Keeps every usable shortcut and reports each one that is not, without changing the file:
    /// the "ignored binding" a person repairs from Settings. Everything else in the file is
    /// held to the strict rules.
    package func toleratingShortcuts(context: ShortcutContext) throws -> (settings: Self, issues: [ShortcutLoadIssue]) {
        let shortcuts = Self.adoptingRetiredShortcuts(shortcuts)
        var result = self
        result.shortcuts = [:]
        // Core schema/values are never repaired, guessed or made lenient.
        try result.validate(context: context)
        var issues: [String: ShortcutLoadIssue] = [:]
        func ignore(_ id: String, _ reason: ShortcutLoadIssue.Reason, detail: String? = nil) {
            var owner: String?
            if case .duplicate(let other) = reason { owner = context.title(other) }
            issues[id] = .init(
                command: id, key: shortcuts[id] ?? "", reason: reason,
                title: context.commands[id]?.title ?? EditorCommand(rawValue: id)?.title, ownerTitle: owner,
                detail: detail)
        }
        for id in shortcuts.keys.sorted() {
            guard let text = shortcuts[id] else { continue }
            if version < 2 {
                guard Self.commands.contains(id) else {
                    ignore(id, .unavailable)
                    continue
                }
                guard Self.validShortcutKey(text) else {
                    ignore(id, .invalid)
                    continue
                }
            } else if context.commands[id] == nil {
                if context.isTransient(id) || !context.isComplete {
                    if text.isEmpty || MenuShortcut(storedText: text) != nil {
                        result.shortcuts[id] = text
                    } else {
                        ignore(id, .invalid)
                    }
                } else {
                    ignore(id, .unavailable)
                }
                continue
            }
            if text.isEmpty {
                result.shortcuts[id] = text
                continue
            }
            guard let shortcut = MenuShortcut(storedText: text) else {
                ignore(id, .invalid)
                continue
            }
            if let refusal = ShortcutPolicy.refusal(for: shortcut) {
                ignore(id, refusal.kind == .system ? .reserved : .invalid, detail: refusal.reason)
            } else if context.fixed[shortcut.identity] != nil {
                ignore(id, .reserved)
            } else {
                result.shortcuts[id] = text
            }
        }
        // Removing a conflicting entry can restore a default key. Re-evaluate until stable;
        // every pass removes an entry, so this ends.
        while true {
            var groups: [String: [String]] = [:]
            for id in Set(context.commands.keys).union(result.shortcuts.keys) {
                guard !context.isTransient(id), let shortcut = result.effectiveShortcut(for: id, in: context)
                else { continue }
                if result.shortcuts[id] == nil, context.commands[id]?.yields == true { continue }
                groups[shortcut.identity, default: []].append(id)
            }
            var removed = false
            for key in groups.keys.sorted() {
                let ids = (groups[key] ?? []).sorted()
                guard ids.count > 1 else { continue }
                let winner = ids.first { result.shortcuts[$0] == nil } ?? ids[0]
                for id in ids where id != winner {
                    if result.shortcuts.removeValue(forKey: id) != nil {
                        ignore(id, .duplicate(winner))
                        removed = true
                    }
                }
            }
            if !removed { break }
        }
        try result.validate(context: context)
        return (result, issues.values.sorted { $0.command < $1.command })
    }
}
