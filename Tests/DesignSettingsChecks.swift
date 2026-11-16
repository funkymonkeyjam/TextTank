// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

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
            "settings.save", "settings.cancel", "settings.reset", "automation.create", "automation.edit",
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
                    nativeText(element, selector: "accessibilityTitle"),
                    nativeText(element, selector: "accessibilityAttributeValue:", argument: "AXDescription")
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
