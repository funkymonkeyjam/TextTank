// SPDX-License-Identifier: GPL-3.0-or-later
// Audit package 21: window, menu and keyboard conventions. These sections run inside
// document-checks after the split-view sections and share its support directory and delegate.
// The check process holds no key or main window, so menu validation is asked of the object the
// responder chain would reach, and tab windows are told to come forward directly. The main menu
// is the one the "menu and command wiring" section built: its submenus belong to that menu bar,
// so the delegate cannot build a second one.
import AppKit
import UniformTypeIdentifiers

extension DocumentChecks {
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
        func item(_ action: Selector, _ object: String? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
            item.representedObject = object
            return item
        }
        func walk(_ menu: NSMenu, _ path: String = "") -> [(path: String, item: NSMenuItem)] {
            menu.items.flatMap { item -> [(path: String, item: NSMenuItem)] in
                let here = path.isEmpty ? item.title : path + " > " + item.title
                return [(here, item)] + (item.submenu.map { walk($0, here) } ?? [])
            }
        }

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
                    && controller.statusOptionsMenu("position")?.items.map(\.title) == ["Go to Line…"],
                "the document window implements Go to Line and the status bar keeps its own entry")
            let text = "één\r\ntwo 😀\rthree\nfour"
            document.editor.text = text
            _ = document.editor.setSelectionAnchor(1, caret: 1)
            let revision = document.editor.revision
            check(
                EditorWindowController.goToLine(3, in: document.editor)
                    && document.editor.selectionCaret == "één\r\ntwo 😀\r".utf8.count
                    && document.editor.selectionAnchor == document.editor.selectionCaret
                    && document.editor.statusInfo["line"]?.intValue == 3,
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
            let answer = Timer(timeInterval: 0.05, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard !answered, let modal = NSApp.modalWindow, let content = modal.contentView else { return }
                    let views = descendants(content)
                    if let field = views.compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable }),
                        let go = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Go" })
                    {
                        answered = true
                        field.stringValue = "2"
                        go.performClick(nil)
                    } else if Date() > giveUp {
                        NSApp.abortModal()
                    }
                }
            }
            RunLoop.main.add(answer, forMode: .modalPanel)
            controller.goToLine(nil)
            answer.invalidate()
            check(
                answered && document.editor.statusInfo["line"]?.intValue == 2
                    && (window.firstResponder as? NSView)?.isDescendant(of: document.editor) == true,
                "the Go to Line dialog moves the caret to the line entered and returns to the editor")
            document.close()
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
            // A background tab with unsaved changes is brought forward for its review.
            a.updateChangeCount(.changeDone)
            try closeButton(for: winA, in: controlE).performClick(nil)
            check(
                winA.isVisible && !winE.isVisible && isOpen(a),
                "closing a background tab with unsaved changes shows that tab and keeps its document open")
            let sheet = winA.attachedSheet
            check(sheet != nil, "the unsaved-changes review is presented on the tab that is now showing")
            if let sheet {
                let cancel = (sheet.contentView.map { descendants($0) } ?? []).compactMap { $0 as? NSButton }.first {
                    $0.title == "Cancel"
                }
                if let cancel { cancel.performClick(nil) } else { winA.endSheet(sheet, returnCode: .cancel) }
                spinUntil("the cancelled review to leave") { winA.attachedSheet == nil }
            }
            check(isOpen(a) && winA.isVisible, "cancelling the review keeps the tab open and showing")
            // The cancelled close must not decide where a later close goes.
            let (g, _, winG) = try tab("p21-G")
            winE.makeKeyAndOrderFront(nil)
            winA.makeKeyAndOrderFront(nil)
            a.updateChangeCount(.changeCleared)
            a.close()
            check(
                winE.isVisible && !winG.isVisible,
                "after a cancelled close and a tab switch, closing the tab shows its neighbour again")
            // Quit: nothing is shown or laid out while the documents close.
            winE.makeKeyAndOrderFront(nil)
            let controllers = [
                controlE, try requireValue(g.windowControllers.first as? EditorWindowController, "fixture")
            ]
            let before = controllers.map(\.statusRefreshCount)
            var shownDuringQuit = 0
            let observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: nil, queue: nil
            ) { note in
                if note.object as AnyObject? === winE || note.object as AnyObject? === winG { shownDuringQuit += 1 }
            }
            sessionDelegate.closeAllForTermination()
            NotificationCenter.default.removeObserver(observer)
            check(
                controllers.map(\.statusRefreshCount) == before && shownDuringQuit == 0 && !winE.isVisible
                    && !winG.isVisible && NSDocumentController.shared.documents.isEmpty,
                "closing every document for quit shows and refreshes no remaining tab")
            withExtendedLifetime((controlA, e)) {}
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
                defaults.data(forKey: "TextTank.FolderSearch.v1").flatMap { String(data: $0, encoding: .utf8) }
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
            let key = WindowFrames.defaultsKey("TextTank.Document")
            let (first, _, firstWindow) = try tab("p21-frame-1")
            let placed = NSRect(x: 180, y: 160, width: 880, height: 610)
            firstWindow.setFrame(placed, display: true)
            let left = firstWindow.frame
            check(
                defaults.string(forKey: key) == WindowFrames.description(of: firstWindow),
                "moving or resizing the showing document window saves its frame")
            first.close()
            let (second, _, secondWindow) = try tab("p21-frame-2")
            check(
                secondWindow.frame == left, "the first document window of a later launch opens where the last was left")
            let moved = NSRect(x: 220, y: 120, width: 940, height: 660)
            secondWindow.setFrame(moved, display: true)
            let shared = secondWindow.frame
            defaults.set(WindowFrames.description(of: firstWindow), forKey: key)
            let (third, _, thirdWindow) = try tab("p21-frame-3")
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
    }
}
