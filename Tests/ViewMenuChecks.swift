// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import EditorBridge
@testable import TextTankCore
@testable import TextTankRuntime

/// The regrouped View menu, change bars and the centered text column (owner decision DS-D13),
/// driven through the application's own menu bar, settings, palette and tabs. Nothing here
/// needs the window to be key, and no sheet, alert or tracked menu is presented.
@MainActor enum ViewMenuChecks {
    private static func open(_ name: String, _ text: String, in folder: URL) throws -> (
        TextDocument, EditorWindowController
    ) {
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        let document = TextDocument()
        document.fileURL = url
        document.fileType = TextDocument.plainTextType
        NSDocumentController.shared.addDocument(document)
        try document.read(from: Data(text.utf8), ofType: TextDocument.plainTextType)
        document.makeWindowControllers()
        document.showWindows()
        return (document, try requireValue(document.presentation, "fixture: tab adapter for \(name)"))
    }
    private static func item(_ path: [String]) throws -> NSMenuItem {
        var menu = try requireValue(NSApp.mainMenu, "fixture: main menu"), found: NSMenuItem?
        for (index, title) in path.enumerated() {
            let next = try requireValue(
                menu.items.first { $0.title == title }, "fixture: menu item \(path.joined(separator: " > "))")
            found = next
            if index < path.count - 1 { menu = try requireValue(next.submenu, "fixture: submenu \(title)") }
        }
        return try requireValue(found, "fixture: menu path")
    }
    /// Validates the item the way the menu does before it is drawn, then chooses it.
    @discardableResult private static func choose(_ item: NSMenuItem, in host: WorkspaceWindowController) -> Bool {
        let validator = (item.target as? NSMenuItemValidation) ?? host
        guard validator.validateMenuItem(item), let action = item.action else { return false }
        return NSApp.sendAction(action, to: item.target ?? host.active, from: item)
    }
    private static func state(_ item: NSMenuItem, in host: WorkspaceWindowController) -> (Bool, NSControl.StateValue) {
        let enabled = ((item.target as? NSMenuItemValidation) ?? host).validateMenuItem(item)
        return (enabled, item.state)
    }
    private static func descendants<View: NSView>(of view: NSView, as type: View.Type) -> [View] {
        view.subviews.flatMap { ($0 as? View).map { [$0] } ?? [] + descendants(of: $0, as: type) }
    }
    /// The settings file as it is on disk; empty when there is none yet.
    private static func stored(_ app: AppDelegate) -> [String: Any] {
        (try? Data(contentsOf: app.settings.url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            ?? [:]
    }

    static func run(root: URL, app: AppDelegate, host: WorkspaceWindowController) throws {
        let folder = root.appendingPathComponent("view-menu")
        // Other sections leave their own choices in the settings file; start from the defaults
        // of the keys this one reads, and put back what was there.
        let prior = app.settings.value
        var clean = prior
        clean.changeBars = nil
        clean.centeredColumn = nil
        clean.centeredColumnWidth = nil
        clean.syncPreviewScrolling = nil
        clean.shortcuts = [:]
        try app.settings.save(clean)
        defer { _ = try? app.settings.save(prior) }
        try structure(app: app)
        try palette(app: app)
        try splitToggle(folder: folder, app: app, host: host)
        try syncScrolling(folder: folder, app: app, host: host)
        try changeBars(folder: folder, app: app, host: host)
        try centeredColumn(folder: folder, app: app, host: host)
    }

    // MARK: The menu

    private static func structure(app: AppDelegate) throws {
        let bar = try requireValue(NSApp.mainMenu, "menu bar")
        let view = try requireValue(bar.items.first { $0.title == "View" }?.submenu, "View menu")
        let shape = view.items.filter { !$0.isHidden }.map { $0.isSeparatorItem ? "|" : $0.title }
        check(
            shape == [
                "Preview", "|", "Split Tab View", "|", "Wrap Lines", "Show", "Centered Text Column", "|", "Zoom In",
                "Zoom Out", "Actual Size", "|", "Folding", "Syntax Highlighting", "|", "Workspace Browser",
                "Editor Groups", "|", "Show Toolbar", "Customize Toolbar…"
            ],
            "DS-D13 View lists its fourteen items in the decided order, with the decided separators: \(shape)")
        func crowded(_ menu: NSMenu, _ path: String) -> [String] {
            let count = menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }.count
            return (count > 20 ? ["\(path) (\(count))"] : [])
                + menu.items.flatMap { item in item.submenu.map { crowded($0, path + " > " + item.title) } ?? [] }
        }
        check(
            view.items.filter { !$0.isSeparatorItem && !$0.isHidden }.count == 14 && crowded(view, "View").isEmpty,
            "DS-23 View's top level has 14 items and no level under it lists more than twenty: \(crowded(view, "View"))")
        let show = try requireValue(view.items.first { $0.title == "Show" }?.submenu, "View > Show")
        check(
            show.items.map { $0.isSeparatorItem ? "|" : $0.title } == [
                "Line Numbers", "Whitespace", "Line Endings", "|", "Indentation Guides", "Current Line Highlight",
                "Matching Braces", "|", "Change Bars"
            ] && !view.items.contains { $0.title == "Guides and Highlights" || $0.title == "Close Split View" },
            "DS-D13 Show holds the seven toggles in three sections; Guides and Highlights and Close Split View have no row")

        // Every command the View menu had keeps its action, target role and represented object.
        func commands(_ menu: NSMenu) -> [String] {
            menu.items.flatMap { item -> [String] in
                if let child = item.submenu {
                    return ["Syntax Highlighting", "Editor Groups"].contains(item.title) ? [] : commands(child)
                }
                guard let action = item.action else { return [] }
                return [
                    NSStringFromSelector(action) + "/" + (item.representedObject as? String ?? "") + "/"
                        + (item.target == nil ? "responder" : "explicit") + "/" + item.keyEquivalent
                ]
            }
        }
        let before = [
            "setDocumentViewMode:/source/responder/", "setDocumentViewMode:/preview/responder/",
            "setDocumentViewMode:/both/responder/", "toggleDocumentPreview://responder/V", "clone://responder/",
            "toggleWrap://responder/", "command:/showWhitespace/responder/", "command:/toggleEOL/responder/",
            "command:/toggleLineNumbers/responder/", "toggleIndentGuides://explicit/",
            "toggleCurrentLineHighlight://explicit/", "toggleBraceHighlight://explicit/", "command:/zoomIn/responder/+",
            "command:/zoomOut/responder/-", "actualSize://explicit/0", "command:/foldCurrent/responder/",
            "command:/foldAll/responder/", "command:/unfoldAll/responder/", "command:/foldLevel1/responder/",
            "command:/foldLevel2/responder/", "command:/foldLevel3/responder/", "command:/foldLevel4/responder/",
            "command:/foldLevel5/responder/", "command:/foldLevel6/responder/", "command:/foldLevel7/responder/",
            "command:/foldLevel8/responder/", "show://explicit/", "toggleToolbarShown://responder/",
            "runToolbarCustomizationPalette://responder/", "command:/zoomIn/responder/="
        ]
        let added = [
            "toggleSyncPreviewScrolling://responder/", "toggleChangeBars://explicit/", "toggleCenteredColumn://explicit/"
        ]
        let now = commands(view)
        check(
            now.sorted() == (before + added).sorted(),
            "DS-D13 the regrouped View menu lists every command it had exactly once more, less Close Split View, plus the three additions (lost: \(before.filter { !now.contains($0) }); new: \(now.filter { !(before + added).contains($0) }))")

        // The same rows as the golden menu fixture, which the document suite compares whole.
        // The language and group submenus belong to other checks and change with open tabs.
        func snapshot(_ menu: NSMenu, path: [Int]) -> [[String: String]] {
            menu.items.enumerated().flatMap { index, item -> [[String: String]] in
                let position = path + [index]
                let row: [String: String] = [
                    "position": position.map(String.init).joined(separator: "."), "title": item.title,
                    "action": item.action.map(NSStringFromSelector) ?? "", "key": item.keyEquivalent,
                    "modifiers": String(item.keyEquivalentModifierMask.rawValue),
                    "target": item.target == nil ? "responder" : "explicit",
                    "object": item.representedObject.map { String(describing: $0) } ?? ""
                ]
                let dynamic = ["Syntax Highlighting", "Editor Groups"].contains(item.title)
                return [row] + (dynamic ? [] : item.submenu.map { snapshot($0, path: position) } ?? [])
            }
        }
        let viewIndex = try requireValue(bar.items.firstIndex { $0.title == "View" }, "View's place in the menu bar")
        let fixture =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: TestPaths.fixtures.appendingPathComponent("menu-tree.json"))) as! [[String: String]]
        let live = snapshot(view, path: [viewIndex])
        let dynamicPrefixes = live.filter { ["Syntax Highlighting", "Editor Groups"].contains($0["title"] ?? "") }
            .compactMap { $0["position"].map { $0 + "." } }
        let golden = fixture.filter { row in
            let position = row["position"] ?? ""
            return position.hasPrefix("\(viewIndex).") && !dynamicPrefixes.contains { position.hasPrefix($0) }
        }
        check(
            dynamicPrefixes.count == 2 && live == golden,
            "DS-D13 the View rows of Tests/Fixtures/menu-tree.json are the menu as it is built (differing: \(live.filter { !golden.contains($0) }.prefix(6)) / \(golden.filter { !live.contains($0) }.prefix(6)))")

