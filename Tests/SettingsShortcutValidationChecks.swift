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
}
