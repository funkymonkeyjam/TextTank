@testable import TextTankCore
// SPDX-License-Identifier: GPL-3.0-or-later
// Audit package 21: window, menu and keyboard conventions. These sections run inside
// document-checks after the split-view sections and share its support directory and delegate.
// The check process holds no key or main window, so menu validation is asked of the object the
// responder chain would reach, and tab windows are told to come forward directly. The main menu
// is the one the "menu and command wiring" section built: its submenus belong to that menu bar,
// so the delegate cannot build a second one.
import AppKit
@testable import TextTankRuntime
import EditorBridge
import NativeSearch
import UniformTypeIdentifiers

/// Lets the real application dispatcher observe an open Find window without putting it on screen.
private final class OffscreenFindRoutingWindow: NSWindow {
    override var isVisible: Bool { true }
    override func makeKeyAndOrderFront(_ sender: Any?) {}
}

@MainActor private final class WindowQuitObservation { var shown = 0 }
@MainActor private final class WindowSettingsObservation {
    var returned = false, observedModeless = false, inspected = false, usable = false
}

@MainActor private final class PaletteActionFixture: NSObject, NSMenuItemValidation {
    var enabled = true, count = 0
    @objc func selected(_ item: NSMenuItem) { count += 1 }
    func validateMenuItem(_ item: NSMenuItem) -> Bool { enabled }
}
extension DocumentChecks {
    @MainActor static func item(_ action: Selector, _ object: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
        item.representedObject = object
        return item
    }