        // A moved command is the same command to the shortcut model, listed at its new place.
        let catalog = ShortcutCatalog.catalog(in: bar)
        let listed = Dictionary(catalog.entries.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        check(
            listed["toggleDocumentPreview:"] == "View › Preview › Toggle Preview"
                && listed["showWhitespace"] == "View › Show › Whitespace"
                && listed["toggleLineNumbers"] == "View › Show › Line Numbers"
                && listed["SettingsController.toggleIndentGuides:"] == "View › Show › Indentation Guides"
                && listed["SettingsController.toggleBraceHighlight:"] == "View › Show › Matching Braces"
                && listed["clone:"] == "View › Split Tab View" && listed["closeSplit:"] == nil
                && listed["toggleSyncPreviewScrolling:"] == "View › Preview › Sync Scrolling in Both"
                && listed["SettingsController.toggleChangeBars:"] == "View › Show › Change Bars"
                && listed["SettingsController.toggleCenteredColumn:"] == "View › Centered Text Column",
            "DS-20 each moved command keeps its stored shortcut identity and the shortcut list names its new place")
    }

    private static func palette(app: AppDelegate) throws {
        let bar = try requireValue(NSApp.mainMenu, "menu bar")
        let entries = app.commandDiscovery.commands(in: bar)
        func found(_ query: String) -> [String] { CommandDiscovery.matches(entries, query: query).map(\.path) }
        // The former path, the former name on its own, and the new path each find the command.
        let places: [(old: String, name: String, new: String)] = [
            ("View › Source", "Source", "View › Preview › Source"),
            ("View › Preview", "Preview", "View › Preview › Preview"),
            ("View › Both", "Both", "View › Preview › Both"),
            ("View › Toggle Preview", "Toggle Preview", "View › Preview › Toggle Preview"),
            ("View › Split Tab View", "Split Tab View", "View › Split Tab View"),
            ("View › Close Split View", "Close Split View", "View › Split Tab View"),
            ("View › Wrap Lines", "Wrap Lines", "View › Wrap Lines"),
            ("View › Show Whitespace", "Show Whitespace", "View › Show › Whitespace"),
            ("View › Show Line Endings", "Show Line Endings", "View › Show › Line Endings"),
            ("View › Show Line Numbers", "Show Line Numbers", "View › Show › Line Numbers"),
            (
                "View › Guides and Highlights › Show Indentation Guides", "Show Indentation Guides",
                "View › Show › Indentation Guides"
            ),
            (
                "View › Guides and Highlights › Highlight Current Line", "Highlight Current Line",
                "View › Show › Current Line Highlight"
            ),
            (
                "View › Guides and Highlights › Highlight Matching Braces", "Highlight Matching Braces",
                "View › Show › Matching Braces"
            ),
            ("View › Zoom In", "Zoom In", "View › Zoom In"), ("View › Zoom Out", "Zoom Out", "View › Zoom Out"),
            ("View › Actual Size", "Actual Size", "View › Actual Size"),
            ("View › Folding › Fold Level 3", "Fold Level 3", "View › Folding › Fold Level 3"),
            ("View › Workspace Browser", "Workspace Browser", "View › Workspace Browser"),
            ("View › Show Toolbar", "Show Toolbar", "View › Show Toolbar"),
            ("View › Customize Toolbar…", "Customize Toolbar", "View › Customize Toolbar…")
        ]
        let unfound = places.filter {
            !found($0.old).contains($0.new) || !found($0.name).contains($0.new) || !found($0.new).contains($0.new)
        }.map(\.old)
        check(unfound.isEmpty, "DS-D13 the palette finds each View command by its former path, its former name and its new path: \(unfound)")
        check(
            found("View › Preview › Sync Scrolling in Both") == ["View › Preview › Sync Scrolling in Both"]
                && found("show change bars") == ["View › Show › Change Bars"]
                && found("centered text column") == ["View › Centered Text Column"],
            "DS-D13 the palette lists the three new View commands")
        let shown = entries.filter { $0.row.detail == "View › Show" }
        check(
            shown.map(\.row.title) == [
                "Show Line Numbers", "Show Whitespace", "Show Line Endings", "Show Indentation Guides",
                "Show Current Line Highlight", "Show Matching Braces", "Show Change Bars"
            ] && shown.allSatisfy { $0.name == $0.row.title && $0.path == "View › Show › " + $0.item.title },
            "DS-24 a Show item is titled by what it shows in the menu, and the palette names the command in full: \(shown.map(\.row.title))")
        check(
            CommandDiscovery.rows(entries, matching: "show whitespace").first?.title == "Show Whitespace"
                && CommandDiscovery.rows(entries, matching: "close split").map(\.title) == ["Split Tab View"]
                && !entries.contains { $0.path.contains("Guides and Highlights") || $0.path.contains("Close Split") },
            "a former name is matched and never shown: Close Split View answers as Split Tab View")
    }

