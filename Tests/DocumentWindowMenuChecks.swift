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
            return (document, controller, try requireValue(controller.window, "fixture: window"))
        }
        /// The close button for `target` in the tab strip of the window that is showing.
        @MainActor func closeButton(for target: NSWindow, in shown: EditorWindowController) throws -> NSButton {
            shown.refreshStatusDetails()
            let content = try requireValue(shown.window?.contentView, "fixture: content view")
            return try requireValue(
                descendants(content).compactMap { $0 as? NSButton }.first { $0.toolTip == "Close \(target.title)" },
                "fixture: the close button for \(target.title)")
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
                descendants(content).compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }?.performClick(
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
            try settings.save(intervening)
            let bytes = try Data(contentsOf: settings.url)
            views.compactMap { $0 as? NSButton }.first { $0.title == "Save" }?.performClick(nil)
            check(
                window.isVisible && field.stringValue == "7" && field.window != nil,
                "DG stale Settings keeps the pending native fields open")
            let after = try Data(contentsOf: settings.url)
            check(
                settings.value.wrap && settings.value.tabWidth == 4 && after == bytes,
                "DG stale Settings never overwrites an intervening real controller save")
            check(
                views.compactMap { $0 as? NSTextField }.contains {
                    $0.stringValue.contains("changed while this window was open")
                },
                "DG stale Settings explains the conflict beside the retained fields")
            views.compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }?.performClick(nil)
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

        section("DG explicit filtered choice activation", #line) { try DesignSettingsChecks.choicePanelChecks() }
        section("DG Open Documents Cancel never switches documents", #line) {
            let (first, _, firstWindow) = try tab("docs-cancel-first")
            let (second, _, secondWindow) = try tab("docs-cancel-second")
            firstWindow.makeKeyAndOrderFront(nil)
            let shown = (firstWindow.isVisible, secondWindow.isVisible)
            sessionDelegate.showDocumentTabs(nil)
            let form = try requireValue(FormPanel.visible.last, "fixture: actual Open Documents panel")
            let filter = try DesignSettingsChecks.field("TextTank.OpenDocuments.filter", form.window)
            filter.selectText(nil)
            DesignSettingsChecks.type("docs-cancel-second", in: form.window)
            try DesignSettingsChecks.button("TextTank.OpenDocuments.cancel", form.window).performClick(nil)
            check(
                firstWindow.isVisible == shown.0 && secondWindow.isVisible == shown.1,
                "DG filtering and cancelling Open Documents never switches the captured tab")
            sessionDelegate.showDocumentTabs(nil)
            let switching = try requireValue(FormPanel.visible.last, "fixture: reopened Open Documents panel")
            let secondFilter = try DesignSettingsChecks.field("TextTank.OpenDocuments.filter", switching.window)
            secondFilter.selectText(nil)
            DesignSettingsChecks.type("docs-cancel-second", in: switching.window)
            try DesignSettingsChecks.button("TextTank.OpenDocuments.choose", switching.window).performClick(nil)
            check(
                secondWindow.isVisible && !firstWindow.isVisible,
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
                    "About TextTank", "Settings…", "", "Services", "", "Hide TextTank", "Hide Others", "Show All", "",
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

            let goTo = entry("Search > Go to Line…")
            check(
                goTo?.action == #selector(EditorWindowController.goToLine(_:)) && goTo?.keyEquivalent == "l"
                    && goTo?.keyEquivalentModifierMask == [.command] && goTo?.target == nil,
                "Search > Go to Line… is Command-L and goes to the document window")
            let palettes = all.filter { $0.item.title == "Automation Palette…" }
            check(
                palettes.map(\.path) == ["Automations > Automation Palette…"]
                    && palettes.first?.item.keyEquivalent == "P"
                    && palettes.first?.item.keyEquivalentModifierMask == [.command]
                    && palettes.first?.item.target === sessionDelegate.automations,
                "Automation Palette… is one item, in the Automations menu, with Shift-Command-P")
            check(
                !all.contains { $0.item.title == "Choose Automation…" },
                "the duplicate Choose Automation… item is gone")
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
                views.compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }?.performClick(nil)
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
                    let save = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Save" })
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
            controller.window?.makeFirstResponder(doc.editor)
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
            _ = controller.window?.makeFirstResponder(clone)
            clone.executeCommand(TTEditorCommandIdentifier(rawValue: "toggleEOL"))
            check(
                controller.validateMenuItem(endings) && endings.state == .on,
                "DS22 catalog toggle checkmarks follow the focused clone's own view state")
            _ = controller.window?.makeFirstResponder(doc.editor)
            check(
                controller.validateMenuItem(endings) && endings.state == .off,
                "DS22 returning to the source pane restores that view's toggle checkmark")
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
                    let save = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Save" })
                else {
                    views.compactMap { $0 as? NSButton }.first?.performClick(nil)
                    return
                }
                if stage == 0 {
                    field.stringValue = "invalid width"
                    stage = 1
                    save.performClick(nil)
                } else if stage == 1 {
                    keptDraft =
                        field.stringValue == "invalid width"
                        && views.compactMap({ $0 as? NSTextField }).contains(where: {
                            !$0.isEditable && $0.stringValue.contains("Tab width must")
                                && $0.stringValue.contains("32")
                        })
                    field.stringValue = "8 "
                    stage = 2
                    save.performClick(nil)
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
                [winA, winB, winC, winD].allSatisfy { $0.collectionBehavior.contains(.fullScreenNone) },
                "document tab windows do not enter full screen")
            check(
                winD.isVisible && ![winA, winB, winC].contains { $0.isVisible },
                "fixture: the last of four tabs is showing")
            winD.setFrame(NSRect(x: 160, y: 140, width: 900, height: 640), display: true)
            let frame = winD.frame
            // B first, while C is still open between it and D: only the return-to target, not
            // adjacency, brings D back (B's neighbour is C).
            try closeButton(for: winB, in: controlD).performClick(nil)
            check(
                winD.isVisible && !isOpen(b) && isOpen(c) && isOpen(d) && !winC.isVisible && !winA.isVisible,
                "closing a background tab that is not next to the active one returns to the active tab, not its neighbour"
            )
            if !NSScreen.screens.isEmpty {
                check(winD.frame == frame, "closing a background tab leaves the window's frame as it was")
            }
            try closeButton(for: winC, in: controlD).performClick(nil)
            check(
                winD.isVisible && !isOpen(c) && isOpen(d) && !winA.isVisible,
                "closing a clean background tab from its close button returns to the tab that was active")
            let (e, controlE, winE) = try tab("p21-E")
            let (f, _, winF) = try tab("p21-F")
            try require(winF.isVisible, "fixture: the new last tab is showing")
            f.close()
            check(
                winE.isVisible && !winA.isVisible && !winD.isVisible,
                "closing the active last tab shows the previous tab, not the first")
            winD.makeKeyAndOrderFront(nil)
            let middleFrame = winD.frame
            d.close()
            check(winE.isVisible && !winA.isVisible, "closing an active middle tab shows the next tab")
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
                try closeButton(for: window, in: control).performClick(nil)
                check(
                    window.isVisible && control.window?.isVisible == false && isOpen(document),
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
            winE.makeKeyAndOrderFront(nil)
            winA.makeKeyAndOrderFront(nil)
            a.close()
            check(
                winE.isVisible && !winG.isVisible,
                "after a cancelled close and a tab switch, closing the tab shows its neighbour again")
            // And after the person has gone on working in the tab without switching.
            let (h, controlH, winH) = try tab("p21-H")
            try cancelledClose(e, winE, from: controlH)
            winE.sendEvent(leftArrow)
            e.close()
            check(
                winG.isVisible && !winH.isVisible,
                "after a cancelled close and a key typed in the tab, closing the tab shows its neighbour again")
            // Closed straight after the cancel, it still returns to the tab that was active; a key
            // pressed while the review was up is not work in the tab.
            let (i, controlI, winI) = try tab("p21-I")
            try cancelledClose(g, winG, from: controlI, keyDuringReview: true)
            g.close()
            check(
                winI.isVisible && !winH.isVisible,
                "closed straight after a cancelled review, the tab returns to the tab that was active")
            // Quit: nothing is shown or laid out while the documents close.
            winH.makeKeyAndOrderFront(nil)
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
                controllers.map(\.statusRefreshCount) == before && quitObservation.shown == 0 && !winH.isVisible
                    && !winI.isVisible && NSDocumentController.shared.documents.isEmpty,
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
                replies == [false] && otherWindow.isVisible && !window.isVisible
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
            let red = controller.window?.standardWindowButton(.closeButton)
            check(
                red?.target === controller.window
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
                barButtons.first { $0.title == "Replace Selection" }, "fixture: Replace Selection button")
            let nextMatchButton = try requireValue(barButtons.first { $0.title == "Next" }, "fixture: Next button")
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
                (controller.window?.firstResponder as? NSView)?.isDescendant(of: document.editor) == true,
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
            let fieldEditor = controller.window?.firstResponder
            check(
                controller.control(
                    field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))),
                "Return in the find field is handled as Find Next")
            spinUntil("Return Find to finish") { !controller.inlineSearchPending }
            check(
                controller.window?.firstResponder === fieldEditor && field.currentEditor() === fieldEditor,
                "DS35 Return retains the Find field editor for repeated navigation")
            let afterReturn = document.editor.selectionStart
            controller.performFind(backwards: true, focusEditor: false)
            spinUntil("backwards field Find to finish") { !controller.inlineSearchPending }
            check(
                document.editor.selectedText == "alpha" && document.editor.selectionStart != afterReturn
                    && controller.window?.firstResponder === fieldEditor,
                "DS35 backwards field navigation retains the field editor")
            // A real bar action records shared search only after the asynchronous result applies.
            sessionDelegate.noteActive(controller)
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
                capturedBar?.steps.map(\.kind) == [.search, .search]
                    && capturedBar?.steps.compactMap(\.search).map(\.action) == ["next", "replaceOne"],
                "the actual bar captures search steps for navigation and strict replacement")
            let replayedText = document.editor.text
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
                document.editor.text.utf8.elementsEqual(replayedText.utf8),
                "captured bar search steps replay to the exact same document bytes")
            document.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
            check(
                document.editor.text == beforeBarRecording && document.editor.selectionAnchor == firstEditAnchor
                    && document.editor.selectionCaret == firstEditCaret,
                "one Undo of the replay restores the same text and first-edit selection as the native control")
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
            // N4: a failed find is put into words and announced, not only beeped.
            NativeFixtureEnvironment.announcements.removeAll()
            controller.findField.stringValue = "zebra"
            controller.findFromMenu(backwards: false)
            spinUntil("inline Find to finish") { !controller.inlineSearchPending }
            check(
                controller.status.stringValue == "No matches for “zebra”."
                    && NativeFixtureEnvironment.announcements.contains("No matches for “zebra”."),
                "a failed find says No matches in the status line and to assistive technology")
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
                edit.items.count <= 20 && edit.items.contains { $0.isSeparatorItem }
                    && edit.items.allSatisfy { ($0.submenu?.items.count ?? 0) <= 20 },
                "the Edit menu is grouped: no level lists more than twenty items")
            check(
                has("Edit > Lines > Sort Lines Ascending") && has("Edit > Convert Case > Title Case")
                    && has("Edit > Line Endings > Convert to CRLF") && has("Edit > Comment > Toggle Line Comment"),
                "Edit commands sit in named groups")
            check(
                EditorTransform.allCases.allSatisfy { transform in
                    all.contains { ($0.item.representedObject as? String) == "transform." + transform.rawValue }
                }, "every text transform still has a menu item")
            check(
                has("Encoding > Reload as UTF-8…") && !all.contains { $0.path.contains("utf8") },
                "Reload items use encoding names, not stored identifiers")
            check(has("File > Open Recent"), "File has Open Recent")
            let recent = NSMenu(title: "Open Recent")
            sessionDelegate.recentDocumentsMenu.menuNeedsUpdate(recent)
            check(recent.items.last?.title == "Clear Menu", "Open Recent ends with Clear Menu")
            let find = all.first { $0.path == "Search > Find…" }?.item
            let panel = all.first { $0.path == "Search > Find and Replace…" }?.item
            check(
                find?.keyEquivalent == "f" && find?.keyEquivalentModifierMask == [.command]
                    && panel?.keyEquivalentModifierMask == [.command, .option]
                    && has("Search > Use Selection for Find"),
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
                    && explanation.contains(".texttank-backup") && explanation.contains("Undo in the editor does not")
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
