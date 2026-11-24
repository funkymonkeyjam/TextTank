@testable import TextTankCore
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
@testable import TextTankRuntime
import EditorBridge
import NativeSearch

/// The shortcut model for any command: how a key is stored, shown and refused, the version-2
/// step of the settings file and its upgrade, and what happens to entries that cannot be used.
/// The Shortcuts pane itself is driven in `DesignSettingsChecks.shortcutPaneChecks`.
enum SettingsShortcutValidationChecks {
    @MainActor static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
    /// A small menu bar: one command with a default that stays, one with none, one whose
    /// default gives way, a key that belongs to a command that cannot change, and the twelve
    /// editor commands every context has.
    static let context = ShortcutContext(
        commands: [
            "saveDocument:": .init(title: "File › Save", standard: MenuShortcut("s")),
            "saveCopy:": .init(title: "File › Save Copy…"),
            "toggleDocumentPreview:": .init(title: "View › Toggle Preview", standard: MenuShortcut("v", [.control, .command]), yields: true)
        ], fixed: [MenuShortcut("\u{f70c}", []).identity: "Tools › Macros › Start Recording"], isComplete: true,
        transientPrefixes: ["RunController.run:/"])

    @MainActor static func run(root: URL) {
        Checks.section("V8 a shortcut is stored, shown and compared one way") { storedForms() }
        Checks.section("V8 keys that cannot be given to a command") { refusals() }
        Checks.section("V8 the version-2 step and its upgrade") { try versionStep(root: root) }
        Checks.section("V8 entries that cannot be used are ignored and repaired as before") {
            try ignoredEntries(root: root)
        }
        Checks.section("V8 yielding defaults, conflicts and Replace") { conflicts() }
        Checks.section("V8 the reserved keys are exactly these") { reservedKeys() }
        Checks.section("V8 an older TextTank refuses a version-2 file and leaves it alone") {
            try olderReader(root: root)
        }
        Checks.section("V8 a shortcut is drawn as the menu bar draws it") { try menuRendering() }
    }

    /// Item 5: every key the recorder refuses although it has Command or Control, with the reason
    /// it gives. Anything else with Command or Control can be recorded.
    static func reservedKeys() {
        let expected: [(String, ShortcutPolicy.Reserved, String)] = [
            ("cmd+q", .system, "system shortcut"), ("cmd+w", .system, "system shortcut"),
            ("cmd+h", .system, "system shortcut"), ("opt+cmd+h", .system, "system shortcut"),
            ("cmd+m", .system, "system shortcut"), ("cmd+,", .system, "system shortcut"),
            ("cmd+`", .system, "system shortcut"), ("shift+cmd+`", .system, "system shortcut"),
            ("cmd+f", .system, "system shortcut"), ("cmd+g", .system, "system shortcut"),
            ("shift+cmd+g", .system, "system shortcut"), ("cmd+e", .system, "system shortcut"),
            ("cmd+z", .editing, "Text fields in every window"), ("shift+cmd+z", .editing, "Text fields in every window"),
            ("cmd+x", .editing, "Text fields in every window"), ("cmd+c", .editing, "Text fields in every window"),
            ("cmd+v", .editing, "Text fields in every window"), ("cmd+a", .editing, "Text fields in every window"),
            ("cmd+tab", .macOS, "macOS acts on it before TextTank receives it"),
            ("shift+cmd+tab", .macOS, "macOS acts on it before TextTank receives it"),
            ("opt+cmd+escape", .macOS, "macOS acts on it before TextTank receives it"),
            ("shift+cmd+q", .macOS, "macOS acts on it before TextTank receives it"),
            ("ctrl+cmd+q", .macOS, "macOS acts on it before TextTank receives it")
        ]
        check(
            ShortcutPolicy.reserved.map { $0.shortcut.identity }.sorted()
                == expected.compactMap { MenuShortcut(storedText: $0.0)?.identity }.sorted()
                && ShortcutPolicy.reserved.count == expected.count,
            "V8 the reserved keys are the twelve of DS-25, six editing keys and five macOS takes first")
        for (text, kind, words) in expected {
            let shortcut = MenuShortcut(storedText: text)
            let reason = shortcut.flatMap { ShortcutPolicy.refusal(for: $0) }?.reason ?? ""
            check(
                ShortcutPolicy.reserved.first { $0.shortcut.identity == shortcut?.identity }?.kind == kind
                    && reason.contains(words) && reason.hasPrefix(shortcut?.spokenText ?? "?"),
                "V8 \(text) is refused and the message names why: \(reason)")
        }
        // Every other key with Command or Control is accepted by the policy, whatever has it now.
        let reserved = Set(ShortcutPolicy.reserved.map { $0.shortcut.identity })
        var refused: [String] = []
        let keys = "abcdefghijklmnopqrstuvwxyz0123456789`-=[]\\;',./ ".map(String.init)
            + ["\t", "\r", "\u{1b}", "\u{8}", "\u{7f}", "\u{f700}", "\u{f701}", "\u{f702}", "\u{f703}", "\u{f704}", "\u{f70f}"]
        let masks: [Set<MenuShortcut.Modifier>] = [
            [.command], [.control], [.command, .shift], [.command, .option], [.command, .control], [.control, .option],
            [.control, .shift], [.command, .option, .shift], [.command, .control, .shift], [.command, .control, .option],
            [.control, .option, .shift], [.command, .control, .option, .shift]
        ]
        for key in keys {
            for mask in masks {
                let shortcut = MenuShortcut(key, mask)
                if ShortcutPolicy.refusal(for: shortcut) != nil, !reserved.contains(shortcut.identity) {
                    refused.append(shortcut.spokenText)
                }
            }
        }
        check(refused.isEmpty, "V8 no other key with Command or Control is refused: \(refused)")
        check(
            ShortcutPolicy.refusal(for: MenuShortcut(" ")) == nil && ShortcutPolicy.refusal(for: MenuShortcut("s")) == nil
                && ShortcutPolicy.refusal(for: MenuShortcut("n")) == nil,
            "V8 Command-Space and the keys of ordinary commands (Save, New) are not reserved: they are conflicts to answer")
    }

