// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import TextTankCore
import EditorBridge

/// Discover and invoke the same menu items that belong to the window where the chooser opened.
@MainActor final class CommandDiscovery {
    struct Entry {
        let row: ChoicePanel.Row
        let item: NSMenuItem
        weak var target: AnyObject?
        let externalNotice: String?
        /// Where the command used to be listed, matched by the filter but never shown.
        var legacyPath = ""
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
        (["View", "Guides and Highlights"], "View"),
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
    static func legacyPath(for route: [String]) -> String {
        guard let old = legacyLocations.first(where: { route.starts(with: $0.current) }), let title = route.last
        else { return "" }
        return old.legacy + " " + title
    }
    /// The rows whose path, or former path, contains every word typed, in any order.
    static func rows(_ entries: [Entry], matching query: String) -> [ChoicePanel.Row] {
        let words = query.split(whereSeparator: \.isWhitespace)
        return entries.filter { entry in
            let text = entry.row.title + " " + entry.legacyPath
            return words.allSatisfy { text.localizedCaseInsensitiveContains($0) }
        }.map(\.row)
    }

    private var panel: ChoicePanel?

    func show(editor: @escaping () -> TTEditor?) {
        if let panel {
            panel.form.window.makeKeyAndOrderFront(nil)
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
        chooser.rows = { entries.map(\.row) }
        chooser.filteredRows = { Self.rows(entries, matching: $0) }
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
            current.row.enabled, current.target === expected, current.row.detail == original.row.detail,
            current.item.action == original.item.action, let action = current.item.action
        else { return false }
        // Group invocations carry the original tab, group membership and destination generation.
        // Its controller must receive that captured sender and can still reject it if the layout changed.
        if let validator = expected as? NSMenuItemValidation, !validator.validateMenuItem(original.item) {
            return false
        }
        return NSApp.sendAction(action, to: expected, from: original.item)
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
                entries.append(
                    Entry(
                        row: .init(id: id, title: pathLabel, detail: scope, enabled: enabled),
                        item: item, target: target, externalNotice: destination,
                        legacyPath: Self.legacyPath(for: route)))
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
            if let value = EditorCommand(rawValue: raw), value.isViewOnly { return ("Changes active editor view", nil) }
            if raw == EditorCommand.bookmarkCopyLines.rawValue {
                return ("Reads bookmarked lines • Writes clipboard", nil)
            }
            if raw == EditorCommand.bookmarkCutLines.rawValue {
                return ("Reads bookmarked lines • Changes document and clipboard", nil)
            }
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