    @MainActor static func windowMenuAndKeyboard(
        root: URL, app: NSApplication, sessionDelegate: AppDelegate, section: SectionRunner
    ) {
        /// An untitled document with a window, named so that its tab and close button can be found.
        @MainActor func tab(_ name: String) throws -> (TextDocument, EditorWindowController, NSWindow) {
            let document = TextDocument()
            document.displayName = name
            NSDocumentController.shared.addDocument(document)
            document.makeWindowControllers()
            document.showWindows()
            let controller = try requireValue(
                document.windowControllers.first as? EditorWindowController, "fixture: editor window controller")
            return (document, controller, try requireValue(controller.hostWindow, "fixture: window"))
        }
        /// The close button for `target` in the tab strip of the window that is showing.
        @MainActor func closeButton(for target: TextDocument, in shown: EditorWindowController) throws -> NSButton {
            shown.refreshStatusDetails()
            let content = try requireValue(shown.hostWindow?.contentView, "fixture: content view")
            return try requireValue(
                descendants(content).compactMap { $0 as? NSButton }.first {
                    $0.toolTip == "Close \(target.displayName ?? "Untitled")"
                },
                "fixture: the close button for \(target.displayName ?? "Untitled")")
        }
        @MainActor func isOpen(_ document: NSDocument) -> Bool {
            NSDocumentController.shared.documents.contains { $0 === document }
        }
        func walk(_ menu: NSMenu, _ path: String = "") -> [(path: String, item: NSMenuItem)] {
            menu.items.flatMap { item -> [(path: String, item: NSMenuItem)] in
                let here = path.isEmpty ? item.title : path + " > " + item.title
                return [(here, item)] + (item.submenu.map { walk($0, here) } ?? [])
            }
        }

        section("DG-R1 Settings leaves the document usable", #line) {
            let settings = SettingsController(url: root.appendingPathComponent("modeless-settings-red.json"))
            let (document, documentController, documentWindow) = try tab("settings-document-stays-usable")
            defer { document.close() }
            let observation = WindowSettingsObservation()
            let timerAction: @MainActor @Sendable () -> Void = {
                guard
                    let window = NSApp.windows.first(where: {
                        $0.isVisible && ($0.title == "Settings" || $0.title == "Editor Settings")
                    }), let content = window.contentView
                else { return }
                observation.observedModeless = observation.returned && NSApp.modalWindow == nil
                observation.usable =
                    documentWindow.canBecomeKey
                    && documentController.validateMenuItem(
                        item(#selector(EditorWindowController.perform(_:)), "upper"))
                observation.inspected = true
                DesignSettingsChecks.checkNativeButtons(window)
                descendants(content).compactMap { $0 as? NSButton }.first { $0.title == "Close" }?.performClick(
                    nil)
            }
            let timer = Timer(timeInterval: 0.02, repeats: true) { _ in
                MainActor.assumeIsolated { timerAction() }
            }
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .modalPanel)
            settings.showSettings(nil)
            observation.returned = true
            _ = spinUntil("Settings presentation is inspected") { observation.inspected }
            timer.invalidate()
            check(
                observation.observedModeless,
                "DG-R1 opening Settings returns without entering an application modal loop")
            check(
                observation.usable,
                "DG-R1 the document stays key-capable and its commands validate while Settings is open")
        }

        section("DG Settings keyboard, restoration and minimum layout", #line) {
            try DesignSettingsChecks.settingsFrameChecks(root: root)
        }

        section("DG Settings refuses an intervening controller save", #line) {
            let settings = SettingsController(url: root.appendingPathComponent("modeless-settings-stale.json"))
            try settings.save(EditorSettings())
            settings.showSettings(nil)
            let window = try requireValue(FormPanel.frontWindow, "fixture: Settings modeless window")
            let views = descendants(try requireValue(window.contentView, "fixture: Settings content"))
            let field = try requireValue(
                views.compactMap { $0 as? NSTextField }.first { $0.isEditable }, "fixture: tab width")
            window.makeFirstResponder(nil)
            field.stringValue = "7"
            var intervening = settings.value
            intervening.wrap = true
            intervening.tabWidth = 6
            try settings.save(intervening)
            let bytes = try Data(contentsOf: settings.url)
            _ = NSApp.sendAction(field.action!, to: field.target, from: field)
            check(
                window.isVisible && field.stringValue == "7" && field.window != nil,
                "DG stale Settings keeps the pending native fields open")
            let after = try Data(contentsOf: settings.url)
            check(
                settings.value.wrap && settings.value.tabWidth == 6 && after == bytes,
                "DG stale Settings never overwrites an intervening real controller save")
            check(
                views.compactMap { $0 as? NSTextField }.contains {
                    $0.stringValue.contains("changed while this window was open")
                },
                "DG stale Settings explains the conflict beside the retained fields")
            views.compactMap { $0 as? NSButton }.first { $0.title == "Close" }?.performClick(nil)
        }

        section("DG Go to Line owns its captured document lifetime", #line) {
            let (document, controller, _) = try tab("goto-owner-close")
            document.editor.text = "one\ntwo"
            document.editor.setSavePoint()
            controller.goToLine(nil)
            let form = try requireValue(FormPanel.visible.last, "fixture: owned Go to Line form")
            let caret = document.editor.selectionCaret
            document.close()
            check(!form.window.isVisible, "DG closing the captured document closes its Go to Line form")
            check(
                document.editor.selectionCaret == caret,
                "DG closing a Go to Line target never navigates a retired editor")
        }

        section("offline guide and editable welcome", #line) {
            let profile = root.appendingPathComponent("owned-help-profile")
            check(TextTankApplication.isNewProfile(at: profile), "an absent private profile is new")
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            check(TextTankApplication.isNewProfile(at: profile), "an empty private profile is new")
            try Data("prior".utf8).write(to: profile.appendingPathComponent("owned-entry"))
            check(!TextTankApplication.isNewProfile(at: profile), "an existing profile is preserved")
            let original = sessionDelegate.helpResourceDirectory
            sessionDelegate.helpResourceDirectory = TestPaths.resources
            defer { sessionDelegate.helpResourceDirectory = original }
            let menu = try requireValue(NSApp.helpMenu, "actual Help menu")
            for (action, name) in [
                (#selector(AppDelegate.openUserGuide(_:)), "TextTank-User-Guide"),
                (#selector(AppDelegate.openWelcome(_:)), "TextTank-Welcome")
            ] {
                let item = try requireValue(menu.items.first { $0.action == action }, "offline Help item")
                let source = TestPaths.resources.appendingPathComponent(name + ".txt")
                let bytes = try Data(contentsOf: source)
                let previous = Set(NSDocumentController.shared.documents.map(ObjectIdentifier.init))
                check(NSApp.sendAction(action, to: sessionDelegate, from: item), "normal Help action dispatches")
                let doc = try requireValue(
                    NSDocumentController.shared.documents.compactMap { $0 as? TextDocument }
                        .first { !previous.contains(ObjectIdentifier($0)) }, "owned untitled help")
                defer { doc.close() }
                check(doc.fileURL == nil && doc.displayName == item.title && !doc.isDocumentEdited
                    && !doc.editor.modified && !doc.editor.readOnly && doc.editor.checkedUTF8Data == bytes,
                    "offline help has exact bundled text and a clean editable untitled identity")
                check(doc.editor.wrap, "offline help opens wrapped so that its paragraphs are readable")
                doc.editor.replaceSelection("sample edit")
                check(doc.isDocumentEdited && doc.editor.checkedUTF8Data != bytes, "typing marks the help draft edited")
                doc.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
                check(try doc.editor.checkedUTF8Data == bytes && Data(contentsOf: source) == bytes,
                    "one Undo restores the original text and bundled help remains untouched")
            }
            let sample = "- green tea\n- milk"
            let bulletRule = AutomationDefinition.Step(kind: .removeListMarkers)
            check(try AutomationDefinition.testRules([bulletRule], sample: sample) == "green tea\nmilk",
                "the welcome's worked example yields the documented result with the one rule it names")
            let welcome = try String(
                contentsOf: TestPaths.resources.appendingPathComponent("TextTank-Welcome.txt"), encoding: .utf8)
            let exercises = ["Edit, undo and find", "Find any command", "Make your first automation"].compactMap {
                welcome.range(of: $0)?.lowerBound
            }
            check(
                exercises.count == 3 && exercises == exercises.sorted()
                    && welcome.contains("pick " + bulletRule.kind.label + " and")
                    && !welcome.localizedCaseInsensitiveContains("recipe"),
                "the welcome starts with editing and finding, and builds a first automation from a real rule")
            let guide = try String(
                contentsOf: TestPaths.resources.appendingPathComponent("TextTank-User-Guide.txt"), encoding: .utf8)
            check(
                guide.contains("A new installation includes one automation, " + AutomationDefinition.remindersExample.name + ",")
                    && !guide.localizedCaseInsensitiveContains("recipe"),
                "the user guide names the one automation a new installation has")
            // DS-D4: the help text names commands where the nine-menu bar lists them.
            let helpPaths = [
                "Find → Find…", "Help → Command Palette…", "Compare → Compare with Saved Version",
                "View → Editor Groups → Editor Group Layout → Two Columns",
                "View → Editor Groups → Show Tab in Another Group", "Tools → Automations → Manage Automations…",
                "File → Quick Open…", "Find → Find and Replace…", "Tools → Macros", "Tools → Run Commands",
                "View → Syntax Highlighting", "Help → TextTank User Guide", "Help → Welcome to TextTank",
                "Edit → Undo", "File → New", "File → Save"
            ]
            let listed = Set(walk(try requireValue(NSApp.mainMenu, "actual menu bar")).map(\.path))
            let unlisted = helpPaths.filter { !listed.contains($0.replacingOccurrences(of: " → ", with: " > ")) }
            let unmentioned = helpPaths.filter { !(welcome + guide).contains($0) }
            let help = (welcome + guide).replacingOccurrences(of: "Tools → Automations → ", with: "")
            let former = [
                "Search → ", "Automations → ", "The Automations menu", "The Run menu", "Language → ", "Encoding → "
            ].filter { help.contains($0) }
            check(
                unlisted.isEmpty && unmentioned.isEmpty && former.isEmpty,
                "the welcome and user guide name menu paths that exist (unlisted: \(unlisted); unmentioned: \(unmentioned); former: \(former))")
        }

        section("command discovery uses ordinary menu validation", #line) {
            let bar = try requireValue(NSApp.mainMenu, "actual menu bar")
            let palette = sessionDelegate.commandDiscovery
            let entries = palette.commands(in: bar)
            // A row shows the command's name, with its menu as secondary text; `path` is both.
            let titles = entries.map(\.path)
            check(Set(entries.map { $0.row.id }).count == entries.count, "palette row identities are unique")
            check(titles.contains("Edit › Undo") && titles.contains("Tools › Automations › Run Automation…")
                && titles.contains(where: { $0.hasPrefix("View › Syntax Highlighting › ") && $0.hasSuffix(" › Markdown") })
                && titles.contains("Tools › Macros › Start Recording")
                && titles.contains("View › Editor Groups › Editor Group Layout › Two Columns")
                && titles.contains(where: { $0.hasPrefix("Tools › Run Commands › ") }),
                "actual editor, language, saved automation chooser, macro, group and Run routes are discoverable at any depth")
            // DS-D4: a person who types where a command used to be, or its old name, still finds it.
            @MainActor func found(_ query: String) -> [String] { CommandDiscovery.matches(entries, query: query).map(\.path) }
            let formerPlaces = [
                ("Search Compare", "Compare › Compare Text…"), ("Encoding Reload", "File › Reload with Encoding › UTF-8…"),
                ("Reload as Windows-1252", "File › Reload with Encoding › Windows-1252…"),
                ("Encoding Convert to UTF-16", "File › Convert to Encoding › UTF-16 LE with BOM"),
                ("Macros Start Recording", "Tools › Macros › Start Recording"),
                ("Workspace Quick Open", "File › Quick Open…"),
                ("Show Workspace Browser", "View › Workspace Browser"),
                ("Text Utilities Base64", "Edit › Encode and Decode › Base64 › Base64 Encode"),
                ("Text Utilities Validate JSON", "Tools › Validate JSON"),
                ("Run Configure", "Tools › Run Commands › Configure Command…"),
                ("Automations Manage", "Tools › Automations › Manage Automations…"),
                ("Language Function List", "Find › Function List…"),
                ("Search Bookmarked Lines Invert", "Find › Bookmarks › Invert Bookmarks"),
                ("File Compare with Saved", "Compare › Compare with Saved Version"),
                ("View Auto-Pair", "Edit › Typing › Auto-Pair Brackets and Quotes")
            ]
            let unfound = formerPlaces.filter { !found($0.0).contains($0.1) }.map(\.0)
            check(unfound.isEmpty, "palette finds each command by its former menu or name: \(unfound)")
            check(
                found("Language Markdown").count == 1 && found("Language Markdown").first?.hasSuffix(" › Markdown") == true,
                "a language is found by the former Language menu, and only that one row")
            check(
                found("lines sort").contains("Edit › Lines › Sort Lines Ascending")
                    && found("ascending  SORT") == ["Edit › Lines › Sort Lines Ascending"]
                    && found("Edit › Undo") == ["Edit › Undo"],
                "palette matching ignores word order and case, and a typed path still matches")
            check(
                found("").count == entries.count && found("   ").count == entries.count
                    && found("no-such-command-anywhere").isEmpty
                    && !titles.contains(where: { $0.contains("Text Utilities") || $0.hasPrefix("Search › ") }),
                "an empty filter lists every command; a former menu name is matched but never shown")
            @MainActor func detail(_ title: String) -> String? { entries.first { $0.path == title }?.scope }
            check(
                detail("File › Quick Open…") == "Reads workspace state • Changes windows or tabs"
                    && detail("Find › Function List…") == "Reads language profiles • Changes editor assistance or settings"
                    && detail("Edit › Typing › Auto-Indent on Return") == "Reads typing settings • Changes them for every editor"
                    && detail("Tools › Run Commands › Configure Command…")
                        == "Reads or manages saved commands and process output"
                    && detail("Tools › Validate JSON") == "Active text, utility results or export"
                    && detail("Compare › Compare Text…") == "Reads open documents or chosen text • Opens a comparison"
                    && detail("Find › Matching Brace") == "Search, bookmarks or editor selection"
                    && detail("File › Reload with Encoding › UTF-8…")
                        == "Reads saved file • Reloads document contents after the normal review"
                    && detail("View › Guides and Highlights › Highlight Current Line")
                        == "Reads active view • Changes display or view settings",
                "DS-20 a palette entry records what its command works on, wherever the menu bar lists it")
            check(
                !entries.contains { $0.row.detail == $0.scope || $0.row.title.contains(" › ") }
                    && entries.allSatisfy { $0.path == ($0.row.detail.isEmpty ? "" : $0.row.detail + " › ") + $0.row.title },
                "a palette row shows the command's name and the menu that holds it, never the internal description")
            // Toggle Preview is an ordinary menu item, so the palette lists and validates it
            // exactly as it does Source, Preview and Both.
            let toggleRow = try requireValue(
                entries.first { $0.path == "View › Toggle Preview" }, "palette row for View › Toggle Preview")
            let previewRow = try requireValue(
                entries.first { $0.path == "View › Preview" }, "palette row for View › Preview")
            let previewable = sessionDelegate.currentDocumentController?.previewKind != nil
            check(
                found("toggle preview") == ["View › Toggle Preview"]
                    && toggleRow.scope == "Reads active view • Changes display or view settings"
                    && toggleRow.scope == previewRow.scope && toggleRow.row.detail == "View"
                    && toggleRow.row.detail == previewRow.row.detail,
                "DS-20 the palette finds Toggle Preview and describes it as it does the three mode commands")
            check(
                toggleRow.row.enabled == previewRow.row.enabled && toggleRow.row.enabled == previewable
                    && (previewable || !palette.perform(toggleRow, in: bar)),
                "DS-21 Toggle Preview is enabled in the palette exactly when Preview is (\(previewable))")
            let aliased = try requireValue(
                entries.first { $0.row.id == CommandDiscovery.rows(entries, matching: "view auto-indent").first?.id },
                "fixture: Auto-Indent on Return found by its former View menu")
            let autoIndent = sessionDelegate.settings.value.autoIndentEnabled
            check(
                aliased.path == "Edit › Typing › Auto-Indent on Return" && aliased.row.enabled
                    && palette.perform(aliased, in: bar)
                    && sessionDelegate.settings.value.autoIndentEnabled == !autoIndent,
                "a command found by its former menu runs through the same validated menu item")
            check(
                palette.perform(aliased, in: bar) && sessionDelegate.settings.value.autoIndentEnabled == autoIndent,
                "fixture: Auto-Indent on Return is put back")
            check(!titles.contains(where: { $0.contains(" › Services › ") || $0.contains(" › Reopen Recent File › ") || $0.hasSuffix(" › Command Palette…") }),
                "system services and recursive palette invocation are omitted")
            check(entries.contains { $0.item.action == NSSelectorFromString("runAction:") && $0.scope.hasPrefix("Reads ") && $0.scope.contains("Writes ") },
                "saved workflows identify their actual input and output")
            check(entries.contains {
                $0.item.action == #selector(MacroController.playAgain) && $0.scope == "Reads recorded commands • Changes active editor"
            }, "Play Again declares its recorded input and current editor destination")
            let menu = NSMenu(), target = PaletteActionFixture(), other = PaletteActionFixture()
            let item = NSMenuItem(title: "Owned action", action: #selector(PaletteActionFixture.selected(_:)), keyEquivalent: "")
            item.target = target
            menu.addItem(item)
            let row = try requireValue(palette.commands(in: menu).first, "private menu action")
            target.enabled = false
            check(!palette.perform(row, in: menu) && target.count == 0, "a command disabled after discovery cannot run")
            target.enabled = true
            item.target = other
            check(!palette.perform(row, in: menu) && other.count == 0, "changed responder cannot receive an earlier selection")
            item.target = target
            check(palette.perform(row, in: menu) && target.count == 1, "deliberate choice dispatches the actual menu action once")
            menu.removeItem(item)
            check(!palette.perform(row, in: menu) && target.count == 1, "a removed command remains unavailable")
        }
        section("command palette ranking, recent commands and shortcuts", #line) {
            let bar = try requireValue(NSApp.mainMenu, "actual menu bar")
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
                "TextTankPalette-" + UUID().uuidString)
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: folder) }
            let storage = folder.appendingPathComponent("CommandPaletteRecents.json")
            let palette = CommandDiscovery(recentsURL: storage)
            let entries = palette.commands(in: bar)
            @MainActor func paths(_ query: String, recent: [String] = []) -> [String] {
                CommandDiscovery.matches(entries, query: query, recent: recent).map(\.path)
            }
            check(
                paths("sort").first == "Edit › Lines › Sort Lines Ascending"
                    && CommandDiscovery.rows(entries, matching: "sort").first?.title == "Sort Lines Ascending"
                    && CommandDiscovery.rows(entries, matching: "sort").first?.detail == "Edit › Lines",
                "typing sort lists Sort Lines Ascending first, with its menu as secondary text: \(paths("sort").prefix(3))")
            check(
                CommandDiscovery.rank(name: "Quick Open…", query: " quick  OPEN ") == 0
                    && CommandDiscovery.rank(name: "Sort Lines Ascending", query: "sort") == 1
                    && CommandDiscovery.rank(name: "Sort Lines Ascending", query: "asc lines") == 2
                    && CommandDiscovery.rank(name: "Sort Lines Ascending", query: "ort") == 3
                    && CommandDiscovery.rank(name: "Undo", query: "edit") == 4,
                "a name ranks exact, then prefix, then word prefix, then inside the name, then path only")
            let sorted = CommandDiscovery.matches(entries, query: "sort")
            let sortedRanks = sorted.map { CommandDiscovery.rank(name: $0.name, query: "sort") }
            let positions = sorted.map { found in entries.firstIndex { $0.row.id == found.row.id } ?? -1 }
            check(
                sorted.count > 3 && sortedRanks == sortedRanks.sorted()
                    && zip(zip(sortedRanks, positions), zip(sortedRanks.dropFirst(), positions.dropFirst()))
                        .allSatisfy { $0.0 != $1.0 || $0.1 < $1.1 },
                "the real commands are listed best name match first, in menu order within a rank")

            // An owned menu bar pins the whole order, the recent commands and what is left out.
            let target = PaletteActionFixture()
            let owned = NSMenu()
            @MainActor func submenu(_ title: String, _ names: [String]) -> NSMenu {
                let menu = NSMenu(title: title)
                for name in names {
                    let item = NSMenuItem(title: name, action: #selector(PaletteActionFixture.selected(_:)), keyEquivalent: "")
                    item.target = target
                    menu.addItem(item)
                }
                let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                parent.submenu = menu
                owned.addItem(parent)
                return menu
            }
            _ = submenu("Sort", ["Apply"])
            let fix = submenu("Fix", ["Resort", "Quick Sort Now", "Sort Later", "Sort…", "Sort Again", "Unrelated"])
            var fixture = palette.commands(in: owned)
            @MainActor func names(_ query: String, recent: [String] = []) -> [String] {
                CommandDiscovery.rows(fixture, matching: query, recent: recent).map(\.title)
            }
            @MainActor func identity(_ name: String) throws -> String {
                try requireValue(fixture.first { $0.name == name }?.row.id, "fixture: command \(name)")
            }
            check(
                names("sort") == ["Sort…", "Sort Later", "Sort Again", "Quick Sort Now", "Resort", "Apply"],
                "exact, prefix in menu order, word prefix, inside the name, then the menu path alone: \(names("sort"))")
            let againID = try identity("Sort Again"), applyID = try identity("Apply"), laterID = try identity("Sort Later")
            check(
                names("sort", recent: [againID, applyID])
                    == ["Sort…", "Sort Again", "Sort Later", "Quick Sort Now", "Resort", "Apply"],
                "a recent command leads its own rank and never leaves it")
            check(
                names("") == ["Apply", "Resort", "Quick Sort Now", "Sort Later", "Sort…", "Sort Again", "Unrelated"]
                    && names("", recent: [laterID, "no-such-command", applyID])
                        == ["Sort Later", "Apply", "Resort", "Quick Sort Now", "Sort…", "Sort Again", "Unrelated"],
                "an empty palette lists recent commands first, newest first, then the rest in menu order")
            check(names("no-such-command-anywhere").isEmpty, "nonsense matches no command")

            // Six commands run from the palette: the newest five are kept, newest first.
            let ran = ["Apply", "Resort", "Quick Sort Now", "Sort Later", "Sort…", "Sort Again"]
            for name in ran {
                let entry = try requireValue(fixture.first { $0.name == name }, "fixture: \(name)")
                try require(palette.perform(entry, in: owned), "fixture: \(name) runs from the palette")
            }
            let expected = try ran.dropFirst().reversed().map(identity)
            check(
                target.count == 6 && palette.recentCommands == expected,
                "the palette remembers the last five commands run from it, newest first")
            target.enabled = false
            let refused = try requireValue(fixture.first { $0.name == "Unrelated" }, "fixture: Unrelated")
            check(
                !palette.perform(refused, in: owned) && palette.recentCommands == expected,
                "a command that did not run is not remembered")
            target.enabled = true
            // The storage round trip a relaunch makes: a new palette reads the same private file.
            let relaunched = CommandDiscovery(recentsURL: storage)
            var info = stat()
            check(
                relaunched.recentCommands == expected && lstat(storage.path, &info) == 0
                    && info.st_mode & 0o777 == 0o600 && info.st_mode & S_IFMT == S_IFREG,
                "recent commands survive a relaunch in a private file")
            check(
                CommandDiscovery.rows(
                    relaunched.commands(in: owned), matching: "", recent: relaunched.recentCommands
                ).prefix(5).map(\.title) == ["Sort Again", "Sort…", "Sort Later", "Quick Sort Now", "Resort"],
                "after a relaunch the command just run is at the top of an empty palette")
            fix.items.first { $0.title == "Sort Again" }?.isHidden = true
            fix.removeItem(try requireValue(fix.items.first { $0.title == "Sort Later" }, "fixture: Sort Later"))
            fixture = relaunched.commands(in: owned)
            check(
                names("", recent: relaunched.recentCommands)
                    == ["Sort…", "Quick Sort Now", "Resort", "Apply", "Unrelated"]
                    && relaunched.recentCommands == expected,
                "a hidden or removed command is not listed, and is still remembered if it returns")
            // A file a later version wrote is left alone; one that is not a list at all is replaced.
            let later = folder.appendingPathComponent("later.json")
            let laterBytes = Data(#"{"commands":["kept"],"later":true,"version":2}"#.utf8)
            try laterBytes.write(to: later)
            let laterStore = CommandRecentsStore(url: later)
            laterStore.note("new")
            check(
                laterStore.recents.ids == ["new"] && (try? Data(contentsOf: later)) == laterBytes,
                "a recent-commands file from a later version is not rewritten")
            let damaged = folder.appendingPathComponent("damaged.json")
            try Data("not json".utf8).write(to: damaged)
            let damagedStore = CommandRecentsStore(url: damaged)
            damagedStore.note("fresh")
            check(
                damagedStore.recents.ids == ["fresh"] && CommandRecentsStore(url: damaged).recents.ids == ["fresh"]
                    && CommandRecentsStore(url: folder.appendingPathComponent("missing.json")).recents.ids.isEmpty,
                "a damaged recent-commands file is replaced and a missing one means no recent commands")

            // DS-20: each row shows the key its menu item has now.
            @MainActor func key(_ path: String) -> String? { entries.first { $0.path == path }?.row.accessory }
            let keyed = entries.filter { !$0.item.keyEquivalent.isEmpty }
            // Command with the second function key. Spelled in two parts because the finding
            // register reads an F followed by digits in a check as an audit finding's number.
            let functionKeyTwo = "⌘F" + "2"
            check(
                keyed.count > 20 && keyed.allSatisfy { !$0.row.accessory.isEmpty && !$0.row.accessoryLabel.isEmpty }
                    && entries.allSatisfy { $0.row.accessory == (ControlPresentation.shortcut(of: $0.item) ?? "") },
                "every palette row whose command has a key shows it, and no other row shows one")
            check(
                key("File › Save") == "⌘S" && key("File › Save All") == "⌥⌘S" && key("View › Toggle Preview") == "⇧⌘V"
                    && key("File › Quick Open…") == "⇧⌘O" && key("Window › Next Tab") == "⌃⇥"
                    && key("Edit › Undo") == "⌘Z" && key("Edit › Redo") == "⇧⌘Z"
                    && key("Find › Bookmarks › Toggle Bookmark") == functionKeyTwo
                    && entries.first { $0.path == "View › Toggle Preview" }?.row.accessoryLabel == "Shortcut Shift-Command-V",
                "keys read as the menu bar draws them: \(["File › Save All", "Window › Next Tab", "Find › Bookmarks › Toggle Bookmark"].map { key($0) ?? "none" })")
            let upper = EditorCommand.upper.rawValue
            let before = sessionDelegate.settings.value
            var custom = before
            custom.setShortcut("J", for: upper)
            try sessionDelegate.settings.save(custom)
            check(
                palette.commands(in: bar).first { ($0.item.representedObject as? String) == upper }?.row.accessory == "⇧⌘J",
                "a shortcut assigned in Settings is the one the palette shows")
            try sessionDelegate.settings.save(before)

            // The palette itself: the row that says nothing matched, and a retained query.
            FormPanel.visible.filter { $0.window.identifier?.rawValue == "command.palette" }.forEach { $0.close() }
            palette.show(editor: { nil })
            let chooser = try requireValue(palette.panel, "fixture: the Command Palette is showing")
            defer { chooser.form.close() }
            let choose = try DesignSettingsChecks.button("command.palette.choose", chooser.form.window)
            chooser.filter.stringValue = "save"
            chooser.refresh()
            let first = try requireValue(chooser.displayedRows.first, "fixture: a row for save")
            let cell = try requireValue(
                chooser.table.view(atColumn: 0, row: 0, makeIfNecessary: true), "fixture: the first row's view")
            let texts = DesignSettingsChecks.descendants(cell).compactMap { ($0 as? NSTextField)?.stringValue }
            check(
                first.title == "Save" && texts == ["Save", "File", "⌘S"] && chooser.table.selectedRow == 0
                    && choose.isEnabled == first.enabled,
                "a palette row draws the name, the menu and the key: \(texts)")
            chooser.filter.stringValue = "zz-no-such-command-qq"
            chooser.refresh()
            let placeholder =
                chooser.table.numberOfRows > 0
                ? chooser.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTextField : nil
            check(
                chooser.displayedRows.isEmpty && chooser.table.numberOfRows == 1
                    && placeholder?.stringValue == "No matching commands"
                    && !chooser.tableView(chooser.table, shouldSelectRow: 0) && chooser.table.selectedRow == -1
                    && chooser.selectedID == nil && !choose.isEnabled,
                "DS-36 nonsense shows one No matching commands row that cannot be selected or run")
            palette.show(editor: { nil })
            let editing = chooser.filter.currentEditor()
            check(
                palette.panel === chooser && chooser.filter.stringValue == "zz-no-such-command-qq"
                    && editing?.selectedRange == NSRange(location: 0, length: chooser.filter.stringValue.utf16.count),
                "opening the palette again selects the retained query, so typing replaces it")
        }
        section("DG explicit filtered choice activation", #line) { try DesignSettingsChecks.choicePanelChecks() }
        section("DG Open Documents Cancel never switches documents", #line) {
            let (first, _, firstWindow) = try tab("docs-cancel-first")
            let (second, _, secondWindow) = try tab("docs-cancel-second")
            first.showWindows()
            let shown = first.presentation!.host.model.activeTab?.id
            sessionDelegate.showDocumentTabs(nil)
            let form = try requireValue(FormPanel.visible.last, "fixture: actual Open Documents panel")
            let filter = try DesignSettingsChecks.field("TextTank.OpenDocuments.filter", form.window)
            filter.selectText(nil)
            DesignSettingsChecks.type("docs-cancel-second", in: form.window)
            try DesignSettingsChecks.button("TextTank.OpenDocuments.cancel", form.window).performClick(nil)
            check(
                first.presentation!.host.model.activeTab?.id == shown && firstWindow === secondWindow,
                "DG filtering and cancelling Open Documents never switches the captured tab")
            sessionDelegate.showDocumentTabs(nil)
            let switching = try requireValue(FormPanel.visible.last, "fixture: reopened Open Documents panel")
            let secondFilter = try DesignSettingsChecks.field("TextTank.OpenDocuments.filter", switching.window)
            secondFilter.selectText(nil)
            DesignSettingsChecks.type("docs-cancel-second", in: switching.window)
            try DesignSettingsChecks.button("TextTank.OpenDocuments.choose", switching.window).performClick(nil)
            check(
                second.presentation!.isActiveTab && !first.presentation!.isActiveTab,
                "DG explicit Switch opens the filtered document by its live identity")
            first.close()
            second.close()
        }

        section("DG native managers and lifetimes", #line) { try DesignSettingsChecks.managerChecks() }

        section("standard customizable toolbar", #line) { try ToolbarChecks.run(composition: sessionDelegate) }

        // F294
        section("menu validation follows the document and the view", #line) {
            let (first, controller, window) = try tab("p21-validate-1")
            let (second, _, _) = try tab("p21-validate-2")
            let readOnly = item(#selector(TextDocument.toggleReadOnly(_:)))
            check(
                first.validateMenuItem(readOnly) && readOnly.state == .off,
                "Read Only validates enabled and unchecked for a writable document")
            first.toggleReadOnly(readOnly)
            check(
                first.editor.readOnly && first.validateMenuItem(readOnly) && readOnly.state == .on,
                "after Read Only is chosen the item validates checked for that document")
            check(
                second.validateMenuItem(readOnly) && readOnly.state == .off,
                "the same Read Only item validates unchecked for another, writable document")
            // The status bar's menu sends the action with an item of its own.
            second.toggleReadOnly(item(#selector(TextDocument.toggleReadOnly(_:))))
            check(
                second.editor.readOnly && second.validateMenuItem(readOnly) && readOnly.state == .on,
                "Read Only set from the status bar shows in the File menu item at its next validation")
            let fileItem = try requireValue(
                NSApp.mainMenu.map { walk($0) }?.first { $0.path == "File > Read Only" }?.item,
                "fixture: File > Read Only")
            first.toggleReadOnly(fileItem)
            check(
                !first.editor.readOnly && first.validateMenuItem(fileItem) && fileItem.state == .off
                    && second.validateMenuItem(fileItem) && fileItem.state == .on,
                "the File > Read Only checkmark follows whichever document validates it")
            // Everything else is left to NSDocument, whose answers a plain document gives.
            let plain = NSDocument()
            for (name, action) in [
                ("Revert to Saved", #selector(NSDocument.revertToSaved(_:))), ("Save", #selector(NSDocument.save(_:))),
                ("Save As", #selector(NSDocument.saveAs(_:))), ("Print", #selector(NSDocument.printDocument(_:)))
            ] {
                let entry = item(action)
                check(
                    first.validateMenuItem(entry) == plain.validateMenuItem(entry),
                    "\(name) is validated by NSDocument, as for a plain document")
            }
            check(
                !first.validateMenuItem(item(#selector(NSDocument.revertToSaved(_:)))),
                "Revert to Saved stays disabled for an untitled document")
            let convert = item(#selector(TextDocument.convertEncoding(_:)), "utf16LE")
            let reload = item(#selector(TextDocument.reloadEncoding(_:)), "utf8")
            check(
                second.editor.readOnly && second.validateMenuItem(convert) && second.validateMenuItem(reload),
                "Convert and Reload As keep their enabling: neither is disabled by this package")

            first.showWindows()
            let wrap = item(#selector(EditorWindowController.toggleWrap(_:)))
            first.editor.wrap = false
            check(
                controller.validateMenuItem(wrap) && wrap.state == .off,
                "Wrap Lines validates unchecked while the view does not wrap")
            controller.toggleWrap(wrap)
            check(
                first.editor.wrap && controller.validateMenuItem(wrap) && wrap.state == .on,
                "Wrap Lines validates checked after it is chosen")
            controller.clone(nil)
            let clone = try requireValue(controller.secondary, "fixture: clone view")
            clone.wrap = false
            _ = window.makeFirstResponder(clone)
            check(
                controller.validateMenuItem(wrap) && wrap.state == .off,
                "Wrap Lines shows the focused pane's own setting")
            _ = window.makeFirstResponder(first.editor)
            check(
                controller.validateMenuItem(wrap) && wrap.state == .on,
                "Wrap Lines follows focus back to the other pane")
            controller.closeSplit(nil)
            check(
                controller.validateMenuItem(item(#selector(EditorWindowController.command(_:)), "duplicateLine"))
                    && controller.validateMenuItem(item(#selector(EditorWindowController.convertEOL(_:)), "LF"))
                    && controller.validateMenuItem(item(#selector(EditorWindowController.goToLine(_:)))),
                "every other editor command still validates enabled")
            first.close()
            second.close()
        }

        // F306, G418
        section("standard menu items and command placement", #line) {
            let bar = try requireValue(NSApp.mainMenu, "fixture: the main menu built by the menu wiring section")
            let all = walk(bar)
            func entry(_ path: String) -> NSMenuItem? { all.first { $0.path == path }?.item }
            let hide = entry("TextTank > Hide TextTank"), others = entry("TextTank > Hide Others")
            check(
                hide?.action == #selector(NSApplication.hide(_:)) && hide?.keyEquivalent == "h"
                    && hide?.keyEquivalentModifierMask == [.command] && hide?.target == nil,
                "Hide TextTank is Command-H and goes to the application")
            check(
                others?.action == #selector(NSApplication.hideOtherApplications(_:)) && others?.keyEquivalent == "h"
                    && others?.keyEquivalentModifierMask == [.command, .option]
                    && entry("TextTank > Show All")?.action == #selector(NSApplication.unhideAllApplications(_:)),
                "Hide Others is Option-Command-H and Show All is present")
            check(
                entry("TextTank > Services")?.submenu != nil
                    && entry("TextTank > Services")?.submenu === NSApp.servicesMenu,
                "the Services submenu is the application's services menu")
            check(
                app.responds(to: #selector(NSApplication.hide(_:)))
                    && app.responds(to: #selector(NSApplication.hideOtherApplications(_:)))
                    && app.responds(to: #selector(NSApplication.unhideAllApplications(_:)))
                    && app.responds(to: #selector(NSApplication.arrangeInFront(_:))),
                "the application implements the standard items' actions")
            check(
                bar.items.first?.submenu?.items.map(\.title) == [
                    "About TextTank", "Settings…", "Install tt Command-Line Tool…", "", "Services", "", "Hide TextTank",
                    "Hide Others", "Show All", "",
                    "Quit TextTank"
                ], "the application menu is in the standard order")
            check(
                entry("Window > Bring All to Front")?.action == #selector(NSApplication.arrangeInFront(_:))
                    && NSApp.windowsMenu?.title == "Window",
                "the Window menu has Bring All to Front and is the application's windows menu")
            check(
                bar.items.last?.title == "Help" && bar.items.last?.submenu === NSApp.helpMenu,
                "the last menu is Help and is the application's help menu, which carries the command search")
            check(
                EditorSettings.reserved.isSuperset(of: ["h", "l", "P", "q", "w"]),
                "Command-H and Command-L are reserved, so a user shortcut cannot take them")
            var colliding = EditorSettings()
            colliding.shortcuts = ["joinLines": "h"]
            rejects("a saved shortcut on Command-H is rejected", expecting: SettingsError.conflict) {
                try colliding.validate()
            }
            colliding.shortcuts = ["joinLines": "l"]
            rejects("a saved shortcut on Command-L is rejected", expecting: SettingsError.conflict) {
                try colliding.validate()
            }

            let goTo = entry("Find > Go to Line…")
            check(
                goTo?.action == #selector(EditorWindowController.goToLine(_:)) && goTo?.keyEquivalent == "l"
                    && goTo?.keyEquivalentModifierMask == [.command] && goTo?.target == nil,
                "Find > Go to Line… is Command-L and goes to the document window")
            let palettes = all.filter { $0.item.title == "Command Palette…" }
            check(
                palettes.map(\.path) == ["Help > Command Palette…"]
                    && palettes.first?.item.keyEquivalent == "P"
                    && palettes.first?.item.keyEquivalentModifierMask == [.command]
                    && palettes.first?.item.target === sessionDelegate.automations,
                "Command Palette… is one item, in the Help menu, with Shift-Command-P")
            check(
                !all.contains { $0.item.title == "Choose Automation…" },
                "the duplicate Choose Automation… item is gone")

            // DS-D4 findability: each command is at the path a person would look in first, with its
            // shortcut, and is enabled exactly when it can run. AppKit's own rules are followed here:
            // a menu that does not auto-enable shows its items' own state; otherwise the target (or,
            // for a responder-chain command, the first responder that implements it) validates.
            @MainActor func available(_ path: String, responders: [AnyObject]) -> Bool? {
                // A menu its controller rebuilds holds a new item at the same path, so look twice.
                guard let menu = walk(bar).first(where: { $0.path == path })?.item.menu else { return nil }
                menu.delegate?.menuNeedsUpdate?(menu)
                guard let item = walk(bar).first(where: { $0.path == path })?.item, let action = item.action
                else { return nil }
                if !menu.autoenablesItems { return item.isEnabled }
                guard let target = item.target ?? responders.first(where: { $0.responds(to: action) }) else {
                    return false
                }
                if let validator = target as? NSMenuItemValidation { return validator.validateMenuItem(item) }
                if let validator = target as? NSUserInterfaceValidations {
                    return validator.validateUserInterfaceItem(item)
                }
                return true
            }
            let markdown = all.first {
                $0.path.hasPrefix("View > Syntax Highlighting > ") && $0.path.hasSuffix(" > Markdown")
                    && $0.path.components(separatedBy: " > ").count == 4
            }?.path
            // Path, key, modifiers, enabled without a document, enabled with one untitled document.
            let expected: [(String, String, NSEvent.ModifierFlags, Bool, Bool)] = [
                ("Compare > Compare Two Visible Tabs", "", [.command], false, false),
                ("File > Quick Open…", "O", [.command], true, true),
                ("Edit > Lines > Sort Lines Ascending", "", [.command], false, true),
                ("File > Reload with Encoding > UTF-8…", "", [.command], false, true),
                ("File > Convert to Encoding > UTF-8", "", [.command], false, true),
                ("Tools > Macros > Start Recording", MenuShortcut.recordMacro.key, [], false, true),
                ("Help > Command Palette…", "P", [.command], true, true),
                ("Find > Go to Line…", "l", [.command], false, true),
                (markdown ?? "View > Syntax Highlighting > (no range) > Markdown", "", [.command], true, true)
            ]
            let placed = expected.filter { row in
                guard let item = entry(row.0) else { return true }
                return item.keyEquivalent != row.1 || item.keyEquivalentModifierMask != row.2
            }.map(\.0)
            check(placed.isEmpty, "DS-D4 each command is at its stated path with its shortcut: \(placed)")
            sessionDelegate.noteActive(nil)
            try require(
                sessionDelegate.currentEditor == nil && NSDocumentController.shared.documents.isEmpty,
                "fixture: no document is open")
            let withoutDocument = expected.filter { available($0.0, responders: [sessionDelegate]) != $0.3 }.map(\.0)
            check(
                withoutDocument.isEmpty,
                "DS-21 with no document open, each command is enabled only if it can run: \(withoutDocument)")
            do {
                let (document, controller, _) = try tab("findability")
                defer { document.close() }
                sessionDelegate.noteActive(controller)
                try require(sessionDelegate.currentEditor === document.editor, "fixture: the tab is current")
                let withDocument = expected.filter {
                    available($0.0, responders: [controller, document, sessionDelegate]) != $0.4
                }.map(\.0)
                check(
                    withDocument.isEmpty,
                    "DS-21 with one untitled document, each command is enabled only if it can run: \(withDocument)")
            }
            let shifted = all.filter {
                $0.item.keyEquivalent == "P" && $0.item.keyEquivalentModifierMask == [.command]
            }
            check(shifted.count == 1, "Shift-Command-P is assigned once in the menus")

            let (document, controller, window) = try tab("p21-goto")
            check(
                controller.responds(to: #selector(EditorWindowController.goToLine(_:)))
                    && controller.statusOptionsMenu("position")?.items.first?.title == "Go to Line…",
                "the document window implements Go to Line and the status bar keeps its own entry")
            let text = "één\r\ntwo 😀\rthree\nfour"
            document.editor.text = text
            _ = document.editor.setSelectionAnchor(1, caret: 1)
            let revision = document.editor.revision
            check(
                EditorWindowController.goToLine(3, in: document.editor)
                    && document.editor.selectionCaret == "één\r\ntwo 😀\r".utf8.count
                    && document.editor.selectionAnchor == document.editor.selectionCaret
                    && document.editor.statusInfo.line == 3,
                "Go to Line puts the caret at the start of the line, after CRLF, CR and multi-byte text")
            check(
                EditorWindowController.goToLine(1, in: document.editor) && document.editor.selectionCaret == 0
                    && EditorWindowController.goToLine(4, in: document.editor)
                    && document.editor.selectionCaret == text.utf8.count - 4,
                "Go to Line reaches the first and the last line")
            let held = document.editor.selectionCaret
            check(
                !EditorWindowController.goToLine(0, in: document.editor)
                    && !EditorWindowController.goToLine(5, in: document.editor)
                    && !EditorWindowController.goToLine(-3, in: document.editor)
                    && document.editor.selectionCaret == held && document.editor.revision == revision
                    && document.editor.text == text,
                "a line the document does not have moves nothing and edits nothing")
            // The dialog itself, answered as a person would.
            _ = document.editor.setSelectionAnchor(0, caret: 0)
            var answered = false
            let giveUp = Date().addingTimeInterval(10)
            let answerAction: @MainActor @Sendable () -> Void = {
                guard !answered, let modal = presentedFormWindow, let content = modal.contentView else { return }
                let views = descendants(content)
                if let field = views.compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable }),
                    let go = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Go" })
                {
                    answered = true
                    modal.makeFirstResponder(nil)
                    field.stringValue = "2"
                    go.performClick(nil)
                } else if Date() > giveUp {
                    NSApp.abortModal()
                }
            }
            let answer = Timer(timeInterval: 0.05, repeats: true) { _ in
                MainActor.assumeIsolated { answerAction() }
            }
            RunLoop.main.add(answer, forMode: .modalPanel)
            controller.goToLine(nil)
            waitForModelessForms()
            answer.invalidate()
            check(
                answered && document.editor.statusInfo.line == 2
                    && (window.firstResponder as? NSView)?.isDescendant(of: document.editor) == true,
                "the Go to Line dialog moves the caret to the line entered and returns to the editor")
            document.close()
        }

        section("audit25 shortcut settings keep unrelated values", #line) {
            var stored = EditorSettings()
            stored.tabWidth = 9
            stored.wrap = true
            stored.shortcuts = ["upper": "u", "lower": "s", "removedCommand": "k"]
            let bytes = try JSONEncoder().encode(stored)
            let url = root.appendingPathComponent("audit25-shortcuts-load.json")
            try bytes.write(to: url)
            let settings = SettingsController(url: url)
            check(
                settings.value.tabWidth == 9 && settings.value.wrap && settings.value.shortcuts == ["upper": "u"],
                "G362 invalid shortcut entries leave valid shortcuts and unrelated settings usable")
            check(try Data(contentsOf: url) == bytes, "G362 loading ignored shortcuts does not rewrite original bytes")
            check(
                settings.loadError == nil
                    && settings.ignoredShortcutBindings.map(\.command) == ["lower", "removedCommand"]
                    && settings.shortcutLoadNotice?.contains("Lowercase") == true,
                "G362 ignored bindings are reported individually without pretending the entire file failed")
            var invalid = settings.value
            invalid.shortcuts["upper"] = ","
            rejects("G362 tolerant loading does not weaken strict validation on save") { try settings.save(invalid) }
            check(
                try Data(contentsOf: url) == bytes,
                "G362 rejected repair save leaves original bytes in place before backup")
            let repairedBackup = try requireValue(
                try settings.save(settings.value), "fixture: explicit shortcut repair retains backup")
            check(
                try Data(contentsOf: repairedBackup) == bytes && SettingsController(url: url).value == settings.value
                    && settings.ignoredShortcutBindings.isEmpty,
                "G362 only explicit Save writes repaired settings and keeps the exact original in a backup")
            var edited = EditorSettings()
            edited.setShortcut("k", for: "deleteLine")
            let model = SettingsController(url: root.appendingPathComponent("audit25-shortcut-model.json"))
            try model.save(edited)
            check(
                SettingsController(url: model.url).value.shortcuts["deleteLine"] == "k",
                "G396 shortcut assignment survives a controller restart")
            edited.setShortcut("", for: "deleteLine")
            try model.save(edited)
            check(
                SettingsController(url: model.url).value == EditorSettings(),
                "G396 clearing one custom shortcut restores the original settings without an empty wire value")
            edited.setShortcut("d", for: "duplicateLine")
            check(
                edited.shortcuts["duplicateLine"] == nil,
                "G396 assigning the built-in default never pollutes persisted overrides")
            var draft = SettingsShortcutDraft(EditorSettings())
            _ = draft.select("upper", committing: "")
            _ = draft.select("deleteLine", committing: "u")
            check(
                draft.select("upper", committing: "k") == "u" && draft.settings.shortcuts["deleteLine"] == "k",
                "G396 changing popup commands commits and retains every previous draft")
            var collision = EditorSettings()
            collision.setShortcut("j", for: "duplicateLine")
            collision.setShortcut("d", for: "upper")
            collision.setShortcut("", for: "duplicateLine")
            rejects("G396 restoring the default reports the other command holding its key", message: "Uppercase") {
                try model.save(collision)
            }
            check(
                SettingsController(url: model.url).value == EditorSettings(),
                "G396 conflicting default restoration leaves the previous settings file intact")
            var explicitDefault = EditorSettings()
            explicitDefault.shortcuts = ["duplicateLine": "d"]
            check(
                try EditorSettings.decode(JSONEncoder().encode(explicitDefault)) == explicitDefault,
                "G396 legacy explicit default entries remain readable")
            let frozen = try requireValue(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: TestPaths.fixtures.appendingPathComponent("editor-commands-wave-3.json")))
                    as? [String: Any], "fixture: reserved key baseline")
            check(
                EditorSettings.reserved
                    == Set(try requireValue(frozen["reserved"] as? [String], "fixture: historical reserved fallback")),
                "F281 the historical pre-menu reserved fallback remains unchanged")
            let temporary = NSMenu()
            let protected = temporary.addItem(title: "New Fixed Action", action: nil, keyEquivalent: "k")
            protected.keyEquivalentModifierMask = [.command, .shift]
            let own = temporary.addItem(title: "Duplicate Line", action: nil, keyEquivalent: "d")
            own.representedObject = EditorCommand.duplicateLine.rawValue
            let option = temporary.addItem(title: "Option Action", action: nil, keyEquivalent: "b")
            option.keyEquivalentModifierMask = [.command, .option]
            let reserved = SettingsController.reservedShortcuts(in: temporary)
            check(
                !reserved.contains("b") && SettingsController.reservedShortcuts(in: nil).isSuperset(of: ["e", "`"]),
                "G362 unrelated Command-Option keys stay available while headless validation protects system shortcuts")
            check(
                reserved.contains("K") && !reserved.contains("d") && reserved.isSuperset(of: ["e", "`"]),
                "G362 reserved keys follow actual menu modifiers and protect system Find/window shortcuts before menus exist"
            )
            var changedMenuSettings = EditorSettings()
            changedMenuSettings.tabWidth = 7
            changedMenuSettings.shortcuts = ["upper": "K", "lower": "u"]
            let changedURL = root.appendingPathComponent("audit25-menu-upgrade.json")
            let changedBytes = try JSONEncoder().encode(changedMenuSettings)
            try changedBytes.write(to: changedURL)
            let upgraded = SettingsController(url: changedURL)
            upgraded.reconcileShortcuts(with: temporary)
            let unchangedMenuBytes = try Data(contentsOf: changedURL)
            check(
                upgraded.value.tabWidth == 7 && upgraded.value.shortcuts == ["lower": "u"]
                    && upgraded.ignoredShortcutBindings.map(\.command) == ["upper"]
                    && unchangedMenuBytes == changedBytes,
                "G362 a newly reserved menu key drops only its conflicting binding after startup and preserves original bytes"
            )
            let dialog = SettingsController(url: root.appendingPathComponent("audit25-shortcuts-dialog.json"))
            var observed = false, readable = false, current = false
            let deadline = Date().addingTimeInterval(10)
            let timerAction: @MainActor @Sendable () -> Void = {
                guard let content = presentedFormWindow?.contentView else { return }
                if Date() > deadline {
                    NSApp.abortModal()
                    return
                }
                let views = descendants(content)
                guard
                    let popup = views.compactMap({ $0 as? NSPopUpButton }).first(where: {
                        $0.accessibilityLabel() == "Command shortcut to assign"
                    }),
                    let key = views.compactMap({ $0 as? NSTextField }).first(where: {
                        $0.accessibilityLabel() == "Shortcut key"
                    })
                else { return }
                observed = true
                readable = popup.itemArray.contains {
                    $0.title == "Duplicate Line" && $0.representedObject as? String == "duplicateLine"
                }
                if let entry = popup.itemArray.first(where: {
                    $0.representedObject as? String == "duplicateLine" || $0.title == "duplicateLine"
                }) {
                    popup.select(entry)
                    if let action = popup.action { _ = NSApp.sendAction(action, to: popup.target, from: popup) }
                    current = key.stringValue == "d"
                }
                views.compactMap { $0 as? NSButton }.first { $0.title == "Close" }?.performClick(nil)
            }
            let timer = Timer(timeInterval: 0.02, repeats: true) { _ in
                MainActor.assumeIsolated { timerAction() }
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            dialog.showSettings(nil)
            waitForModelessForms()
            timer.invalidate()
            check(
                observed && readable && current,
                "G396 Settings shows readable command names and the selected current shortcut")
            check(
                !FileManager.default.fileExists(atPath: dialog.url.path),
                "G396 Cancel after reading a shortcut leaves settings absent")
        }

        section("audit25 actual shortcut drafts and menu updates", #line) {
            let settings = SettingsController(
                url: root.appendingPathComponent("audit25-live-shortcuts.json"),
                onApply: EditorSettingsApplication.apply)
            do {
                let previousMenu = NSApp.mainMenu
                defer { NSApp.mainMenu = previousMenu }
                let menu = NSMenu()
                let delete = menu.addItem(title: EditorCommand.deleteLine.title, action: nil)
                delete.representedObject = EditorCommand.deleteLine.rawValue
                let duplicate = menu.addItem(title: EditorCommand.duplicateLine.title, action: nil)
                duplicate.representedObject = EditorCommand.duplicateLine.rawValue
                NSApp.mainMenu = menu
                var value = EditorSettings()
                value.setShortcut("k", for: "deleteLine")
                try settings.save(value)
                check(
                    delete.keyEquivalent == "k" && duplicate.keyEquivalent == "d",
                    "G396 saving a custom shortcut updates its actual menu item and the built-in default")
                value.setShortcut("", for: "deleteLine")
                try settings.save(value)
                check(
                    delete.keyEquivalent.isEmpty && duplicate.keyEquivalent == "d",
                    "G396 clearing a custom shortcut removes its menu key and keeps Command-D")
            }
            var acted = false, kept = false, cleared = false, defaultRestored = false
            let deadline = Date().addingTimeInterval(10)
            let timerAction: @MainActor @Sendable () -> Void = {
                guard let content = presentedFormWindow?.contentView else { return }
                if Date() > deadline {
                    NSApp.abortModal()
                    return
                }
                let views = descendants(content)
                guard !acted,
                    let popup = views.compactMap({ $0 as? NSPopUpButton }).first(where: {
                        $0.identifier?.rawValue == "settings.shortcut.command"
                    }),
                    let key = views.compactMap({ $0 as? NSTextField }).first(where: {
                        $0.identifier?.rawValue == "settings.shortcut.key"
                    }),
                    let clear = views.compactMap({ $0 as? NSButton }).first(where: {
                        $0.identifier?.rawValue == "settings.shortcut.clear"
                    }),
                    let save = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Apply Shortcuts" })
                else { return }
                @MainActor func select(_ id: String) {
                    guard let entry = popup.itemArray.first(where: { $0.representedObject as? String == id }) else {
                        return
                    }
                    popup.select(entry)
                    if let action = popup.action { _ = NSApp.sendAction(action, to: popup.target, from: popup) }
                }
                select("upper")
                key.stringValue = "u"
                select("deleteLine")
                key.stringValue = "k"
                select("upper")
                kept = key.stringValue == "u"
                clear.performClick(nil)
                cleared = key.stringValue.isEmpty
                select("duplicateLine")
                key.stringValue = "j"
                select("deleteLine")
                kept = kept && key.stringValue == "k"
                select("duplicateLine")
                clear.performClick(nil)
                defaultRestored = key.stringValue == "d"
                acted = true
                save.performClick(nil)
                views.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "settings.close" }?
                    .performClick(nil)
            }
            let timer = Timer(timeInterval: 0.02, repeats: true) { _ in
                MainActor.assumeIsolated { timerAction() }
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            settings.showSettings(nil)
            waitForModelessForms()
            timer.invalidate()
            check(
                acted && kept && cleared && defaultRestored,
                "G396 the real Settings popup retains multiple drafts and Clear restores each command's default")
            check(
                settings.value.shortcuts == ["deleteLine": "k"]
                    && SettingsController(url: settings.url).value == settings.value,
                "G396 one explicit Save persists all popup edits without adding default or empty overrides")
            try settings.save(EditorSettings())
        }

        SettingsShortcutValidationChecks.run(root: root)

        section("audit25 command refusal and menu validation", #line) {
            let (doc, controller, _) = try tab("audit25-commands")
            doc.editor.text = "safe"
            let font = try requireValue(controller.statusOptionsMenu("font"), "fixture: catalog font menu")
            let zoom = try requireValue(
                font.items.first { $0.representedObject as? String == "zoomIn" }, "fixture: Zoom In context action")
            check(
                zoom.title == EditorCommand.zoomIn.title
                    && zoom.keyEquivalent == EditorCommand.zoomIn.defaultMenuShortcut,
                "DS20 status commands share catalog titles and fixed menu shortcuts")
            let priorSettings = sessionDelegate.settings.value
            var shortcutSettings = priorSettings
            shortcutSettings.setShortcut("k", for: "bookmarkNext")
            try sessionDelegate.settings.save(shortcutSettings)
            let bookmarks = try requireValue(
                controller.statusOptionsMenu("bookmarks"), "fixture: catalog bookmark menu")
            let next = try requireValue(
                bookmarks.items.first { $0.representedObject as? String == "bookmarkNext" },
                "fixture: Next Bookmark context action")
            check(
                next.title == EditorCommand.bookmarkNext.title && next.keyEquivalent == "k",
                "DS20 status commands share the user's current main-menu shortcut")
            try sessionDelegate.settings.save(priorSettings)
            let before = doc.editor.revision, generation = doc.editor.selectionGeneration
            rejects("F281 the shared dispatcher rejects an unknown command") {
                try controller.perform(command: "noSuchCommand")
            }
            check(
                doc.editor.text == "safe" && doc.editor.revision == before
                    && doc.editor.selectionGeneration == generation, "F281 refused dispatch never changes editor state")
            controller.hostWindow?.makeFirstResponder(doc.editor)
            controller.command(item(#selector(EditorWindowController.command(_:)), "noSuchCommand"))
            check(
                controller.status.stringValue == EditorCommandFailure.unsupported.localizedDescription
                    && doc.editor.revision == before,
                "F281 an unknown UI command reports visible words without an alert or edit")
            check(
                !doc.validateUserInterfaceItem(item(#selector(TextDocument.checkExternalChanges(_:)))),
                "F18 Check for External Changes is disabled for an untitled document")
            let unavailable = item(#selector(EditorWindowController.command(_:)), "noSuchCommand")
            check(
                !controller.validateMenuItem(unavailable),
                "DS21 an unknown routed command is disabled before invocation")
            let duplicate = item(#selector(EditorWindowController.command(_:)), "duplicateLine")
            doc.editor.readOnly = true
            check(
                !controller.validateMenuItem(duplicate),
                "DS21 a text-changing catalog command is disabled for a read-only document")
            check(
                controller.validateMenuItem(item(#selector(EditorWindowController.command(_:)), "charLeft"))
                    && controller.validateMenuItem(item(#selector(EditorWindowController.command(_:)), "toggleEOL")),
                "DS21 navigation and view toggles remain enabled in a read-only document")
            doc.editor.readOnly = false
            let endings = item(#selector(EditorWindowController.command(_:)), "toggleEOL")
            try controller.perform(command: "toggleEOL")
            check(
                controller.validateMenuItem(endings) && endings.state == .on,
                "DS22 a catalog toggle validates with its actual checked state")
            try controller.perform(command: "toggleEOL")
            controller.clone(nil)
            let clone = try requireValue(controller.secondary, "fixture: catalog toggle clone")
            _ = controller.hostWindow?.makeFirstResponder(clone)
            // V4: Show Line Endings is one stored choice, so its checkmark is the same in both panes;
            // Overtype stays a choice of the view that has the keyboard.
            try controller.perform(command: "toggleEOL")
            check(
                controller.validateMenuItem(endings) && endings.state == .on && clone.lineEndingsVisible
                    && doc.editor.lineEndingsVisible,
                "DS22 a stored view choice made with the clone focused checks its item and reaches both panes")
            let overtype = item(#selector(EditorWindowController.command(_:)), "toggleOvertype")
            clone.executeCommand(TTEditorCommandIdentifier(rawValue: "toggleOvertype"))
            check(
                controller.validateMenuItem(overtype) && overtype.state == .on,
                "DS22 catalog toggle checkmarks follow the focused clone's own view state")
            _ = controller.hostWindow?.makeFirstResponder(doc.editor)
            check(
                controller.validateMenuItem(endings) && endings.state == .on
                    && controller.validateMenuItem(overtype) && overtype.state == .off,
                "DS22 returning to the source pane restores that view's toggle checkmark and keeps the stored choice")
            try controller.perform(command: "toggleEOL")
            check(
                controller.validateMenuItem(endings) && endings.state == .off && !clone.lineEndingsVisible
                    && !doc.editor.lineEndingsVisible,
                "DS22 turning the stored view choice off clears its checkmark and both panes")
            controller.closeSplit(nil)
            doc.close()
        }

        section("audit24 settings invalid drafts and unexpected termination", #line) {
            let settings = SettingsController(url: root.appendingPathComponent("audit24-settings.json"))
            let original = settings.value
            var aborted = false
            let abortAction: @MainActor @Sendable () -> Void = {
                guard let window = presentedFormWindow else { return }
                aborted = true
                window.performClose(nil)
            }
            let abort = Timer(timeInterval: 0.02, repeats: true) { _ in
                precondition(Thread.isMainThread)
                MainActor.assumeIsolated { abortAction() }
            }
            RunLoop.main.add(abort, forMode: .modalPanel)
            settings.showSettings(nil)
            waitForModelessForms()
            abort.invalidate()
            check(
                aborted && settings.value == original && !FileManager.default.fileExists(atPath: settings.url.path),
                "F16 closing modeless Settings never saves defaults or creates its file")
            var stage = 0, keptDraft = false
            let deadline = Date().addingTimeInterval(10)
            let retryAction: @MainActor @Sendable () -> Void = {
                guard let content = presentedFormWindow?.contentView else { return }
                let views = descendants(content)
                if Date() > deadline {
                    NSApp.abortModal()
                    return
                }
                guard let field = views.compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable }),
                    let action = field.action
                else {
                    views.compactMap { $0 as? NSButton }.first?.performClick(nil)
                    return
                }
                if stage == 0 {
                    field.stringValue = "invalid width"
                    stage = 1
                    _ = NSApp.sendAction(action, to: field.target, from: field)
                } else if stage == 1 {
                    keptDraft =
                        field.stringValue == "invalid width"
                        && views.compactMap({ $0 as? NSTextField }).contains(where: {
                            !$0.isEditable && $0.stringValue.contains("Tab width must")
                                && $0.stringValue.contains("32")
                        })
                    field.stringValue = "8 "
                    stage = 2
                    _ = NSApp.sendAction(action, to: field.target, from: field)
                    views.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "settings.close" }?
                        .performClick(nil)
                }
            }
            let retry = Timer(timeInterval: 0.02, repeats: true) { _ in
                MainActor.assumeIsolated { retryAction() }
            }
            RunLoop.main.add(retry, forMode: .modalPanel)
            settings.showSettings(nil)
            waitForModelessForms()
            retry.invalidate()
            check(stage == 2 && keptDraft, "F214 Settings preserves invalid input and identifies its tab-width field")
            check(
                settings.value.tabWidth == 8,
                "F214 corrected Settings input saves after retry, accepting surrounding whitespace")
        }

        // F295
        section("the automation context menu is reachable", #line) {
            let (document, _, window) = try tab("p21-context")
            let content = try requireValue(
                descendants(document.editor).first { String(describing: type(of: $0)) == "TTContentView" },
                "fixture: the engine's text view")
            let click = try requireValue(
                NSEvent.mouseEvent(
                    with: .rightMouseDown, location: NSPoint(x: 300, y: 300), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0),
                "fixture: a right-click")
            let shown = try requireValue(content.menu(for: click), "a right-click in the text shows a menu")
            let manage = shown.items.first { $0.title == "Manage Automations…" }
            check(
                Array(shown.items.map(\.title).prefix(9)) == [
                    "Undo", "Redo", "", "Cut", "Copy", "Paste", "Delete", "", "Select All"
                ] && manage?.target === sessionDelegate.automations && manage?.action != nil
                    && manage?.isEnabled == true,
                "a right-click in a document shows the edit commands followed by the automation items")
            let own = sessionDelegate.automations.contextMenu().items
            check(
                shown.items.count == 10 + own.count && shown.items[9].isSeparatorItem
                    && shown.items.suffix(own.count).map(\.title) == own.map(\.title)
                    && shown.items.suffix(own.count).map { $0.representedObject as? String }
                        == own.map { $0.representedObject as? String },
                "the items added are the automation context menu's own, with their stable identifiers")
            document.close()
        }

        // F297, F298
        section("closing a tab shows the adjacent or the previous tab", #line) {
            let (a, controlA, winA) = try tab("p21-A")
            let (b, _, winB) = try tab("p21-B")
            let (c, _, winC) = try tab("p21-C")
            let (d, controlD, winD) = try tab("p21-D")
            check(
                [winA, winB, winC, winD].allSatisfy { !$0.collectionBehavior.contains(.fullScreenNone) },
                "the shared workspace supports native full screen")
            check(
                d.presentation!.isActiveTab && [a, b, c].allSatisfy { !$0.presentation!.isActiveTab } && winA === winD,
                "fixture: the last of four tabs is showing")
            winD.setFrame(NSRect(x: 160, y: 140, width: 900, height: 640), display: true)
            let frame = winD.frame
            // B first, while C is still open between it and D: only the return-to target, not
            // adjacency, brings D back (B's neighbour is C).
            try closeButton(for: b, in: controlD).performClick(nil)
            check(
                (d.presentation?.isActiveTab == true) && !isOpen(b) && isOpen(c) && isOpen(d)
                    && (c.presentation?.isActiveTab != true) && (a.presentation?.isActiveTab != true),
                "closing a background tab that is not next to the active one returns to the active tab, not its neighbour"
            )
            if !NSScreen.screens.isEmpty {
                check(winD.frame == frame, "closing a background tab leaves the window's frame as it was")
            }
            try closeButton(for: c, in: controlD).performClick(nil)
            check(
                (d.presentation?.isActiveTab == true) && !isOpen(c) && isOpen(d)
                    && (a.presentation?.isActiveTab != true),
                "closing a clean background tab from its close button returns to the tab that was active")
            let (e, controlE, winE) = try tab("p21-E")
            let (f, _, _) = try tab("p21-F")
            try require((f.presentation?.isActiveTab == true), "fixture: the new last tab is showing")
            f.close()
            check(
                (e.presentation?.isActiveTab == true) && (a.presentation?.isActiveTab != true)
                    && (d.presentation?.isActiveTab != true),
                "closing the active last tab shows the previous tab, not the first")
            d.showWindows()
            let middleFrame = winD.frame
            d.close()
            check(
                (e.presentation?.isActiveTab == true) && (a.presentation?.isActiveTab != true),
                "closing an active middle tab shows the next tab")
            if !NSScreen.screens.isEmpty {
                check(winE.frame == middleFrame, "the tab shown after a close takes the closed tab's frame")
            }
            // A background tab with unsaved changes is brought forward for its review. Each time
            // the tab that was active is not the closed tab's neighbour, so the two can be told apart.
            let leftArrow = try requireValue(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                    characters: "\u{F702}", charactersIgnoringModifiers: "\u{F702}", isARepeat: false, keyCode: 123),
                "fixture: a Left Arrow key event")
            @MainActor func cancelledClose(
                _ document: TextDocument, _ window: NSWindow, from control: EditorWindowController,
                keyDuringReview: Bool = false
            ) throws {
                document.updateChangeCount(.changeDone)
                try closeButton(for: document, in: control).performClick(nil)
                check(
                    window.isVisible && document.presentation?.isActiveTab == true && !control.isActiveTab
                        && isOpen(document),
                    "closing a background tab with unsaved changes shows that tab and keeps its document open")
                spinUntil("the unsaved-changes review to attach to the tab now showing") { window.attachedSheet != nil }
                let sheet = window.attachedSheet
                check(sheet != nil, "the unsaved-changes review is presented on the tab that is now showing")
                if keyDuringReview { window.sendEvent(leftArrow) }
                if let sheet {
                    let cancel = (sheet.contentView.map { descendants($0) } ?? []).compactMap { $0 as? NSButton }
                        .first { $0.title == "Cancel" }
                    if let cancel { cancel.performClick(nil) } else { window.endSheet(sheet, returnCode: .cancel) }
                    spinUntil("the cancelled review to leave") { window.attachedSheet == nil }
                }
                check(isOpen(document) && window.isVisible, "cancelling the review keeps the tab open and showing")
                document.updateChangeCount(.changeCleared)
            }
            // The cancelled close must not decide where a later close goes: after a tab switch.
            let (g, controlG, winG) = try tab("p21-G")
            try cancelledClose(a, winA, from: controlG)
            e.showWindows()
            a.showWindows()
            a.close()
            check(
                (e.presentation?.isActiveTab == true) && (g.presentation?.isActiveTab != true),
                "after a cancelled close and a tab switch, closing the tab shows its neighbour again")
            // And after the person has gone on working in the tab without switching.
            let (h, controlH, winH) = try tab("p21-H")
            try cancelledClose(e, winE, from: controlH)
            winE.sendEvent(leftArrow)
            e.close()
            check(
                (g.presentation?.isActiveTab == true) && (h.presentation?.isActiveTab != true),
                "after a cancelled close and a key typed in the tab, closing the tab shows its neighbour again")
            // Closed straight after the cancel, it still returns to the tab that was active; a key
            // pressed while the review was up is not work in the tab.
            let (i, controlI, winI) = try tab("p21-I")
            try cancelledClose(g, winG, from: controlI, keyDuringReview: true)
            g.close()
            check(
                (i.presentation?.isActiveTab == true) && (h.presentation?.isActiveTab != true),
                "closed straight after a cancelled review, the tab returns to the tab that was active")
            // Quit: nothing is shown or laid out while the documents close.
            h.showWindows()
            let controllers = [controlH, controlI]
            let before = controllers.map(\.statusRefreshCount)
            let quitObservation = WindowQuitObservation()
            let observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: nil, queue: nil
            ) { note in
                precondition(Thread.isMainThread)
                let isClosingWindow = note.object as AnyObject? === winH || note.object as AnyObject? === winI
                MainActor.assumeIsolated {
                    if isClosingWindow { quitObservation.shown += 1 }
                }
            }
            sessionDelegate.closeAllForTermination()
            NotificationCenter.default.removeObserver(observer)
            check(
                controllers.map(\.statusRefreshCount) == before && quitObservation.shown == 0
                    && (h.presentation?.isActiveTab != true)
                    && (i.presentation?.isActiveTab != true) && NSDocumentController.shared.documents.isEmpty,
                "closing every document for quit shows and refreshes no remaining tab")
            withExtendedLifetime((controlA, controlE, h, i)) {}
        }
        section("a cancelled quit leaves the windows alone", #line) {
            let (document, _, window) = try tab("p21-quit-cancel")
            let (other, _, otherWindow) = try tab("p21-quit-cancel-2")
            document.updateChangeCount(.changeDone)
            let quitting = AppDelegate()
            var replies: [Bool] = []
            quitting.replyToTerminate = { replies.append($0) }
            quitting.reviewed(NSDocumentController.shared, didReviewAll: false, contextInfo: nil)
            check(
                replies == [false] && other.presentation!.isActiveTab && !document.presentation!.isActiveTab
                    && window === otherWindow
                    && NSDocumentController.shared.documents.count == 2,
                "a cancelled quit review closes nothing and leaves the showing tab on screen")
            document.updateChangeCount(.changeCleared)
            document.close()
            other.close()
        }

        // G391, G400
        section("Find in Folder results open from the keyboard", #line) {
            let suite = "TextTankFolderKeyboardChecks-" + UUID().uuidString
            let defaults = try requireValue(UserDefaults(suiteName: suite), "fixture: isolated defaults suite")
            defer { defaults.removePersistentDomain(forName: suite) }
            let area = root.appendingPathComponent("package-21-folder", isDirectory: true)
            try FileManager.default.createDirectory(at: area, withIntermediateDirectories: true)
            let listed = area.appendingPathComponent("listed.txt")
            try Data("a pin here\n".utf8).write(to: listed)
            let document = TextDocument()
            document.fileURL = listed
            try document.read(from: Data("a pin here\n".utf8), ofType: "Plain Text")
            NSDocumentController.shared.addDocument(document)
            document.makeWindowControllers()
            let folder = FolderSearchController(defaults: defaults)
            folder.workspaceRoots = { [area] }
            folder.scope.selectItem(at: 1)
            folder.mode.selectItem(at: 0)
            folder.filterField.stringValue = "*.txt"
            folder.queryField.stringValue = "pin"
            let start = try requireValue(folder.queryField.action, "fixture: the query field's action")
            _ = NSApp.sendAction(start, to: folder.queryField.target, from: folder.queryField)
            spinUntil("the folder search to finish") { !folder.isSearching }
            try require(folder.numberOfRows(in: folder.table) == 1, "fixture: one result listed")
            _ = document.editor.setSelectionAnchor(0, caret: 0)
            folder.table.selectRowIndexes([0], byExtendingSelection: false)
            let statusBefore = folder.status.stringValue
            check(
                folder.table.clickedRow == -1
                    && NSApp.sendAction(NSSelectorFromString("openResult:"), to: folder, from: folder.table),
                "fixture: a double-click away from the rows dispatched")
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            check(
                document.editor.selectionCaret == 0 && folder.status.stringValue == statusBefore,
                "a double-click away from the rows opens nothing, even with a row selected")
            let returnKey = try requireValue(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                    characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36),
                "fixture: a Return key event")
            folder.table.keyDown(with: returnKey)
            spinUntil("the result to open") {
                document.editor.selectedText == "pin" || folder.status.stringValue != statusBefore
            }
            if !check(
                document.editor.selectedText == "pin" && document.editor.selectionStart == 2,
                "Return on a selected result opens its document at the match")
            {
                print("NOTE folder status: \(folder.status.stringValue)")
            }
            // Closing saves the settings, which shows that Escape went through the close path.
            func savedSettings() -> String? {
                (try? Data(contentsOf: AppStorage.url(.folderSearch))).flatMap { String(data: $0, encoding: .utf8) }
            }
            let panel = try requireValue(folder.window, "fixture: the Find in Folder panel")
            folder.queryField.stringValue = "escape-marker-one"
            _ = NSApp.sendAction(start, to: folder.queryField.target, from: folder.queryField)
            try require(folder.isSearching, "fixture: a folder search is running before Escape")
            panel.cancelOperation(nil)
            check(
                folder.isSearching, "Escape does not close Find in Folder, and so does not stop it, while it is working"
            )
            spinUntil("the search Escape left alone to finish") { !folder.isSearching }
            folder.queryField.stringValue = "escape-marker-two"
            panel.cancelOperation(nil)
            check(savedSettings()?.contains("escape-marker-two") == true, "Escape closes the idle Find in Folder panel")
            // A chooser shown as a sheet, as the Command Palette is, has no close button.
            let host = NSWindow(
                contentRect: NSRect(x: 200, y: 200, width: 700, height: 500), styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false
            host.makeKeyAndOrderFront(nil)
            defer { host.close() }
            let chooser = ChoicePanel(
                title: "Escape fixture", identifier: "escape.fixture", action: "Choose", filterLabel: "Filter")
            chooser.rows = { [] }
            var chooserClosed = false
            chooser.onClose = { chooserClosed = true }
            chooser.show(parent: host)
            try require(host.attachedSheet === chooser.form.window, "fixture: the chooser is the document's sheet")
            chooser.form.window.cancelOperation(nil)
            check(
                host.attachedSheet == nil && chooserClosed && !chooser.form.window.isVisible,
                "Escape closes a chooser shown as a sheet and tells its owner")
            document.close()
        }

        // F310
        section("window frames are remembered", #line) {
            check(
                sessionDelegate.applicationSupportsSecureRestorableState(app),
                "the application opts in to secure restorable state")
            check(WindowFrames.defaults == nil, "a check run keeps no window frames unless it supplies defaults")
            let suite = "TextTankWindowFrameChecks-" + UUID().uuidString
            let defaults = try requireValue(UserDefaults(suiteName: suite), "fixture: isolated defaults suite")
            WindowFrames.defaults = defaults
            defer {
                WindowFrames.defaults = nil
                defaults.removePersistentDomain(forName: suite)
            }
            guard !NSScreen.screens.isEmpty else {
                print("SKIP window frames: no screen in native test process")
                return
            }
            let priorEffects = RuntimeEnvironment.dependencies
            var effects = RuntimeEnvironment.current
            effects.windowAnimation = nil
            RuntimeEnvironment.dependencies = effects
            defer { RuntimeEnvironment.dependencies = priorEffects }
            let priorServices = EditorServices.current
            let frameComposition = AppDelegate()
            frameComposition.installEditorServices()
            defer { EditorServices.current = priorServices }
            let key = WindowFrames.defaultsKey("TextTank.Document")
            let (first, _, firstWindow) = try tab("p21-frame-1")
            check(
                firstWindow.animationBehavior == .none,
                "document windows disable transition animation without a test-only override")
            // A restored title bar must fit a connected screen. The former fixed rectangle
            // reached y=770, outside the 768-point CI screen, and was correctly rejected.
            let screen = NSScreen.screens[0].visibleFrame
            let placed = NSRect(
                x: screen.minX + 20, y: screen.minY + 20,
                width: min(880, screen.width - 40), height: min(610, screen.height - 40))
            check(WindowFrames.isUsable(placed), "fixture: the saved frame fits the connected screen")
            firstWindow.setFrame(placed, display: true)
            let left = firstWindow.frame
            check(
                defaults.string(forKey: key) == WindowFrames.description(of: firstWindow),
                "moving or resizing the showing document window saves its frame")
            first.close()
            let (second, _, secondWindow) = try tab("p21-frame-2")
            check(
                secondWindow.frame == left, "the first document window of a later launch opens where the last was left")
            let moved = NSRect(
                x: screen.minX + 30, y: screen.minY + 30,
                width: min(940, screen.width - 60), height: min(660, screen.height - 60))
            secondWindow.setFrame(moved, display: true)
            let shared = secondWindow.frame
            defaults.set(WindowFrames.description(of: firstWindow), forKey: key)
            let (third, _, thirdWindow) = try tab("p21-frame-3")
            check(
                secondWindow.animationBehavior == .none && thirdWindow.animationBehavior == .none,
                "opening and switching document tabs keeps both native windows unanimated")
            check(
                thirdWindow.isVisible && thirdWindow.frame == shared,
                "a further tab takes the showing tab's frame, not the saved one")
            check(
                defaults.string(forKey: key) == WindowFrames.description(of: thirdWindow),
                "the frame saved is the one the showing tab has")
            second.close()
            third.close()
            // A tool window restores the frame saved under its own name.
            let searchSuite = "TextTankWindowFrameSearch-" + UUID().uuidString
            let searchDefaults = try requireValue(UserDefaults(suiteName: searchSuite), "fixture: search defaults")
            defer { searchDefaults.removePersistentDomain(forName: searchSuite) }
            let sample = try requireValue(SearchController(defaults: searchDefaults).window, "fixture: Find window")
            sample.setFrame(NSRect(x: 240, y: 200, width: 800, height: 480), display: false)
            defaults.set(
                WindowFrames.description(of: sample), forKey: WindowFrames.defaultsKey("TextTank.FindAndReplace"))
            let reopened = SearchController(defaults: searchDefaults)
            check(
                reopened.window?.frame == sample.frame && reopened.shouldCascadeWindows == false,
                "the Find window opens at its saved frame and is not offset from it")
            check(
                !WindowFrames.isUsable(NSRect(x: -5000, y: -5000, width: 800, height: 600))
                    && !WindowFrames.isUsable(NSRect(x: 100, y: 100, width: 10, height: 10))
                    && !WindowFrames.isUsable(NSRectFromString("not a frame")),
                "a saved frame that is off every screen, tiny or unreadable is not applied")
            check(
                defaults.string(forKey: WindowFrames.defaultsKey("TextTank.FindInFolder")) == nil
                    && FolderSearchController(defaults: searchDefaults).shouldCascadeWindows,
                "a tool window without a saved frame opens as before")
            // A tool window that has never been placed opens over the document window.
            let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
            let host = NSRect(x: 200, y: 100, width: 1000, height: 700)
            check(
                WindowFrames.centredOrigin(for: NSSize(width: 600, height: 400), over: host, within: visible)
                    == NSPoint(x: 400, y: 250),
                "an unplaced tool window is centred over the document window")
            check(
                WindowFrames.centredOrigin(
                    for: NSSize(width: 600, height: 400), over: NSRect(x: 1200, y: 700, width: 400, height: 300),
                    within: visible) == NSPoint(x: 840, y: 500)
                    && WindowFrames.centredOrigin(for: NSSize(width: 600, height: 1000), over: host, within: visible).y
                        == -100,
                "centring keeps the tool window on screen, and its title bar when it is taller than the screen")
            let unplaced = try requireValue(
                FolderSearchController(defaults: searchDefaults).window as? ToolPanel, "fixture: unplaced tool window")
            check(
                unplaced.awaitsFirstPlacement && (reopened.window as? ToolPanel)?.awaitsFirstPlacement == false,
                "only a tool window without a saved frame waits to be placed")
            unplaced.orderFront(nil)
            let placedOnce = unplaced.frame
            unplaced.orderOut(nil)
            // Sideways only: on showing a window AppKit keeps it between the top and bottom of the screen.
            let movedTo = NSPoint(x: placedOnce.minX + 40, y: placedOnce.minY)
            unplaced.setFrameOrigin(movedTo)
            unplaced.orderFront(nil)
            check(
                !unplaced.awaitsFirstPlacement && unplaced.frame.origin == movedTo,
                "a tool window is placed once; showing it again keeps where it was moved to")
            unplaced.close()
        }

        // G402, G403
        section("About panel and bundle metadata", #line) {
            let plistURL = TestPaths.repoRoot.appendingPathComponent("Resources/Info.plist")
            let info = try requireValue(
                NSDictionary(contentsOf: plistURL) as? [String: Any], "fixture: Resources/Info.plist is readable")
            let version = try requireValue(info["CFBundleShortVersionString"] as? String, "fixture: bundle version")
            let creditsURL = TestPaths.repoRoot.appendingPathComponent("Resources/Credits.rtf")
            let options = AppDelegate.aboutOptions(info: info, credits: creditsURL)
            check(
                options[.applicationVersion] as? String == version + " — INCOMPLETE PREVIEW"
                    && options[.applicationName] == nil && options[.version] == nil,
                "the About panel takes its name, version and build from the bundle and adds only the preview notice")
            check(
                AppDelegate.aboutOptions(info: ["CFBundleShortVersionString": "9.8.7"], credits: nil)[
                    .applicationVersion] as? String == "9.8.7 — INCOMPLETE PREVIEW",
                "a version bump in Info.plist reaches the About panel")
            let credits = (options[.credits] as? NSAttributedString)?.string ?? ""
            check(
                ["GPL-3.0-or-later", "Scintilla", "Lexilla", "Boost"].allSatisfy(credits.contains)
                    && ["TextTank-License.txt", "scintilla-License.txt", "lexilla-License.txt", "boost-License.txt"]
                        .allSatisfy {
                            credits.contains($0)
                                && FileManager.default.fileExists(
                                    atPath: TestPaths.repoRoot.appendingPathComponent("Resources/" + $0).path)
                        },
                "the bundled credits name all four licences and the files that hold them")
            // Every listed content type is a writable type, and all but one are named "Plain Text":
            // the Save panel's File Format pop-up would offer seven entries, three of which add an
            // extension (.txt, .xml, .json) to the name. The document keeps its own type instead.
            check(
                !TextDocument().shouldRunSavePanelWithAccessoryView,
                "the Save panel has no File Format pop-up, so saving never switches the type or adds its extension")
            check(
                AppDelegate.aboutOptions(info: nil, credits: nil).isEmpty,
                "without bundle information the About panel falls back to its standard contents")
            check(
                [
                    "CFBundleDevelopmentRegion", "CFBundleInfoDictionaryVersion", "NSHumanReadableCopyright",
                    "LSApplicationCategoryType", "CFBundleDisplayName"
                ].allSatisfy { (info[$0] as? String)?.isEmpty == false },
                "Info.plist carries the standard bundle keys")
            let types = try requireValue(info["CFBundleDocumentTypes"] as? [[String: Any]], "fixture: document types")
            check(
                types.allSatisfy {
                    ($0["NSDocumentClass"] as? String).flatMap(NSClassFromString) === TextDocument.self
                }, "every document type's class name resolves to TextDocument whatever the module is called")
            func contentTypes(_ type: [String: Any]) -> [String] { type["LSItemContentTypes"] as? [String] ?? [] }
            let anyFile = types.filter { contentTypes($0).contains("public.data") }
            check(
                anyFile.count == 1 && contentTypes(anyFile[0]) == ["public.data"]
                    && anyFile[0]["LSHandlerRank"] as? String == "None"
                    && anyFile[0]["CFBundleTypeRole"] as? String == "Editor",
                "any file can still be opened and saved, but TextTank is not offered as a handler for every file")
            let textType = types.first { contentTypes($0).contains("public.plain-text") }
            check(
                textType?["CFBundleTypeRole"] as? String == "Editor"
                    && textType?["LSHandlerRank"] as? String == "Alternate"
                    && Set(contentTypes(textType ?? [:])).isSuperset(of: [
                        "public.text", "public.plain-text", "public.source-code", "public.script", "public.xml",
                        "public.json"
                    ]), "text, source, script, XML and JSON files are claimed as an alternate editor")
            let exported = (info["UTExportedTypeDeclarations"] as? [[String: Any]] ?? []).first {
                $0["UTTypeIdentifier"] as? String == "app.texttank.session"
            }
            let tags = exported?["UTTypeTagSpecification"] as? [String: Any]
            check(
                (tags?["public.filename-extension"] as? [String]) == [WorkspaceStore.sessionFileExtension]
                    && (exported?["UTTypeConformsTo"] as? [String]) == ["public.json"]
                    && types.contains { contentTypes($0) == ["app.texttank.session"] },
                "the session snapshot type is exported with its extension and has its own document type")
            check(
                TextDocument.plainTextType == "public.plain-text"
                    && contentTypes(textType ?? [:]).contains(TextDocument.plainTextType),
                "the type name used in code is one the bundle declares")
            // Files with no extension or an unknown one stay openable: their type conforms to a
            // declared editor type, and they read as text.
            let area = root.appendingPathComponent("package-21", isDirectory: true)
            try FileManager.default.createDirectory(at: area, withIntermediateDirectories: true)
            let declared = types.filter { $0["CFBundleTypeRole"] as? String == "Editor" }.flatMap(contentTypes)
                .compactMap { UTType($0) }
            for (name, bytes) in [
                ("Makefile", Data("all:\n\techo hi\n".utf8)), (".env", Data("KEY=value\n".utf8)),
                ("server.log", Data("line one\nline two\n".utf8)), ("app.conf", Data("[section]\n".utf8)),
                ("utf16.txt", try FileCodec.encode("héllo\n", format: FileFormat(encoding: .utf16LE, bom: true)))
            ] {
                let url = area.appendingPathComponent(name)
                try bytes.write(to: url)
                let typeName = try NSDocumentController.shared.typeForContents(of: url)
                let type = try requireValue(UTType(typeName), "fixture: \(name) has a uniform type")
                check(
                    declared.contains { type.conforms(to: $0) },
                    "\(name) (\(typeName)) conforms to a document type TextTank declares as editable")
                let document = try TextDocument(contentsOf: url, ofType: typeName)
                check(
                    try FileCodec.encode(document.editor.text, format: document.format) == bytes,
                    "\(name) opens as text and encodes back to the same bytes")
                document.close()
            }
        }

        // Apple design review of 15 November 2026, actions N2 and N4 to N8.
        section("design review: one Find, grouped menus, safe defaults, kept document choices", #line) {
            let (document, controller, _) = try tab("n-fixes")
            let (plain, _, _) = try tab("n-fixes-default")
            defer {
                document.close()
                plain.close()
            }
            // The red close button quits the app; closing one tab stays with performClose.
            let red = controller.hostWindow?.standardWindowButton(.closeButton)
            check(
                red?.target === controller.hostWindow
                    && red?.action.map { NSStringFromSelector($0) } == "closeButtonPressed:"
                    && red?.toolTip?.hasPrefix("Quit TextTank") == true,
                "the window's red close button is routed to Quit, not to closing one tab")
            let (spare, _, spareWindow) = try tab("n-fixes-spare")
            spareWindow.performClose(nil)
            check(
                !isOpen(spare) && isOpen(document) && isOpen(plain),
                "File > Close still closes only the current tab and leaves the others open")
            controller.findField.stringValue = "alpha"
            controller.replaceField.stringValue = "changed"
            document.editor.text = "alpha beta"
            _ = document.editor.setSelectionAnchor(0, caret: 0)
            let caretRevision = document.editor.revision
            let barButtons = descendants(try requireValue(controller.findBar, "fixture: find bar")).compactMap {
                $0 as? NSButton
            }
            let replaceMatchButton = try requireValue(
                barButtons.first { $0.title == "Replace" }, "fixture: Replace button")
            let nextMatchButton = try requireValue(descendants(try requireValue(controller.findBar, "fixture: Find bar"))
                .compactMap { $0 as? NSSegmentedControl }.first { $0.segmentCount == 2 && $0.label(forSegment: 1) == "Next" },
                "fixture: Previous and Next segmented control")
            controller.controlTextDidChange(
                Notification(name: NSControl.textDidChangeNotification, object: controller.findField))
            check(
                !replaceMatchButton.isEnabled && nextMatchButton.isEnabled,
                "DS21 caret disables Replace Selection while Find Next remains available")
            try controller.replaceSelectionFromBar()
            check(
                document.editor.text == "alpha beta" && document.editor.revision == caretRevision,
                "F17 Replace Selection with only a caret never inserts text")
            _ = document.editor.setSelectionAnchor(6, caret: 10)
            try controller.replaceSelectionFromBar()
            spinUntil("a nonmatching selected replacement to finish") { !controller.inlineSearchPending }
            check(
                document.editor.text == "alpha beta" && document.editor.revision == caretRevision,
                "F17 Replace Selection refuses selected text that is not the query")
            _ = document.editor.setSelectionRanges([
                TTSelectionRange(anchor: 0, caret: 5), TTSelectionRange(anchor: 6, caret: 10)
            ])
            try controller.replaceSelectionFromBar()
            check(
                document.editor.text == "alpha beta" && document.editor.revision == caretRevision
                    && document.editor.selectionCount == 2,
                "F17 Replace Selection refuses multiple selections before any edit")
            _ = document.editor.setSelectionAnchor(5, caret: 0)
            spinUntil("the single selection to enable Replace") { replaceMatchButton.isEnabled }
            document.editor.readOnly = true
            spinUntil("read-only metadata to disable Replace") { !replaceMatchButton.isEnabled }
            check(nextMatchButton.isEnabled, "DS21 read-only keeps Find Next available")
            document.editor.readOnly = false
            spinUntil("writable metadata to re-enable Replace") { replaceMatchButton.isEnabled }
            controller.findField.stringValue = ""
            controller.controlTextDidChange(
                Notification(name: NSControl.textDidChangeNotification, object: controller.findField))
            check(
                !replaceMatchButton.isEnabled && !nextMatchButton.isEnabled,
                "DS21 an empty query disables both inline buttons")
            controller.findField.stringValue = String(repeating: "q", count: 65_537)
            controller.controlTextDidChange(
                Notification(name: NSControl.textDidChangeNotification, object: controller.findField))
            check(
                !replaceMatchButton.isEnabled && !nextMatchButton.isEnabled,
                "DS21 a known oversized query disables both inline buttons")
            controller.findField.stringValue = "alpha"
            controller.replaceField.stringValue = String(repeating: "x", count: 1_048_577)
            controller.controlTextDidChange(
                Notification(name: NSControl.textDidChangeNotification, object: controller.replaceField))
            check(
                !replaceMatchButton.isEnabled && nextMatchButton.isEnabled,
                "DS21 an oversized replacement disables Replace without blocking Find")
            controller.replaceField.stringValue = "changed"
            controller.controlTextDidChange(
                Notification(name: NSControl.textDidChangeNotification, object: controller.replaceField))
            check(
                replaceMatchButton.isEnabled && nextMatchButton.isEnabled,
                "DS21 valid query, replacement and writable selection enable both buttons")
            document.editor.resetUndoHistory()
            try controller.replaceSelectionFromBar()
            check(
                !replaceMatchButton.isEnabled && !nextMatchButton.isEnabled,
                "DS21 pending inline work disables both buttons until completion")
            spinUntil("a selected-match replacement to finish") { !controller.inlineSearchPending }

            check(
                document.editor.text == "changed beta" && document.editor.selectionAnchor == 7
                    && document.editor.selectionCaret == 0,
                "F17 strict replacement carries the reversed selection through the replacement")
            document.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
            check(
                document.editor.text == "alpha beta" && document.editor.selectionAnchor == 5
                    && document.editor.selectionCaret == 0,
                "one Undo restores the inline replacement and its reversed selection")
            document.editor.text = "aaa"
            controller.findField.stringValue = "aa"
            controller.replaceField.stringValue = "X"
            _ = document.editor.setSelectionAnchor(1, caret: 1)
            controller.findFromMenu(backwards: false)
            spinUntil("inline overlapping navigation to finish") { !controller.inlineSearchPending }
            check(
                document.editor.selectionStart == 1 && document.editor.selectionEnd == 3,
                "inline navigation selects the overlapping literal from an interior caret")
            try controller.replaceSelectionFromBar()
            spinUntil("inline overlapping strict replacement to finish") { !controller.inlineSearchPending }
            check(document.editor.text == "aX", "inline strict replacement accepts the overlapping selected match")
            document.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
            check(
                document.editor.text == "aaa" && document.editor.selectionStart == 1
                    && document.editor.selectionEnd == 3,
                "one Undo restores the inline overlapping match")
            controller.findField.stringValue = ""
            // N6: the find bar is out of the way until asked for, and works from the keyboard path.
            check(!controller.findBarVisible, "the find bar is hidden until Find is chosen")
            document.editor.text = "alpha beta alpha\n"
            EditorWindowController.findPasteboardText = ""
            controller.findFromMenu(backwards: false)
            spinUntil("inline Find to finish") { !controller.inlineSearchPending }
            check(controller.findBarVisible, "Find Next with nothing to find opens the find bar")
            controller.findField.stringValue = "alpha"
            controller.findFromMenu(backwards: false)
            spinUntil("inline Find to finish") { !controller.inlineSearchPending }
            check(
                (controller.hostWindow?.firstResponder as? NSView)?.isDescendant(of: document.editor) == true,
                "DS35 menu Find Next leaves keyboard focus in the document")
            let firstMatch = document.editor.selectionStart
            check(document.editor.selectedText == "alpha", "Find Next selects a match of the find bar's text")
            controller.findFromMenu(backwards: false)
            spinUntil("inline Find to finish") { !controller.inlineSearchPending }
            check(
                document.editor.selectedText == "alpha" && document.editor.selectionStart != firstMatch,
                "Find Next again moves to the following match")
            check(
                EditorWindowController.findPasteboardText == "alpha",
                "the text searched for is shared through the find pasteboard")
            controller.showFind(nil)
            let field = controller.findField
            let fieldEditor = controller.hostWindow?.firstResponder
            check(
                controller.control(
                    field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))),
                "Return in the find field is handled as Find Next")
            spinUntil("Return Find to finish") { !controller.inlineSearchPending }
            check(
                controller.hostWindow?.firstResponder === fieldEditor && field.currentEditor() === fieldEditor,
                "DS35 Return retains the Find field editor for repeated navigation")
            let afterReturn = document.editor.selectionStart
            controller.performFind(backwards: true, focusEditor: false)
            spinUntil("backwards field Find to finish") { !controller.inlineSearchPending }
            check(
                document.editor.selectedText == "alpha" && document.editor.selectionStart != afterReturn
                    && controller.hostWindow?.firstResponder === fieldEditor,
                "DS35 backwards field navigation retains the field editor")
            // A real bar action records shared search only after the asynchronous result applies.
            sessionDelegate.noteActive(controller)
            // Passive typing may select a result. Escape restores the exact opening direction.
            let priorQuery = controller.findField.stringValue
            controller.showFind(nil)
            let previousWord = controller.wordBox.state
            controller.wordBox.performClick(nil)
            check(sessionDelegate.searchController.wordButton.state == controller.wordBox.state
                    && controller.wordBox.state != previousWord,
                  "a whole-word change uses the same option in the bar and Find window")
            controller.wordBox.performClick(nil)
            let priorMode = sessionDelegate.searchController.mode.indexOfSelectedItem
            if controller.regexBox.state != .on { controller.regexBox.performClick(nil) }
            controller.findField.stringValue = "["
            controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: controller.findField))
            spinUntil("inline regex error") { !controller.findCount.stringValue.isEmpty }
            check(controller.regexBox.state == .on && controller.findCount.stringValue != "No matches"
                    && !controller.findCount.stringValue.contains(" of ") && NSApp.modalWindow == nil,
                  "a malformed bar regex reports its error in the Find bar")
            // DS-45: the field is marked and the whole message is shown, not a clipped count label.
            let malformed = try requireValue(controller.findField.toolTip, "the Find field carries the message")
            check(
                controller.findFieldIsMarked && controller.findCount.stringValue == "Expression not valid"
                    && malformed.count > 20 && controller.findField.accessibilityHelp() == malformed
                    && controller.statusText == malformed && controller.findField.stringValue == "[",
                "an invalid pattern marks the Find field and shows the full message in the status line")
            controller.findField.stringValue = "[a]"
            controller.controlTextDidChange(
                Notification(name: NSControl.textDidChangeNotification, object: controller.findField))
            spinUntil("the corrected regex to publish") { !controller.findCount.stringValue.isEmpty }
            check(
                !controller.findFieldIsMarked && controller.findField.accessibilityHelp() == nil,
                "correcting the expression removes the mark")
            sessionDelegate.searchController.mode.selectItem(at: priorMode)
            _ = NSApp.sendAction(sessionDelegate.searchController.mode.action!, to: sessionDelegate.searchController,
                                 from: sessionDelegate.searchController.mode)
            controller.hideFind(nil)
            _ = document.editor.setSelectionAnchor(3, caret: 1)
            controller.showFind(nil)
            controller.findField.stringValue = "alpha"
            controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: controller.findField))
            spinUntil("inline count publication") { !controller.findCount.stringValue.isEmpty }
            check(document.editor.selectedText.lowercased() == "alpha" && !controller.findCount.stringValue.isEmpty,
                  "live Find publishes a native selection and its count")
            check(NativeFixtureEnvironment.announcements.contains(controller.findCount.stringValue),
                  "the live Find count is announced, not only shown (DS-36)")
            controller.hideFind(nil)
            check(document.editor.selectionAnchor == 3 && document.editor.selectionCaret == 1,
                  "closing an uncommitted live Find restores the reversed opening selection")
            // V3, DS-35: one Find text and one replacement, live in the bar and the Find window.
            let oneFind = sessionDelegate.searchController
            let peerBar = try requireValue(plain.presentation, "fixture: another tab's find bar")
            controller.showFind(nil)
            let barEditor = try requireValue(
                controller.findField.currentEditor() as? NSTextView,
                "fixture: the Find field editor")
            barEditor.string = "alp"
            barEditor.setSelectedRange(NSRange(location: 1, length: 1))
            controller.controlTextDidChange(
                Notification(name: NSControl.textDidChangeNotification, object: controller.findField))
            check(
                oneFind.queryField.stringValue == "alp" && oneFind.sharedQuery == "alp"
                    && peerBar.findField.stringValue == "alp",
                "text typed in the find bar is in the Find and Replace window, and in other tabs' bars, as it is typed")
            check(
                barEditor.selectedRange() == NSRange(location: 1, length: 1)
                    && controller.hostWindow?.firstResponder === barEditor && barEditor.string == "alp",
                "sharing the typed text leaves the caret and selection in the find bar where they were")
            controller.replaceField.stringValue = "swap"
            controller.controlTextDidChange(
                Notification(name: NSControl.textDidChangeNotification, object: controller.replaceField))
            check(
                oneFind.replacementField.stringValue == "swap", "the replacement typed in the bar is in the window too")
            oneFind.queryField.stringValue = "beta"
            oneFind.controlTextDidChange(
                Notification(name: NSControl.textDidChangeNotification, object: oneFind.queryField))
            oneFind.replacementField.stringValue = "BETA"
            oneFind.controlTextDidChange(
                Notification(name: NSControl.textDidChangeNotification, object: oneFind.replacementField))
            check(
                controller.findField.stringValue == "beta" && controller.replaceField.stringValue == "BETA"
                    && peerBar.findField.stringValue == "beta" && !controller.inlineSearchPending
                    && !oneFind.isSearching,
                "text typed in the Find and Replace window is in the find bar as it is typed, and runs no search")
            // History: reachable from the bar by pointer (the magnifying glass) and keyboard (Down Arrow).
            for word in ["alpha", "beta"] {
                controller.findField.stringValue = word
                controller.findFromMenu(backwards: false)
                spinUntil("a remembered bar Find to finish") { !controller.inlineSearchPending }
            }
            let recentFinds = controller.findHistoryMenu(replacements: false)
            check(
                recentFinds.items.prefix(2).map(\.title) == ["beta", "alpha"]
                    && oneFind.findHistory.queries.prefix(2) == ["beta", "alpha"]
                    && (oneFind.queryField.objectValues as? [String])?.prefix(2) == ["beta", "alpha"],
                "a search made from the bar is in the history both surfaces offer, newest first")
            check(
                controller.findField.searchMenuTemplate?.items.prefix(2).map(\.title) == ["beta", "alpha"]
                    && controller.findField.searchMenuTemplate?.items.contains {
                        $0.submenu?.title == "Recent Replacements"
                    } == true,
                "the Find field's magnifying glass opens the recent searches, with the recent replacements beneath")
            var shownHistory: (menu: NSMenu, anchor: NSView)?
            let nativeHistoryPresenter = controller.presentFindHistory
            controller.presentFindHistory = { shownHistory = ($0, $1) }
            check(
                controller.control(
                    controller.findField, textView: NSTextView(),
                    doCommandBy: #selector(NSResponder.moveDown(_:)))
                    && shownHistory?.menu.items.first?.title == "beta" && shownHistory?.anchor === controller.findField,
                "Down Arrow in the Find field opens its history")
            check(
                controller.control(
                    controller.replaceField, textView: NSTextView(),
                    doCommandBy: #selector(NSResponder.moveDown(_:)))
                    && shownHistory?.menu.title == "Recent Replacements"
                    && shownHistory?.anchor === controller.replaceField,
                "Down Arrow in the Replace field opens the replacement history")
            controller.presentFindHistory = nativeHistoryPresenter
            let earlier = recentFinds.items[1]
            check(
                NSApp.sendAction(
                    try requireValue(earlier.action, "a history entry has an action"), to: earlier.target, from: earlier
                )
                    && controller.findField.stringValue == "alpha" && oneFind.queryField.stringValue == "alpha",
                "an entry chosen from the history is the Find text in the bar and in the window")
            // DS-21: Replace All is not offered once the live count has found nothing.
            _ = document.editor.setSelectionAnchor(0, caret: 0)
            controller.findField.stringValue = "no such text here"
            controller.controlTextDidChange(
                Notification(name: NSControl.textDidChangeNotification, object: controller.findField))
            spinUntil("the live count to find nothing") { controller.findCount.stringValue == "No matches" }
            check(
                !controller.replaceAllButton.isEnabled && controller.replaceAllButton.toolTip?.isEmpty == false
                    && controller.findNavigation.isEnabled,
                "the bar's Replace All is disabled, with the reason, when the live count found nothing")
            controller.findField.stringValue = "alpha"
            controller.controlTextDidChange(
                Notification(name: NSControl.textDidChangeNotification, object: controller.findField))
            check(
                controller.replaceAllButton.isEnabled && controller.replaceAllButton.toolTip == nil,
                "changing the Find text offers Replace All again at once")
            spinUntil("the live count for the new text") { !controller.findCount.stringValue.isEmpty }
            check(controller.replaceAllButton.isEnabled, "a live count with matches leaves Replace All enabled")
            controller.hideFind(nil)
            _ = document.editor.setSelectionAnchor(3, caret: 1)
            controller.findField.stringValue = priorQuery
            controller.showFind(nil)
            let beforeBarRecording = document.editor.text
            let recordingAnchor = document.editor.selectionAnchor, recordingCaret = document.editor.selectionCaret
            sessionDelegate.macros.startRecording()
            controller.findFromMenu(backwards: false)
            spinUntil("recorded bar Find to finish") { !controller.inlineSearchPending }
            controller.replaceField.stringValue = "ALPHA"
            try controller.replaceSelectionFromBar()
            spinUntil("recorded bar replacement to finish") { !controller.inlineSearchPending }
            let capturedBar = try sessionDelegate.macros.finishRecording()
            check(
                capturedBar?.steps.map(\.kind) == [.search, .search, .search]
                    && capturedBar?.steps.compactMap(\.search).map(\.action) == ["next", "replaceOne", "next"],
                "the actual bar captures search steps for navigation and strict replacement")
            let replayedText = document.editor.text
            let replayedAnchor = document.editor.selectionAnchor, replayedCaret = document.editor.selectionCaret
            // Native control: the original literal primitive plus its first edit. Scintilla Undo
            // remembers the first edit's selection; the preceding pure navigation is not an edit.
            document.editor.text = beforeBarRecording
            _ = document.editor.setSelectionAnchor(recordingAnchor, caret: recordingCaret)
            document.editor.resetUndoHistory()
            var firstEditAnchor = 0, firstEditCaret = 0
            do {
                document.editor.beginUndoGroup()
                defer { document.editor.endUndoGroup() }
                try require(
                    document.editor.find("alpha", matchCase: false, backwards: false),
                    "fixture: native primitive control finds the same match")
                firstEditAnchor = document.editor.selectionAnchor
                firstEditCaret = document.editor.selectionCaret
                try require(
                    document.editor.replaceSelection("ALPHA"),
                    "fixture: native primitive control replaces its first match")
            }
            check(
                document.editor.text.utf8.elementsEqual(replayedText.utf8),
                "native primitive control reaches the same text as the captured bar flow")
            document.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
            check(
                document.editor.text == beforeBarRecording && document.editor.selectionAnchor == firstEditAnchor
                    && document.editor.selectionCaret == firstEditCaret,
                "native control Undo restores the first edit selection rather than pre-navigation selection")
            document.editor.text = beforeBarRecording
            _ = document.editor.setSelectionAnchor(recordingAnchor, caret: recordingCaret)
            document.editor.resetUndoHistory()
            let priorPlayback = sessionDelegate.macros.searchPlayback
            sessionDelegate.macros.searchPlayback = { search, target in
                var options = SearchOptions()
                options.query = search.query
                options.replacement = search.replacement
                options.matchCase = search.matchCase
                try sessionDelegate.searchController.playRecorded(options: options, action: search.action, on: target)
            }
            defer { sessionDelegate.macros.searchPlayback = priorPlayback }
            try sessionDelegate.macros.play(
                try requireValue(capturedBar, "fixture: captured inline macro"), on: document.editor)
            check(
                document.editor.text.utf8.elementsEqual(replayedText.utf8)
                    && document.editor.selectionAnchor == replayedAnchor && document.editor.selectionCaret == replayedCaret,
                "captured bar search steps replay the exact document bytes and final selection")
            document.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
            check(
                document.editor.text == beforeBarRecording && document.editor.selectionAnchor == firstEditAnchor
                    && document.editor.selectionCaret == firstEditCaret,
                "one Undo of the replay restores the same text and first-edit selection as the native control")
            let allDocument = DocumentFactory.makeUntitled(display: false)
            let allController = try requireValue(allDocument.presentation, "fixture: current-document Replace All")
            _ = allDocument.editor.loadDocumentText("x x x")
            allController.showFind(nil)
            allController.findField.stringValue = "x"
            allController.replaceField.stringValue = "yy"
            allController.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: allController.findField))
            allController.replaceAllButton.performClick(nil)
            spinUntil("bar Replace All to finish") { !allController.inlineSearchPending }
            check(allDocument.editor.text == "yy yy yy" && allController.statusText.contains("Replaced 3 matches")
                    && document.editor.text == beforeBarRecording,
                  "bar Replace All counts changed matches and leaves the other open document alone")
            allDocument.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
            check(allDocument.editor.text == "x x x", "one Undo restores every inline Replace All edit")
            allDocument.close()
            controller.host.activate(controller, focus: false)
            sessionDelegate.noteActive(controller)
            // The previously accepted oversized query is explicitly refused by the bounded shared path.
            sessionDelegate.macros.startRecording()
            document.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "charRight"))
            let beforeLimitRevision = document.editor.revision, beforeLimitAnchor = document.editor.selectionAnchor,
                beforeLimitCaret = document.editor.selectionCaret, beforeLimitText = document.editor.text
            controller.findField.stringValue = String(repeating: "q", count: 65_537)
            controller.findFromMenu(backwards: false)
            spinUntil("the bounded inline query refusal to finish") { !controller.inlineSearchPending }
            check(
                controller.status.stringValue.contains("64 Ki") && document.editor.revision == beforeLimitRevision
                    && document.editor.selectionAnchor == beforeLimitAnchor
                    && document.editor.selectionCaret == beforeLimitCaret
                    && document.editor.text.utf8.elementsEqual(beforeLimitText.utf8),
                "an oversized inline query reports the limit and preserves bytes, revision and selection")
            check(
                try sessionDelegate.macros.finishRecording()?.steps == [.command("charRight")],
                "an inline query refused by the shared limit adds no recording step")
            controller.findField.stringValue = "alpha"
            // Query changes invalidate captured requests before selection, editing or recording.
            let beforePending = document.editor.revision
            _ = document.editor.setSelectionAnchor(0, caret: 0)
            controller.findFromMenu(backwards: false)
            controller.findField.stringValue = "other"
            spinUntil("a query-stale bar Find to finish") { !controller.inlineSearchPending }
            check(
                document.editor.revision == beforePending && document.editor.selectionCaret == 0,
                "a changed Find query drops its pending selection")
            controller.findField.stringValue = "alpha"
            controller.findFromMenu(backwards: false)
            controller.hideFind(nil)
            // FIFO main-actor completion is observed by issuing and finishing a fresh request.
            controller.findFromMenu(backwards: false)
            spinUntil("a new bar Find after Escape to finish") { !controller.inlineSearchPending }
            let advanced = sessionDelegate.searchController
            let originalFindWindow = advanced.window
            let routingWindow = OffscreenFindRoutingWindow(
                contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
            advanced.window = routingWindow
            defer { advanced.window = originalFindWindow }
            EditorWindowController.findPasteboardText = "beta"
            advanced.showSearch(nil)
            check(advanced.queryField.stringValue == "beta", "the advanced Find window imports the shared Find text")
            advanced.mode.selectItem(at: 0)
            advanced.scope.selectItem(at: 0)
            sessionDelegate.noteActive(controller)
            sessionDelegate.findNextShared(nil)
            spinUntil("menu navigation through the open advanced window") { !advanced.isSearching }
            check(
                document.editor.selectedText == "beta" && !controller.inlineSearchPending
                    && controller.findField.stringValue == "beta"
                    && EditorWindowController.findPasteboardText == "beta",
                "DS35 menu navigation uses the open advanced window and shares its query back to the bar")
            advanced.queryField.stringValue = "alpha"
            sessionDelegate.findPreviousShared(nil)
            spinUntil("previous navigation through the open advanced window") { !advanced.isSearching }
            check(
                document.editor.selectedText == "alpha" && controller.findField.stringValue == "alpha",
                "DS35 Find Previous also routes to the open advanced window")
            advanced.window = originalFindWindow
            // A preceding Undo can leave this fixture at its save point. Make the
            // recovery boundary below a real write of a dirty document.
            try require(document.editor.replaceSelection("owned recovery edit"), "Find fixture accepts an edit")
            try require(document.isDocumentEdited, "Find fixture has unsaved text")
            // N4: a failed find is put into words and announced, not only beeped.
            NativeFixtureEnvironment.announcements.removeAll()
            controller.findField.stringValue = "zebra"
            controller.findFromMenu(backwards: false)
            spinUntil("inline Find to finish") { !controller.inlineSearchPending }
            // A successful recovery may publish in the same run-loop turn as the no-match result.
            // Force that ordering before observing the real status label and announcement.
            document.flushRecovery()
            let savedFindSnapshot = try TextDocument.recovery.load(id: document.recoveryID)
            check(
                document.lastRecoveryError == nil && document.currentSaveStateStatus == "Edited — recovery copy kept"
                    && savedFindSnapshot.text.utf8.elementsEqual(document.editor.text.utf8),
                "the edited Find fixture has a confirmed recovery copy containing its exact bytes")
            check(
                controller.status.stringValue == "No matches for “zebra”."
                    && controller.status.accessibilityLabel() == "No matches for “zebra”."
                    && NativeFixtureEnvironment.announcements.contains("No matches for “zebra”."),
                "a failed find says No matches in the status line and to assistive technology")
            // An intervening edit ends the first display. Its queued expiry must not dismiss
            // another display of the same words. A second presentation witnesses expiry delivery.
            let repeated = "Repeated Find feedback"
            controller.showTransientStatus(repeated, seconds: 0, announce: false)
            try require(document.editor.replaceSelection("edit"), "a real edit interrupts the first display")
            check(controller.statusText != repeated, "editing clears the first transient before the next one")
            controller.showTransientStatus(repeated, seconds: 60, announce: false)
            let peer = try requireValue(plain.presentation, "fixture: independent status presentation")
            peer.showTransientStatus("Queued expiry control", seconds: 0, announce: false)
            spinUntil("a later queued transient expiry to run") { peer.statusText == plain.currentSaveStateStatus }
            check(
                controller.status.stringValue == repeated && controller.status.accessibilityLabel() == repeated,
                "an earlier expiry cannot retire a newer display with identical text")
            check(
                controller.control(
                    field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
                    && !controller.findBarVisible, "Escape in the find field closes the find bar")
            document.editor.text = "pick me\n"
            document.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "selectAll"))
            controller.useSelectionForFind(nil)
            check(
                controller.findField.stringValue == "zebra" && controller.status.stringValue.contains("one line"),
                "Use Selection for Find refuses a selection that spans lines, in words")
            NativeFixtureEnvironment.announcements.removeAll()
            document.editor.readOnly = true
            document.noteReadOnlyAttempt()
            check(
                NativeFixtureEnvironment.announcements.contains { $0.hasPrefix("Read Only is on") },
                "typing in a read-only document is explained, not only beeped")
            document.editor.readOnly = false
            controller.refreshStatusDetails()
            check(
                document.editor.accessibilityDocumentName == "n-fixes",
                "VoiceOver's name for the text area is the document's name")
            // N7 and N5: grouped Edit menu, readable encoding names, Open Recent, one Find entry.
            let bar = try requireValue(NSApp.mainMenu, "fixture: the main menu")
            let all = walk(bar)
            func has(_ path: String) -> Bool { all.contains { $0.path == path } }
            let edit = try requireValue(bar.items.first { $0.title == "Edit" }?.submenu, "fixture: the Edit menu")
            check(
                edit.items.contains { $0.isSeparatorItem } && menuLevelsOverTwenty(bar).isEmpty,
                "DS-23 every menu is grouped: no level lists more than twenty items \(menuLevelsOverTwenty(bar))")
            check(
                has("Edit > Lines > Sort Lines Ascending") && has("Edit > Convert Case > Title Case")
                    && has("Edit > Line Endings > Convert to CRLF") && has("Edit > Comment > Toggle Line Comment"),
                "Edit commands sit in named groups")
            check(
                EditorTransform.allCases.allSatisfy { transform in
                    all.contains { ($0.item.representedObject as? String) == "transform." + transform.rawValue }
                }, "every text transform still has a menu item")
            check(
                has("File > Reload with Encoding > UTF-8…") && has("File > Convert to Encoding > UTF-8 with BOM")
                    && !all.contains { $0.path.contains("utf8") },
                "Reload and Convert items use encoding names, not stored identifiers")
            check(has("File > Open Recent"), "File has Open Recent")
            let recent = NSMenu(title: "Open Recent")
            sessionDelegate.recentDocumentsMenu.menuNeedsUpdate(recent)
            check(recent.items.last?.title == "Clear Menu", "Open Recent ends with Clear Menu")
            let find = all.first { $0.path == "Find > Find…" }?.item
            let panel = all.first { $0.path == "Find > Find and Replace…" }?.item
            check(
                find?.keyEquivalent == "f" && find?.keyEquivalentModifierMask == [.command]
                    && panel?.keyEquivalentModifierMask == [.command, .option]
                    && has("Find > Use Selection for Find"),
                "Command-F is the find bar; Find and Replace has its own shortcut")
            check(all.contains { $0.path.hasPrefix("Help > ") }, "the Help menu has an item of its own")
            // N2: Return never destroys; Escape always has a button.
            @MainActor func roles(_ titles: [String], destructive: Int? = nil) -> [Int?] {
                let alert = TTAlert()
                for (index, title) in titles.enumerated() {
                    alert.addButton(withTitle: title).hasDestructiveAction = index == destructive
                }
                let keys = alert.keyRoles()
                return [keys.returnIndex, keys.escapeIndex]
            }
            check(roles(["Save", "Cancel"]) == [0, 1], "an ordinary alert: Return confirms, Escape cancels")
            check(
                roles(["Delete", "Cancel"], destructive: 0) == [1, 1],
                "a destructive first button: Return and Escape both cancel")
            check(roles(["Cancel", "Discard"], destructive: 1) == [nil, 0], "Cancel first: Return presses nothing")
            let explanation = FolderSearchController.replacementExplanation(
                query: "colour", replacement: "", matches: 3, files: 2, folders: 1)
            check(
                explanation.hasPrefix("Delete every match of “colour”: 3 matches in 2 files.")
                    && explanation.contains("private recovery batch in TextTank Application Support") && explanation.contains("Undo in the editor does not")
                    && !explanation.contains("root"),
                "the disk-replace prompt states the change, its size and that editor Undo does not reverse it")
            // N8: saving Settings carries a changed default only to views that still had the old one.
            let settings = sessionDelegate.settings
            let original = settings.value
            defer { _ = try? settings.save(original) }
            var base = original
            base.tabWidth = 4
            base.useTabs = true
            base.wrap = false
            try settings.save(base)
            for editor in [document.editor, plain.editor] {
                editor.configureTabWidth(4, useTabs: true)
                editor.wrap = false
            }
            document.editor.configureTabWidth(2, useTabs: false)
            document.editor.wrap = true
            var changed = base
            changed.tabWidth = 8
            changed.wrap = false
            try settings.save(changed)
            check(
                document.editor.statusInfo.tabWidth == 2
                    && document.editor.statusInfo.useTabs == false && document.editor.wrap,
                "a document's own indentation and wrapping survive a Settings save")
            check(
                plain.editor.statusInfo.tabWidth == 8,
                "a document still on the old default takes the new one")
        }
    }
}