    /// Item 2. What TextTank at main 1222b98 does with a settings file, copied from that commit's
    /// `EditorSettings`: the members it decodes and the gate in `validate`, which `load` runs
    /// (through `toleratingShortcuts`, on a copy with no shortcuts) before it looks at any
    /// shortcut. A file that fails here was a load error there: defaults in use, the file untouched.
    private struct ReaderAt1222b98: Codable {
        var version: Int
        var tabWidth: Int
        var useTabs: Bool
        var fontName: String?
        var fontSize: Double?
        var defaultZoom: Int?
        var currentLineHighlight: Bool?
        var indentGuides: Bool?
        var braceHighlight: Bool?
        var autoPair: Bool?
        var autoIndent: Bool?
        var reopenLastSession: Bool?
        var wrap: Bool
        var appearance: String
        var externalChangePolicy: ExternalChangePolicy?
        var previewOpenModes: [String: String]?
        var lastRenderedPreviewMode: String?
        var shortcuts: [String: String]
        static func load(_ data: Data) throws -> Self {
            try PersistedFormat.check(data, context: "Editor settings")
            let settings = try JSONDecoder().decode(Self.self, from: data)
            guard settings.version == 1, (1...32).contains(settings.tabWidth),
                ["system", "light", "dark"].contains(settings.appearance)
            else { throw SettingsError.invalid }
            return settings
        }
    }
    static func olderReader(root: URL) throws {
        let folder = root.appendingPathComponent("v8-older-reader", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = try Data(contentsOf: TestPaths.fixtures.appendingPathComponent("persistence/Settings.json"))
        let second = try Data(contentsOf: TestPaths.fixtures.appendingPathComponent("persistence/Settings-v2.json"))
        check(
            (try? ReaderAt1222b98.load(first))?.shortcuts == ["joinLines": "J", "upper": "u"],
            "V8 fixture: the previous build's rule reads the version-1 golden file")
        let url = folder.appendingPathComponent("Settings.json")
        try second.write(to: url)
        rejects("V8 the previous build's rule refuses the version-2 golden file", expecting: SettingsError.invalid) {
            _ = try ReaderAt1222b98.load(Data(contentsOf: url))
        }
        check(
            SettingsError.invalid.localizedDescription
                == "Unsupported settings version or value. Existing settings have not been replaced.",
            "V8 and what it tells the person is that the version is unsupported and nothing was replaced")
        // A file this build upgraded itself is refused the same way.
        let live = folder.appendingPathComponent("Upgraded.json")
        try first.write(to: live)
        let store = SettingsStore(url: live, context: context)
        var assigned = store.value
        assigned.assignShortcut(MenuShortcut("k", [.control, .option]), to: "saveCopy:", in: context)
        try store.save(assigned)
        let upgraded = try Data(contentsOf: live)
        rejects("V8 the previous build's rule refuses a file this build upgraded", expecting: SettingsError.invalid) {
            _ = try ReaderAt1222b98.load(upgraded)
        }
        // A file that failed to load is behind the store's latch, which that build has too
        // (F199 in DocumentChecks drives it with an unknown version): no save, no member update.
        var unknown = try JSONDecoder().decode(EditorSettings.self, from: second)
        unknown.version = 3
        let refusedURL = folder.appendingPathComponent("Refused.json")
        let refusedBytes = try JSONEncoder().encode(unknown)
        try refusedBytes.write(to: refusedURL)
        let latched = SettingsStore(url: refusedURL)
        rejects("V8 a store that refused a file's version does not save over it", expecting: SettingsError.unreadable) {
            try latched.save(EditorSettings())
        }
        rejects("V8 nor change one member of it", expecting: SettingsError.unreadable) {
            try latched.updateViewPreference(.autoPair) { !$0 }
        }
        check(
            try latched.loadError != nil && Data(contentsOf: refusedURL) == refusedBytes
                && Data(contentsOf: url) == second && Data(contentsOf: live) == upgraded
                && FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
                    == ["Refused.json", "Settings.json", "Upgraded.json"],
            "V8 every refused file is byte-identical afterwards and nothing was written beside it")
    }

    /// Item 6. AppKit publishes what a menu item draws for its key through the item's own
    /// accessibility attributes: a glyph code for a key that is drawn as a symbol, the character
    /// otherwise, and the modifiers. `MenuShortcut.displayText` must agree with them.
    @MainActor static func menuRendering() throws {
        // Carbon's menu glyph codes (Menus.h), which is what AXMenuItemCmdGlyph reports.
        var glyphs: [Int: String] = [
            0x02: "⇥", 0x03: "⇤", 0x04: "⌅", 0x09: "Space", 0x0A: "⌦", 0x0B: "↩", 0x17: "⌫", 0x1B: "⎋", 0x62: "⇞",
            0x64: "←", 0x65: "→", 0x66: "↖", 0x68: "↑", 0x69: "↘", 0x6A: "↓", 0x6B: "⇟"
        ]
        // The first twelve function keys are 0x6F to 0x7A.
        for number in 1...12 { glyphs[0x6E + number] = "F" + String(number) }
        func attribute(_ item: NSMenuItem, _ name: String) -> Any? {
            let selector = NSSelectorFromString("accessibilityAttributeValue:")
            guard item.responds(to: selector) else { return nil }
            return item.perform(selector, with: name)?.takeUnretainedValue()
        }
        let menu = NSMenu(title: "Rendering")
        var observed = 0, symbols = 0
        let cases: [(String, NSEvent.ModifierFlags)] = [
            ("\u{3}", .command), ("\r", .command), ("\u{7f}", .command), ("\u{8}", .command), ("\u{f728}", .command),
            ("\t", .control), ("\u{19}", [.control, .shift]), ("\u{1b}", [.command, .option]), (" ", [.control, .command]),
            ("\u{f700}", [.control, .command]), ("\u{f701}", .command), ("\u{f702}", .option), ("\u{f703}", .command),
            ("\u{f729}", .command), ("\u{f72b}", .command), ("\u{f72c}", .command), ("\u{f72d}", .command),
            ("\u{f704}", []), ("\u{f705}", .shift), ("\u{f70c}", []), ("\u{f70f}", [.command, .shift]), (",", .command),
            ("k", .command), ("K", .command), ("k", [.control, .option]), ("?", .command), ("+", .command), ("0", .command),
            ("/", [.command, .shift, .option, .control])
        ]
        for (key, mask) in cases {
            let item = NSMenuItem(title: "Item", action: nil, keyEquivalent: key)
            item.keyEquivalentModifierMask = mask
            menu.addItem(item)
            let shortcut = try requireValue(MenuShortcut(item), "V8 fixture: a menu item's key")
            let glyph = (attribute(item, "AXMenuItemCmdGlyph") as? NSNumber)?.intValue
            let character = attribute(item, "AXMenuItemCmdChar") as? String
            guard let bits = (attribute(item, "AXMenuItemCmdModifiers") as? NSNumber)?.intValue else { continue }
            observed += 1
            // Bit 0 Shift, 1 Option, 2 Control, 3 "no Command", as the menu draws them.
            let drawn =
                (bits & 4 != 0 ? "⌃" : "") + (bits & 2 != 0 ? "⌥" : "") + (bits & 1 != 0 ? "⇧" : "")
                + (bits & 8 == 0 ? "⌘" : "")
            let symbol: String
            if let glyph, glyph != 0 {
                symbol = try requireValue(glyphs[glyph], "V8 fixture: the menu glyph code \(glyph)")
                symbols += 1
            } else {
                symbol = (character ?? "").uppercased()
            }
            check(
                shortcut.displayText == drawn + symbol,
                "V8 \(shortcut.spokenText) is shown as the menu item itself draws it: \(shortcut.displayText) and \(drawn + symbol)")
        }
        check(
            observed == cases.count && symbols >= 20,
            "V8 the menu items' own rendering was observable for every case (\(observed) of \(cases.count), \(symbols) drawn as symbols)")
        // What a key is called aloud is not something a menu item publishes; the names are the
        // ones on the keys.
        check(
            MenuShortcut(",").spokenText == "Command-Comma" && MenuShortcut("\u{3}").spokenText == "Command-Enter"
                && MenuShortcut("\u{7f}").spokenText == "Command-Forward Delete"
                && MenuShortcut("\u{f728}").displayText == "⌘⌦",
            "V8 punctuation and the two Delete keys are named in words")
    }

    static func storedForms() {
        let up = "\u{f700}", f5 = "\u{f708}", f9 = "\u{f70c}"
        let forms: [(MenuShortcut, String, String, String)] = [
            (MenuShortcut("k"), "k", "⌘K", "Command-K"),
            (MenuShortcut("k", [.command, .shift]), "K", "⇧⌘K", "Shift-Command-K"),
            (MenuShortcut("k", [.control, .option]), "ctrl+opt+k", "⌃⌥K", "Control-Option-K"),
            (MenuShortcut(f5, []), "f5", "F5", "F5"), (MenuShortcut(f9, [.shift]), "shift+f9", "⇧F9", "Shift-F9"),
            (MenuShortcut(up, [.control, .command]), "ctrl+cmd+up", "⌃⌘↑", "Control-Command-Up Arrow"),
            (MenuShortcut("s", [.command, .option]), "opt+cmd+s", "⌥⌘S", "Option-Command-S"),
            (MenuShortcut(" ", [.control, .command]), "ctrl+cmd+space", "⌃⌘Space", "Control-Command-Space"),
            (MenuShortcut("+"), "+", "⌘+", "Command-Plus"), (MenuShortcut("/", [.control]), "ctrl+/", "⌃/", "Control-/"),
            (MenuShortcut("\t", [.control, .shift]), "ctrl+shift+tab", "⌃⇧⇥", "Control-Shift-Tab")
        ]
        for (shortcut, text, display, spoken) in forms {
            check(
                shortcut.storedText == text && MenuShortcut(storedText: text)?.identity == shortcut.identity,
                "V8 \(spoken) is stored as “\(text)” and read back as the same key: \(shortcut.storedText)")
            check(
                shortcut.displayText == display && shortcut.spokenText == spoken,
                "V8 \(text) is shown as \(display) and said as \(spoken): \(shortcut.displayText) / \(shortcut.spokenText)")
        }
        check(
            MenuShortcut(storedText: "k") == MenuShortcut("k") && MenuShortcut(storedText: "K") == MenuShortcut("K")
                && MenuShortcut("K").identity == MenuShortcut("k", [.command, .shift]).identity
                && MenuShortcut("K").storedText == "K",
            "V8 the version-1 form keeps its meaning: one character is Command, and uppercase adds Shift")
        check(
            MenuShortcut("+").identity == MenuShortcut("=", [.command, .shift]).identity
                && MenuShortcut("{").identity == MenuShortcut("[", [.command, .shift]).identity
                && MenuShortcut("=").identity != MenuShortcut("+").identity
                && MenuShortcut("\u{19}", [.control, .shift]).identity == MenuShortcut("\t", [.control, .shift]).identity,
            "V8 two spellings of one key press compare as the same shortcut")
        for text in ["", "ctrl+", "+k", "cmd+cmd+k", "hyper+k", "ctrl+K", "kk", "ctrl+opt", "ctrl + k", "f21", "ctrl+f0"] {
            check(MenuShortcut(storedText: text) == nil, "V8 “\(text)” is not a shortcut")
        }
    }

    static func refusals() {
        func refused(_ shortcut: MenuShortcut, _ kind: ShortcutRefusal.Kind, _ words: String) {
            let refusal = ShortcutPolicy.refusal(for: shortcut)
            check(
                refusal?.kind == kind && refusal?.reason.contains(words) == true && refusal?.reason.hasSuffix(".") == true,
                "V8 \(shortcut.spokenText) is refused with a stated reason: \(refusal?.reason ?? "accepted")")
        }
        refused(MenuShortcut("k", []), .typesText, "would type text")
        refused(MenuShortcut("k", [.shift]), .typesText, "would type text")
        refused(MenuShortcut("k", [.option]), .typesText, "would type text")
        refused(MenuShortcut("1", [.option, .shift]), .typesText, "Add Command or Control")
        refused(MenuShortcut(" ", []), .typesText, "would type text")
        refused(MenuShortcut("\r", []), .typesText, "moves or edits text")
        refused(MenuShortcut("\u{f700}", [.shift]), .typesText, "moves or edits text")
        refused(MenuShortcut("\u{8}", [.option]), .typesText, "moves or edits text")
        // DS-25, and the editing keys every text field takes from the menu bar.
        refused(MenuShortcut("q"), .system, "quits TextTank")
        refused(MenuShortcut("w"), .system, "closes")
        refused(MenuShortcut("h"), .system, "hides TextTank")
        refused(MenuShortcut("h", [.command, .option]), .system, "hides the other applications")
        refused(MenuShortcut("m"), .system, "minimizes")
        refused(MenuShortcut(","), .system, "opens Settings")
        refused(MenuShortcut("`"), .system, "next window")
        refused(MenuShortcut("f"), .system, "opens Find")
        refused(MenuShortcut("g"), .system, "next match")
        refused(MenuShortcut("G"), .system, "previous match")
        refused(MenuShortcut("g", [.command, .shift]), .system, "previous match")
        refused(MenuShortcut("e"), .system, "selection for Find")
        refused(MenuShortcut("c"), .system, "Copy in every text field")
        refused(MenuShortcut("\t"), .system, "switches between applications")
        for shortcut in [
            MenuShortcut("k", [.control, .option]), MenuShortcut("k", [.control]), MenuShortcut("\u{f708}", []),
            MenuShortcut("\u{f708}", [.shift]), MenuShortcut("\u{f700}", [.control, .command]),
            MenuShortcut("f", [.command, .option]), MenuShortcut("d"), MenuShortcut("\r", [.command])
        ] {
            check(
                ShortcutPolicy.refusal(for: shortcut) == nil,
                "V8 \(shortcut.spokenText) may be given to a command")
        }
    }

    static func versionStep(root: URL) throws {
        // Today's file, exactly as the build of 15 November 2026 wrote it.
        let golden = try Data(contentsOf: TestPaths.fixtures.appendingPathComponent("persistence/Settings.json"))
        let url = root.appendingPathComponent("v8-upgrade.json")
        try golden.write(to: url)
        let store = SettingsStore(url: url, context: context)
        check(
            try store.loadError == nil && store.ignoredShortcutBindings.isEmpty && store.value.version == 1
                && store.value.shortcuts == ["joinLines": "J", "upper": "u"] && store.value.tabWidth == 8
                && store.value.wrap && !store.value.useTabs && store.value.appearance == "dark"
                && (try Data(contentsOf: url)) == golden,
            "V8 an older settings file loads unchanged: every value, and not a byte rewritten")
        var widened = store.value
        widened.tabWidth = 3
        try store.save(widened)
        let stillOne = try Data(contentsOf: url)
        check(
            store.value.version == 1 && String(decoding: stillOne, as: UTF8.self).contains("\"version\":1")
                && stillOne == Data(String(decoding: golden, as: UTF8.self).replacingOccurrences(
                    of: "\"tabWidth\":8", with: "\"tabWidth\":3").utf8),
            "V8 a change that needs nothing new leaves the file at version 1, byte for byte elsewhere")

        var assigned = store.value
        assigned.assignShortcut(MenuShortcut("k", [.control, .option]), to: "saveCopy:", in: context)
        check(
            assigned.version == 2 && assigned.requiredVersion == 2
                && assigned.shortcuts == ["joinLines": "J", "upper": "u", "saveCopy:": "ctrl+opt+k"],
            "V8 a shortcut version 1 cannot hold makes the settings version 2 and keeps every earlier one")
        try store.save(assigned)
        let upgraded = try requireValue(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], "V8 fixture: upgraded file")
        let before = try requireValue(
            JSONSerialization.jsonObject(with: stillOne) as? [String: Any], "V8 fixture: version-1 file")
        check(
            upgraded["version"] as? Int == 2
                && upgraded["shortcuts"] as? [String: String] == ["joinLines": "J", "upper": "u", "saveCopy:": "ctrl+opt+k"]
                && Set(upgraded.keys) == Set(before.keys)
                && upgraded.keys.filter { $0 != "version" && $0 != "shortcuts" }.allSatisfy {
                    (upgraded[$0] as? NSObject) == (before[$0] as? NSObject)
                },
            "V8 the upgrade writes version 2 with all shortcuts kept and no other member changed")
        let reread = SettingsStore(url: url, context: context)
        check(
            reread.loadError == nil && reread.ignoredShortcutBindings.isEmpty && reread.value == store.value
                && reread.value.effectiveShortcut(for: "saveCopy:", in: context)?.displayText == "⌃⌥K"
                && reread.value.effectiveShortcut(for: "upper", in: context)?.displayText == "⌘U"
                && reread.value.effectiveShortcut(for: "joinLines", in: context)?.displayText == "⇧⌘J",
            "V8 the upgraded file reads back with every assignment")
        // An older TextTank accepts only `version == 1` and reports anything else as an unsupported
        // version, leaving the file alone. Version 1 here means exactly what it meant there:
        var older = try JSONDecoder().decode(EditorSettings.self, from: Data(contentsOf: url))
        older.version = 1
        rejects("V8 a version-1 reader's rules do not accept a version-2 entry as version 1") {
            try older.validate(context: context)
        }
        check(
            (try? older.toleratingShortcuts(context: context))?.issues.map(\.command) == ["saveCopy:"],
            "V8 read as version 1, the new entry is an ignored binding and the old ones stay")
        // Taking the new shortcut away brings the file back to a form an older TextTank reads.
        var back = store.value
        back.assignShortcut(nil, to: "saveCopy:", in: context)
        try store.save(back)
        check(
            try store.value.version == 1 && store.value.shortcuts == ["joinLines": "J", "upper": "u"]
                && (try EditorSettings.decode(Data(contentsOf: url))) == store.value,
            "V8 without such a shortcut the file is version 1 again")
        var future = store.value
        future.version = 3
        rejects("V8 a version this build does not know is still refused", expecting: SettingsError.invalid) {
            try store.save(future)
        }

        // A version-2 file as this build writes it, kept as a golden fixture beside version 1.
        let second = try Data(contentsOf: TestPaths.fixtures.appendingPathComponent("persistence/Settings-v2.json"))
        let loaded = try EditorSettings.load(second, context: context)
        check(
            loaded.issues.isEmpty && loaded.settings.version == 2 && loaded.settings.tabWidth == 8
                && loaded.settings.wrap && !loaded.settings.useTabs && loaded.settings.appearance == "dark"
                && loaded.settings.shortcuts
                    == ["joinLines": "J", "upper": "u", "saveCopy:": "ctrl+opt+k", "saveDocument:": ""]
                && loaded.settings.effectiveShortcut(for: "saveDocument:", in: context) == nil
                && loaded.settings.effectiveShortcut(for: "saveCopy:", in: context)?.spokenText == "Control-Option-K",
            "V8 the version-2 golden fixture decodes with every value, including a default taken away")
        // Before the menu bar exists nothing is known about a version-2 command; it is kept.
        let early = try EditorSettings.load(second, reservedKeys: EditorSettings.protectedShortcuts)
        check(
            early.issues.isEmpty && early.settings.shortcuts == loaded.settings.shortcuts,
            "V8 a version-2 entry is not judged before the menu bar is known")
    }

