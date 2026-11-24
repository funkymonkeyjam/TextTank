// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import TextTankCore

/// The menu bar: TextTank, File, Edit, Find, View, Compare, Tools, Window, Help (DS-D4).
///
/// One function per top-level menu. Each command is listed where a person would look for it
/// first, and no level lists more than about twenty items (DS-23). A command keeps its action,
/// target and represented object wherever it is listed, so shortcuts, macros, validation and
/// the Command Palette find it by identity, never by position.
extension AppDelegate {
    @MainActor func buildMenus() {
        let bar = NSMenu()
        NSApp.mainMenu = bar
        for menu in [
            applicationMenu(), fileMenu(), editMenu(), findMenu(), viewMenu(), compareMenu(), toolsMenu(),
            windowMenu(), helpMenu()
        ] { bar.addSubmenu(menu) }
        settings.reconcileShortcuts(with: bar)
        EditorSettingsApplication.applyShortcuts(settings.value, to: bar)
    }

    private func applicationMenu() -> NSMenu {
        let app = NSMenu(title: "TextTank")
        app.addItem(title: "About TextTank", action: #selector(about))
        app.addItem(
            title: "Settings…", action: #selector(SettingsController.showSettings(_:)), keyEquivalent: ",",
            target: settings)
        app.addItem(
            title: "Install tt Command-Line Tool…", action: #selector(installCommandLine(_:)), keyEquivalent: "",
            target: self)
        app.addItem(.separator())
        // The standard application items. AppKit fills the Services menu.
        let services = NSMenu(title: "Services")
        NSApp.servicesMenu = services
        app.addSubmenu(services)
        app.addItem(.separator())
        app.addItem(title: "Hide TextTank", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(
            title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h",
            modifiers: [.command, .option])
        app.addItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        app.addItem(title: "Quit TextTank", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return app
    }

    /// Opening, saving, encodings and the files of the workspace (DS-26).
    private func fileMenu() -> NSMenu {
        let file = NSMenu(title: "File")
        file.addItem(title: EditorToolbarCommand.new.title, action: EditorToolbarCommand.new.action, keyEquivalent: "n")
        file.addItem(
            title: EditorToolbarCommand.open.title, action: EditorToolbarCommand.open.action, keyEquivalent: "o")
        file.addItem(workspaceBrowser.menuItem(.quickOpen))
        let recent = NSMenu(title: "Open Recent")
        recent.delegate = recentDocumentsMenu
        file.addSubmenu(recent)
        file.addItem(.separator())
        file.addItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(
            title: EditorToolbarCommand.save.title, action: EditorToolbarCommand.save.action, keyEquivalent: "s")
        file.addItem(title: "Save As…", action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "S")
        file.addItem(title: "Save Copy…", action: #selector(TextDocument.saveCopy(_:)))
        automations.saveAllShortcutItem = file.addItem(
            title: "Save All", action: #selector(NSDocumentController.saveAllDocuments(_:)), fallback: .saveAll)
        file.addItem(title: "Revert to Saved…", action: #selector(NSDocument.revertToSaved(_:)))
        file.addItem(.separator())
        // The encoding names the status bar shows, never the stored identifier (DS-24).
        let reload = file.addSubmenu(titled: "Reload with Encoding")
        for value in FileEncoding.allCases {
            reload.addItem(
                title: "\(value.displayName)…", action: #selector(TextDocument.reloadEncoding(_:)),
                representedObject: value.rawValue)
        }
        let convert = file.addSubmenu(titled: "Convert to Encoding")
        for target in FileFormat.convertTargets {
            convert.addItem(
                title: target.title, action: #selector(TextDocument.convertEncoding(_:)),
                representedObject: target.code)
        }
        file.addItem(.separator())
        file.addItem(title: "Read Only", action: #selector(TextDocument.toggleReadOnly(_:)))
        file.addItem(title: "Check for External Changes", action: #selector(TextDocument.checkExternalChanges(_:)))
        file.addItem(workspaceBrowser.menuItem(.monitor))
        file.addItem(workspaceBrowser.menuItem(.reloadMonitored))
        file.addItem(.separator())
        let workspaceFiles = file.addSubmenu(titled: "Workspace")
        workspaceFiles.addItem(workspaceBrowser.menuItem(.addFolder))
        workspaceFiles.addItem(workspaceBrowser.recentFilesMenuItem())
        workspaceFiles.addItem(.separator())
        workspaceFiles.addItem(
            title: "Save Session Snapshot…", action: #selector(WorkspaceController.saveSession(_:)), target: workspace)
        workspaceFiles.addItem(
            title: "Open Session Snapshot…", action: #selector(WorkspaceController.openSession(_:)), target: workspace)
        file.addItem(.separator())
        file.addItem(title: "Page Setup…", action: #selector(NSDocument.runPageLayout(_:)))
        file.addItem(title: "Print…", action: #selector(NSDocument.printDocument(_:)), keyEquivalent: "p")
        return file
    }

    /// Everything that changes the text or the selection, grouped by what the command acts on.
    private func editMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        // This delegate names the action in Undo and Redo, which stay direct children of Edit.
        edit.delegate = self
        for (command, action) in [
            (EditorCommand.undo, NSSelectorFromString("undo:")), (.redo, NSSelectorFromString("redo:"))
        ] {
            edit.addItem(
                title: command.title, action: action, keyEquivalent: command.defaultMenuShortcut,
                representedObject: command.rawValue)
        }
        edit.addItem(.separator())
        for (command, action) in [
            (EditorCommand.cut, #selector(NSText.cut(_:))), (.copy, #selector(NSText.copy(_:))),
            (.paste, #selector(NSText.paste(_:)))
        ] {
            edit.addItem(
                title: command.title, action: action, keyEquivalent: command.defaultMenuShortcut,
                representedObject: command.rawValue)
        }
        edit.addSubmenu(automations.pasteThroughMenu())
        edit.addItem(
            title: EditorCommand.selectAll.title, action: #selector(NSText.selectAll(_:)),
            keyEquivalent: EditorCommand.selectAll.defaultMenuShortcut,
            representedObject: EditorCommand.selectAll.rawValue)
        edit.addItem(.separator())
        let lines = edit.addSubmenu(titled: "Lines")
        for value: EditorCommand in [.duplicateLine, .deleteLine, .transposeLine, .moveLineUp, .moveLineDown, .joinLines]
        { lines.addCommand(value) }
        lines.addItem(.separator())
        for value: EditorTransform in [
            .sortAscending, .sortDescending, .sortCaseInsensitive, .sortLocalized, .sortLength
        ] { lines.addTransform(value) }
        lines.addItem(.separator())
        for value: EditorTransform in [.reverseLines, .uniqueLines, .removeEmptyLines] { lines.addTransform(value) }
        let whitespace = edit.addSubmenu(titled: "Indentation and Whitespace")
        whitespace.addCommand(.indent)
        whitespace.addCommand(.unindent)
        whitespace.addItem(.separator())
        whitespace.addTransform(.trimLeading)
        whitespace.addCommand(.trimTrailing)
        whitespace.addTransform(.trimBoth)
        let letterCase = edit.addSubmenu(titled: "Convert Case")
        letterCase.addCommand(.upper)
        letterCase.addCommand(.lower)
        letterCase.addTransform(.titleCase)
        letterCase.addTransform(.invertCase)
        let comments = edit.addSubmenu(titled: "Comment")
        for comment in CommentCommand.allCases {
            comments.addItem(
                title: comment.title, action: #selector(EditorWindowController.comment(_:)),
                fallback: comment.defaultMenuShortcut, representedObject: comment.rawValue)
        }
        let selection = edit.addSubmenu(titled: "Selection")
        for value: EditorCommand in [
            .rectangularSelection, .streamSelection, .addNextOccurrence, .selectAllOccurrences,
            .clearAdditionalSelections, .duplicateSelection
        ] { selection.addCommand(value) }
        selection.addItem(.separator())
        selection.addItem(title: "Column Insert / Number…", action: #selector(EditorWindowController.columnInsert(_:)))
        let deletion = edit.addSubmenu(titled: "Delete")
        for value: EditorCommand in [.deleteWordLeft, .deleteWordRight, .deleteLineLeft, .deleteLineRight] {
            deletion.addCommand(value)
        }
        let endings = edit.addSubmenu(titled: "Line Endings")
        for mode in ["LF", "CRLF", "CR"] {
            endings.addItem(
                title: "Convert to \(mode)", action: #selector(EditorWindowController.convertEOL(_:)),
                representedObject: mode)
        }
        edit.addItem(.separator())
        edit.addSubmenu(utilities.encodeAndDecodeMenu())
        edit.addItem(utilities.menuItem(.formatJSON))
        edit.addItem(.separator())
        edit.addItem(languages.completeWordMenuItem())
        let typing = edit.addSubmenu(titled: "Typing")
        typing.addCommand(.toggleOvertype)
        typing.addItem(
            title: "Auto-Indent on Return", action: #selector(SettingsController.toggleAutoIndent(_:)), target: settings
        )
        typing.addItem(
            title: "Auto-Pair Brackets and Quotes", action: #selector(SettingsController.toggleAutoPair(_:)),
            target: settings)
        // Every transform has a place above; a new case must be given one.
        assert(
            Set(EditorTransform.allCases).isSubset(of: [
                .sortAscending, .sortDescending, .sortCaseInsensitive, .sortLocalized, .sortLength, .reverseLines,
                .uniqueLines, .removeEmptyLines, .trimLeading, .trimBoth, .titleCase, .invertCase
            ]), "an EditorTransform has no Edit menu item")
        return edit
    }

    /// Finding text and moving to a place in the document.
    private func findMenu() -> NSMenu {
        let find = NSMenu(title: "Find")
        // One Find. Command-F opens the find bar in the document window; Find Next, Find Previous
        // and Use Selection for Find share its text with the system find pasteboard. Find and
        // Replace is the window with scopes, regular expressions and results.
        find.addItem(
            title: EditorToolbarCommand.find.title, action: EditorToolbarCommand.find.action, keyEquivalent: "f")
        find.addItem(
            title: "Find and Replace…", action: #selector(SearchController.showSearch(_:)), keyEquivalent: "f",
            modifiers: [.command, .option], target: searchController)
        find.addItem(title: "Find Next", action: #selector(findNextShared(_:)), keyEquivalent: "g", target: self)
        find.addItem(
            title: "Find Previous", action: #selector(findPreviousShared(_:)), keyEquivalent: "G", target: self)
        find.addItem(
            title: "Use Selection for Find", action: #selector(EditorWindowController.useSelectionForFind(_:)),
            keyEquivalent: "e")
        find.addItem(
            title: "Find in Folder…", action: #selector(FolderSearchController.showSearch(_:)), keyEquivalent: "F",
            target: folderSearch)
        find.addItem(.separator())
        find.addItem(title: "Go to Line…", action: #selector(EditorWindowController.goToLine(_:)), keyEquivalent: "l")
        find.addCommand(.gotoMatchingBrace)
        find.addCommand(.selectMatchingBrace)
        find.addItem(.separator())
        let bookmarks = find.addSubmenu(titled: "Bookmarks")
        for value: EditorCommand in [.bookmarkToggle, .bookmarkNext, .bookmarkPrevious] { bookmarks.addCommand(value) }
        bookmarks.addItem(.separator())
        for value: EditorCommand in [
            .bookmarkCutLines, .bookmarkCopyLines, .bookmarkDeleteLines, .bookmarkInvert, .bookmarkClearAll
        ] { bookmarks.addCommand(value) }
        find.addItem(.separator())
        find.addItem(languages.functionListMenuItem())
        return find
    }

    /// How the document is shown (DS-D4, DS-D13). Fourteen items at the top level: what a tab
    /// shows, its split, how the text is laid out, zoom, folding and highlighting, the workspace
    /// and the toolbar. A toggle that applies to every editor view is in Show; the next addition
    /// belongs in a submenu too (DS-23).
    private func viewMenu() -> NSMenu {
        let view = NSMenu(title: "View")
        view.addSubmenu(DocumentViewCommands.makeMenu())
        view.addItem(.separator())
        // One toggle with a checkmark: it splits the tab, and closes the split when there is one
        // (DS-22). `closeSplit:` is still an action, with no row of its own.
        view.addItem(title: EditorToolbarCommand.split.title, action: EditorToolbarCommand.split.action)
        view.addItem(.separator())
        view.addItem(title: "Wrap Lines", action: #selector(EditorWindowController.toggleWrap(_:)))
        // Each title completes "Show" (DS-24). The command is the same one, with the same
        // identity, wherever it is named in full: the palette and Settings say "Show Line Numbers".
        let show = view.addSubmenu(titled: ViewMenuTitles.show)
        for value: EditorCommand in [.toggleLineNumbers, .showWhitespace, .toggleEOL] {
            show.addCommand(value, title: ViewMenuTitles.inShow(value))
        }
        show.addItem(.separator())
        show.addItem(
            title: "Indentation Guides", action: #selector(SettingsController.toggleIndentGuides(_:)),
            target: settings)
        show.addItem(
            title: "Current Line Highlight", action: #selector(SettingsController.toggleCurrentLineHighlight(_:)),
            target: settings)
        show.addItem(
            title: "Matching Braces", action: #selector(SettingsController.toggleBraceHighlight(_:)),
            target: settings)
        show.addItem(.separator())
        show.addItem(title: "Change Bars", action: #selector(SettingsController.toggleChangeBars(_:)), target: settings)
            .toolTip = EditorSettingsApplication.changeBarsHelp
        view.addItem(
            title: "Centered Text Column", action: #selector(SettingsController.toggleCenteredColumn(_:)),
            target: settings)
        view.addItem(.separator())
        view.addCommand(.zoomIn)
        view.addCommand(.zoomOut)
        view.addItem(title: "Actual Size", action: #selector(actualSize(_:)), fallback: .actualSize, target: self)
        view.addItem(.separator())
        let folding = view.addSubmenu(titled: "Folding")
        for value: EditorCommand in [
            .foldCurrent, .foldAll, .unfoldAll, .foldLevel1, .foldLevel2, .foldLevel3, .foldLevel4,
            .foldLevel5, .foldLevel6, .foldLevel7, .foldLevel8
        ] { folding.addCommand(value) }
        view.addSubmenu(languages.menu())
        view.addItem(.separator())
        view.addItem(workspaceBrowser.menuItem(.show))
        view.addSubmenu(workspaceWindow.groupCommands.menu())
        view.addItem(.separator())
        view.addItem(
            title: Strings.text("toolbar.show", "Show Toolbar"), action: #selector(NSWindow.toggleToolbarShown(_:)))
        view.addItem(
            title: Strings.text("toolbar.customize", "Customize Toolbar…"),
            action: #selector(NSWindow.runToolbarCustomizationPalette(_:)))
        view.addHiddenAlias(
            title: EditorCommand.zoomIn.title, action: #selector(EditorWindowController.command(_:)),
            key: .zoomInAlternate, target: nil, object: EditorCommand.zoomIn.rawValue)
        return view
    }

    /// Starting a comparison, then reading, merging and exporting it.
    private func compareMenu() -> NSMenu {
        let menu = NSMenu(title: "Compare")
        menu.addItem(
            title: "Compare Two Visible Tabs", action: #selector(CompareService.compareVisibleTabs(_:)),
            target: compare)
        menu.addItem(title: "Compare with Saved Version", action: #selector(TextDocument.compareWithSavedVersion(_:)))
        // DS-D10: the earlier versions kept at each save, and the one command that deletes them.
        menu.addItem(
            title: "Compare with Earlier Version…", action: #selector(TextDocument.compareWithEarlierVersion(_:)))
        compare.addMainItems(to: menu)
        menu.addItem(title: "Clear Local History…", action: #selector(clearLocalHistory(_:)), target: self)
        for command in CompareCommand.allCases where !command.isMergeCommand {
            // Moving between changes, the view choices, then the comparison itself.
            if [.previous, .sideBySide, .refresh].contains(command) { menu.addItem(.separator()) }
            menu.addItem(
                title: command.title, action: #selector(CompareController.performCompareCommand(_:)),
                fallback: command.defaultMenuShortcut, target: command.defaultMenuShortcut == nil ? nil : self,
                representedObject: command.rawValue)
        }
        menu.addItem(.separator())
        for (title, commands) in [
            ("Merge Changes", CompareCommand.mergeCommands), ("Patch", CompareCommand.patchCommands)
        ] {
            let submenu = menu.addSubmenu(titled: title)
            for command in commands {
                submenu.addItem(
                    title: command.title, action: #selector(CompareController.performCompareCommand(_:)), target: nil,
                    representedObject: command.rawValue)
            }
        }
        return menu
    }

    /// Macros, automations and Run commands, then the utilities that leave the text as it is.
    private func toolsMenu() -> NSMenu {
        let tools = NSMenu(title: "Tools")
        tools.addSubmenu(macros.menu())
        tools.addSubmenu(automations.menu())
        tools.addSubmenu(runner.makeMenu())
        tools.addItem(.separator())
        UtilityController.inspections.forEach { tools.addItem(utilities.menuItem($0)) }
        tools.addItem(utilities.numberConversionMenuItem())
        tools.addItem(.separator())
        tools.addSubmenu(utilities.styledTextMenu())
        return tools
    }

    private func windowMenu() -> NSMenu {
        let window = NSMenu(title: "Window")
        NSApp.windowsMenu = window
        window.addItem(
            title: "Next Tab", action: #selector(nextDocumentTab(_:)), keyEquivalent: "\t", modifiers: [.control],
            target: self)
        window.addItem(
            title: "Previous Tab", action: #selector(previousDocumentTab(_:)), keyEquivalent: "\t",
            modifiers: [.control, .shift], target: self)
        window.addItem(title: "Open Documents…", action: #selector(showDocumentTabs(_:)))
        // DS-73: the keyboard route between the window's areas, in one submenu.
        workspaceWindow.areaFocus.addMenuItems(to: window.addSubmenu(titled: WindowAreaFocusController.menuTitle))
        // DS-23: AppKit lists the open windows at the end of this menu, so its own commands must
        // leave room for them. The five commands that close several tabs at once share a
        // submenu; every tab's own menu lists them too. Close Tab stays at this level.
        let several: Set<TabCommand> = [.closeOthers, .closeLeft, .closeRight, .closeGroup, .closeSaved]
        var closeSeveral: NSMenu?
        for section in TabCommandController.sections {
            window.addItem(.separator())
            for command in section {
                var window = window
                if several.contains(command) {
                    let submenu = closeSeveral ?? window.addSubmenu(titled: "Close Multiple Tabs")
                    closeSeveral = submenu
                    window = submenu
                }
                let item = window.addItem(
                    title: command.title, action: #selector(performTabCommand(_:)),
                    fallback: command.defaultMenuShortcut, target: self,
                    representedObject: command.rawValue)
                item.identifier = NSUserInterfaceItemIdentifier("tabs.command." + command.rawValue)
            }
        }
        window.addItem(.separator())
        window.addItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)))
        window.addItem(.separator())
        window.addItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)))
        window.addHiddenAlias(
            title: "Next Tab", action: #selector(nextDocumentTab(_:)), key: .nextTabAlternate, target: self)
        window.addHiddenAlias(
            title: "Previous Tab", action: #selector(previousDocumentTab(_:)), key: .previousTabAlternate,
            target: self)
        // AppKit can translate Control-Shift-Tab to backtab on the active keyboard layout.
        window.addHiddenAlias(
            title: "Previous Tab", action: #selector(previousDocumentTab(_:)), key: .previousTabBacktab,
            target: self)
        return window
    }

    /// AppKit puts its search field here; it and the Command Palette find any command above.
    private func helpMenu() -> NSMenu {
        let help = NSMenu(title: "Help")
        NSApp.helpMenu = help
        help.addItem(title: "TextTank User Guide", action: #selector(openUserGuide(_:)), keyEquivalent: "?")
        help.addItem(title: "Welcome to TextTank", action: #selector(openWelcome(_:)))
        help.addItem(title: "TextTank Help (Online)", action: #selector(openOnlineHelp(_:)))
        help.addItem(.separator())
        help.addItem(automations.paletteMenuItem())
        help.addItem(languages.keywordHelpMenuItem())
        return help
    }
}

/// The wording of View > Show (DS-D13). An item there is titled by what is shown, because the
/// submenu already says "Show"; anywhere the command is named on its own it keeps the verb.
enum ViewMenuTitles {
    static let show = "Show"
    /// "Show Line Numbers" is "Line Numbers" under Show.
    static func inShow(_ command: EditorCommand) -> String {
        let title = command.title
        return title.hasPrefix(show + " ") ? String(title.dropFirst(show.count + 1)) : title
    }
    /// The name a command of View > Show has outside that submenu, in the Command Palette for
    /// one: "Show Change Bars". Nil for a command anywhere else.
    static func spokenName(route: [String]) -> String? {
        guard route.count == 3, route[0] == "View", route[1] == show else { return nil }
        return show + " " + route[2]
    }
}

extension NSMenu {
    /// Lists `menu` under its own title.
    fileprivate func addSubmenu(_ menu: NSMenu) {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        addItem(item)
    }
    fileprivate func addSubmenu(titled title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        addSubmenu(menu)
        return menu
    }
    /// An editor command keeps its identifier as its represented object, so shortcuts, macros
    /// and validation find it wherever it is listed.
    fileprivate func addCommand(_ value: EditorCommand, title: String? = nil) {
        let action = #selector(EditorWindowController.command(_:))
        let title = title ?? value.title
        if let fallback = value.extendedMenuShortcut {
            addItem(title: title, action: action, fallback: fallback, representedObject: value.rawValue)
        } else {
            addItem(
                title: title, action: action, keyEquivalent: value.defaultMenuShortcut,
                representedObject: value.rawValue)
        }
    }
    fileprivate func addTransform(_ value: EditorTransform) {
        addItem(
            title: value.title, action: #selector(EditorWindowController.command(_:)),
            representedObject: "transform." + value.rawValue)
    }
    /// A second shortcut for a command that is already listed: hidden, but still answering its key.
    fileprivate func addHiddenAlias(
        title: String, action: Selector, key: MenuShortcut, target: AnyObject?, object: String? = nil
    ) {
        let item = addItem(title: title, action: action, fallback: key, target: target, representedObject: object)
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
    }
}