    // MARK: Split Tab View

    private static func splitToggle(folder: URL, app: AppDelegate, host: WorkspaceWindowController) throws {
        let (document, tab) = try open("split.txt", "one\ntwo\n", in: folder)
        defer { document.close() }
        let split = try item(["View", "Split Tab View"])
        check(host.active === tab && tab.secondary == nil, "fixture: the tab is active and not split")
        var seen = [state(split, in: host)]
        check(choose(split, in: host) && tab.secondary != nil, "Split Tab View splits a tab that is not split")
        seen.append(state(split, in: host))
        check(choose(split, in: host) && tab.secondary == nil, "and the same item closes the split")
        seen.append(state(split, in: host))
        check(
            seen.map(\.0) == [true, true, true] && seen.map(\.1) == [.off, .on, .off],
            "DS-22 its checkmark follows the split: off, on while split, off again")

        // The old command's selector is still an action: it closes, and does nothing with no split.
        tab.closeSplit(nil)
        check(tab.secondary == nil, "closeSplit with no split changes nothing")
        tab.clone(nil)
        let close = NSMenuItem(title: "", action: #selector(EditorWindowController.closeSplit(_:)), keyEquivalent: "")
        check(tab.secondary != nil && tab.validateMenuItem(close), "fixture: split again; closeSplit validates while split")
        tab.closeSplit(close)
        check(tab.secondary == nil && !tab.validateMenuItem(close), "closeSplit still closes the split, and is disabled without one")

        // A shortcut saved for Close Split View before the upgrade.
        let context = app.settings.shortcutContext
        func load(_ shortcuts: String) throws -> (settings: EditorSettings, issues: [ShortcutLoadIssue]) {
            try EditorSettings.load(
                Data(#"{"version":2,"tabWidth":4,"useTabs":true,"wrap":false,"appearance":"system","shortcuts":\#(shortcuts)}"#.utf8),
                context: context)
        }
        let upgraded = try load(#"{"closeSplit:":"ctrl+opt+k"}"#)
        check(
            upgraded.settings.shortcuts == ["clone:": "ctrl+opt+k"] && upgraded.issues.isEmpty,
            "a shortcut saved for Close Split View becomes Split Tab View's, and nothing is reported as ignored: \(upgraded.settings.shortcuts) \(upgraded.issues.map(\.message))")
        let both = try load(#"{"closeSplit:":"ctrl+opt+k","clone:":"ctrl+opt+j"}"#)
        check(
            both.settings.shortcuts == ["clone:": "ctrl+opt+j"] && both.issues.isEmpty,
            "Split Tab View's own saved shortcut stays, and the Close Split View one is dropped without a notice")
        let removed = try load(#"{"closeSplit:":""}"#)
        check(removed.settings.shortcuts.isEmpty && removed.issues.isEmpty, "an entry that only removed a key is dropped")
        let before = app.settings.value
        try app.settings.save(upgraded.settings)
        defer { _ = try? app.settings.save(before) }
        check(
            split.keyEquivalent == "k" && split.keyEquivalentModifierMask == [.control, .option],
            "after the upgrade the key is on Split Tab View")
        tab.clone(nil)
        check(tab.secondary != nil, "fixture: split")
        check(
            choose(split, in: host) && tab.secondary == nil,
            "so the saved Close Split View key still closes a split")
    }

    // MARK: Sync Scrolling in Both

    private static func syncScrolling(folder: URL, app: AppDelegate, host: WorkspaceWindowController) throws {
        let sync = try item(["View", "Preview", "Sync Scrolling in Both"])
        let plain = DocumentFactory.makeUntitled()
        check(
            sync.target == nil && state(sync, in: host).0 == false,
            "DS-21 Sync Scrolling in Both is disabled, with the rest of the Preview submenu, for a document with no preview")
        plain.presentation?.toggleSyncPreviewScrolling(sync)
        check(app.settings.value.syncsPreviewScrolling, "and does nothing if it is sent anyway")
        plain.close()

        let (document, tab) = try open("sync.md", "# Sync\n", in: folder)
        defer { document.close() }
        check(host.active === tab, "fixture: the Markdown tab is active")
        check(state(sync, in: host) == (true, .on), "DS-22 it is enabled for a Markdown document and checked by default")
        app.settings.showSettings(nil)
        let form = try requireValue(
            FormPanel.visible.last { $0.window.identifier?.rawValue == "TextTank.Settings" }, "fixture: Settings window")
        defer { form.close() }
        let content = try requireValue(form.window.contentView, "fixture: Settings content")
        let box = try requireValue(
            descendants(of: content, as: NSButton.self).first { $0.identifier?.rawValue == "settings.syncPreviewScrolling" },
            "fixture: the Sync scrolling in Both row")
        check(box.state == .on, "fixture: the Settings row starts on")
        check(choose(sync, in: host), "choosing the menu item")
        check(
            !app.settings.value.syncsPreviewScrolling && (stored(app)["syncPreviewScrolling"] as? Bool) == false
                && state(sync, in: host) == (true, .off) && box.state == .off,
            "turns the stored setting off, unchecks the item and the Settings row at once")
        box.performClick(nil)
        check(
            app.settings.value.syncsPreviewScrolling && state(sync, in: host) == (true, .on) && box.state == .on,
            "and the Settings row turns it on again, which the menu item shows: one value")
    }

    // MARK: Change bars

    private static func changeBars(folder: URL, app: AppDelegate, host: WorkspaceWindowController) throws {
        let bars = try item(["View", "Show", "Change Bars"])
        let (edited, editedTab) = try open("edited.txt", "alpha\nbeta\n", in: folder)
        let (fresh, freshTab) = try open("fresh.txt", "one\ntwo\n", in: folder)
        defer {
            edited.close()
            fresh.close()
        }
        check(
            state(bars, in: host) == (true, .off) && !app.settings.value.changeBarsEnabled
                && (stored(app)["changeBars"]) == nil
                && [edited, fresh].allSatisfy { !$0.editor.changeBarsVisible && !$0.editor.changeTrackingActive },
            "Change Bars is off by default: no margin, nothing recorded, no stored key")
        edited.editor.setSelectionAnchor(0, caret: 0)
        check(edited.editor.replaceSelection("typed ") && edited.editor.text == "typed alpha\nbeta\n", "fixture: an edit made before the toggle")
        freshTab.clone(nil)
        let clone = try requireValue(freshTab.secondary, "fixture: a split view of the unedited document")

        check(choose(bars, in: host), "choosing View > Show > Change Bars")
        check(
            app.settings.value.changeBars == true && (stored(app)["changeBars"] as? Bool) == true
                && state(bars, in: host) == (true, .on),
            "stores the choice and checks the item")
        check(
            fresh.editor.changeBarsVisible && fresh.editor.changeTrackingActive && clone.changeBarsVisible
                && clone.changeTrackingActive,
            "an unedited document shows the margin and records changes at once, in both panes of a split")
        check(
            edited.editor.changeBarsVisible && !edited.editor.changeTrackingActive
                && editedTab.statusText == EditorSettingsApplication.changeBarsPendingMessage
                && freshTab.statusText != EditorSettingsApplication.changeBarsPendingMessage,
            "a document edited earlier shows the margin with no bars, and its tab says why: \(editedTab.statusText)")
        check(
            edited.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
                && edited.editor.text == "alpha\nbeta\n",
            "and its Undo history was not cleared to start the record")
        try edited.read(from: Data("alpha\nbeta\n".utf8), ofType: TextDocument.plainTextType)
        check(
            edited.editor.changeBarsVisible && edited.editor.changeTrackingActive,
            "its record starts when the document is loaded again")

        let (later, laterTab) = try open("later.txt", "new\n", in: folder)
        defer { later.close() }
        check(
            later.editor.changeBarsVisible && later.editor.changeTrackingActive && host.active === laterTab,
            "a document opened afterwards has change bars from the start")
        let untitled = DocumentFactory.makeUntitled()
        check(untitled.editor.changeBarsVisible && untitled.editor.changeTrackingActive, "and so has a new untitled document")
        untitled.close()

        // Large-file mode: above the highlighting limit nothing is shown or recorded.
        let long = String(repeating: "x", count: SizePolicy.standard.largeLineThreshold + 16) + "\nend\n"
        let (large, largeTab) = try open("large.txt", long, in: folder)
        defer { large.close() }
        check(
            large.deferredLargeFileLanguage != nil && !large.editor.changeBarsVisible && !large.editor.changeTrackingActive,
            "a large-file document shows no change bars and records nothing")
        largeTab.clone(nil)
        check(
            largeTab.secondary.map { !$0.changeBarsVisible && !$0.changeTrackingActive } == true,
            "nor does a split view of it")
        var again = app.settings.value
        again.changeBars = false
        try app.settings.save(again)
        again.changeBars = true
        try app.settings.save(again)
        check(
            !large.editor.changeBarsVisible && !large.editor.changeTrackingActive && fresh.editor.changeBarsVisible,
            "and turning the setting off and on leaves it out")

        // Off: the margin goes, the record stays, so the bars are complete when it returns.
        check(choose(bars, in: host), "choosing Change Bars again")
        check(
            !app.settings.value.changeBarsEnabled && state(bars, in: host) == (true, .off)
                && !fresh.editor.changeBarsVisible && !clone.changeBarsVisible && fresh.editor.changeTrackingActive,
            "hides the margin in every view and keeps the record of a document that had one")
        check(choose(bars, in: host) && fresh.editor.changeBarsVisible && fresh.editor.changeTrackingActive, "and on again shows it")

        // The Settings row is the same value.
        app.settings.showSettings(nil)
        let form = try requireValue(
            FormPanel.visible.last { $0.window.identifier?.rawValue == "TextTank.Settings" }, "fixture: Settings window")
        defer { form.close() }
        let content = try requireValue(form.window.contentView, "fixture: Settings content")
        let box = try requireValue(
            descendants(of: content, as: NSButton.self).first { $0.identifier?.rawValue == "settings.changeBars" },
            "fixture: the Show change bars row")
        check(box.state == .on && box.title == "Show change bars", "the Appearance row shows the stored choice")
        box.performClick(nil)
        check(
            !app.settings.value.changeBarsEnabled && state(bars, in: host) == (true, .off) && !fresh.editor.changeBarsVisible,
            "and turning it off there unchecks the menu item and hides the margin")
        freshTab.closeSplit(nil)
    }

    // MARK: Centered text column

    private static func centeredColumn(folder: URL, app: AppDelegate, host: WorkspaceWindowController) throws {
        let column = try item(["View", "Centered Text Column"])
        let text = (1...40).map { "line \($0) " + String(repeating: "word ", count: 30) }.joined(separator: "\n") + "\n"
        let (document, tab) = try open("column.txt", text, in: folder)
        defer { document.close() }
        let editor = document.editor
        host.window?.layoutIfNeeded()
        let plain = (editor.textMarginLeft, editor.textMarginRight)
        let digit = editor.textWidth(ofColumns: 1)
        func textArea(_ view: TTEditor) -> Int { view.textAreaWidth }
        check(
            state(column, in: host) == (true, .off) && editor.centeredColumnCharacters == 0
                && (stored(app)["centeredColumn"]) == nil && plain.0 == plain.1 && plain.0 < 8,
            "Centered Text Column is off by default: the ordinary margins (\(plain)), no stored key")
        check(textArea(editor) > 90 * digit + 40, "fixture: the text area (\(textArea(editor))) is wider than 90 characters (\(90 * digit))")

        check(choose(column, in: host), "choosing View > Centered Text Column")
        func centered(_ view: TTEditor, _ characters: Int) -> Bool {
            let left = view.textMarginLeft, right = view.textMarginRight
            return view.centeredColumnCharacters == characters && abs(left - right) <= 1
                && left + right + characters * view.textWidth(ofColumns: 1) == textArea(view) && left > plain.0
        }
        check(
            app.settings.value.centeredColumn == true && (stored(app)["centeredColumn"] as? Bool) == true
                && state(column, in: host) == (true, .on) && centered(editor, 90),
            "stores the choice, checks the item and centres a 90-character column: margins \(editor.textMarginLeft) and \(editor.textMarginRight) of \(textArea(editor))")
        check(
            editor.text == text && !document.isDocumentEdited && !editor.wrap,
            "the document, its edited state and Wrap Lines are untouched")

        // Zoom, the stored width, a split and the font each move the margins.
        let wide = editor.textMarginLeft
        editor.zoomLevel += 3
        check(
            centered(editor, 90) && editor.textMarginLeft < wide,
            "zooming in keeps the column centred with narrower margins (\(wide) to \(editor.textMarginLeft))")
        editor.resetZoomLevel()
        check(editor.textMarginLeft == wide, "and Actual Size puts them back")
        var narrow = app.settings.value
        narrow.centeredColumnWidth = 60
        try app.settings.save(narrow)
        check(centered(editor, 60) && editor.textMarginLeft > wide, "a 60-character column has wider margins")
        tab.clone(nil)
        let clone = try requireValue(tab.secondary, "fixture: split")
        host.window?.layoutIfNeeded()
        check(
            textArea(clone) < textArea(editor) + 1 && clone.centeredColumnCharacters == 60
                && [editor, clone].allSatisfy { view in
                    textArea(view) > 60 * digit + 2 * plain.0 ? centered(view, 60) : view.textMarginLeft == plain.0
                },
            "in a split each pane centres the column in its own width, or keeps the ordinary margins when it is narrower")
        let splitWidth = textArea(editor)
        tab.closeSplit(nil)
        // The split view gives the pane its full width at the next layout pass.
        host.window?.contentView?.layoutSubtreeIfNeeded()
        host.window?.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        check(
            textArea(editor) > splitWidth && centered(editor, 60),
            "closing the split recentres the one pane (\(splitWidth) to \(textArea(editor)), margins \(editor.textMarginLeft) and \(editor.textMarginRight))")

        // The Settings rows.
        app.settings.showSettings(nil)
        let form = try requireValue(
            FormPanel.visible.last { $0.window.identifier?.rawValue == "TextTank.Settings" }, "fixture: Settings window")
        defer { form.close() }
        let content = try requireValue(form.window.contentView, "fixture: Settings content")
        let box = try requireValue(
            descendants(of: content, as: NSButton.self).first { $0.identifier?.rawValue == "settings.centeredColumn" },
            "fixture: the Center the text in a column row")
        let field = try requireValue(
            descendants(of: content, as: NSTextField.self).first {
                $0.identifier?.rawValue == "settings.centeredColumn.width"
            }, "fixture: the Column width field")
        check(
            box.state == .on && field.stringValue == "60" && field.accessibilityLabel() == "Column width (characters)",
            "DS-70 Settings shows the toggle and the labelled width")
        func commit(_ value: String) {
            field.stringValue = value
            if let action = field.action { _ = NSApp.sendAction(action, to: field.target, from: field) }
        }
        commit("72")
        check(
            app.settings.value.centeredColumnWidth == 72 && (stored(app)["centeredColumnWidth"] as? Int) == 72
                && centered(editor, 72),
            "a width typed in Settings is saved and applied at once")
        commit("500")
        check(
            app.settings.value.centeredColumnWidth == 72 && centered(editor, 72) && field.stringValue == "500",
            "DS-45 a width outside 40 to 240 is refused, kept in the field, and changes nothing")
        commit("72")
        box.performClick(nil)
        check(
            !app.settings.value.centeredColumnEnabled && state(column, in: host) == (true, .off)
                && editor.centeredColumnCharacters == 0
                && (editor.textMarginLeft, editor.textMarginRight) == plain,
            "turning it off in Settings unchecks the menu item and restores the ordinary margins exactly")
        check(
            EditorSettings().centeredColumnCharacters == 90 && !EditorSettings().centeredColumnEnabled
                && narrow.centeredColumnCharacters == 60,
            "the default width is 90 characters and the default is off")
    }
}