    static func ignoredEntries(root: URL) throws {
        var stored = EditorSettings()
        stored.version = 2
        stored.tabWidth = 9
        stored.shortcuts = [
            "saveCopy:": "ctrl+opt+k", "retired:": "ctrl+opt+g", "upper": "q", "lower": "kk", "joinLines": "opt+j",
            "deleteLine": "ctrl+opt+k", "transposeLine": "f9", "RunController.run:/7A0B": "ctrl+opt+r",
            "trimTrailing": "s"
        ]
        let bytes = try JSONEncoder().encode(stored)
        let url = root.appendingPathComponent("v8-ignored.json")
        try bytes.write(to: url)
        let store = SettingsStore(url: url, context: context)
        let reasons = Dictionary(uniqueKeysWithValues: store.ignoredShortcutBindings.map { ($0.command, $0.reason) })
        check(
            try store.loadError == nil && store.value.tabWidth == 9
                && store.value.shortcuts == ["deleteLine": "ctrl+opt+k", "RunController.run:/7A0B": "ctrl+opt+r"]
                && (try Data(contentsOf: url)) == bytes,
            "V8 usable entries and unrelated settings stay in use and the file is not rewritten: \(store.value.shortcuts)")
        check(
            reasons == [
                "retired:": .unavailable, "upper": .reserved, "lower": .invalid, "joinLines": .invalid,
                "saveCopy:": .duplicate("deleteLine"), "transposeLine": .reserved,
                "trimTrailing": .duplicate("saveDocument:")
            ],
            "V8 each unusable entry is reported with its own reason: \(reasons)")
        let notice = store.shortcutLoadNotice ?? ""
        check(
            notice.contains("“Uppercase” was ignored. Command-Q quits TextTank.")
                && notice.contains("“Join Selected Lines” was ignored. Option-J would type text")
                && notice.contains("“File › Save Copy…” conflicts with “Delete Line”")
                && notice.contains("“Trim Trailing Whitespace” conflicts with “File › Save”")
                && notice.contains("no longer available") && !notice.contains("retired:")
                && !notice.contains("ctrl+"),
            "V8 DS-82 the notice names commands as the menus do and never shows a stored identifier: \(notice)")
        rejects("V8 a setting cannot be changed around ignored entries", expecting: SettingsError.unreadable) {
            try store.updateViewPreference(.autoPair) { !$0 }
        }
        check((try Data(contentsOf: url)) == bytes, "V8 the refused change leaves the original bytes")
        let backup = try requireValue(try store.save(store.value), "V8 fixture: explicit repair keeps a backup")
        check(
            (try Data(contentsOf: backup)) == bytes && store.ignoredShortcutBindings.isEmpty
                && SettingsStore(url: url, context: context).value == store.value
                && SettingsStore(url: url, context: context).ignoredShortcutBindings.isEmpty,
            "V8 only an explicit save repairs the file, and the original is kept beside it")
        check(
            store.value.shortcuts["RunController.run:/7A0B"] == "ctrl+opt+r",
            "V8 a shortcut for a saved Run command that is not there now is kept, not reported")
        var taken = store.value
        taken.assignShortcut(MenuShortcut("r", [.control, .option]), to: "saveCopy:", in: context)
        check(
            taken.shortcuts["RunController.run:/7A0B"] == nil && taken.shortcuts["saveCopy:"] == "ctrl+opt+r",
            "V8 giving its key to a command drops that dormant entry instead of leaving a hidden clash")

        // The version-1 behaviour, through the same code: unknown commands and wrong keys.
        var first = EditorSettings()
        first.shortcuts = ["upper": "u", "lower": "s", "removedCommand": "k", "saveCopy:": "j", "joinLines": "ctrl+j"]
        let old = try first.toleratingShortcuts(context: context)
        check(
            old.settings.shortcuts == ["upper": "u"]
                && old.issues.map(\.command) == ["joinLines", "lower", "removedCommand", "saveCopy:"]
                && old.issues.map(\.reason)
                    == [.invalid, .duplicate("saveDocument:"), .unavailable, .unavailable],
            "V8 a version-1 file is held to version 1: only the twelve editor commands, one character each")
        // Once the menu bar is known, a command it does not have is reported.
        var unknown = store.value
        unknown.shortcuts["retired:"] = "ctrl+opt+g"
        unknown.version = 2
        try JSONEncoder().encode(unknown).write(to: url)
        let deferred = SettingsStore(url: url)
        check(
            deferred.ignoredShortcutBindings.isEmpty && deferred.value.shortcuts["retired:"] == "ctrl+opt+g",
            "V8 fixture: before the menu bar exists the entry is kept")
        deferred.shortcutContext = context
        deferred.reconcileShortcuts(reservedKeys: [])
        check(
            deferred.ignoredShortcutBindings.map(\.command) == ["retired:"] && deferred.value.shortcuts["retired:"] == nil,
            "V8 reconciling with the menu bar reports a command that is no longer available")
    }

