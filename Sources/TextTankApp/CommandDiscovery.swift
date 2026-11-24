// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import TextTankCore
import EditorBridge

/// The commands a person ran from the palette most recently, newest first.
struct CommandRecents: Equatable {
    static let limit = 5
    private(set) var ids: [String]
    init(_ ids: [String] = []) {
        var seen = Set<String>()
        self.ids = Array(ids.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(Self.limit))
    }
    mutating func note(_ id: String) {
        guard !id.isEmpty else { return }
        self = Self([id] + ids)
    }
}

/// Keeps `CommandRecents` in the private support folder, so the list survives a relaunch.
///
/// The file holds row identities only: menu titles and command identifiers, never document
/// text. It is a convenience, so a failure to read or write it is never an alert (DS-40); the
/// palette then works from the list in memory. A file this version cannot read because a later
/// one wrote it is left as it is.
@MainActor final class CommandRecentsStore {
    static let maximumBytes = 64 * 1024
    private struct File: Codable {
        var version: Int
        var commands: [String]
    }
    let url: URL
    private(set) var recents = CommandRecents()
    private var replaceable = true
    init(url: URL? = nil) {
        self.url = url ?? AppStorage.url(.commandRecents)
        do {
            let data = try PrivateFileStore.read(self.url, maximumBytes: Self.maximumBytes)
            guard let file = try? JSONDecoder().decode(File.self, from: data) else { return }
            if file.version == 1 { recents = CommandRecents(file.commands) } else { replaceable = false }
        } catch where error.isFileNotFound {} catch {
            // Too large, not a regular file or not readable: do not write over what is there.
            replaceable = false
        }
    }
    func note(_ id: String) {
        // A row identity is a few menu titles long. Anything larger is not worth a file write.
        guard id.utf8.count <= 4096 else { return }
        let previous = recents
        recents.note(id)
        guard replaceable, recents != previous else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(File(version: 1, commands: recents.ids))
            try PrivateFileStore.prepareDirectory(url.deletingLastPathComponent())
            try PrivateFileStore.write(data, to: url, maximumBytes: Self.maximumBytes)
        } catch {}
    }
}

/// Discover and invoke the same menu items that belong to the window where the chooser opened.
@MainActor final class CommandDiscovery {
    struct Entry {
        /// What the palette shows: the command's name, the menu that holds it as secondary
        /// text, and its current key equivalent at the trailing edge.
        let row: ChoicePanel.Row
        let item: NSMenuItem
        weak var target: AnyObject?
        let externalNotice: String?
        /// Where the command used to be listed, matched by the filter but never shown.
        var legacyPath = ""
        /// The command's own name, and its whole menu path ending in that name.
        var name = ""
        var path = ""
        /// What the command reads and changes. It is not shown; `perform` compares it so that a
        /// saved automation reconfigured while the palette was open is not run by mistake.
        var scope = ""
    }

