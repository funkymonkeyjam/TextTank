@testable import TextTankCore
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
@testable import TextTankRuntime
import EditorBridge
import NativeSearch

@MainActor enum DesignSettingsChecks {
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func nativeText(_ value: Any, selector name: String, argument: String? = nil) -> String {
        guard let object = value as? NSObject else { return "" }
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return "" }
        let result = argument.map { object.perform(selector, with: $0) } ?? object.perform(selector)
        return result?.takeUnretainedValue() as? String ?? ""
    }
    static func checkNativeButtons(_ window: NSWindow) {
        guard let content = window.contentView else {
            check(false, "DG fixture owns form content")
            return
        }
        let ids: Set<String> = [
            "settings.shortcuts.apply", "settings.close", "settings.reset", "settings.font.choose", "automation.create",
            "automation.edit",
            "automation.rules", "automation.duplicate", "automation.delete", "automation.favorite", "automation.json"
        ]
        for button in descendants(content).compactMap({ $0 as? NSButton }).filter({
            let id = $0.identifier?.rawValue ?? ""
            return ids.contains(id) || id.hasPrefix("macro.manager.") || id.hasPrefix("run.manager.")
        }) {
            let exposed = NSAccessibility.unignoredChildrenForOnlyChild(from: button)
            let expected = button.accessibilityLabel() ?? ""
            let names = exposed.flatMap { element in
                [
                    nativeText(element, selector: "accessibilityLabel"),
                    nativeText(element, selector: "accessibilityTitle")
                ]
            }
            print("AX_FORM_ELEMENT", button.identifier!.rawValue, "expected=", expected, "actual=", names)
            check(
                !expected.isEmpty && expected != button.title && names.contains(expected),
                "DG actual unignored form action exposes its scoped name: \(button.identifier!.rawValue)")
        }
    }
    static func button(_ id: String, _ window: NSWindow) throws -> NSButton {
        let content = try requireValue(window.contentView, "DG fixture: owned content")
        return try requireValue(
            descendants(content).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == id },
            "DG fixture: native button \(id)")
    }
    static func table(_ window: NSWindow) throws -> NSTableView {
        try requireValue(
            descendants(window.contentView!).compactMap { $0 as? NSTableView }.first, "DG fixture: manager table")
    }
    static func field(_ id: String, _ window: NSWindow) throws -> NSTextField {
        try requireValue(
            descendants(window.contentView!).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == id },
            "DG fixture: native field \(id)")
    }
    static func type(_ value: String, in window: NSWindow) {
        for character in value {
            let text = String(character)
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0)!
            window.sendEvent(event)
        }
    }
    static func choicePanelChecks() throws {
        func prepared(_ suffix: String, count: @escaping () -> Void) -> ChoicePanel {
            let panel = ChoicePanel(
                title: "Owned Choice", identifier: "fixture.choice." + suffix, action: "Choose",
                filterLabel: "Filter owned choices")
            panel.rows = { [.init(id: "first", title: "First item"), .init(id: "second", title: "Second item")] }
            panel.choose = { id in
                check(id == "second", "DG explicit chooser activation resolves the filtered stable identity")
                count()
                return true
            }
            panel.show()
            panel.filter.selectText(nil)
            type("second", in: panel.form.window)
            return panel
        }
        var invocations = 0
        let cancelled = prepared("cancel") { invocations += 1 }
        check(
            cancelled.table.numberOfRows == 1
                && (cancelled.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTextField)?.stringValue
                    == "Second item",
            "DG typing in the real filter narrows the actual native rows")
        cancelled.form.window.makeFirstResponder(cancelled.table)
        check(invocations == 0, "DG typing and leaving a chooser filter never invokes its action")
        try button("fixture.choice.cancel.cancel", cancelled.form.window).performClick(nil)
        check(invocations == 0 && !cancelled.form.window.isVisible, "DG chooser Cancel never invokes an action")
        for action in ["button", "return", "table"] {
            let before = invocations
            let panel = prepared(action) { invocations += 1 }
            if action == "button" {
                try button("fixture.choice.button.choose", panel.form.window).performClick(nil)
            } else {
                if action == "table" { panel.form.window.makeFirstResponder(panel.table) }
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: panel.form.window.windowNumber, context: nil, characters: "\r",
                    charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
                panel.form.window.sendEvent(event)
            }
            check(
                invocations == before + 1 && !panel.form.window.isVisible,
                "DG actual chooser \(action) activation invokes exactly once")
        }
    }
    static func settingsFrameChecks(root: URL) throws {
        let suite = "TextTankDesignSettingsFrames-" + UUID().uuidString
        let defaults = try requireValue(UserDefaults(suiteName: suite), "DG fixture: private frame defaults")
        let previous = WindowFrames.defaults
        WindowFrames.defaults = defaults
        defer {
            WindowFrames.defaults = previous
            defaults.removePersistentDomain(forName: suite)
        }
        try maintenanceSheetChecks(root: root)
        let controller = SettingsController(url: root.appendingPathComponent("design-settings-frames.json"))
        controller.showSettings(nil)
        let form = try requireValue(FormPanel.visible.last, "DG fixture: Settings frame")
        form.window.setContentSize(form.window.contentMinSize)
        form.window.contentView!.layoutSubtreeIfNeeded()
        let content = form.window.contentView!
        let controls = descendants(content).compactMap { $0 as? NSControl }.filter { !$0.isHidden }
        let clipped = controls.filter { control in
            let rect = control.convert(control.bounds, to: content)
            return rect.minX < -1 || rect.minY < -1 || rect.maxX > content.bounds.maxX + 1
                || rect.maxY > content.bounds.maxY + 1
        }
        print(
            "DG_MINIMUM_SETTINGS", content.bounds, "outside=",
            clipped.map { ($0.identifier?.rawValue ?? String(describing: Swift.type(of: $0)), $0.frame) })
        check(clipped.isEmpty, "DG Settings labels, fields and actions fit its minimum content size")
        _ = spinUntil("Settings minimum layout settles into its constrained window frame") {
            form.window.contentRect(forFrameRect: form.window.frame).height >= content.bounds.height - 1
        }
        let screen = try requireValue(NSScreen.screens.first, "DG fixture: native screen").visibleFrame
        form.window.setFrameOrigin(NSPoint(x: screen.minX + 25, y: screen.minY + 25))
        let saved = form.window.frame
        let close = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: form.window.windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w",
            isARepeat: false, keyCode: 13)!
        // The CLI has no key/main window. Bind the unchanged real File > Close metadata
        // to this owned window, rather than pretending to test global physical dispatch.
        let closeMenu = NSMenu()
        let closeItem = NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeItem.target = form.window
        closeMenu.addItem(closeItem)
        check(
            closeMenu.performKeyEquivalent(with: close) && !form.window.isVisible,
            "DG Command-W closes the owned Settings window through the native Close menu action")
        if form.window.isVisible { form.close() }
        controller.showSettings(nil)
        let reopened = try requireValue(FormPanel.visible.last, "DG fixture: restored Settings frame")
        print(
            "DG_RESTORED_SETTINGS", "saved=", saved, "actual=", reopened.window.frame, "stored=",
            defaults.string(forKey: WindowFrames.defaultsKey("TextTank.Settings")) ?? "nil")
        check(
            reopened.window.frame == saved
                && defaults.string(forKey: WindowFrames.defaultsKey("TextTank.Settings")) != nil,
            "DG Settings restores its last frame from the explicitly injected private defaults")
        let escape = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: reopened.window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        reopened.window.sendEvent(escape)
        check(
            !reopened.window.isVisible && !FileManager.default.fileExists(atPath: controller.url.path),
            "DG Escape closes actual Settings without saving pending changes")
        if reopened.window.isVisible { reopened.close() }
        controller.showSettings(nil)
        let live = try requireValue(FormPanel.visible.last, "fixture: live Settings")
        let size = try field("settings.font.size", live.window), font = try button("settings.font.choose", live.window)
        check(
            font.acceptsFirstResponder && font.accessibilityLabel()?.contains("Settings") == true,
            "the native editor font button exposes a scoped name and accepts keyboard focus")
        size.stringValue = "18.75"
        _ = NSApp.sendAction(size.action!, to: size.target, from: size)
        let savedBytes = try Data(contentsOf: controller.url)
        let decoded = try EditorSettings.decode(savedBytes)
        check(
            live.window.isVisible && controller.value.fontSize == 18.75 && decoded.fontSize == 18.75,
            "committing fractional size persists it without closing modeless Settings")
        size.stringValue = "73"
        _ = NSApp.sendAction(size.action!, to: size.target, from: size)
        let unchanged = try Data(contentsOf: controller.url)
        check(
            size.stringValue == "73" && live.window.isVisible && unchanged == savedBytes,
            "invalid font size keeps the draft and previous settings bytes")
        font.performClick(nil)
        size.stringValue = "31.75"
        _ = NSApp.sendAction(size.action!, to: size.target, from: size)
        font.performClick(nil)
        check(
            NSFontManager.shared.selectedFont?.pointSize == 31.75 && controller.value.fontSize == 31.75,
            "reopening the native Font panel retains the live field's latest fractional size")
        NSFontManager.shared.fontPanel(false)?.performClose(nil)
        live.close()
    }
    static func maintenanceSheetChecks(root: URL) throws {
        let url = root.appendingPathComponent("maintenance-settings.json")
        let controller = SettingsController(url: url)
        var initial = EditorSettings()
        initial.tabWidth = 13
        try controller.save(initial)
        let initialBytes = try Data(contentsOf: url)
        let existing = Set(FormPanel.visible.map(ObjectIdentifier.init))
        defer { for f in FormPanel.visible where !existing.contains(ObjectIdentifier(f)) { f.close() } }
        controller.showSettings(nil)
        let form = try requireValue(FormPanel.visible.last, "Settings maintenance fixture")
        let width = try field("settings.width", form.window)
        width.stringValue = "999"
        let reset = try button("settings.reset", form.window)
        func sheet(_ parent: FormPanel, action: NSButton) throws -> NSWindow {
            action.performClick(nil)
            let result = try requireValue(parent.window.attachedSheet, "owned Settings maintenance sheet")
            check(
                result.sheetParent === parent.window && NSApp.modalWindow == nil,
                "only Settings is blocked by maintenance confirmation")
            return result
        }
        func choose(_ title: String, in sheet: NSWindow) throws {
            let item = try requireValue(
                descendants(sheet.contentView!).compactMap { $0 as? NSButton }.first { $0.title == title },
                "Settings maintenance choice")
            check(item.hasDestructiveAction == (title != "Cancel"), "Settings marks the deliberate destructive button")
            item.performClick(nil)
            _ = spinUntil("Settings maintenance sheet finished") { sheet.sheetParent == nil && !sheet.isVisible }
        }
        let first = try sheet(form, action: reset)
        reset.performClick(nil)
        check(
            form.window.sheets.count == 1 && form.window.attachedSheet === first,
            "duplicate Reset cannot enqueue another confirmation")
        try choose("Cancel", in: first)
        check(
            try Data(contentsOf: url) == initialBytes && width.stringValue == "999" && form.acceptsActions,
            "Cancel preserves exact saved settings and invalid draft")
        // Setting the user-immutable flag on this owned regular file allows reading the
        // original bytes but makes the atomic replacement fail at the actual save boundary.
        do {
            try require(chflags(url.path, UInt32(UF_IMMUTABLE)) == 0, "owned immutable settings fixture")
            defer { _ = chflags(url.path, 0) }
            try choose("Reset Defaults", in: sheet(form, action: reset))
            check(
                try Data(contentsOf: url) == initialBytes && width.stringValue == "999" && controller.value == initial
                    && !form.validation.isHidden,
                "failed confirmed Reset retains original bytes, applied values and unfinished draft")
        }
        let stale = try sheet(form, action: reset)
        var changed = initial
        changed.tabWidth = 23
        try SettingsController(url: url).save(changed)
        let changedBytes = try Data(contentsOf: url)
        try choose("Reset Defaults", in: stale)
        check(
            try Data(contentsOf: url) == changedBytes && width.stringValue == "999" && !form.validation.isHidden,
            "stale sheet cannot overwrite a different controller's settings or discard the draft")
        form.close()
        controller.showSettings(nil)
        let reopened = try requireValue(FormPanel.visible.last, "reopened Settings maintenance fixture")
        let secondReset = try button("settings.reset", reopened.window)
        let closing = try sheet(reopened, action: secondReset)
        reopened.close()
        _ = spinUntil("parent closed Settings maintenance sheet") { !closing.isVisible }
        check(
            try Data(contentsOf: url) == changedBytes && !reopened.window.isVisible,
            "closing the parent cancels its pending destructive action")
        controller.showSettings(nil)
        let third = try requireValue(FormPanel.visible.last, "fresh Settings reset fixture")
        // Change only optional/unknown representation, then let two menu commands bring the
        // effective setting back to its original value and refresh the live store baseline.
        var normalized = controller.value
        normalized.autoIndent = true
        try controller.save(normalized)
        let staleMetadata = try sheet(third, action: button("settings.reset", third.window))
        var metadata = try requireValue(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], "owned extended settings")
        metadata["unrecognizedMetadata"] = "retained"
        try JSONSerialization.data(withJSONObject: metadata).write(to: url)
        controller.toggleAutoIndent(nil)
        controller.toggleAutoIndent(nil)
        let metadataBytes = try Data(contentsOf: url)
        try choose("Reset Defaults", in: staleMetadata)
        check(
            try Data(contentsOf: url) == metadataBytes && controller.value == normalized && !third.validation.isHidden,
            "sheet retains original disk baseline when menu round trip refreshes current store")

        try choose("Reset Defaults", in: sheet(third, action: button("settings.reset", third.window)))
        check(
            SettingsStore(url: url).value == EditorSettings() && !third.window.isVisible,
            "confirmed Reset saves defaults and refreshes Settings")
        FormPanel.visible.last?.close()
        let damaged = Data("damaged settings".utf8)
        try damaged.write(to: url)
        controller.showSettings(nil)
        let repair = try requireValue(FormPanel.visible.last, "damaged Settings fixture")
        let repairButton = try button("settings.repair", repair.window)
        let repairDraft = try field("settings.width", repair.window)
        repairDraft.stringValue = "unfinished"
        let cancelRepair = try sheet(repair, action: repairButton)
        try button("settings.reset", repair.window).performClick(nil)
        check(
            repair.window.sheets.count == 1 && repair.window.attachedSheet === cancelRepair,
            "repair cannot queue an incompatible reset")
        try choose("Cancel", in: cancelRepair)
        check(
            try Data(contentsOf: url) == damaged && repairDraft.stringValue == "unfinished",
            "cancelled Repair keeps original damaged bytes and draft")
        try choose("Back Up and Repair", in: sheet(repair, action: repairButton))
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter {
            $0.lastPathComponent.contains("unreadable") && (try? Data(contentsOf: $0)) == damaged
        }
        check(
            backups.count == 1 && SettingsStore(url: url).loadError == nil,
            "confirmed Repair creates exactly one intact backup and readable settings")
    }
    static func managerChecks() throws {
        let isolated = try IsolatedSupportDirectory("DesignSettingsManagers")
        defer { isolated.restore() }
        let automation = AutomationController(editorProvider: { nil }, newDocument: { _ in })
        let original = try Data(contentsOf: isolated.url.appendingPathComponent("Automations.json"))
        weak var releasedAutomation: FormPanel?
        try autoreleasepool {
            automation.manage()
            let form = try requireValue(FormPanel.visible.last, "DG fixture: automation manager")
            releasedAutomation = form
            let window = form.window
            check(NSApp.modalWindow == nil, "DG automation manager leaves the application non-modal")
            checkNativeButtons(window)
            let list = try table(window)
            let first = try requireValue(
                list.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTextField,
                "DG fixture: first automation name")
            let originalID = first.identifier
            let favorite = try button("automation.favorite", window)
            let oldState = favorite.state
            favorite.performClick(nil)
            check(favorite.state != oldState, "DG Favorite shows the selected automation's pending checked state")
            let exposed = NSAccessibility.unignoredChildrenForOnlyChild(from: favorite)
            let values = exposed.compactMap { element -> NSNumber? in
                guard let object = element as? NSObject else { return nil }
                let selector = NSSelectorFromString("accessibilityValue")
                return object.responds(to: selector)
                    ? object.perform(selector)?.takeUnretainedValue() as? NSNumber : nil
            }
            check(
                values.contains { $0.intValue == favorite.state.rawValue },
                "DG the real native favorite element exposes its checked value")
            let count = list.numberOfRows
            try button("automation.duplicate", window).performClick(nil)
            let copied = try requireValue(
                list.view(atColumn: 0, row: list.selectedRow, makeIfNecessary: true) as? NSTextField,
                "DG fixture: duplicate automation row")
            check(
                list.numberOfRows == count + 1 && copied.stringValue == first.stringValue
                    && copied.identifier != originalID,
                "DG duplicate automation names keep distinct real table identities")
            try button("automation.manager.cancel", window).performClick(nil)
        }
        check(
            try Data(contentsOf: isolated.url.appendingPathComponent("Automations.json")) == original,
            "DG Cancel abandons duplicate and favorite changes without a library write")
        _ = spinUntil("the automation manager releases its owned form") { releasedAutomation == nil }
        check(
            releasedAutomation == nil,
            "DG closing the manager releases action closures while its controller stays alive")
        withExtendedLifetime(automation) {}

        let macro = MacroController(editorProvider: { nil })
        let macroItem = try requireValue(
            macro.menu().items.first { $0.action == NSSelectorFromString("manage") },
            "DG fixture: saved macro manager command")
        _ = NSApp.sendAction(macroItem.action!, to: macroItem.target, from: macroItem)
        let macroForm = try requireValue(FormPanel.visible.last, "DG fixture: macro manager")
        checkNativeButtons(macroForm.window)
        try button("macro.manager.add", macroForm.window).performClick(nil)
        let newMacro = try requireValue(FormPanel.visible.last, "DG fixture: native new macro form")
        newMacro.window.makeFirstResponder(nil)
        try field("macro.new.name", newMacro.window).stringValue = "Café"
        let input = try requireValue(
            descendants(newMacro.window.contentView!).compactMap { $0 as? NSTextView }.first {
                $0.identifier?.rawValue == "macro.new.text"
            }, "DG fixture: macro inserted text")
        try button("macro.new.save", newMacro.window).performClick(nil)
        check(
            newMacro.window.isVisible && input.accessibilityHelp() != nil,
            "DG Add Macro refuses empty actions inline without discarding input")
        input.string = "kept text"
        try button("macro.new.save", newMacro.window).performClick(nil)
        let macroList = try table(macroForm.window)
        check(
            macroList.numberOfRows == 1
                && !FileManager.default.fileExists(atPath: isolated.url.appendingPathComponent("Macros.json").path),
            "DG Add Macro changes only the working copy and never executes or saves it")
        try button("macro.manager.duplicate", macroForm.window).performClick(nil)
        let renamed = try requireValue(
            macroList.view(atColumn: 0, row: macroList.selectedRow, makeIfNecessary: true) as? NSTextField,
            "DG fixture: editable duplicated macro name")
        renamed.selectText(nil)
        type("Renamed macro", in: macroForm.window)
        macroForm.window.makeFirstResponder(nil)
        try button("macro.manager.save", macroForm.window).performClick(nil)
        let storedMacro = try MacroLibrary.decode(Data(contentsOf: isolated.url.appendingPathComponent("Macros.json")))
        check(
            storedMacro.macros.map(\.name) == ["Café", "Renamed macro"] && Set(storedMacro.macros.map(\.id)).count == 2,
            "DG native macro Add, inline Rename, Duplicate and Save retain names and fresh identities")
        check(
            storedMacro.macros.allSatisfy { $0.steps == [.insertText("kept text")] },
            "DG native macro management preserves the exact supported actions")

        let run = RunController()
        var invocations = 0
        run.onUnrecordableAction = { invocations += 1 }
        let item = try requireValue(
            run.makeMenu().items.first { $0.action == NSSelectorFromString("manage:") },
            "DG fixture: Run manager command")
        _ = NSApp.sendAction(item.action!, to: item.target, from: item)
        let runForm = try requireValue(FormPanel.visible.last, "DG fixture: Run manager")
        checkNativeButtons(runForm.window)
        try button("run.manager.add", runForm.window).performClick(nil)
        let newRun = try requireValue(FormPanel.visible.last, "DG fixture: Run command sheet")
        newRun.window.makeFirstResponder(nil)
        try field("run.command.name", newRun.window).stringValue = "Native command"
        let configure = try requireValue(
            run.makeMenu().items.first { $0.action == NSSelectorFromString("configure:") },
            "DG fixture: Configure Command route")
        _ = NSApp.sendAction(configure.action!, to: configure.target, from: configure)
        let keptRunName = try field("run.command.name", newRun.window).stringValue
        check(
            FormPanel.visible.filter { $0.window.identifier?.rawValue == "run.command" }.count == 1
                && keptRunName == "Native command",
            "DG repeated Configure preserves the existing owned Run sheet and its pending input")
        try field("run.command.arguments", newRun.window).stringValue = "[\"hello\"]"
        try button("run.command.save", newRun.window).performClick(nil)
        let runList = try table(runForm.window)
        try button("run.manager.duplicate", runForm.window).performClick(nil)
        check(
            runList.numberOfRows == 2 && invocations == 0 && !run.isRunning,
            "DG creating and duplicating Run definitions never starts a process")
        try button("run.manager.delete", runForm.window).performClick(nil)
        let confirmation = try requireValue(
            runForm.window.attachedSheet, "DG fixture: native Delete confirmation sheet")
        let destructive = try requireValue(
            descendants(confirmation.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Delete" },
            "DG fixture: Delete action")
        check(
            destructive.hasDestructiveAction && destructive.keyEquivalent != "\r",
            "DG deletion is explicitly marked and Return is never destructive")
        destructive.performClick(nil)
        _ = spinUntil("Run delete confirmation completes") { runList.numberOfRows == 1 }
        runForm.window.makeFirstResponder(nil)
        try button("run.manager.save", runForm.window).performClick(nil)
        let storedRun = try ConfiguredRun.decodeLibrary(Data(contentsOf: run.storage))
        check(
            storedRun.count == 1 && storedRun[0].name == "Native command" && storedRun[0].arguments == ["hello"]
                && invocations == 0,
            "DG native Run Add, Duplicate, Delete and Save preserve the configured arguments without execution")
    }

}