    static func conflicts() {
        var settings = EditorSettings()
        // Control-Command-V is Toggle Preview's default, and that default gives way.
        let toggleKey = MenuShortcut("v", [.control, .command])
        settings.assignShortcut(toggleKey, to: "upper", in: context)
        check(
            settings.version == 2 && settings.shortcutValidationFailure(context: context) == nil
                && settings.effectiveShortcut(for: "toggleDocumentPreview:", in: context) == nil
                && settings.effectiveShortcut(for: "upper", in: context)?.displayText == "⌃⌘V"
                && settings.holders(of: toggleKey, in: context, except: "lower") == ["upper"]
                && settings.holders(of: toggleKey, in: context, except: "upper").isEmpty,
            "V8 a yielding default gives way to an assignment without a conflict, and returns when it goes")
        settings.setShortcut("", for: "upper")
        check(
            settings.effectiveShortcut(for: "toggleDocumentPreview:", in: context)?.displayText == "⌃⌘V",
            "V8 the yielding default has its key again")

        // Command-S is Save's default, and Save does not give way.
        check(
            settings.holders(of: MenuShortcut("s"), in: context, except: "saveCopy:") == ["saveDocument:"],
            "V8 a key in use names the command that has it")
        var clash = settings
        clash.assignShortcut(MenuShortcut("s"), to: "saveCopy:", in: context)
        let failure = clash.shortcutValidationFailure(context: context)
        check(
            failure?.command == "saveCopy:"
                && failure?.error == .shortcutClash(first: "File › Save", second: "File › Save Copy…", shortcut: "Command-S")
                && failure?.localizedDescription.contains("Command-S is assigned to both “File › Save” and “File › Save Copy…”")
                    == true,
            "V8 saving two commands on one key is refused, naming both: \(failure?.localizedDescription ?? "accepted")")
        var replaced = settings
        replaced.assignShortcut(MenuShortcut("s"), to: "saveCopy:", replacing: ["saveDocument:"], in: context)
        check(
            replaced.shortcuts == ["saveCopy:": "s", "saveDocument:": ""] && replaced.version == 2
                && replaced.shortcutValidationFailure(context: context) == nil
                && replaced.effectiveShortcut(for: "saveDocument:", in: context) == nil
                && replaced.effectiveShortcut(for: "saveCopy:", in: context) == MenuShortcut("s"),
            "V8 Replace gives the key to the new command and leaves the other without a shortcut")
        // Reset one: Save's default is now held by Save Copy, which is asked about the same way.
        check(
            replaced.holders(of: MenuShortcut("s"), in: context, except: "saveDocument:") == ["saveCopy:"],
            "V8 returning a command to its default finds the command that now has that key")
        var restored = replaced
        restored.assignShortcut(MenuShortcut("s"), to: "saveDocument:", replacing: ["saveCopy:"], in: context)
        check(
            restored.shortcuts.isEmpty && restored.version == 1 && restored == EditorSettings(),
            "V8 resetting both leaves no entry and a version-1 file")
        var fixed = settings
        fixed.assignShortcut(MenuShortcut("\u{f70c}", []), to: "saveCopy:", in: context)
        check(
            fixed.shortcutValidationFailure(context: context)?.error == .conflict,
            "V8 a key that belongs to a command that cannot change is refused on save")
        var system = settings
        system.assignShortcut(MenuShortcut("q"), to: "saveCopy:", in: context)
        let refusal = system.shortcutValidationFailure(context: context)
        check(
            refusal?.error == .conflict && refusal?.localizedDescription.contains("quits TextTank") == true,
            "V8 a system shortcut is refused on save with its reason: \(refusal?.localizedDescription ?? "accepted")")
        var editor = settings
        editor.assignShortcut(MenuShortcut("k", [.control, .option]), to: "deleteLine", in: context)
        editor.assignShortcut(MenuShortcut("d"), to: "upper", replacing: ["duplicateLine"], in: context)
        check(
            editor.shortcuts == ["deleteLine": "ctrl+opt+k", "upper": "d", "duplicateLine": ""] && editor.version == 2
                && editor.shortcutValidationFailure(context: context) == nil,
            "V8 the twelve editor commands take any modifiers too, and several assignments are all kept")
    }