    /// Where commands were listed before the nine-menu bar of 23 November 2026 (DS-D4), by the
    /// start of today's path. The first entry that fits is used, so an exception precedes the
    /// menu it is in. A person who types the old place or the old name still finds the command.
    static let legacyLocations: [(current: [String], legacy: String)] = [
        (["File", "Quick Open…"], "Workspace"),
        (["File", "Reload with Encoding"], "Encoding › Reload as"),
        (["File", "Convert to Encoding"], "Encoding › Convert to"),
        (["File", "Monitor Current File"], "Workspace"),
        (["File", "Reload Monitored File…"], "Workspace"),
        (["File", "Workspace", "Add Folder to Workspace…"], "Workspace"),
        (["File", "Workspace"], "File"),
        (["Edit", "Encode and Decode"], "Text Utilities"),
        (["Edit", "Format JSON"], "Text Utilities"),
        (["Edit", "Complete Word"], "Language"),
        (["Edit", "Typing", "Toggle Overtype"], "Edit"),
        (["Edit", "Typing"], "View"),
        (["Find", "Bookmarks"], "Search › Bookmarked Lines"),
        (["Find", "Function List…"], "Language"),
        (["Find"], "Search"),
        (["View", "Show"], "View"),
        (["View", "Syntax Highlighting"], "Language"),
        (["View", "Workspace Browser"], "Workspace › Show"),
        (["View", "Editor Groups"], "View"),
        (["Compare", "Compare with Saved Version"], "File"),
        (["Compare"], "Search › Compare"),
        (["Tools", "Macros"], "Macros"),
        (["Tools", "Automations"], "Automations"),
        (["Tools", "Run Commands"], "Run"),
        (["Tools"], "Text Utilities"),
        (["Help", "Show Keyword Help"], "Language")
    ]
    /// Where the View menu listed a command, and what it called it, before the menu was
    /// regrouped on 23 November 2026 (DS-D13), by today's whole path. Close Split View has no
    /// row now: Split Tab View is the one toggle, and answers to the old name.
    static let formerPaths: [(current: [String], former: String)] = [
        (["View", "Preview", "Source"], "View › Source"),
        (["View", "Preview", "Preview"], "View › Preview"),
        (["View", "Preview", "Both"], "View › Both"),
        (["View", "Preview", "Toggle Preview"], "View › Toggle Preview"),
        (["View", "Split Tab View"], "View › Close Split View"),
        (["View", "Show", "Line Numbers"], "View › Show Line Numbers"),
        (["View", "Show", "Whitespace"], "View › Show Whitespace"),
        (["View", "Show", "Line Endings"], "View › Show Line Endings"),
        (["View", "Show", "Indentation Guides"], "View › Guides and Highlights › Show Indentation Guides"),
        (["View", "Show", "Current Line Highlight"], "View › Guides and Highlights › Highlight Current Line"),
        (["View", "Show", "Matching Braces"], "View › Guides and Highlights › Highlight Matching Braces")
    ]
    /// Every former place and name of the command at `route`, as one text the filter reads.
    static func legacyPath(for route: [String]) -> String {
        var former = formerPaths.filter { $0.current == route }.map(\.former)
        if let old = legacyLocations.first(where: { route.starts(with: $0.current) }), let title = route.last {
            former.insert(old.legacy + " " + title, at: 0)
        }
        return former.joined(separator: " ")
    }
    private static func key(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
    /// How well a command's name answers what was typed; lower is listed first.
    ///
    /// 0 the name is exactly what was typed, 1 the name starts with it, 2 every word typed
    /// starts a word of the name, 3 every word typed is somewhere in the name, 4 the match is
    /// only in the menu path or the former one. A trailing ellipsis is not part of the name.
    static func rank(name: String, query: String) -> Int {
        let words = key(query).split(whereSeparator: \.isWhitespace).map(String.init)
        var title = key(name)
        while title.hasSuffix("…") || title.hasSuffix(".") { title.removeLast() }
        let typed = words.joined(separator: " ")
        if title == typed { return 0 }
        if title.hasPrefix(typed) { return 1 }
        let parts = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.allSatisfy({ word in parts.contains { $0.hasPrefix(word) } }) { return 2 }
        if words.allSatisfy({ title.contains($0) }) { return 3 }
        return 4
    }
    /// The entries whose path, or former path, contains every word typed, in any order: best
    /// name match first, and within one rank the commands run recently before the rest, each in
    /// a stable order (recency, then menu order). With nothing typed the recent commands lead and
    /// every other command follows in menu order. A recent command that is not among `entries`,
    /// because it no longer exists or is hidden now, is not listed.
    static func matches(_ entries: [Entry], query: String, recent: [String] = []) -> [Entry] {
        let words = key(query).split(whereSeparator: \.isWhitespace)
        let recency = Dictionary(recent.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var ranked: [(rank: Int, recency: Int, order: Int, entry: Entry)] = []
        for (order, entry) in entries.enumerated() {
            let text = key(entry.path + " " + entry.legacyPath)
            guard words.allSatisfy({ text.contains($0) }) else { continue }
            ranked.append(
                (
                    words.isEmpty ? 0 : rank(name: entry.name, query: query), recency[entry.row.id] ?? Int.max, order,
                    entry
                ))
        }
        return ranked.sorted { ($0.rank, $0.recency, $0.order) < ($1.rank, $1.recency, $1.order) }.map(\.entry)
    }
    static func rows(_ entries: [Entry], matching query: String, recent: [String] = []) -> [ChoicePanel.Row] {
        matches(entries, query: query, recent: recent).map(\.row)
    }

    static let emptyMessage = "No matching commands"
    private(set) var panel: ChoicePanel?
    private let recentsURL: URL?
    /// Read when the palette is first used, so a launch never waits on it.
    private(set) lazy var recentsStore = CommandRecentsStore(url: recentsURL)
    var recentCommands: [String] { recentsStore.recents.ids }
    init(recentsURL: URL? = nil) { self.recentsURL = recentsURL }
    /// Called when a command chosen in the palette has been sent to its target.
    func noteRan(_ entry: Entry) { recentsStore.note(entry.row.id) }

    func show(editor: @escaping () -> TTEditor?) {
        if let panel {
            // What was typed stays, selected, so typing replaces it.
            panel.showAgain()
            return
        }
        guard let menu = NSApp.mainMenu else { return }
        let window = NSApp.keyWindow
        guard window?.attachedSheet == nil && window?.sheetParent == nil else { return }
        let expectedEditor = editor()
        let hadEditor = expectedEditor != nil
        let entries = commands(in: menu)
        let chooser = ChoicePanel(
            title: "Command Palette", identifier: "command.palette", action: "Run Command",
            filterLabel: "Search commands by name or menu")
        panel = chooser
        // The list as it was when the palette opened: a command run from this palette closes it.
        let recent = recentCommands
        chooser.rows = { Self.rows(entries, matching: "", recent: recent) }
        chooser.filteredRows = { Self.rows(entries, matching: $0, recent: recent) }
        chooser.emptyMessage = Self.emptyMessage
        chooser.onClose = { [weak self] in self?.panel = nil }
        let hadWindow = window != nil
        chooser.choose = { [weak self, weak chooser, weak menu, weak window, weak expectedEditor] id in
            guard let self, let chooser, let menu, let original = entries.first(where: { $0.row.id == id })
            else { return false }
            chooser.form.close()
            guard !hadWindow || window?.isVisible == true, menu === NSApp.mainMenu else { return true }
            // A nil-target command must travel the originating responder chain, never the filter field's.
            window?.makeKey()
            guard window == nil || NSApp.keyWindow === window else { return true }
            let isCurrent = { (!hadEditor || expectedEditor != nil) && editor() === expectedEditor }
            guard isCurrent() else {
                TTAlert.explain("The active editor changed. Open the palette again to choose a command.")
                return true
            }
            if let notice = original.externalNotice {
                let alert = TTAlert()
                alert.messageText = "Run “\(original.item.title)”?"
                alert.informativeText = notice
                alert.addButton(withTitle: "Cancel", role: .cancel)
                alert.addButton(withTitle: "Continue")
                guard alert.run() == .button(1) else { return true }
            }
            guard (!hadWindow || window?.isVisible == true), window == nil || NSApp.keyWindow === window,
                isCurrent(), perform(original, in: menu)
            else {
                TTAlert.explain("This command is no longer available in the original window.")
                return true
            }
            return true
        }
        chooser.show(parent: window)
    }

    /// Recreate dynamic entries and revalidate the same action and target after closing the chooser.
    /// Managers may rename, remove, or reconfigure a saved entry while a modeless panel is open.
    @discardableResult func perform(_ original: Entry, in menu: NSMenu) -> Bool {
        guard original.row.enabled, let expected = original.target,
            let current = commands(in: menu).first(where: { $0.row.id == original.row.id }),
            current.row.enabled, current.target === expected, current.scope == original.scope,
            current.item.action == original.item.action, let action = current.item.action
        else { return false }
        // Group invocations carry the original tab, group membership and destination generation.
        // Its controller must receive that captured sender and can still reject it if the layout changed.
        if let validator = expected as? NSMenuItemValidation, !validator.validateMenuItem(original.item) {
            return false
        }
        guard NSApp.sendAction(action, to: expected, from: original.item) else { return false }
        noteRan(original)
        return true
    }

    func commands(in bar: NSMenu) -> [Entry] {
        var entries: [Entry] = [], seen: Set<String> = []
        func collect(_ menu: NSMenu, path: [String]) {
            guard menu !== NSApp.servicesMenu else { return }
            // Macro, language, automation and group menus list items that change. Their owners
            // must build them when the menu is made and rebuild them whenever the list changes:
            // a key equivalent is matched against the items a menu already has, and pressing one
            // does not call `menuNeedsUpdate`. Opening a menu is not what populates them. The
            // call here only brings such a menu up to date before its commands are listed, at
            // whatever depth the menu bar has it.
            if menu.delegate is MacroController || menu.delegate is AutomationController
                || menu.delegate is LanguageController || menu.delegate is GroupCommandController
            {
                menu.delegate?.menuNeedsUpdate?(menu)
            }
            for item in menu.items where !item.isHidden && !item.isSeparatorItem && !item.title.isEmpty {
                let route = path + [item.title]
                if let child = item.submenu {
                    // Recently opened file names are documents, not commands.
                    if !(child.delegate is RecentDocumentsMenu) && item.title != WorkspaceBrowserController.recentFilesTitle {
                        collect(child, path: route)
                    }
                    continue
                }
                guard let action = item.action else { continue }
                let selector = NSStringFromSelector(action)
                guard selector != "paletteAction", !selector.hasPrefix("_"), !item.isAlternate else { continue }
                let target = NSApp.target(forAction: action, to: item.target, from: item) as AnyObject?
                let enabled: Bool
                if !menu.autoenablesItems && !item.isEnabled {
                    enabled = false
                } else if let validator = target as? NSMenuItemValidation {
                    enabled = validator.validateMenuItem(item)
                } else if let validator = target as? NSUserInterfaceValidations {
                    enabled = validator.validateUserInterfaceItem(item)
                } else {
                    enabled = target != nil
                }
                let pathLabel = route.joined(separator: " › ")
                let object = item.representedObject as? String ?? ""
                let fields = route + [selector, object, String(item.tag)]
                let id = fields.map { "\($0.utf8.count):\($0)" }.joined()
                guard seen.insert(id).inserted else { continue }
                let (scope, destination) = Self.scope(item, menu: route.first ?? "", selector: selector)
                // DS-20: the key shown is the one the menu item has now, including a shortcut
                // assigned in Settings. The menu that holds the command is the secondary text.
                let shortcut = ControlPresentation.shortcut(of: item) ?? ""
                // A View > Show item is titled by what it shows; on its own it keeps the verb.
                let name = ViewMenuTitles.spokenName(route: route) ?? item.title
                entries.append(
                    Entry(
                        row: .init(
                            id: id, title: name, detail: path.joined(separator: " › "), enabled: enabled,
                            accessory: shortcut,
                            accessoryLabel: ControlPresentation.spokenShortcut(of: item).map { "Shortcut " + $0 } ?? ""),
                        item: item, target: target, externalNotice: destination,
                        legacyPath: Self.legacyPath(for: route), name: name, path: pathLabel, scope: scope))
            }
        }
        collect(bar, path: [])
        return entries
    }

    private static func scope(_ item: NSMenuItem, menu: String, selector: String) -> (String, String?) {
        if let workflow = (item.target as? AutomationController)?.paletteWorkflow(item) {
            return (
                "Reads \(workflow.input.displayName) • Writes \(workflow.output.displayName)",
                workflow.output == .reminders
                    ? "This automation sends its result to Reminders. Editor Undo cannot remove those items." : nil
            )
        }
        if selector == "run:", item.target is RunController {
            return ("Runs a saved process • \(item.toolTip ?? item.title)", nil)
        }
        if let raw = item.representedObject as? String,
            let command = CompareCommand(rawValue: raw), selector == "performCompareCommand:"
        {
            switch command {
            case .applySelected: return ("Reads selected differences • Changes the destination editor", nil)
            case .copyPatch: return ("Reads comparison • Writes clipboard", nil)
            case .exportPatch: return ("Reads comparison • Writes a chosen patch file", nil)
            default: return ("Reads compared documents • Changes comparison view or selection", nil)
            }
        }
        switch selector {
        case "cut:": return ("Reads selection • Changes editor text and clipboard", nil)
        case "copy:": return ("Reads selection • Writes clipboard", nil)
        case "paste:": return ("Reads clipboard • Changes editor text", nil)
        case "undo:", "redo:": return ("Reads edit history • Changes active text", nil)
        case "saveDocument:", "saveDocumentAs:", "saveAllDocuments:", "saveCopy:":
            return ("Reads document text • Writes files to disk", nil)
        case "openUserGuide:", "openWelcome:": return ("Reads bundled help • Opens an editable untitled tab", nil)
        case "openOnlineHelp:":
            return (
                "Opens the TextTank help site in your browser", "Open TextTank’s online help in the default browser?"
            )
        case "convertEncoding:": return ("Reads current document • Changes format used on its next save", nil)
        case "reloadEncoding:", "revertDocumentToSaved:":
            return ("Reads saved file • Reloads document contents after the normal review", nil)
        case "checkExternalChanges:", "compareWithSavedVersion:":
            return ("Reads active document and saved file • Shows differences or external status", nil)
        case "compareWithEarlierVersion:":
            return ("Reads active document and its earlier versions • Shows differences", nil)
        case "clearLocalHistory:":
            return ("Reads local history • Deletes kept earlier versions after confirmation", nil)
        case "saveSession:": return ("Reads workspace documents • Writes a saved session", nil)
        case "openSession:": return ("Reads saved session • Opens workspace documents", nil)
        case "exportUDL", "exportStyled:": return ("Reads language or styled text • Writes chosen file", nil)
        case "importUDL": return ("Reads a chosen language file • Changes local language profiles", nil)
        case "printDocument:": return ("Reads active document • Opens print options", nil)
        case "useSelectionForFind:": return ("Reads editor selection • Changes the search query", nil)
        case "findNextShared:", "findPreviousShared:", "goToLine:", "selectAll:":
            return ("Reads active content • Changes selection or position", nil)
        case "showSearch:", "showFind:": return ("Reads active editor or files • Opens search options", nil)
        case "comment:", "columnInsert:", "convertEOL:": return ("Reads active editor • Changes document text", nil)
        case "performTabCommand:":
            switch item.representedObject as? String {
            case TabCommand.reveal.rawValue: return ("Reads active file path • Shows it in Finder", nil)
            case TabCommand.copyPath.rawValue: return ("Reads active file path • Writes clipboard", nil)
            default: return ("Reads workspace tabs • Changes tab order, selection or open documents", nil)
            }
        case "selectLanguage:": return ("Reads language profile • Changes active editor highlighting", nil)
        case "startRecording", "stopRecording": return ("Reads editor commands • Changes recording state", nil)
        case "playLast", "playSaved:", "playAgain": return ("Reads recorded commands • Changes active editor", nil)
        default: break
        }
        if selector == "command:", let raw = item.representedObject as? String {
            if let value = EditorCommand(rawValue: raw), value.viewPreference != nil {
                return ("Reads view settings • Changes them for every editor", nil)
            }
            if let value = EditorCommand(rawValue: raw), value.isViewOnly { return ("Changes active editor view", nil) }
            if raw == EditorCommand.bookmarkCopyLines.rawValue {
                return ("Reads bookmarked lines • Writes clipboard", nil)
            }
            if raw == EditorCommand.bookmarkCutLines.rawValue {
                return ("Reads bookmarked lines • Changes document and clipboard", nil)
            }
        }
        if ["toggleChangeBars:", "toggleCenteredColumn:", "toggleSyncPreviewScrolling:"].contains(selector) {
            return ("Reads view settings • Changes them for every editor", nil)
        }
        if selector == "toggleAutoIndent:" || selector == "toggleAutoPair:" {
            return ("Reads typing settings • Changes them for every editor", nil)
        }
        // What the command's owner works on, wherever the menu bar lists it.
        let detail: String
        switch item.target {
        case is LanguageController: detail = "Reads language profiles • Changes editor assistance or settings"
        case is MacroController: detail = "Reads or changes saved macros and editor recording"
        case is AutomationController: detail = "Reads or manages saved automations and history"
        case is RunController: detail = "Reads or manages saved commands and process output"
        case is UtilityController: detail = "Active text, utility results or export"
        case is WorkspaceBrowserController: detail = "Reads workspace state • Changes windows or tabs"
        default:
            switch menu {
            case "TextTank", "Help": detail = "Uses the application, its windows or settings"
            case "File": detail = "Reads or changes open documents and files"
            case "Edit": detail = "Reads active editor • Changes text, marks or selection"
            case "Find": detail = "Search, bookmarks or editor selection"
            case "View": detail = "Reads active view • Changes display or view settings"
            case "Compare": detail = "Reads open documents or chosen text • Opens a comparison"
            case "Window": detail = "Reads workspace state • Changes windows or tabs"
            default: detail = menu
            }
        }
        return (detail, nil)
    }
}
