@testable import TextTankCore
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
@testable import TextTankRuntime
import EditorBridge
import NativeSearch

enum DesignStatusChecks {
    @MainActor private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    @MainActor static func run() throws {
        let initialURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TEXTTANK_SUPPORT_DIRECTORY"]!)
            .appendingPathComponent("owned-status-initial-" + UUID().uuidString + ".txt")
        try Data("saved input".utf8).write(to: initialURL)
        defer { try? FileManager.default.removeItem(at: initialURL) }
        let opened = try TextDocument.open(initialURL, as: .utf8, display: false)
        opened.makeWindowControllers()
        let openedController = opened.windowControllers[0] as! EditorWindowController
        check(
            !opened.isDocumentEdited && openedController.statusText == opened.currentSaveStateStatus,
            "DB-R1 an actually loaded saved file starts with its current save-state words")
        opened.close()
        let document = TextDocument()
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
        defer { document.close() }
        let controller = document.windowControllers[0] as! EditorWindowController
        controller.statusTimerInterval = nil
        controller.visibilityChanged()
        let window = controller.hostWindow!
        window.setContentSize(NSSize(width: 800, height: 500))
        let root = window.contentView!
        root.layoutSubtreeIfNeeded()
        let row = descendants(root).first { $0 is StatusBadgeRow }! as! StatusBadgeRow
        // Every field is a native button: a pull-down for a field with a menu of its own, a
        // plain button for a field that runs one command.
        func field(_ identifier: String) -> NSButton? {
            descendants(row).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == identifier }
        }
        let fieldIDs = ["status.position.0", "status.language.0", "status.indent.0", "status.encoding.0", "status.eol.0"]
        let fields = fieldIDs.compactMap(field)
        check(fields.count == 5, "DB-R1 the five unselected fields are native controls in the row")
        check(
            ["status.position.0", "status.language.0"].allSatisfy { field($0).map { !($0 is NSPopUpButton) } == true },
            "SR-1 the position and the language are buttons that run one command, not menus")
        check(
            ["status.indent.0", "status.encoding.0", "status.eol.0"].allSatisfy { field($0) is NSPopUpButton },
            "SR-1 indentation, encoding and line endings stay native pull-down menus")
        check(row.bounds.height == 28, "DS-74 the status row is 28 points tall: \(row.bounds.height)")
        check(controller.status.isDescendant(of: row), "DB-R1 save-state label shares the same status row")
        check(
            controller.status.textColor == .labelColor,
            "DS-61 the status message is drawn in the primary label colour")
        check(
            !controller.statusText.contains("Incomplete preview"),
            "DB-R4 preview disclosure is outside operational status")
        for control in fields {
            check(
                !control.isBordered && control.frame.height >= 28,
                "DS-74 status field \(control.identifier!.rawValue) is borderless and 28 points high")
        }
        // The position runs Go to Line. Its former menu is gone; what that menu said about the
        // document is the field's tooltip and accessibility help.
        controller.refreshStatusDetails()
        _ = spinUntil(timeout: 2, "SR-1 the character total reaches the position field") {
            controller.statusMetricsCaptureCount > 0 && controller.statusStatistics.contains(Strings.count(0, .character))
        }
        let positionField = try requireValue(field("status.position.0"), "fixture: position field")
        check(
            controller.statusOptionsMenu(.position) == nil && controller.statusOptionsMenu(.language) == nil,
            "SR-1 the position and language fields have no menu")
        let statistics = [Strings.count(1, .line), Strings.count(0, .character), Strings.count(0, .bookmark)]
        check(
            statistics.allSatisfy { positionField.toolTip?.contains($0) == true },
            "SR-1 the position tooltip holds the line and character totals: \(positionField.toolTip ?? "nil")")
        check(
            statistics.allSatisfy { positionField.accessibilityHelp()?.contains($0) == true }
                && positionField.accessibilityHelp()?.hasPrefix("Opens Go to Line.") == true,
            "SR-1 the position's accessibility help says what it opens and holds the same statistics")
        check(
            positionField.accessibilityLabel()?.hasPrefix("Position: Ln ") == true
                && positionField.accessibilityLabel()?.hasSuffix("Go to line.") == true,
            "DS-70 the position is named by what it shows and what it does: \(positionField.accessibilityLabel() ?? "nil")")
        var ran: [StatusField] = []
        let wired = row.onCommand
        row.onCommand = { ran.append($0) }
        positionField.performClick(nil)
        try requireValue(field("status.language.0"), "fixture: language field").performClick(nil)
        row.onCommand = wired
        check(ran == [.position, .language], "SR-1 clicking the position or the language runs that field's one command")
        check(!controller.goToLineBarVisible, "fixture: Go to Line is not showing before the click")
        positionField.performClick(nil)
        check(controller.goToLineBarVisible, "SR-1 clicking the position field runs Go to Line itself")
        check(FormPanel.visible.isEmpty, "SR-1 Go to Line opens no separate panel")
        controller.closeGoToLineBar(restoring: true, returningKeyboard: false)
        let items = [
            StatusItem(field: .position, text: "Ln 1, Col 1"),
            .init(field: .language, text: String(repeating: "Long language name ", count: 10)),
            .init(field: .indent, text: "Spaces: 4"), .init(field: .encoding, text: "UTF-8"),
            .init(field: .eol, text: "LF")
        ]
        row.update(items)
        root.layoutSubtreeIfNeeded()
        let visible = descendants(row).compactMap { $0 as? NSControl }.filter {
            !$0.isHiddenOrHasHiddenAncestor && ($0 === controller.status || $0 is NSButton)
        }
        check(row.bounds.height == 28, "DB-R5 a long language name collapses instead of wrapping")
        check(
            visible.allSatisfy {
                $0.convert($0.bounds, to: row).minX >= -0.5
                    && $0.convert($0.bounds, to: row).maxX <= row.bounds.width + 0.5
            },
            "DB-R5 every visible control remains within the minimum-width row")
        let visibleLanguage = field("status.language.0")
        check(
            visibleLanguage?.isHiddenOrHasHiddenAncestor == true,
            "DB-R5 long language is the first collapsed field")
        // A field that left the row is listed in the More menu, so it is never out of reach.
        let more = try requireValue(field(StatusBadgeRow.overflowIdentifier), "fixture: the More menu")
        check(
            row.collapsedFields == [.language] && !more.isHiddenOrHasHiddenAncestor && more is NSPopUpButton
                && more.convert(more.bounds, to: row).maxX <= row.bounds.width + 0.5,
            "SR-1 the More menu appears inside the row once a field has collapsed: \(row.collapsedFields)")
        let overflowLanguage = row.overflowItems()
        check(
            overflowLanguage.count == 1 && overflowLanguage[0].title.hasPrefix("Language: ")
                && overflowLanguage[0].title.hasSuffix("…") && overflowLanguage[0].submenu == nil,
            "SR-1 a collapsed language is offered in the More menu as the chooser command")
        ran = []
        row.onCommand = { ran.append($0) }
        if let item = overflowLanguage.first, let action = item.action {
            _ = NSApp.sendAction(action, to: item.target, from: item)
        }
        row.onCommand = wired
        check(ran == [.language], "SR-1 the More menu's language entry runs the language field's command")
        check(
            more.accessibilityLabel()?.hasPrefix("More status fields") == true,
            "DS-70 the More menu is named for what it holds")
        let languageIdentity = visibleLanguage.map(ObjectIdentifier.init)
        window.setContentSize(NSSize(width: 2400, height: 500))
        root.layoutSubtreeIfNeeded()
        check(
            visibleLanguage?.isHiddenOrHasHiddenAncestor == false,
            "DB-R5 collapsed language returns when the owned window widens")
        check(
            visibleLanguage.map(ObjectIdentifier.init) == languageIdentity,
            "DB-R5 resizing retains the existing native field identity")
        check(
            row.collapsedFields.isEmpty && more.isHiddenOrHasHiddenAncestor && row.overflowItems().isEmpty,
            "SR-1 the More menu leaves the row when every field fits again")
        let visibleFields = fieldIDs.compactMap(field).filter { !$0.isHiddenOrHasHiddenAncestor }
        check(visibleFields.count == 5, "DB-R5 every field is shown again in the wide window")
        for control in visibleFields {
            check(
                window.makeFirstResponder(control) && window.firstResponder === control,
                "DB-R6 native status field accepts keyboard focus: \(control.identifier!.rawValue)")
            let exposed = NSAccessibility.unignoredChildrenForOnlyChild(from: control)
            let cell = exposed.first as? NSObject
            let selector = NSSelectorFromString("accessibilityLabel")
            let name =
                cell?.responds(to: selector) == true
                ? cell?.perform(selector)?.takeUnretainedValue() as? String : nil
            let expected =
                control.identifier?.rawValue == "status.position.0"
                ? "Go to line."
                : control.identifier?.rawValue == "status.language.0" ? "Choose language." : "Show options."
            check(
                name?.hasSuffix(expected) == true,
                "DB-R6 actual native cell name states what the field does: \(name ?? "nil")")
        }
        window.setContentSize(NSSize(width: 800, height: 500))
        let longName = String(repeating: "owned-long-document-", count: 10) + ".txt"
        document.fileURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TEXTTANK_SUPPORT_DIRECTORY"]!)
            .appendingPathComponent(longName)
        controller.showRecoveryStatus(document.currentSaveStateStatus, failed: false)
        let longPath = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TEXTTANK_SUPPORT_DIRECTORY"]!)
            .appendingPathComponent(String(repeating: "nested-owned-directory/", count: 50))
            .appendingPathComponent("recovery.json").path
        let diagnostic = NSError(
            domain: "TextTankOwnedStatusFixture", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The recovery copy at \(longPath) could not be written."])
        let failureMessage = "⚠︎ Recovery copy not written: \(diagnostic.localizedDescription)"
        controller.showRecoveryStatus(failureMessage, failed: true)
        root.layoutSubtreeIfNeeded()
        check(
            controller.statusText == failureMessage && controller.status.toolTip?.contains(longPath) == true,
            "DB-R7 compact layout retains the complete owned long-path diagnostic in the model and tooltip")
        check(
            controller.status.stringValue == "⚠︎ Recovery copy not written",
            "DB-R5 essential recovery-failure words and symbol stay visible at minimum width")
        check(
            controller.status.frame.width >= controller.status.intrinsicContentSize.width - 0.5,
            "DB-R5 essential failure wording is not clipped at minimum width")
        controller.showTransientStatus(
            "Transient fixture must not hide recovery failure", seconds: 0.02, announce: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        check(
            controller.statusText == failureMessage,
            "DB-R7 transient display and expiry never replace a standing recovery failure")
        controller.showRecoveryStatus(document.currentSaveStateStatus, failed: false)
        controller.showTransientStatus(
            String(repeating: "A complete owned transient message. ", count: 40), seconds: 0.03, announce: false)
        root.layoutSubtreeIfNeeded()
        check(
            controller.statusText.hasPrefix("A complete owned transient message.")
                && controller.status.accessibilityLabel() == controller.statusText
                && controller.status.toolTip == controller.statusText,
            "DB-R1 a long transient keeps its complete real accessibility name and tooltip")
        _ = spinUntil(timeout: 1, "DB transient returns to the document save state") {
            controller.statusText == document.currentSaveStateStatus
        }
        check(
            controller.statusText == document.currentSaveStateStatus,
            "DB-R1 transient expiry restores the document's actual save state")
        let missing = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TEXTTANK_SUPPORT_DIRECTORY"]!)
            .appendingPathComponent(String(repeating: "missing-owned-status-", count: 10) + UUID().uuidString + ".txt")
        var actualOpenError: Error?
        do { _ = try FileHandle(forReadingFrom: missing) } catch { actualOpenError = error }
        let openError = try requireValue(actualOpenError, "fixture: actual read failure for a missing owned file")
        check(
            !document.isDocumentEdited && document.currentSaveStateStatus == "Saved",
            "DB-R1 actual-error fixture starts clean and saved")
        controller.showSearchFailure(openError, seconds: 0.03, announce: false)
        root.layoutSubtreeIfNeeded()
        print("DB_LONG_ERROR", "full=", controller.statusText, "visible=", controller.status.stringValue)
        check(
            controller.status.stringValue != "Saved" && controller.status.stringValue.contains("could not complete"),
            "DB-R1 an actual long error keeps essential failure words visible instead of becoming Saved")
        check(
            controller.statusText == openError.localizedDescription
                && controller.status.accessibilityLabel() == openError.localizedDescription,
            "DB-R1 actual error retains its entire diagnostic in the model and native name")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        document.fileURL = nil
        controller.showRecoveryStatus(document.currentSaveStateStatus, failed: false)
        // An actual Language menu invocation, without a fabricated missing notification.
        let previousServices = EditorServices.current
        defer { EditorServices.current = previousServices }
        let composition = AppDelegate()
        composition.installEditorServices()
        EditorServices.current?.noteActiveController(controller)
        document.showWindows()
        controller.refreshStatusDetails()
        _ = spinUntil(timeout: 1, "DB language fixture queued events settle") {
            controller.statusMetricsCaptureCount > 0
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let languagePopup = try requireValue(field("status.language.0"), "fixture: language field")
        let menuItem = composition.languages.languageMenuItems().first {
            ($0.representedObject as? String) != document.languageIdentifier && $0.action != nil
        }!
        let targetID = menuItem.representedObject as! String
        let targetTitle = composition.languages.displayName(identifier: targetID)
        let indentPopup = try requireValue(field("status.indent.0") as? NSPopUpButton, "fixture: indentation field")
        indentPopup.menu!.delegate?.menuNeedsUpdate?(indentPopup.menu!)
        indentPopup.menu!.update()
        let spaces = try requireValue(
            indentPopup.menu!.items.first { $0.representedObject as? String == "spaces" },
            "fixture: native indentation menu")
        check(
            NSApp.sendAction(spaces.action!, to: spaces.target, from: spaces)
                && controller.activeEditor.statusInfo.useTabs == false,
            "DB-R2 the actual native popup menu keeps its indentation dispatcher")
        indentPopup.menu!.delegate?.menuNeedsUpdate?(indentPopup.menu!)
        indentPopup.menu!.update()
        check(
            indentPopup.menu!.items.first { $0.representedObject as? String == "spaces" }?.state == .on,
            "DB-R2 native popup menus refresh their current checkmarks")
        // SR-1: each menu lists its own commands and nothing else.
        // A pull-down gives every item its own pop-up action; a command is an item with an object.
        let indentOwn = indentPopup.menu!.items.dropFirst().filter { !$0.isSeparatorItem && $0.isEnabled }
        check(
            indentOwn.map { $0.representedObject as? String ?? "" }
                == ["tabs", "spaces", "width.2", "width.3", "width.4", "width.8"]
                && indentPopup.menu!.items.dropFirst().filter { !$0.isSeparatorItem && !$0.isEnabled }.map(\.title)
                    == ["Indentation for this document"]
                && indentPopup.menu!.items.allSatisfy { $0.submenu == nil },
            "SR-1 the indentation menu lists tabs, spaces and widths only: \(indentOwn.map(\.title))")
        let eolPopup = try requireValue(field("status.eol.0") as? NSPopUpButton, "fixture: line-ending field")
        let encodingPopup = try requireValue(field("status.encoding.0") as? NSPopUpButton, "fixture: encoding field")
        encodingPopup.menu!.delegate?.menuNeedsUpdate?(encodingPopup.menu!)
        let encodingActions = Set(
            encodingPopup.menu!.items.dropFirst().filter { $0.representedObject != nil }.compactMap {
                $0.action.map(NSStringFromSelector)
            })
        let encodingHeadings = encodingPopup.menu!.items.dropFirst().filter {
            !$0.isSeparatorItem && $0.representedObject == nil
        }.map(\.title)
        check(
            encodingActions == ["reloadEncoding:", "convertEncoding:"]
                && encodingHeadings == ["Reload using encoding…", "Convert document encoding (save separately)"]
                && encodingPopup.menu!.items.allSatisfy { $0.submenu == nil },
            "SR-1 the encoding menu lists reloading and converting the encoding only: \(encodingActions)")
        controller.activeEditor.readOnly = true
        print(
            "DB_MENU_BEFORE", "delegate=", String(describing: eolPopup.menu!.delegate), "sameRow=",
            eolPopup.menu!.delegate === row, "auto=", eolPopup.menu!.autoenablesItems)
        eolPopup.menu!.delegate?.menuNeedsUpdate?(eolPopup.menu!)
        eolPopup.menu!.update()
        print(
            "DB_MENU_AFTER",
            eolPopup.menu!.items.map {
                (
                    $0.title, $0.representedObject as? String ?? "none",
                    NSStringFromSelector($0.action ?? #selector(NSObject.description)), $0.isEnabled
                )
            })
        check(!eolPopup.menu!.autoenablesItems, "DB-R2 native popup keeps explicit status-menu validation")
        check(
            eolPopup.menu!.items.dropFirst().filter { $0.representedObject != nil }.map {
                $0.representedObject as? String ?? ""
            } == ["LF", "CRLF", "CR"]
                && eolPopup.menu!.items.dropFirst().filter { $0.representedObject == nil }.map(\.title)
                    == ["Convert document line endings"] && eolPopup.menu!.items.allSatisfy { $0.submenu == nil },
            "SR-1 the line-ending menu lists the three conversions only")
        let conversionIDs: Set<String> = ["LF", "CRLF", "CR"]
        let conversions = eolPopup.menu!.items.filter {
            ($0.representedObject as? String).map(conversionIDs.contains) == true
        }
        check(
            conversions.count == 3 && conversions.allSatisfy { !$0.isEnabled },
            "DB-R2 native line-ending popup disables text changes for a read-only document")
        controller.activeEditor.readOnly = false
        eolPopup.menu!.delegate?.menuNeedsUpdate?(eolPopup.menu!)
        eolPopup.menu!.update()
        check(
            eolPopup.menu!.items.filter { ($0.representedObject as? String).map(conversionIDs.contains) == true }.count
                == 3
                && eolPopup.menu!.items.filter { ($0.representedObject as? String).map(conversionIDs.contains) == true }
                    .allSatisfy(\.isEnabled),
            "DB-R2 native line-ending popup restores writable validation")
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let beforeLanguage = languagePopup.title
        check(
            NSApp.sendAction(menuItem.action!, to: menuItem.target, from: menuItem)
                && document.languageIdentifier == targetID,
            "DB-R8 real Language menu invocation applies the intended profile")
        let eventUpdated = spinUntil(timeout: 1, "the Language status to reflect the lexer change event") {
            languagePopup.title == targetTitle
        }
        check(
            beforeLanguage != targetTitle && !controller.statusTimerActive && eventUpdated,
            "DB-R8 the coalesced lexer event updates Language with automatic polling disabled")
        let nextItem = try requireValue(
            composition.languages.languageMenuItems().first {
                ($0.representedObject as? String) != targetID && $0.action != nil
            }, "fixture: a second Language menu action")
        let nextID = try requireValue(nextItem.representedObject as? String, "fixture: second Language identifier")
        let nextTitle = composition.languages.displayName(identifier: nextID)
        check(
            NSApp.sendAction(nextItem.action!, to: nextItem.target, from: nextItem)
                && document.languageIdentifier == nextID && languagePopup.title == targetTitle,
            "DB-R8 a second real Language action changes the document before its queued event")
        controller.statusTimerTick()
        check(languagePopup.title == nextTitle, "DB-R8 an immediate polling tick presents the second Language profile")
        _ = document.editor.setSelectionAnchor(0, caret: 0)
        document.fileURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TEXTTANK_SUPPORT_DIRECTORY"]!)
            .appendingPathComponent("owned-positive-result.txt")
        controller.showRecoveryStatus(document.currentSaveStateStatus, failed: false)
        let positive =
            "Added 2 items to “\(String(repeating: "owned result destination ", count: 25))” in Reminders. Editor Undo does not remove them."
        // Drive the real composition callback with an owned result fixture. No reminders are sent.
        composition.automations.onQuietExportResult(positive)
        root.layoutSubtreeIfNeeded()
        check(
            controller.statusText == positive
                && controller.status.stringValue == "Items were added in Reminders. Editor Undo does not remove them.",
            "DB-R1 long positive action result keeps its action and external Undo limitation visible")
        check(
            controller.status.accessibilityLabel() == positive && controller.status.toolTip == positive,
            "DB-R1 positive-result callback retains the complete native name and tooltip")
        _ = document.editor.setSelectionAnchor(0, caret: 0)
        _ = document.editor.replaceSelection("selected")
        _ = document.editor.setSelectionAnchor(0, caret: 4)
        controller.refreshStatusDetails()
        _ = spinUntil(timeout: 2, "SR-1 the position tooltip follows the text") {
            field("status.position.0")?.toolTip?.contains(Strings.count(8, .character)) == true
        }
        check(
            field("status.position.0")?.toolTip?.contains(Strings.count(8, .character)) == true
                && field("status.position.0")?.accessibilityHelp()?.contains(Strings.count(8, .character)) == true,
            "SR-1 the position's statistics follow the document: \(field("status.position.0")?.toolTip ?? "nil")")
        root.layoutSubtreeIfNeeded()
        let selectionField = try requireValue(
            field("status.selection.0") as? NSPopUpButton, "fixture: the selection field is in the row")
        selectionField.menu!.delegate?.menuNeedsUpdate?(selectionField.menu!)
        check(
            selectionField.title == Strings.count(4, .character)
                && selectionField.menu!.items.dropFirst().map { $0.representedObject as? String ?? "" }
                    == ["clearSelection"],
            "SR-1 the selection field shows the selection and lists Clear Selection only")
        let selectedLine = String(
            format: Strings.text("status.fieldValue", "%@: %@"), StatusField.selectedCharacters.displayName,
            Strings.count(4, .character))
        check(
            controller.statusStatistics.contains(selectedLine)
                && field("status.position.0")?.toolTip?.contains(selectedLine) == true,
            "DB-R3 selection details are in the position tooltip whether or not their field fits")
        // At the minimum width a long message collapses fields; each stays reachable in More
        // with its own menu, the selection's Clear Selection included.
        controller.showTransientStatus(
            String(repeating: "A long owned message that takes the row. ", count: 8),
            compactMessage: String(repeating: "Compact owned words ", count: 30), seconds: 30, announce: false)
        window.setContentSize(NSSize(width: 800, height: 500))
        root.layoutSubtreeIfNeeded()
        let collapsed = row.collapsedFields
        check(
            collapsed.contains(.selectedCharacters) && collapsed.contains(.indent)
                && field("status.position.0")?.isHiddenOrHasHiddenAncestor == false,
            "DB-R5 at the minimum width fields collapse by priority and the position stays: \(collapsed)")
        let entries = row.overflowItems()
        let clear = entries.first { $0.title == selectedLine }?.submenu?.items.first {
            $0.representedObject as? String == "clearSelection"
        }
        check(
            entries.count == collapsed.count && clear != nil
                && entries.contains {
                    $0.submenu?.items.contains { $0.representedObject as? String == "spaces" } == true
                },
            "SR-1 every collapsed field keeps its own menu in More: \(entries.map(\.title))")
        if let clear, let action = clear.action {
            check(
                NSApp.sendAction(action, to: clear.target, from: clear)
                    && document.editor.selectionStart == document.editor.selectionEnd,
                "SR-1 Clear Selection from the More menu clears the selection")
        }
        let shown = descendants(row).compactMap { $0 as? NSControl }.filter {
            !$0.isHiddenOrHasHiddenAncestor && ($0 === controller.status || $0 is NSButton)
        }
        check(
            row.bounds.height == 28
                && shown.allSatisfy {
                    $0.convert($0.bounds, to: row).minX >= -0.5
                        && $0.convert($0.bounds, to: row).maxX <= row.bounds.width + 0.5
                },
            "DB-R5 the collapsed row is still one row with every visible control inside it")
        // DS-D11: the docked sidebar takes width beside the editor groups; the row still collapses.
        let host = controller.host
        if host.setSidebarShown(true, browser: composition.workspaceBrowser) {
            window.setContentSize(window.contentMinSize)
            root.layoutSubtreeIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            let beside = descendants(row).compactMap { $0 as? NSControl }.filter {
                !$0.isHiddenOrHasHiddenAncestor && ($0 === controller.status || $0 is NSButton)
            }
            check(
                host.isSidebarShown && row.bounds.height == 28 && row.bounds.width > 0
                    && field("status.position.0")?.isHiddenOrHasHiddenAncestor == false
                    && beside.allSatisfy {
                        $0.convert($0.bounds, to: row).minX >= -0.5
                            && $0.convert($0.bounds, to: row).maxX <= row.bounds.width + 0.5
                    },
                "DB-R5 with the sidebar docked at the minimum window width the row stays one row inside its tab: \(row.bounds.width)")
            host.setSidebarShown(false)
        } else {
            check(false, "fixture: the docked sidebar could be shown for the status-row width check")
        }
        try progressAndFollowUpChecks(composition: composition, controller: controller, document: document, row: row)
        try languageChooserChecks(
            composition: composition, controller: controller, document: document, row: row, field: field)
    }

    /// A long operation's progress and Cancel, and a message's follow-up, are controls in the row.
    @MainActor private static func progressAndFollowUpChecks(
        composition: AppDelegate, controller: EditorWindowController, document: TextDocument, row: StatusBadgeRow
    ) throws {
        let window = try requireValue(controller.hostWindow, "fixture: window")
        let root = try requireValue(window.contentView, "fixture: content")
        func control<View: NSView>(_ identifier: String, _ type: View.Type) -> View? {
            descendants(row).compactMap { $0 as? View }.first { $0.identifier?.rawValue == identifier }
        }
        @MainActor func said() -> [String] { NativeFixtureEnvironment.announcements }
        controller.showRecoveryStatus(document.currentSaveStateStatus, failed: false)
        window.setContentSize(NSSize(width: 1600, height: 500))
        root.layoutSubtreeIfNeeded()
        let center = StatusOperationCenter.shared
        let usualDelay = center.revealDelay
        defer { center.revealDelay = usualDelay }
        let bar = try requireValue(
            control(StatusBadgeRow.progressIdentifier, NSProgressIndicator.self), "fixture: progress indicator")
        let cancel = try requireValue(control(StatusBadgeRow.cancelIdentifier, NSButton.self), "fixture: Cancel")
        check(
            bar.isHidden && cancel.isHidden && row.progress == nil && usualDelay > 0,
            "SR-3 the row shows no progress while nothing is running")
        // An operation that ends at once is neither shown nor spoken.
        center.revealDelay = 30
        NativeFixtureEnvironment.announcements = []
        let quick = center.begin("Searching the document", in: document.editor, cancelLabel: "Cancel search") {}
        center.update(quick, done: 1, total: 2)
        center.end(quick, announce: "Search finished.")
        check(
            bar.isHidden && cancel.isHidden && said().isEmpty && center.operations.isEmpty,
            "SR-3 an operation that ends before the reveal delay shows and announces nothing: \(said())")
        center.revealDelay = 0
        var cancels = 0
        let search = center.begin("Searching the document", in: document.editor, cancelLabel: "Cancel search") {
            cancels += 1
        }
        root.layoutSubtreeIfNeeded()
        check(
            !bar.isHiddenOrHasHiddenAncestor && bar.isIndeterminate && !cancel.isHiddenOrHasHiddenAncestor
                && bar.isDescendant(of: row) && cancel.isDescendant(of: row),
            "SR-3 a running operation shows an indeterminate indicator and a Cancel button in the row")
        check(
            bar.accessibilityLabel() == "Searching the document" && cancel.title == "Cancel"
                && cancel.accessibilityLabel() == "Cancel search" && bar.controlSize == .small,
            "DS-70 the indicator says what is running and Cancel says what it cancels")
        check(said() == ["Searching the document."], "DS-72 the start of the operation is announced once: \(said())")
        center.update(search, done: 1, total: 4)
        center.update(search, done: 2, total: 4)
        check(
            !bar.isIndeterminate && bar.doubleValue == 0.5 && bar.minValue == 0 && bar.maxValue == 1
                && row.progress?.fraction == 0.5,
            "DS-51 reported progress makes the indicator determinate at the real fraction: \(bar.doubleValue)")
        check(said().count == 1, "DS-72 progress steps are not announced: \(said())")
        // Another document's operation is not this tab's; one that belongs to no document is.
        let elsewhere = TTEditor(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let other = center.begin("Replacing in the document", in: elsewhere, cancelLabel: "Cancel replacing") {}
        check(row.progress?.id == search, "SR-3 a tab shows only the operations on its own document")
        center.end(other)
        window.setContentSize(NSSize(width: 800, height: 500))
        root.layoutSubtreeIfNeeded()
        let visible = descendants(row).filter {
            !$0.isHiddenOrHasHiddenAncestor && ($0 === controller.status || $0 is NSButton || $0 is NSProgressIndicator)
        }
        check(
            row.bounds.height == 28
                && descendants(row).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "status.position.0" }?
                    .isHiddenOrHasHiddenAncestor == false
                && visible.allSatisfy {
                    $0.convert($0.bounds, to: row).minX >= -0.5
                        && $0.convert($0.bounds, to: row).maxX <= row.bounds.width + 0.5
                },
            "DB-R5 at the minimum width the indicator and Cancel fit in the one row with the position")
        cancel.performClick(nil)
        check(
            cancels == 1 && row.progress?.id == search,
            "SR-3 Cancel in the row calls the operation's own cancellation once")
        center.end(search, announce: "Search cancelled. Nothing was changed.")
        check(
            bar.isHidden && cancel.isHidden && row.progress == nil
                && said().last == "Search cancelled. Nothing was changed.",
            "SR-3 an ended operation leaves the row and a cancellation is announced: \(said())")
        let folder = center.begin("Searching the folder", cancelLabel: "Stop the folder search") {}
        check(
            row.progress?.title == "Searching the folder" && bar.isIndeterminate && !bar.isHidden
                && cancel.accessibilityLabel() == "Stop the folder search",
            "SR-3 an operation that belongs to no document is shown, indeterminate, in the tab on screen")
        center.end(folder)
        check(bar.isHidden && center.operations.isEmpty, "fixture: no operation is left running")
        window.setContentSize(NSSize(width: 1600, height: 500))
        root.layoutSubtreeIfNeeded()

        // The find bar's own search: a document searched in windows reports real progress in
        // the row, and the row's Cancel stops it with nothing selected.
        let finder = composition.searchController
        let usualUnits = finder.largeDocumentUnits, usualChunk = finder.largeChunkBytes
        finder.largeDocumentUnits = 64
        finder.largeChunkBytes = 32
        defer {
            finder.largeDocumentUnits = usualUnits
            finder.largeChunkBytes = usualChunk
        }
        document.editor.text = String(repeating: "alpha beta gamma\n", count: 60) + "needle\n"
        _ = document.editor.setSelectionAnchor(0, caret: 0)
        controller.refreshStatusDetails()
        var fractions: [Double] = []
        let observer = NotificationCenter.default.addObserver(
            forName: StatusOperationCenter.didChange, object: center, queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                if let fraction = row.progress?.fraction { fractions.append(fraction) }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        NativeFixtureEnvironment.announcements = []
        controller.findField.stringValue = "needle"
        controller.performFind(backwards: false, focusEditor: false)
        check(
            controller.inlineSearchPending && row.progress?.title == "Searching the document" && !bar.isHidden
                && cancel.accessibilityLabel() == "Cancel search",
            "SR-3 a find-bar search is a status-row operation with a Cancel button while it runs")
        _ = spinUntil(timeout: 5, "SR-3 the find-bar search finishes") { !controller.inlineSearchPending }
        check(
            document.editor.selectedText == "needle" && row.progress == nil && bar.isHidden
                && center.operations.isEmpty,
            "SR-3 the finished search selects its match and leaves the row")
        check(
            !fractions.isEmpty && fractions == fractions.sorted() && fractions.allSatisfy { $0 > 0 && $0 <= 1 },
            "DS-51 a search of a large document reports its real progress to the row: \(fractions.prefix(4))… of \(fractions.count)")
        check(
            said().first == "Searching the document." && said().last == "Search finished. A match is selected."
                && said().count == 2,
            "DS-72 the search is announced when it starts and when it finishes, and not in between: \(said())")
        _ = document.editor.setSelectionAnchor(0, caret: 0)
        NativeFixtureEnvironment.announcements = []
        controller.performFind(backwards: false, focusEditor: false)
        try require(controller.inlineSearchPending && !cancel.isHidden, "fixture: a second find-bar search is running")
        cancel.performClick(nil)
        check(
            !controller.inlineSearchPending && row.progress == nil && center.operations.isEmpty,
            "SR-3 Cancel in the row cancels the find-bar search at once")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        check(
            document.editor.selectionStart == 0 && document.editor.selectionEnd == 0
                && said() == ["Searching the document.", "Search cancelled. Nothing was changed."],
            "SR-3 a cancelled search selects nothing and says so: \(said())")
        controller.findField.stringValue = ""

        // A bulk change: the message gives the counts and Show Changes is a real button.
        let followUp = try requireValue(
            control(StatusBadgeRow.followUpIdentifier, NSButton.self), "fixture: follow-up button")
        check(followUp.isHidden && !controller.hasStatusFollowUp, "SR-4 no follow-up is offered without a message that has one")
        document.editor.text = "b\na\nc\n"
        NativeFixtureEnvironment.announcements = []
        let capture = try requireValue(BulkChangeCapture(document.editor, name: "Sort Lines"), "fixture: bulk capture")
        document.editor.text = "a\nb\nc\n"
        capture.finish()
        root.layoutSubtreeIfNeeded()
        let receipt = try requireValue(document.bulkReceipt, "fixture: the bulk change left a receipt")
        check(
            controller.statusText == receipt.summary && receipt.summary.hasPrefix("Sort Lines · ")
                && !receipt.summary.localizedCaseInsensitiveContains("menu")
                && !receipt.summary.contains("Show Changes"),
            "SR-4 the bulk-change message gives the counts and no instruction: \(controller.statusText)")
        check(
            !followUp.isHiddenOrHasHiddenAncestor && followUp.title == "Show Changes" && followUp.isDescendant(of: row)
                && followUp.accessibilityLabel() == "Show the changes made by Sort Lines" && followUp.isEnabled,
            "SR-4 Show Changes is a button in the row, named for what it shows")
        check(
            said() == [receipt.summary + " Show Changes is a button in the status bar."],
            "DS-72 the message is announced once, with where its follow-up is: \(said())")
        let comparisons = composition.compare
        let showedWindows = comparisons.showWindows
        comparisons.showWindows = false
        defer { comparisons.showWindows = showedWindows }
        let openBefore = comparisons.windows.count
        followUp.performClick(nil)
        _ = spinUntil(timeout: 5, "SR-4 Show Changes opens the comparison") {
            comparisons.windows.count == openBefore + 1
        }
        check(
            comparisons.windows.count == openBefore + 1 && NSApp.modalWindow == nil,
            "SR-4 the Show Changes button opens the before-and-after comparison, with no alert")
        comparisons.windows.last?.close()
        controller.refreshStatusDetails()
        check(!followUp.isHidden, "SR-4 the follow-up stays while the text is as the change left it")
        _ = spinUntil(timeout: 6, "SR-4 the transient message returns to the save state") {
            controller.statusText == document.currentSaveStateStatus
        }
        controller.refreshStatusDetails()
        check(
            !followUp.isHidden && controller.statusText == document.currentSaveStateStatus,
            "SR-4 the button outlasts the message, so it does not have to be caught in four seconds")
        _ = document.editor.setSelectionAnchor(0, caret: 0)
        _ = document.editor.replaceSelection("x")
        controller.refreshStatusDetails()
        check(
            followUp.isHidden && !controller.hasStatusFollowUp,
            "SR-4 the follow-up is withdrawn when the text changes again")
        // A second follow-up: a saved language that is gone offers the chooser.
        var presented = 0
        composition.languages.presentChooser = { panel, _ in
            presented += 1
            panel.form.close()
        }
        defer { composition.languages.presentChooser = { $0.show(parent: $1) } }
        controller.showUnavailableLanguage()
        check(
            !followUp.isHidden && followUp.title == "Choose Language…"
                && controller.statusText == "The saved language profile is unavailable.",
            "SR-4 an unavailable language offers Choose Language… as a button")
        followUp.performClick(nil)
        check(presented == 1, "SR-4 that button opens the language chooser")
        controller.refreshStatusDetails()
        check(followUp.isHidden, "SR-4 a follow-up that no longer applies leaves the row")
        controller.showRecoveryStatus(document.currentSaveStateStatus, failed: false)
    }

    /// The language field opens the filterable chooser. The chooser is driven through its real
    /// controls; the injected presenter keeps the sheet off the desktop.
    @MainActor private static func languageChooserChecks(
        composition: AppDelegate, controller: EditorWindowController, document: TextDocument, row: StatusBadgeRow,
        field: (String) -> NSButton?
    ) throws {
        let languages = composition.languages
        var presented: [(panel: ChoicePanel, parent: NSWindow?)] = []
        languages.presentChooser = { panel, parent in
            presented.append((panel, parent))
            panel.refresh()
        }
        defer { languages.presentChooser = { $0.show(parent: $1) } }
        controller.showRecoveryStatus(document.currentSaveStateStatus, failed: false)
        controller.hostWindow?.setContentSize(NSSize(width: 1600, height: 500))
        controller.hostWindow?.contentView?.layoutSubtreeIfNeeded()
        let languageField = try requireValue(field("status.language.0"), "fixture: language field")
        @MainActor func type(_ text: String, in panel: ChoicePanel) {
            panel.filter.stringValue = text
            panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: panel.filter))
        }
        @MainActor func pressReturn(in panel: ChoicePanel) -> Bool {
            panel.control(panel.filter, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        }
        // A name that suggests no language, so nothing is "detected" yet.
        document.fileURL = document.fileURL?.deletingLastPathComponent().appendingPathComponent("owned-undetected.zzz")
        check(
            document.applyLanguage("ruby", using: languages) && languages.detectedLanguage() == nil,
            "fixture: a document highlighted as Ruby whose name suggests no language")
        let recentBefore = languages.recentsStore.ids
        languageField.performClick(nil)
        let first = try requireValue(presented.last, "SR-2 clicking the language field opens the chooser")
        check(
            presented.count == 1 && first.parent === controller.hostWindow && languages.chooser === first.panel
                && first.panel.form.window.title == "Choose Language",
            "SR-2 the chooser is one ChoicePanel, presented as a sheet on the workspace window")
        let all = first.panel.displayedRows
        let internalIDs: Set<String> = ["errorlist", "escseq", "searchResult"]
        let menuIDs = Set(languages.languageMenuItems().compactMap { $0.representedObject as? String })
        print("NOTE internal profiles in the menu: \(internalIDs.intersection(menuIDs).sorted())")
        check(
            !all.contains { internalIDs.contains($0.id) } && !internalIDs.intersection(menuIDs).isEmpty
                && all.count == menuIDs.count - internalIDs.intersection(menuIDs).count,
            "SR-2 internal profiles are left out of the chooser and stay in the Syntax Highlighting menu")
        let unmarked = all.filter { $0.accessory.isEmpty || $0.accessory == "Current" }
        check(
            unmarked.map(\.title) == unmarked.map(\.title).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                && unmarked.count > 60 && Set(all.map(\.id)).count == all.count,
            "SR-2 the chooser lists every language once, alphabetically by display name")
        check(
            all.first { $0.id == "ruby" }?.accessory.hasSuffix("Current") == true,
            "SR-2 the document's language is marked as the current one")
        type("py", in: first.panel)
        check(
            first.panel.displayedRows.map(\.id) == ["python"] && first.panel.selectedID == "python",
            "SR-2 typing py narrows the chooser to Python: \(first.panel.displayedRows.map(\.title))")
        check(pressReturn(in: first.panel), "fixture: Return is handled by the chooser")
        check(
            document.languageIdentifier == "python" && languages.chooser == nil,
            "SR-2 Return applies the selected language and closes the chooser")
        _ = spinUntil(timeout: 2, "SR-2 the language field follows the chosen language") {
            languageField.title == "Python"
        }
        check(languageField.title == "Python", "SR-2 the language field shows the chosen language: \(languageField.title)")
        check(
            NativeFixtureEnvironment.announcements.contains("Syntax highlighting set to Python."),
            "DS-72 choosing a language is announced")
        check(
            languages.recentsStore.ids.first == "python" && languages.recentsStore.ids.count <= 5
                && languages.recentsStore.ids != recentBefore,
            "SR-2 the chosen language is remembered as the most recent")
        // Next time: recents first (there is no detected language for this name), and a
        // relaunch reads the same list from private storage.
        languageField.performClick(nil)
        let second = try requireValue(presented.last, "fixture: the chooser opens again")
        check(
            presented.count == 2 && second.panel !== first.panel
                && second.panel.displayedRows.first?.id == "python"
                && second.panel.displayedRows.first?.accessory == "Recent · Current",
            "SR-2 the chosen language is listed under recents next time: \(second.panel.displayedRows.prefix(3).map { $0.title + " " + $0.accessory })")
        check(
            LanguageRecentsStore(url: languages.recentsStore.url).ids == languages.recentsStore.ids,
            "SR-2 recently chosen languages are read back from private storage")
        type("ruby", in: second.panel)
        check(second.panel.selectedID == "ruby", "fixture: another language is selected in the chooser")
        let recentBeforeCancel = languages.recentsStore.ids
        // Escape is the Cancel button's key equivalent.
        let cancel = try requireValue(
            descendants(second.panel.form.window.contentView!).compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == LanguageController.chooserIdentifier + ".cancel"
            }, "fixture: the chooser's Cancel button")
        check(cancel.keyEquivalent == "\u{1b}", "SR-2 Escape is the chooser's Cancel")
        cancel.performClick(nil)
        check(
            document.languageIdentifier == "python" && languages.chooser == nil
                && languages.recentsStore.ids == recentBeforeCancel && languageField.title == "Python",
            "SR-2 Escape cancels the chooser with nothing changed")
        // A name that says what the file is: detected first, then recents, then the rest.
        document.fileURL = document.fileURL?.deletingLastPathComponent().appendingPathComponent("owned-detected.json")
        languageField.performClick(nil)
        let third = try requireValue(presented.last, "fixture: the chooser opens for a .json name")
        check(
            third.panel.displayedRows.prefix(2).map(\.id) == ["json", "python"]
                && third.panel.displayedRows.first?.accessory == "Detected"
                && third.panel.displayedRows.first?.title == "JSON",
            "SR-2 the detected language is first, then the recently chosen: \(third.panel.displayedRows.prefix(3).map { $0.title + " " + $0.accessory })")
        type("zzzz-no-such-language", in: third.panel)
        check(
            third.panel.displayedRows.isEmpty && third.panel.showsEmptyMessage
                && third.panel.emptyMessage == "No matching languages",
            "DS-36 a filter that matches nothing says so")
        _ = pressReturn(in: third.panel)
        check(
            document.languageIdentifier == "python" && languages.chooser === third.panel,
            "SR-2 Return on an empty list leaves the language as it was and the chooser open")
        type("", in: third.panel)
        check(pressReturn(in: third.panel) && document.languageIdentifier == "json", "SR-2 Return applies the detected language")
        _ = spinUntil(timeout: 2, "SR-2 the language field shows the display name") { languageField.title == "JSON" }
        // One name per language in the field, the chooser and the menu (DS-20, DS-24).
        let menuTitles = Dictionary(
            languages.languageMenuItems().compactMap { item in (item.representedObject as? String).map { ($0, item.title) } },
            uniquingKeysWith: { first, _ in first })
        check(
            languageField.title == "JSON" && menuTitles["json"] == "JSON" && menuTitles["ini"] == "INI"
                && menuTitles["mssql"] == "Microsoft SQL" && menuTitles["normal"] == "Plain Text"
                && languages.displayName(identifier: "mssql") == "Microsoft SQL",
            "SR-2 lexer identifiers are shown by their proper names: \(languageField.title), \(menuTitles["json"] ?? "nil"), \(menuTitles["mssql"] ?? "nil")")
        check(
            all.allSatisfy { menuTitles[$0.id] == $0.title },
            "SR-2 the chooser and the Syntax Highlighting menu use the same display name for every language")
        check(
            !menuTitles.values.contains { ["json", "ini", "mssql", "registry", "ErrorList"].contains($0) },
            "DS-24 no raw lexer identifier is shown as a language name")
        let languageMenu = languages.menu()
        check(
            languageMenu.items.first?.title == "Choose Language…"
                && languageMenu.items.first?.action == #selector(LanguageController.chooseLanguage(_:))
                && languageMenu.items.first?.target === languages
                && languageMenu.items.filter { !$0.isSeparatorItem }.count <= 20,
            "SR-2 the Syntax Highlighting menu starts with Choose Language… and stays within DS-23")
        let before = presented.count
        if let item = languageMenu.items.first, let action = item.action {
            check(languages.validateMenuItem(item), "DS-21 Choose Language… is enabled while a document is active")
            _ = NSApp.sendAction(action, to: item.target, from: item)
        }
        check(
            presented.count == before + 1 && presented.last?.parent === controller.hostWindow,
            "SR-2 the menu's Choose Language… opens the same chooser")
        presented.last?.panel.form.close()
        check(languages.chooser == nil, "fixture: the chooser is closed")
    }
}