    // MARK: The five DS-45 scenarios, through the Shortcuts pane's own controls

    /// One Settings window on a settings file of its own, opened on the Shortcuts pane.
    @MainActor final class PaneFixture {
        let controller: SettingsController, url: URL, form: FormPanel
        let pane: DesignSettingsChecks.ShortcutPaneDriver
        /// Saves the controller made: one per accepted change.
        private(set) var saves = 0
        var window: NSWindow { form.window }
        var bytes: Data? { try? Data(contentsOf: url) }
        var shortcuts: [String: String]? {
            bytes.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }?["shortcuts"]
                as? [String: String]
        }
        init(_ name: String, root: URL, initial: EditorSettings? = EditorSettings(), raw: String? = nil) throws {
            url = root.appendingPathComponent("v8-pane-" + name + ".json")
            if let raw { try Data(raw.utf8).write(to: url) }
            let counter = Counter()
            controller = SettingsController(url: url, onApply: { _, _ in counter.value += 1 })
            if raw == nil, let initial { try controller.save(initial) }
            counter.value = 0
            self.counter = counter
            controller.showSettings(nil)
            form = try requireValue(
                FormPanel.visible.last { $0.window.identifier?.rawValue == "TextTank.Settings" },
                "V8 fixture: Settings for " + name)
            try DesignSettingsChecks.choosePane("shortcuts", in: form.window)
            pane = try DesignSettingsChecks.ShortcutPaneDriver(form.window)
        }
        private final class Counter { var value = 0 }
        private let counter: Counter
        var accepted: Int { counter.value }
        /// Finds a command with the pane's own search field and selects it in the list.
        func choose(_ title: String, searching words: String) throws {
            try pane.find(words)
            try require(pane.listed().contains(title), "V8 fixture: “\(words)” finds \(title)")
            try pane.select(title)
            try pane.find("")
            try require(pane.selectedTitle == title, "V8 fixture: \(title) stays selected when the search is cleared")
        }
        /// Presses the window's own Close button.
        func close() throws {
            try DesignSettingsChecks.button("settings.close", window).performClick(nil)
        }
        /// What a person finds on the recorder and below the list after a key was not saved.
        func refusal(_ title: String, now value: String) -> Bool {
            let recorder = pane.recorder, text = pane.message.stringValue
            return pane.selectedTitle == title && !text.isEmpty && !pane.message.isHidden
                && recorder.accessibilityHelp() == text && recorder.toolTip == text
                && recorder.accessibilityValue() as? String == value
                && recorder.accessibilityLabel() == "Record a shortcut for \(title), now \(value)"
                && !recorder.isRecording
        }
        func status(_ title: String) throws -> (text: String, label: String?, help: String?) {
            let cell = try requireValue(
                pane.table.view(atColumn: 2, row: try pane.row(title), makeIfNecessary: true) as? NSTextField,
                "V8 fixture: the status of \(title)")
            return (cell.stringValue, cell.accessibilityLabel(), cell.accessibilityHelp())
        }
    }
    @MainActor static func paneScenarios(root: URL) throws {
        let upper = "Edit › Convert Case › Uppercase", delete = "Edit › Lines › Delete Line"
        let duplicate = "Edit › Lines › Duplicate Line"
        let unchanged = "The shortcut was not changed."
        /// An unmarked row says nothing beyond its own words.
        func plain(_ status: (text: String, label: String?, help: String?)) -> Bool {
            status.label == status.text && (status.help == nil || status.help == status.text)
        }
        func scenario(_ name: String, _ body: () throws -> Void) {
            let before = Set(FormPanel.visible.map(ObjectIdentifier.init))
            Checks.section("DS45 shortcut scenario: " + name) {
                defer { for form in FormPanel.visible where !before.contains(ObjectIdentifier(form)) { form.close() } }
                try body()
            }
        }

        scenario("invalid") {
            let fixture = try PaneFixture("invalid", root: root)
            let original = try requireValue(fixture.bytes, "V8 fixture: saved settings")
            try fixture.choose(upper, searching: "uppercase convert")
            NativeFixtureEnvironment.announcements = []
            try fixture.pane.press("?", [.shift], code: 44)
            let typed = fixture.pane.message.stringValue
            check(
                typed == "? would type text instead of running a command. Add Command or Control, or use a function key."
                    && fixture.refusal(upper, now: "no shortcut")
                    && NativeFixtureEnvironment.announcements.contains(typed),
                "DS45 invalid: a key that would type text is refused in words on the selected command: \(typed)")
            check(
                try fixture.window.firstResponder === fixture.pane.recorder && fixture.pane.recorder.title == "Record Shortcut"
                    && fixture.pane.text(try fixture.pane.row(upper), 1).isEmpty,
                "DS45 invalid: the recorder is marked and keeps the keyboard, and the command still shows no key")
            try fixture.pane.press("u", [.option], code: 32)
            check(
                fixture.pane.message.stringValue.hasPrefix("Option-U would type text")
                    && fixture.refusal(upper, now: "no shortcut"),
                "DS45 invalid: a second key that cannot be used replaces the first reason")
            check(
                fixture.bytes == original && fixture.accepted == 0 && fixture.controller.value == EditorSettings(),
                "DS45 invalid: nothing is written for a refused key")
            try fixture.close()
            check(
                !fixture.window.isVisible && fixture.bytes == original
                    && SettingsStore(url: fixture.url).value == EditorSettings(),
                "DS45 invalid: Close after the refusals preserves the original settings bytes and model")
        }

        scenario("reserved") {
            let fixture = try PaneFixture("reserved", root: root)
            let original = try requireValue(fixture.bytes, "V8 fixture: saved settings")
            try fixture.choose(upper, searching: "uppercase")
            for (key, flags, code, words) in [
                ("q", NSEvent.ModifierFlags.command, UInt16(12), "Command-Q quits TextTank. It is a system shortcut"),
                ("c", .command, 8, "Command-C is Copy in every text field. Text fields in every window"),
                ("q", [.command, .control], 12, "Control-Command-Q locks the screen. macOS acts on it")
            ] {
                try fixture.pane.press(key, flags, code: code)
                check(
                    fixture.pane.message.stringValue.hasPrefix(words) && fixture.refusal(upper, now: "no shortcut")
                        && fixture.window.firstResponder === fixture.pane.recorder,
                    "DS45 reserved: the key is refused with its reason, on the recorder, which keeps the keyboard: \(fixture.pane.message.stringValue)")
            }
            check(
                fixture.bytes == original && fixture.accepted == 0,
                "DS45 reserved: nothing is written for a reserved key")
            try fixture.close()
            check(
                !fixture.window.isVisible && fixture.bytes == original
                    && fixture.controller.value == EditorSettings(),
                "DS45 reserved: Close preserves the original settings bytes and model")
        }

        scenario("duplicate") {
            let fixture = try PaneFixture("duplicate", root: root)
            let original = try requireValue(fixture.bytes, "V8 fixture: saved settings")
            try fixture.choose(delete, searching: "delete line")
            try fixture.pane.press("k", .command, code: 40)
            let first = try requireValue(fixture.bytes, "V8 fixture: the first write")
            check(
                fixture.accepted == 1 && first != original && fixture.shortcuts == ["deleteLine": "k"]
                    && fixture.pane.message.stringValue == "“\(delete)” now uses Command-K."
                    && fixture.pane.recorder.accessibilityHelp() == nil
                    && fixture.pane.recorder.accessibilityValue() as? String == "Command-K"
                    && fixture.pane.recorder.title == "⌘K",
                "DS45 duplicate: an accepted key is one write, and the recorder shows it with no mark")
            try fixture.choose(upper, searching: "uppercase")
            try fixture.pane.press("k", .command, code: 40)
            let question = fixture.pane.message.stringValue
            let holder = try fixture.status(delete)
            let replace = try fixture.pane.button("replace"), cancel = try fixture.pane.button("cancel")
            check(
                question
                    == "Command-K is already used by “\(delete)”. Replace gives it to “\(upper)” and leaves “\(delete)” without a shortcut. Cancel changes nothing."
                    && fixture.refusal(upper, now: "no shortcut"),
                "DS45 duplicate: the question names both commands and marks the recorder of the selected one: \(question)")
            check(
                try holder.text == "Custom · Has the key in question" && holder.label == holder.text
                    && holder.help
                        == "“\(delete)” has Command-K, the key being recorded for “\(upper)”. Replace leaves “\(delete)” without a shortcut."
                    && plain(try fixture.status(upper)),
                "DS45 duplicate: the command that has the key is marked in words, with help: \(holder)")
            check(
                !replace.isHidden && !cancel.isHidden && fixture.window.firstResponder === cancel
                    && replace.hasDestructiveAction && replace.keyEquivalent.isEmpty,
                "DS45 duplicate: the keyboard is on Cancel, and Return cannot replace (DS-41)")
            DesignSettingsChecks.checkNativeButtons(fixture.window)
            check(
                fixture.bytes == first && fixture.accepted == 1,
                "DS45 duplicate: nothing is written while the question is open")
            cancel.performClick(nil)
            check(
                try fixture.pane.message.stringValue == unchanged && fixture.status(delete).text == "Custom"
                    && plain(fixture.status(delete)) && fixture.pane.recorder.accessibilityHelp() == nil
                    && replace.isHidden && fixture.window.firstResponder === fixture.pane.table
                    && fixture.pane.selectedTitle == upper && fixture.bytes == first && fixture.accepted == 1,
                "DS45 duplicate: Cancel removes every mark, returns the keyboard to the list and writes nothing")
            try fixture.pane.press("k", .command, code: 40)
            try fixture.pane.button("replace").performClick(nil)
            check(
                try fixture.accepted == 2 && fixture.shortcuts == ["upper": "k", "deleteLine": ""]
                    && fixture.pane.message.stringValue == "“\(upper)” now uses Command-K."
                    && fixture.status(delete).text == "Custom: none" && fixture.pane.selectedTitle == upper,
                "DS45 duplicate: Replace is one more write and leaves the other command without a key")
            let final = fixture.bytes
            try fixture.close()
            check(
                !fixture.window.isVisible && fixture.bytes == final
                    && SettingsStore(url: fixture.url).value.shortcuts == ["upper": "k", "deleteLine": ""],
                "DS45 duplicate: Close writes nothing more")
        }

        scenario("restored-default") {
            var initial = EditorSettings()
            initial.shortcuts = ["duplicateLine": "j", "upper": "d"]
            let fixture = try PaneFixture("restored-default", root: root, initial: initial)
            let original = try requireValue(fixture.bytes, "V8 fixture: saved settings")
            try fixture.choose(duplicate, searching: "duplicate line")
            check(
                fixture.pane.recorder.title == "⌘J" && fixture.pane.recorder.accessibilityValue() as? String == "Command-J",
                "DS45 restored-default fixture: Duplicate Line shows its custom key")
            try fixture.pane.button("default").performClick(nil)
            let holder = try fixture.status(upper)
            check(
                try fixture.pane.message.stringValue.hasPrefix("Command-D is already used by “\(upper)”.")
                    && fixture.pane.selectedTitle == duplicate
                    && fixture.pane.recorder.accessibilityHelp() == fixture.pane.message.stringValue
                    && holder.text == "Custom · Has the key in question" && holder.help?.hasPrefix("“\(upper)” has Command-D") == true
                    && fixture.window.firstResponder === (try fixture.pane.button("cancel")),
                "DS45 restored-default: Use Default names the command that now has the default key: \(fixture.pane.message.stringValue)")
            try fixture.pane.button("cancel").performClick(nil)
            check(
                try fixture.bytes == original && fixture.accepted == 0 && fixture.controller.value == initial
                    && fixture.pane.text(try fixture.pane.row(duplicate), 1) == "⌘J"
                    && fixture.status(upper).text == "Custom",
                "DS45 restored-default: Cancel keeps both custom shortcuts and the bytes")
            try fixture.pane.button("default").performClick(nil)
            try fixture.pane.button("replace").performClick(nil)
            check(
                try fixture.accepted == 1 && fixture.shortcuts == [:] && fixture.pane.recorder.title == "⌘D"
                    && fixture.status(duplicate).text == "Default" && fixture.status(upper).text == "None",
                "DS45 restored-default: Replace is one write that restores the default and frees the other command")
            try fixture.close()
            check(
                !fixture.window.isVisible && SettingsStore(url: fixture.url).value == EditorSettings(),
                "DS45 restored-default: the saved file is the default settings again")
        }

        scenario("implicit-default") {
            let fixture = try PaneFixture("implicit-default", root: root)
            let original = try requireValue(fixture.bytes, "V8 fixture: saved settings")
            try fixture.choose(delete, searching: "delete line")
            try fixture.pane.press("d", .command, code: 2)
            let holder = try fixture.status(duplicate)
            check(
                fixture.pane.message.stringValue.hasPrefix("Command-D is already used by “\(duplicate)”.")
                    && fixture.refusal(delete, now: "Control-Shift-K")
                    && holder.text == "Default · Has the key in question" && holder.label == holder.text
                    && holder.help?.contains("the key being recorded for “\(delete)”") == true,
                "DS45 implicit-default: a key a command has by default names that command and marks its row: \(holder)")
            check(
                fixture.bytes == original && fixture.accepted == 0,
                "DS45 implicit-default: nothing is written while the question is open")
            try fixture.close()
            check(
                !fixture.window.isVisible && fixture.bytes == original && fixture.controller.value == EditorSettings(),
                "DS45 implicit-default: Close with the question open preserves the original bytes and model")
            fixture.controller.showSettings(nil)
            let reopened = try requireValue(FormPanel.visible.last, "V8 fixture: Settings reopened")
            try DesignSettingsChecks.choosePane("shortcuts", in: reopened.window)
            let pane = try DesignSettingsChecks.ShortcutPaneDriver(reopened.window)
            try pane.select(delete)
            try pane.press("d", .command, code: 2)
            try pane.button("replace").performClick(nil)
            check(
                try fixture.accepted == 1 && fixture.shortcuts == ["deleteLine": "d", "duplicateLine": ""]
                    && pane.text(try pane.row(duplicate), 1).isEmpty && pane.text(try pane.row(delete), 1) == "⌘D",
                "DS45 implicit-default: Replace is one write that records the default as taken away")
            try pane.select(duplicate)
            try pane.button("default").performClick(nil)
            try pane.button("replace").performClick(nil)
            check(
                try fixture.accepted == 2 && fixture.shortcuts == ["deleteLine": ""]
                    && pane.text(try pane.row(duplicate), 1) == "⌘D" && pane.text(try pane.row(delete), 1).isEmpty,
                "DS45 implicit-default: Use Default gives the key back with one more write and the other command has none")
            try pane.select(delete)
            try pane.button("default").performClick(nil)
            check(
                try fixture.accepted == 3 && fixture.shortcuts == [:] && pane.text(try pane.row(delete), 1) == "⌃⇧K"
                    && !(try pane.button("default")).isEnabled
                    && SettingsStore(url: fixture.url).value == EditorSettings(),
                "DS45 implicit-default: Use Default on each command in turn ends at the default settings")
            reopened.close()
        }

        scenario("ignored binding") {
            let raw =
                #"{"version":1,"tabWidth":4,"useTabs":true,"wrap":false,"appearance":"system","shortcuts":{"upper":"q","lower":"u"}}"#
            let fixture = try PaneFixture("ignored", root: root, raw: raw)
            let issue = try requireValue(fixture.controller.ignoredShortcutBindings.first, "V8 fixture: an ignored binding")
            let status = try fixture.status(upper)
            check(
                fixture.controller.ignoredShortcutBindings.map(\.command) == ["upper"]
                    && status.text == "None · Saved shortcut ignored" && status.label == status.text
                    && status.help == issue.message && issue.message.contains("Command-Q quits TextTank."),
                "DS45 a command whose saved shortcut was ignored is marked in words, and its help says why: \(status)")
            try fixture.pane.select(upper)
            check(
                try !fixture.pane.note.isHidden && fixture.pane.note.stringValue == issue.message
                    && fixture.pane.text(try fixture.pane.row("Edit › Convert Case › Lowercase"), 1) == "⌘U",
                "DS45 selecting it shows the reason, and the usable saved shortcut is in the list")
            try fixture.pane.press("y", [.control, .option], code: 16)
            check(
                fixture.pane.message.stringValue
                    == "Use Repair Settings to back up the original file before changing these settings."
                    && fixture.refusal(upper, now: "no shortcut") && fixture.bytes == Data(raw.utf8)
                    && fixture.accepted == 0,
                "DS45 nothing is changed around an ignored binding until it is repaired, and the recorder says so: \(fixture.pane.message.stringValue)")
            try fixture.close()
            check(fixture.bytes == Data(raw.utf8), "DS45 Close leaves the file with the ignored binding byte for byte")
        }
    }
}
