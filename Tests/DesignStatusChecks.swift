// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

enum DesignStatusChecks {
    @MainActor private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    @MainActor static func run() throws {
        let document = TextDocument()
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        defer { document.close() }
        let controller = document.windowControllers[0] as! EditorWindowController
        controller.statusTimerInterval = nil
        controller.visibilityChanged()
        let window = controller.window!
        window.setContentSize(NSSize(width: 800, height: 500))
        let root = window.contentView!
        root.layoutSubtreeIfNeeded()
        let row = descendants(root).first { $0 is StatusBadgeRow }!
        let popups = descendants(row).compactMap { $0 as? NSPopUpButton }
        check(popups.count == 5, "DB-R1 five unselected trailing fields use native pop-up controls")
        check(row.bounds.height <= 26, "DB-R1 status layout is one row at minimum content width")
        check(controller.status.isDescendant(of: row), "DB-R1 save-state label shares the same status row")
        check(
            !controller.statusText.contains("Incomplete preview"),
            "DB-R4 preview disclosure is outside operational status")
        for popup in popups {
            check(
                !popup.isBordered && popup.frame.height >= 20,
                "DB-R6 native status popup is borderless and at least twenty points high")
        }
        controller.refreshStatusDetails()
        let position = controller.statusOptionsMenu(.position)!
        check(
            position.items.contains { $0.title.contains("character") },
            "DB-R3 character totals are reachable in the position menu")
        check(
            position.items.contains { $0.title.contains("line") && $0.action == nil },
            "DB-R3 line totals are reachable in the position menu")
        check(
            position.items.contains {
                $0.submenu?.items.contains { $0.representedObject as? String == "bookmarkToggle" } == true
            },
            "DB-R3 bookmark commands remain reachable from the position menu")
        let items = [
            StatusItem(field: .position, text: "Ln 1, Col 1"),
            .init(field: .language, text: String(repeating: "Long language name ", count: 10)),
            .init(field: .indent, text: "Spaces: 4"), .init(field: .encoding, text: "UTF-8"),
            .init(field: .eol, text: "LF")
        ]
        (row as! StatusBadgeRow).update(items)
        root.layoutSubtreeIfNeeded()
        let visible = descendants(row).compactMap { $0 as? NSControl }.filter {
            !$0.isHiddenOrHasHiddenAncestor && ($0 === controller.status || $0 is NSPopUpButton)
        }
        check(row.bounds.height <= 26, "DB-R5 a long language name collapses instead of wrapping")
        check(
            visible.allSatisfy {
                $0.convert($0.bounds, to: row).minX >= -0.5
                    && $0.convert($0.bounds, to: row).maxX <= row.bounds.width + 0.5
            },
            "DB-R5 every visible control remains within the minimum-width row")
        let visibleLanguage = descendants(row).compactMap { $0 as? NSPopUpButton }.first {
            $0.identifier?.rawValue == "status.language.0"
        }
        check(
            visibleLanguage?.isHiddenOrHasHiddenAncestor == true,
            "DB-R5 long language is the first collapsed field")
        let languageIdentity = visibleLanguage.map(ObjectIdentifier.init)
        window.setContentSize(NSSize(width: 2400, height: 500))
        root.layoutSubtreeIfNeeded()
        check(
            visibleLanguage?.isHiddenOrHasHiddenAncestor == false,
            "DB-R5 collapsed language returns when the owned window widens")
        check(
            visibleLanguage.map(ObjectIdentifier.init) == languageIdentity,
            "DB-R5 resizing retains the existing native field identity")
        let visibleFields = descendants(row).compactMap { $0 as? NSPopUpButton }.filter {
            !$0.isHiddenOrHasHiddenAncestor
        }
        for popup in visibleFields {
            check(
                window.makeFirstResponder(popup) && window.firstResponder === popup,
                "DB-R6 native status field accepts keyboard focus: \(popup.identifier!.rawValue)")
            let exposed = NSAccessibility.unignoredChildrenForOnlyChild(from: popup)
            let cell = exposed.first as? NSObject
            let selector = NSSelectorFromString("accessibilityLabel")
            let name =
                cell?.responds(to: selector) == true
                ? cell?.perform(selector)?.takeUnretainedValue() as? String : nil
            check(
                name?.contains("Show options.") == true,
                "DB-R6 actual native cell name states that the field opens options")
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
        let languagePopup = descendants(row).compactMap { $0 as? NSPopUpButton }.first {
            $0.identifier?.rawValue == "status.language.0"
        }!
        let menuItem = composition.languages.languageMenuItems().first {
            ($0.representedObject as? String) != document.languageIdentifier && $0.action != nil
        }!
        let targetID = menuItem.representedObject as! String
        let targetTitle = composition.languages.profile(identifier: targetID)!.title
        let indentPopup = descendants(row).compactMap { $0 as? NSPopUpButton }.first {
            $0.identifier?.rawValue == "status.indent.0"
        }!
        indentPopup.menu!.delegate?.menuNeedsUpdate?(indentPopup.menu!)
        indentPopup.menu!.update()
        let spaces = try requireValue(
            indentPopup.menu!.items.first { $0.representedObject as? String == "spaces" },
            "fixture: native indentation menu")
        check(
            NSApp.sendAction(spaces.action!, to: spaces.target, from: spaces)
                && controller.activeEditor.statusInfo["useTabs"]?.boolValue == false,
            "DB-R2 the actual native popup menu keeps its indentation dispatcher")
        indentPopup.menu!.delegate?.menuNeedsUpdate?(indentPopup.menu!)
        indentPopup.menu!.update()
        check(
            indentPopup.menu!.items.first { $0.representedObject as? String == "spaces" }?.state == .on,
            "DB-R2 native popup menus refresh their current checkmarks")
        let eolPopup = descendants(row).compactMap { $0 as? NSPopUpButton }.first {
            $0.identifier?.rawValue == "status.eol.0"
        }!
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
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        let afterEvent = languagePopup.title
        controller.statusTimerTick()
        let afterTick = languagePopup.title
        print(
            "DB_TIMER_LANGUAGE", "before=", beforeLanguage, "afterEvents=", afterEvent, "afterTick=", afterTick,
            "expected=", targetTitle)
        check(afterTick == targetTitle, "DB-R8 actual polling tick presents the Language menu profile")
        check(
            afterEvent != targetTitle,
            "DB-R8 real Language action has no status event on this native fixture before polling")
    }
}