extension DesignSettingsChecks {
    private static func modernAttribute(_ value: Any, _ name: String) -> Any? {
        guard let object = value as? NSObject, object.responds(to: NSSelectorFromString(name)) else { return nil }
        return object.perform(NSSelectorFromString(name))?.takeUnretainedValue()
    }
    /// Traverse the real window's modern accessibility children, including native cells.
    /// Host getter values and deprecated AXDescription are not the acceptance oracle.
    private static func nativeTree(_ window: NSWindow) -> [NSObject] {
        var seen: Set<ObjectIdentifier> = [], result: [NSObject] = []
        func visit(_ value: Any) {
            guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            for child in modernAttribute(object, "accessibilityChildren") as? [Any] ?? [] { visit(child) }
            // Some AppKit-owned table proxies expose only the AXChildren bridge.
            // Use that native edge for navigation, never legacy names/roles as the oracle.
            let childrenSelector = NSSelectorFromString("accessibilityChildren")
            let bridgeSelector = NSSelectorFromString("accessibilityAttributeValue:")
            if !object.responds(to: childrenSelector), object.responds(to: bridgeSelector),
                let children = object.perform(bridgeSelector, with: "AXChildren")?.takeUnretainedValue() as? [Any]
            {
                for child in children { visit(child) }
            }
            // AppKit's private row proxies do not implement modern children selectors.
            // Follow the table protocol's public cell edges instead of a legacy-name fallback.
            if let table = object as? NSTableView {
                for row in 0..<table.numberOfRows {
                    for column in 0..<table.numberOfColumns {
                        if let cell = table.accessibilityCell(forColumn: column, row: row) { visit(cell) }
                    }
                }
            }
        }
        visit(window)
        return result
    }
    private static func exposes(_ value: Any, purpose: String, role: String) -> Bool {
        guard modernAttribute(value, "accessibilityRole") as? String == role else { return false }
        if modernAttribute(value, "accessibilityLabel") as? String == purpose
            || modernAttribute(value, "accessibilityTitle") as? String == purpose
        {
            return true
        }
        guard let caption = modernAttribute(value, "accessibilityTitleUIElement") else { return false }
        return modernAttribute(caption, "accessibilityValue") as? String == purpose
    }
    private static func inputName(
        _ view: NSView, _ purpose: String, role: String, in form: FormPanel, focus: Bool = false
    ) {
        form.window.contentView?.layoutSubtreeIfNeeded()
        form.window.displayIfNeeded()
        let actual = NSAccessibility.unignoredChildrenForOnlyChild(from: view)
        let tree = nativeTree(form.window)
        let cellPass = actual.contains { exposes($0, purpose: purpose, role: role) }
        let treePass = tree.contains { exposes($0, purpose: purpose, role: role) }
        let expectedText =
            (view as? NSPopUpButton)?.titleOfSelectedItem ?? (view as? NSTextField)?.stringValue
            ?? (view as? NSTextView)?.string
        if let expectedText {
            check(
                actual.contains {
                    exposes($0, purpose: purpose, role: role)
                        && modernAttribute($0, "accessibilityValue") as? String == expectedText
                },
                "DG naming preserves the real native input role and displayed value: \(purpose)")
        } else if let button = view as? NSButton {
            check(
                actual.contains {
                    exposes($0, purpose: purpose, role: role)
                        && (modernAttribute($0, "accessibilityValue") as? NSNumber)?.intValue == button.state.rawValue
                },
                "DG naming preserves the real native checkbox state: \(purpose)")
        }
        print("DG_INPUT_AX", form.window.identifier!.rawValue, purpose, role, "native=", cellPass, "window=", treePass)
        if !treePass {
            for element in tree {
                print(
                    "DG_INPUT_AX_TREE", String(describing: Swift.type(of: element)),
                    modernAttribute(element, "accessibilityRole") ?? "",
                    modernAttribute(element, "accessibilityLabel") ?? "",
                    modernAttribute(element, "accessibilityTitle") ?? "",
                    modernAttribute(element, "accessibilityValue") ?? "")
            }
        }
        check(
            cellPass && treePass,
            "DG actual native input and full window tree expose purpose: \(form.window.identifier!.rawValue) / \(purpose)"
        )
        guard focus, let field = view as? NSTextField, field.isEnabled else { return }
        field.selectText(nil)
        type("8", in: form.window)
        let focusedTree = nativeTree(form.window)
        check(
            field.currentEditor() != nil && focusedTree.contains { exposes($0, purpose: purpose, role: role) },
            "DG real focused field editing retains its native input purpose: \(purpose)")
        if let editor = field.currentEditor(), focusedTree.contains(where: { $0 === editor }) {
            let editorRole = modernAttribute(editor, "accessibilityRole") as? String ?? ""
            check(
                exposes(editor, purpose: purpose, role: editorRole),
                "DG an exposed active field editor retains the input purpose: \(purpose)")
        } else {
            print("DG_FIELD_EDITOR", purpose, "represented by its named native input cell in the window tree")
        }
        form.window.makeFirstResponder(nil)
        if purpose.hasPrefix("Rename in ") {
            let renamedPurpose = "Rename in " + field.stringValue
            check(
                nativeTree(form.window).contains { exposes($0, purpose: renamedPurpose, role: role) },
                "DG the native inline Rename name follows its committed display name")
        }
    }
    static func inputAccessibilityChecks(root: URL, composition: AppDelegate) throws {
        let isolated = try IsolatedSupportDirectory("DesignSettingsInputAX")
        defer { isolated.restore() }
        let prior = Set(FormPanel.visible.map(ObjectIdentifier.init))
        defer {
            for form in FormPanel.visible.reversed() where !prior.contains(ObjectIdentifier(form)) { form.close() }
        }
        func form(_ id: String) throws -> FormPanel {
            try requireValue(
                FormPanel.visible.last { $0.window.identifier?.rawValue == id }, "DG AX fixture owns \(id)")
        }
        func labelled(_ purpose: String, in form: FormPanel) throws -> NSView {
            try requireValue(
                descendants(form.window.contentView!).first { $0.accessibilityLabel() == purpose },
                "DG AX fixture input \(purpose)")
        }
        func checkInputs(_ id: String, _ purposes: [(String, String)], focus: Bool = false) throws -> FormPanel {
            let owned = try form(id)
            for (index, pair) in purposes.enumerated() {
                inputName(try labelled(pair.0, in: owned), pair.0, role: pair.1, in: owned, focus: focus && index == 0)
            }
            return owned
        }
        func action(_ selector: String, menu: NSMenu) throws {
            let item = try requireValue(
                menu.items.first { $0.action == NSSelectorFromString(selector) }, "DG AX native menu route \(selector)")
            _ = NSApp.sendAction(item.action!, to: item.target, from: item)
        }
        let settings = SettingsController(url: isolated.url.appendingPathComponent("Settings.json"))
        settings.showSettings(nil)
        let settingsForm = try checkInputs(
            "TextTank.Settings",
            [
                ("Tab width", "AXTextField"), ("Appearance", "AXPopUpButton"),
                ("Command shortcut to assign", "AXPopUpButton"), ("Shortcut key", "AXTextField"),
                ("Indent with tabs", "AXCheckBox"), ("Wrap lines", "AXCheckBox")
            ], focus: true)
        let shortcut = try field("settings.shortcut.key", settingsForm.window)
        let commands = try requireValue(
            descendants(settingsForm.window.contentView!).compactMap { $0 as? NSPopUpButton }.first {
                $0.identifier?.rawValue == "settings.shortcut.command"
            }, "DG AX shortcut choices")
        commands.selectItem(at: min(1, commands.numberOfItems - 1))
        _ = NSApp.sendAction(commands.action!, to: commands.target, from: commands)
        inputName(shortcut, "Shortcut key", role: "AXTextField", in: settingsForm, focus: true)
        settingsForm.close()

        let document = DocumentFactory.makeUntitled()
        defer { document.close() }
        let controller = try requireValue(
            document.windowControllers.first as? EditorWindowController, "DG AX document controller")
        document.editor.text = "one\ntwo"
        document.editor.setSavePoint()
        controller.goToLine(nil)
        try checkInputs("TextTank.GoToLine", [("Line number in Go to Line", "AXTextField")], focus: true).close()
        composition.showDocumentTabs(nil)
        try checkInputs(
            "TextTank.OpenDocuments", [("Filter open documents by name or path", "AXTextField")], focus: true
        ).close()
        let editor = document.editor
        let automation = AutomationController(
            editorProvider: { editor }, newDocument: { _ in check(false, "DG input checks never invoke output") })
        var workflow = AutomationDefinition.example
        workflow.name = "AX automation"
        workflow.shortcut = nil
        try automation.persistLibrary(.init(workflows: [workflow]))
        automation.manage()
        let manager = try checkInputs("automation.manager", [("Rename in AX automation", "AXTextField")], focus: true)
        try button("automation.edit", manager.window).performClick(nil)
        try checkInputs(
            "automation.settings",
            [
                ("Automation name", "AXTextField"), ("Automation input", "AXPopUpButton"),
                ("Automation output", "AXPopUpButton"), ("Automation shortcut", "AXTextField")
            ], focus: true
        ).close()
        try button("automation.rules", manager.window).performClick(nil)
        let rules = try checkInputs(
            "TextTank.Rules", [("Automation name", "AXTextField"), ("Sample input", "AXTextArea")], focus: true)
        try button("rules.add", rules.window).performClick(nil)
        let rule = try checkInputs(
            "rule",
            [
                ("Rule", "AXPopUpButton"), ("Text to match", "AXTextField"), ("Replace with", "AXTextField"),
                ("Ask for match text when running this rule", "AXCheckBox"),
                ("Ask for replacement when running this rule", "AXCheckBox")
            ])
        let kind = try requireValue(try labelled("Rule", in: rule) as? NSPopUpButton, "DG AX actual rule kind")
        kind.selectItem(
            at: try requireValue(
                AutomationDefinition.Step.Kind.allCases.firstIndex { $0.findTitle == "Pattern" },
                "DG AX pattern rule kind"))
        _ = NSApp.sendAction(kind.action!, to: kind.target, from: kind)
        inputName(try labelled("Pattern", in: rule), "Pattern", role: "AXTextField", in: rule, focus: true)
        rule.close()
        rules.close()
        try button("automation.json", manager.window).performClick(nil)
        try checkInputs("automation.json", [("Automation library JSON", "AXTextArea")]).close()
        manager.close()
        automation.showPalette()
        try checkInputs("automation.palette", [("Filter automations by name", "AXTextField")], focus: true).close()

        let macro = MacroController(editorProvider: { editor })
        try macro.persist(.init(macros: [.init(id: UUID(), name: "AX macro", steps: [.insertText("x")])]))
        try action("manage", menu: macro.menu())
        let macroManager = try checkInputs("macro.manager", [("Rename in AX macro", "AXTextField")], focus: true)
        try button("macro.manager.add", macroManager.window).performClick(nil)
        try checkInputs(
            "macro.new", [("Name in New Macro", "AXTextField"), ("Text inserted by the new macro", "AXTextArea")],
            focus: true
        ).close()
        try button("macro.manager.advanced", macroManager.window).performClick(nil)
        try checkInputs("macro.json", [("Macro library JSON", "AXTextArea")]).close()
        macroManager.close()
        macro.startRecording()
        editor.executeCommand(TTEditorCommandIdentifier(rawValue: "newLine"))
        _ = try macro.finishRecording()
        editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
        try action("saveLast", menu: macro.menu())
        try checkInputs("macro.save", [("Macro name in Name Recorded Macro", "AXTextField")], focus: true).close()
        let run = RunController()
        try run.persist([.uppercaseSample])
        try action("manage:", menu: run.makeMenu())
        let runManager = try checkInputs(
            "run.manager", [("Rename in " + ConfiguredRun.uppercaseSample.name, "AXTextField")], focus: true)
        try button("run.manager.add", runManager.window).performClick(nil)
        try checkInputs(
            "run.command",
            [
                ("Name in New Run Command", "AXTextField"), ("Executable in New Run Command", "AXTextField"),
                ("Arguments in New Run Command", "AXTextField"),
                ("Intentional shell mode for this Run command", "AXCheckBox"),
                ("Text extension mode for this Run command", "AXCheckBox")
            ], focus: true
        ).close()
        try button("run.manager.advanced", runManager.window).performClick(nil)
        try checkInputs("run.json", [("Saved Run commands as JSON", "AXTextArea")]).close()
        runManager.close()
        let language = LanguageController(
            editorProvider: { editor }, languageProvider: { "plain" }, setLanguage: { _ in })
        language.configure()
        try checkInputs("language.json", [("Language profiles JSON", "AXTextArea")]).close()
    }
}
