@testable import TextTankCore
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
@testable import TextTankRuntime
import EditorBridge
import NativeSearch

final class AutomationToolbarHost: NSObject, NSToolbarDelegate {
    let controller: AutomationController
    init(_ controller: AutomationController) { self.controller = controller }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        controller.toolbarIdentifiers()
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        controller.toolbarIdentifiers()
    }
    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar: Bool
    ) -> NSToolbarItem? {
        controller.makeToolbarItem(identifier: identifier)
    }
}

final class Audit24RecoverySpy: NSObject {
    var attempts: [Int] = []
    override func attemptRecovery(fromError error: Error, optionIndex: Int) -> Bool {
        attempts.append(optionIndex)
        return true
    }
}

@main struct AutomationControllerChecks {
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func typeKeys(_ text: String, in window: NSWindow) {
        for character in text {
            let value = String(character)
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: value, charactersIgnoringModifiers: value,
                isARepeat: false, keyCode: 0)!
            window.sendEvent(event)
        }
    }
    static func ruleKeyboardCheck() -> (Bool, Bool, AutomationDefinition.Step?) {
        var actionSent = false, fieldsEnabled = false, acted = false
        let deadline = Date().addingTimeInterval(5)
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            guard let modal = presentedFormWindow, let content = modal.contentView else { return }
            if Date() > deadline {
                NSApp.abortModal()
                return
            }
            guard !acted else { return }
            let views = descendants(content)
            guard let popup = views.compactMap({ $0 as? NSPopUpButton }).first,
                let save = views.compactMap({ $0 as? NSButton }).first(where: { $0.identifier?.rawValue == "rule.save" }
                )
            else { return }
            acted = true
            popup.selectItem(at: AutomationDefinition.Step.Kind.allCases.firstIndex(of: .replaceLiteral)!)
            if let action = popup.action { actionSent = NSApp.sendAction(action, to: popup.target, from: popup) }
            let fields = views.compactMap { $0 as? NSTextField }.filter { $0.isEditable }
            guard fields.count == 2 else {
                NSApp.abortModal()
                return
            }
            fieldsEnabled = fields.allSatisfy { $0.isEnabled }
            guard fieldsEnabled else {
                NSApp.abortModal()
                return
            }
            fields[0].selectText(nil)
            typeKeys("[salt]", in: modal)
            fields[1].selectText(nil)
            typeKeys("2 eggs", in: modal)
            save.performClick(nil)
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        let result = capturedStep(.init(kind: .removeBlankLines), timeout: 5)
        timer.invalidate()
        return (actionSent, fieldsEnabled, result)
    }
    static func modalKeyboardChecks(_ controller: AutomationController) throws {
        var stage = 0, nameAccepted = false, sampleAccepted = false, reentryBlocked = false, timedOut = false
        var nestedRule: (Bool, Bool, AutomationDefinition.Step?) = (false, false, nil)
        let deadline = Date().addingTimeInterval(8)
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            guard let window = presentedFormWindow, let content = window.contentView else { return }
            let views = descendants(content)
            if Date() > deadline {
                timedOut = true
                window.performClose(nil)
                return
            }
            switch stage {
            case 0:
                guard let create = button("automation.create", in: views) else { return }
                stage = 1
                create.performClick(nil)
            case 1:
                guard let name = field("automation.settings.name", in: views),
                    let use = button("automation.settings.save", in: views)
                else { return }
                name.selectText(nil)
                typeKeys("Keyboard Recipe", in: window)
                window.makeFirstResponder(nil)
                nameAccepted = name.stringValue == "Keyboard Recipe" && name.isEditable
                let manager = FormPanel.visible.first { $0.window.identifier?.rawValue == "automation.manager" }
                controller.manage()
                reentryBlocked =
                    FormPanel.visible.filter { $0.window.identifier?.rawValue == "automation.manager" }.count == 1
                    && FormPanel.visible.first { $0.window.identifier?.rawValue == "automation.manager" } === manager
                stage = 2
                use.performClick(nil)
            case 2:
                guard let rules = button("automation.rules", in: views), rules.isEnabled else { return }
                stage = 3
                rules.performClick(nil)
            case 3:
                guard let sample = textView("Sample input", in: views), let cancel = button("rules.cancel", in: views)
                else { return }
                window.makeFirstResponder(sample)
                typeKeys("2 eggs", in: window)
                sampleAccepted = sample.string == "2 eggs" && window.firstResponder === sample
                nestedRule = ruleKeyboardCheck()
                stage = 4
                cancel.performClick(nil)
            case 4:
                guard let cancel = button("automation.manager.cancel", in: views) else { return }
                stage = 5
                cancel.performClick(nil)
            default: break
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        controller.manage()
        waitForModelessForms(timeout: 8)
        timer.invalidate()
        check(!timedOut && stage == 5, "native Create Automation and Rules modeless chain completed")
        check(nameAccepted, "Create Automation name accepts dispatched keyboard events")
        check(sampleAccepted, "Sample Input accepts dispatched keyboard events")
        check(reentryBlocked, "management reentry keeps the same single owned manager")
        check(nestedRule.0, "nested rule popup dispatch reaches retained controller target")
        check(nestedRule.1, "changing rule kind enables find and replacement fields")
        check(
            nestedRule.2?.kind == .replaceLiteral && nestedRule.2?.find == "[salt]"
                && nestedRule.2?.replacement == "2 eggs",
            "nested Save Rule commits keyboard-entered find and replacement")
    }
    /// Runs `body`, which presents a modal, with a timer in modal mode. `act` is called on every tick
    /// until it returns true; a modal still open at the deadline is aborted and reported.
    static func drivingModal<T>(
        timeout: TimeInterval, _ act: @escaping (NSWindow, [NSView]) -> Bool, _ body: () throws -> T
    ) rethrows -> (value: T, acted: Bool, timedOut: Bool) {
        var acted = false, timedOut = false
        let deadline = Date().addingTimeInterval(timeout)
        let timer = Timer(timeInterval: 0.005, repeats: true) { _ in
            guard let modal = presentedFormWindow, let content = modal.contentView else { return }
            if Date() > deadline {
                timedOut = true
                NSApp.abortModal()
                return
            }
            if !acted { acted = act(modal, descendants(content)) }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }
        let priorForms = Set(FormPanel.visible.map(ObjectIdentifier.init))
        let value = try body()
        waitForModelessForms(timeout: timeout, excluding: priorForms)
        return (value, acted, timedOut)
    }
    static func drivingAdvanced(
        timeout: TimeInterval, controller: AutomationController, commit: Bool,
        _ act: @escaping (NSWindow, [NSView]) -> Bool
    ) -> (value: Void, acted: Bool, timedOut: Bool) {
        MainActor.assumeIsolated {
            let route = ManagerChildRoute(
                managerID: "automation.manager", openerID: "automation.json", childID: "automation.json", commit: commit
            )
            return drivingModal(
                timeout: timeout,
                { window, views in
                    MainActor.assumeIsolated { route.step(window, views: views) { _ = act(window, views) } }
                }
            ) { controller.manageAdvanced() }
        }
    }
    static func capturedRules(_ original: AutomationDefinition, timeout: TimeInterval) -> AutomationDefinition? {
        var result: AutomationDefinition?
        let before = Set(FormPanel.visible.map(ObjectIdentifier.init))
        AutomationStepEditor.present(original) { result = $0 }
        waitForModelessForms(timeout: timeout, excluding: before)
        return result
    }
    static func capturedStep(_ original: AutomationDefinition.Step, timeout: TimeInterval) -> AutomationDefinition.Step?
    {
        var result: AutomationDefinition.Step?
        let before = Set(FormPanel.visible.map(ObjectIdentifier.init))
        AutomationStepEditor.presentStep(original, parent: presentedFormWindow) { result = $0 }
        waitForModelessForms(timeout: timeout, excluding: before)
        return result
    }
    static func button(_ identifier: String, in views: [NSView]) -> NSButton? {
        views.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == identifier }
    }
    struct RuleListState: Equatable { var rows: Int, selected: Int, up: Bool, down: Bool }
    /// F253: the rule list of the rule builder, driven through its real buttons.
    static func ruleListChecks() {
        func literal(_ find: String) -> AutomationDefinition.Step {
            .init(kind: .replaceLiteral, find: find, replacement: find.uppercased())
        }
        var definition = AutomationDefinition.example
        definition.steps = [literal("a"), literal("b"), literal("c")]
        var trail: [RuleListState] = [], nestedSaved = false
        var keyLoopClosed = false, keyLoopReaches = false, defaultAndCancel = false
        let edited = drivingModal(
            timeout: 10,
            { modal, views in
                guard let table = views.compactMap({ $0 as? NSTableView }).first,
                    let use = button("rules.use", in: views),
                    let add = button("rules.add", in: views), let duplicate = button("rules.duplicate", in: views),
                    let up = button("rules.up", in: views),
                    let down = button("rules.down", in: views), let remove = button("rules.remove", in: views)
                else { return false }
                func note() {
                    trail.append(
                        RuleListState(
                            rows: table.numberOfRows, selected: table.selectedRow, up: up.isEnabled,
                            down: down.isEnabled))
                }
                note()
                duplicate.performClick(nil)
                note()
                down.performClick(nil)
                note()
                down.performClick(nil)
                note()
                down.performClick(nil)
                note() // already last: the disabled button does nothing
                up.performClick(nil)
                note()
                table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
                note()
                remove.performClick(nil)
                note()
                // Add Rule opens the nested Configure Rule dialog; accept its default rule.
                nestedSaved = nestedModal({ _, fields in
                    button("rule.save", in: fields)?.performClick(nil)
                }) { add.performClick(nil) }
                note()
                up.performClick(nil)
                note()
                // G400: Tab reaches every control of this hand-framed window and comes back round.
                var view = modal.initialFirstResponder, reached: [NSView] = []
                while let current = view, reached.count < 200, !reached.contains(where: { $0 === current }) {
                    reached.append(current)
                    view = current.nextKeyView
                }
                keyLoopClosed = view != nil && view === modal.initialFirstResponder
                keyLoopReaches = [use, add, remove, up].allSatisfy { control in reached.contains { $0 === control } }
                defaultAndCancel =
                    use.keyEquivalent == "\r" && button("rules.cancel", in: views)?.keyEquivalent == "\u{1b}"
                use.performClick(nil)
                return true
            }
        ) { capturedRules(definition, timeout: 10) }
        check(
            keyLoopClosed && keyLoopReaches,
            "the rule editor's Tab order starts at its first field, reaches its buttons and closes into a loop")
        check(defaultAndCancel, "the rule editor has Return and Escape buttons")
        check(
            edited.acted && !edited.timedOut && nestedSaved,
            "rule builder buttons were driven and Add Rule accepted the nested default rule")
        let expectedTrail = [
            RuleListState(rows: 3, selected: 0, up: false, down: true),
            RuleListState(rows: 4, selected: 1, up: true, down: true),
            RuleListState(rows: 4, selected: 2, up: true, down: true),
            RuleListState(rows: 4, selected: 3, up: true, down: false),
            RuleListState(rows: 4, selected: 3, up: true, down: false),
            RuleListState(rows: 4, selected: 2, up: true, down: true),
            RuleListState(rows: 4, selected: 1, up: true, down: true),
            RuleListState(rows: 3, selected: 1, up: true, down: true),
            RuleListState(rows: 4, selected: 3, up: true, down: false),
            RuleListState(rows: 4, selected: 2, up: true, down: true)
        ]
        check(
            trail == expectedTrail,
            "duplicate, move, remove and add keep the row count, the selection and the Move buttons in step")
        // G387: a prompt flag that is off is left out of the rule the Configure Rule dialog returns.
        check(
            edited.value?.steps == [literal("a"), literal("a"), .init(kind: .removeBlankLines), literal("c")],
            "Use These Rules returns the rules in the edited order")
        check(
            edited.value?.id == definition.id && edited.value?.name == definition.name
                && edited.value?.input == definition.input && edited.value?.output == definition.output,
            "rule-list editing leaves identity, name, input and output alone")
        let cancelled = drivingModal(
            timeout: 10,
            { _, views in
                guard let remove = button("rules.remove", in: views), let cancel = button("rules.cancel", in: views)
                else { return false }
                remove.performClick(nil)
                cancel.performClick(nil)
                return true
            }
        ) { capturedRules(definition, timeout: 10) }
        check(
            cancelled.acted && !cancelled.timedOut && cancelled.value == nil,
            "Cancel after removing a rule returns no draft")
    }
    /// Runs `trigger`, which opens a modal from inside a modal timer callback, and calls `act` once
    /// with that nested modal. A repeating timer cannot fire again while its own callback is still
    /// running, so the nested modal needs a timer of its own. Returns whether `act` ran.
    @discardableResult
    static func nestedModal(_ act: @escaping (NSWindow, [NSView]) -> Void, _ trigger: () -> Void) -> Bool {
        let outer = presentedFormWindow, deadline = Date().addingTimeInterval(8)
        var acted = false
        let timer = Timer(timeInterval: 0.02, repeats: true) { _ in
            guard let nested = presentedFormWindow, nested !== outer, let content = nested.contentView else { return }
            if acted || Date() > deadline { return }
            acted = true
            act(nested, descendants(content))
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        trigger()
        while let current = presentedFormWindow, current !== outer, Date() < deadline {
            _ = RunLoop.main.run(mode: .modalPanel, before: Date().addingTimeInterval(0.01))
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        if let current = presentedFormWindow, current !== outer {
            check(false, "the nested native editor closes through its controls")
            current.performClose(nil)
        }
        timer.invalidate()
        return acted
    }
    static func field(_ identifier: String, in views: [NSView]) -> NSTextField? {
        views.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == identifier }
    }
    static func shows(_ text: String, in views: [NSView]) -> Bool {
        views.contains { ($0 as? NSTextField)?.stringValue == text }
    }
    static func textView(_ label: String, in views: [NSView]) -> NSTextView? {
        views.compactMap { $0 as? NSTextView }.first { $0.accessibilityLabel() == label }
    }
    /// The OK button of a plain error alert, which has none of the app's own button identifiers.
    static func errorAlertButton(in views: [NSView]) -> NSButton? {
        let buttons = views.compactMap { $0 as? NSButton }
        let ours = buttons.contains {
            guard let identifier = $0.identifier?.rawValue else { return false }
            return identifier.hasPrefix("automation") || identifier.hasPrefix("rule")
        }
        return ours ? nil : buttons.first { $0.title == "OK" && !$0.isHidden }
    }
    static func errorAlertText(in views: [NSView]) -> String {
        views.compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: "\n")
    }
    /// Audit package 15: the automation editor and library dialogs, on their own support directory.
    static func package15Checks(root: URL) throws {
        typealias Step = AutomationDefinition.Step
        let support = root.appendingPathComponent("package15", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        setenv("TEXTTANK_SUPPORT_DIRECTORY", support.path, 1)
        defer { setenv("TEXTTANK_SUPPORT_DIRECTORY", root.path, 1) }
        let path = support.appendingPathComponent("Automations.json")
        func stored() throws -> AutomationLibrary { try AutomationLibrary.decode(Data(contentsOf: path)) }
        let controller = AutomationController(editorProvider: { nil }, newDocument: { _ in })

        Checks.section("G375 pickers keep automations that share a name") {
            var first = AutomationDefinition.example, second = AutomationDefinition.example
            first.id = UUID()
            second.id = UUID()
            second.steps = [Step(kind: .trimWhitespace)]
            var third = AutomationDefinition.remindersExample
            let initialBytes = try Data(contentsOf: path)
            first.shortcut = nil
            second.shortcut = nil
            third.shortcut = nil
            try controller.persistLibrary(AutomationLibrary(workflows: [first, second, third]))
            controller.manage()
            let managerWindow = try requireValue(FormPanel.frontWindow, "fixture: actual automation manager")
            let table = try requireValue(
                descendants(managerWindow.contentView!).compactMap { $0 as? NSTableView }.first,
                "fixture: actual automation list")
            check(table.numberOfRows == 3, "G375 Manage Automations lists both automations that share a name")
            let identities = (0..<table.numberOfRows).compactMap {
                table.view(atColumn: 0, row: $0, makeIfNecessary: true)?.identifier?.rawValue
            }
            check(
                identities == [first.id.uuidString, second.id.uuidString, third.id.uuidString],
                "G375 each actual manager row carries its own automation identifier, in order")
            button("automation.manager.cancel", in: descendants(managerWindow.contentView!))?.performClick(nil)
            try controller.persistLibrary(AutomationLibrary.decode(initialBytes))
            let saved = [first, second, third].map { AutomationRuleSet(name: $0.name, steps: $0.steps) }
            let templates = AutomationTemplates.loadAll().sets
            try require(templates.count == 3, "fixture: the three bundled templates load")
            let sets = saved + templates
            let choices = AutomationStepEditor.ruleSetPopup(saved: saved, templates: templates)
            check(choices.numberOfItems == sets.count, "G375 Load Rules lists every saved automation and template")
            var mapped = true
            for index in sets.indices {
                choices.selectItem(at: index)
                let chosen = AutomationStepEditor.selectedRuleSet(in: choices, from: sets)
                if chosen?.steps != sets[index].steps || chosen?.name != sets[index].name { mapped = false }
            }
            check(mapped, "G375 every Load Rules item resolves to its own rule set")
            choices.selectItem(withTitle: "Template: Recipe ingredient cleanup")
            check(
                AutomationStepEditor.selectedRuleSet(in: choices, from: sets)?.steps
                    == (try AutomationTemplates.load("recipe-ingredient-cleanup")).steps,
                "G375 the last template is reachable when two saved automations share a name")
            check(
                choices.itemArray.prefix(3).allSatisfy { $0.title.hasPrefix("Saved: ") }
                    && choices.itemArray.dropFirst(3).allSatisfy { $0.title.hasPrefix("Template: ") },
                "G375 saved automations and templates keep their prefixes")
        }

        Checks.section("G386 rule guidance") {
            let kinds = Step.Kind.allCases
            check(
                kinds.allSatisfy { !$0.guidance.isEmpty && !$0.guidance.contains("below") },
                "G386 every rule kind has guidance and none points below the dialog")
            check(
                Set(kinds.map(\.guidance)).count == kinds.count - 2,
                "G386 guidance is specific to the kind (the three literal line rules share one)")
            check(
                [Step.Kind.removeBlankLines, .sortLines, .sortLinesLocalized, .deduplicateLines].allSatisfy {
                    $0.guidance.contains("line ending")
                }, "G386 the rules that refuse mixed line endings say so")
            check(
                Step.Kind.clearMarkdownHeadings.guidance.contains("stays in place"),
                "G386 the heading rule says the emptied line stays")
            var patternTitle = false, literalTitle = false, patternGuidance = false
            let configured = drivingModal(
                timeout: 8,
                { _, views in
                    guard let popup = views.compactMap({ $0 as? NSPopUpButton }).first,
                        let cancel = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Cancel" })
                    else { return false }
                    literalTitle = shows("Text to match", in: views) && !shows("Pattern", in: views)
                    popup.selectItem(at: kinds.firstIndex(of: .clearLinesMatching)!)
                    if let action = popup.action { NSApp.sendAction(action, to: popup.target, from: popup) }
                    patternTitle = shows("Pattern", in: views) && !shows("Text to match", in: views)
                    patternGuidance = shows(Step.Kind.clearLinesMatching.guidance, in: views)
                    cancel.performClick(nil)
                    return true
                }
            ) { capturedStep(Step(kind: .clearLinesEqualTo, find: "x"), timeout: 8) }
            check(
                configured.acted && !configured.timedOut && configured.value == nil,
                "the Configure Rule dialog was driven and cancelled")
            check(
                literalTitle && patternTitle, "G386 the text field is titled Pattern only for the pattern rule")
            check(patternGuidance, "G386 the dialog shows the selected kind's own guidance")
        }

        Checks.section("rule builder: opening, layout, test and accept") {
            var definition = AutomationDefinition.example
            definition.name = ""
            definition.steps = [
                Step(kind: .replaceLiteral, find: "x", replacement: "y", askForReplacement: true),
                Step(kind: .trimWhitespace)
            ]
            var stage = 0, openingStatus = "", openingResult = "x", title = "", rowText = ""
            var resizable = false, grew = false, unambiguous = false, clear = false
            var testedStatus = "", testedResult = "", staleStatus = "", staleResult = "x", untouchedStatus = ""
            var nameError = "", addedNested = false, rowCountAfterAdd = 0
            let edited = drivingModal(
                timeout: 20,
                { modal, views in
                    guard let table = views.compactMap({ $0 as? NSTableView }).first,
                        let status = field("rules.status", in: views), let sample = textView("Sample input", in: views),
                        let result = textView("Test result", in: views), let test = button("rules.test", in: views),
                        let use = button("rules.use", in: views), let add = button("rules.add", in: views),
                        let remove = button("rules.remove", in: views), let load = button("rules.load", in: views),
                        let name = views.compactMap({ $0 as? NSTextField }).first(where: {
                            $0.accessibilityLabel() == "Automation name" && $0.isEditable
                        })
                    else { return false }
                    switch stage {
                    case 0:
                        openingStatus = status.stringValue
                        openingResult = result.string
                        title = modal.title
                        rowText =
                            (table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTextField)?.stringValue ?? ""
                        resizable = modal.styleMask.contains(.resizable)
                        let rules = table.enclosingScrollView!, pane = sample.enclosingScrollView!
                        modal.layoutIfNeeded()
                        let before = (rules.frame.size, pane.frame.size, result.enclosingScrollView!.frame.size)
                        clear =
                            !remove.convert(remove.bounds, to: nil).intersects(load.convert(load.bounds, to: nil))
                            && before.1.width == before.2.width
                        modal.setContentSize(NSSize(width: 1300, height: 980))
                        modal.layoutIfNeeded()
                        // The window manager clamps a window to its screen (1024×768 in CI),
                        // or to its minimum height without a screen. Drive the same root layout
                        // at the requested content size so the growth assertions do not depend
                        // on the display attached to the machine running this layout check.
                        let root = modal.contentView!, actualFrame = root.frame
                        root.setFrameSize(NSSize(width: 1300, height: 980))
                        root.layoutSubtreeIfNeeded()
                        grew =
                            rules.frame.width > before.0.width + 200 && rules.frame.height > before.0.height + 50
                            && pane.frame.width > before.1.width + 100 && pane.frame.height > before.1.height + 50
                            && sample.frame.width > before.1.width
                        unambiguous = !(modal.contentView?.hasAmbiguousLayout ?? true)
                        root.frame = actualFrame
                        root.layoutSubtreeIfNeeded()
                        // A rule edit with nothing tested yet leaves the opening instruction alone.
                        remove.performClick(nil)
                        untouchedStatus = status.stringValue
                        sample.insertText("  xx  \n", replacementRange: NSRange(location: 0, length: 0))
                        test.performClick(nil)
                        stage = 1
                    case 1:
                        guard !result.string.isEmpty else { return false }
                        testedStatus = status.stringValue
                        testedResult = result.string
                        sample.insertText("more", replacementRange: NSRange(location: 0, length: 0))
                        staleStatus = status.stringValue
                        staleResult = result.string
                        addedNested = nestedModal({ _, nested in button("rule.save", in: nested)?.performClick(nil) }) {
                            add.performClick(nil)
                        }
                        rowCountAfterAdd = table.numberOfRows
                        // The name is still blank: Use These Rules reports it and the builder stays.
                        use.performClick(nil)
                        nameError = status.stringValue
                        check(
                            modal.isVisible && name.accessibilityHelp() == nameError,
                            "DG invalid Rules name stays in the same builder and marks the name")
                        stage = 2
                    case 2:
                        name.selectText(nil)
                        typeKeys("Named in the builder", in: modal)
                        use.performClick(nil)
                        return true
                    default: break
                    }
                    return false
                }
            ) { capturedRules(definition, timeout: 20) }
            check(
                edited.acted && !edited.timedOut && stage == 2, "the rule builder was driven through to Use These Rules"
            )
            check(
                openingStatus == AutomationStepEditor.openingInstruction && openingResult.isEmpty,
                "G385 a freshly opened builder shows the opening instruction, not a stale-result message")
            check(
                untouchedStatus == AutomationStepEditor.openingInstruction,
                "G385 editing rules before any test leaves the opening instruction in place")
            check(title == "Edit Rules", "G383 the builder's title does not repeat a name that may be stale")
            check(
                rowText == "1. Find and replace text  ·  “x” → “y”  ·  asks for the replacement when run",
                "G386 a rule row shows the replacement and the prompt flag")
            check(resizable, "F313 the rule builder window is resizable")
            check(clear, "F313 the rule buttons do not overlap Load Rules and the two text panes are equally wide")
            check(grew, "F313 the rule list and the text panes grow with the window")
            check(unambiguous, "F313 the rule builder layout is not ambiguous")
            check(
                testedResult == "xx\n" && testedStatus.hasPrefix("Test passed"),
                "G383 Test Rules runs the rules although the automation name is blank")
            check(
                staleStatus == AutomationStepEditor.staleInstruction && staleResult.isEmpty,
                "G385 editing the sample after a test clears the result and says it is stale")
            check(addedNested && rowCountAfterAdd == 2, "G379 Add Rule appended the nested default rule")
            check(nameError.contains("needs a name"), "Use These Rules still refuses a blank name")
            check(
                edited.value?.name == "Named in the builder"
                    && edited.value?.steps == [Step(kind: .trimWhitespace), Step(kind: .removeBlankLines)]
                    && edited.value?.id == definition.id && edited.value?.input == definition.input
                    && edited.value?.output == definition.output,
                "G379 Use These Rules returns the edited name and rules and nothing else changed")
        }

        Checks.section("F203 and F70: a failed Save keeps the edit dialog and its work") {
            var library = try stored()
            try require(library.workflows.count == 2, "fixture: the two first-run automations")
            library.workflows[0].steps = [Step(kind: .trimWhitespace), Step(kind: .removeBlankLines)]
            // An older file may hold an empty string for "no shortcut".
            library.workflows[1].shortcut = ""
            try controller.persistLibrary(library)
            let seeded = try Data(contentsOf: path)
            let previousMenu = NSApp.mainMenu
            defer { NSApp.mainMenu = previousMenu }
            let menu = NSMenu(title: "Main"), host = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: "Edit")
            let taken = NSMenuItem(title: "Taken", action: nil, keyEquivalent: "j")
            taken.keyEquivalentModifierMask = [.command, .option]
            // F70: a Command-Option item with no key must not collide with "no shortcut".
            let keyless = NSMenuItem(title: "Keyless", action: nil, keyEquivalent: "")
            keyless.keyEquivalentModifierMask = [.command, .option]
            submenu.addItem(taken)
            submenu.addItem(keyless)
            host.submenu = submenu
            menu.addItem(host)
            NSApp.mainMenu = menu
            var stage = 0, errorText = "", reopened = false, keptName = "", keptShortcut = "",
                unchangedOnFailure = false
            var settingsWindow: NSWindow?
            let managed = drivingModal(
                timeout: 20,
                { modal, views in
                    switch stage {
                    case 0:
                        guard let rules = button("automation.rules", in: views) else { return false }
                        stage = 1
                        rules.performClick(nil)
                    case 1:
                        guard let remove = button("rules.remove", in: views), let use = button("rules.use", in: views)
                        else { return false }
                        stage = 2
                        remove.performClick(nil)
                        use.performClick(nil)
                    case 2:
                        guard let edit = button("automation.edit", in: views), edit.isEnabled else { return false }
                        stage = 3
                        edit.performClick(nil)
                    case 3:
                        guard let save = button("automation.settings.save", in: views),
                            let name = field("automation.settings.name", in: views),
                            let shortcut = field("automation.settings.shortcut", in: views)
                        else { return false }
                        settingsWindow = modal
                        name.selectText(nil)
                        typeKeys("Renamed after rule edits", in: modal)
                        shortcut.selectText(nil)
                        typeKeys("j", in: modal)
                        stage = 4
                        save.performClick(nil)
                    case 4:
                        guard let save = button("automation.settings.save", in: views),
                            let name = field("automation.settings.name", in: views),
                            let shortcut = field("automation.settings.shortcut", in: views),
                            shortcut.accessibilityHelp() != nil
                        else { return false }
                        errorText = shortcut.accessibilityHelp() ?? ""
                        reopened =
                            modal === settingsWindow && modal.title == "Edit Automation" && NSApp.modalWindow == nil
                        keptName = name.stringValue
                        keptShortcut = shortcut.stringValue
                        unchangedOnFailure = (try? Data(contentsOf: path)) == seeded
                        modal.makeFirstResponder(nil)
                        shortcut.stringValue = ""
                        stage = 5
                        save.performClick(nil)
                    case 5:
                        guard let save = button("automation.manager.save", in: views), save.isEnabled else {
                            return false
                        }
                        stage = 6
                        save.performClick(nil)
                        return true
                    default: break
                    }
                    return false
                }
            ) { controller.manage() }
            check(
                managed.acted && !managed.timedOut && stage == 6,
                "the Edit Automation chain was driven to its second Save")
            check(
                errorText.contains("Command-Option-J is already assigned"),
                "a shortcut taken by an application command is refused on Save")
            check(reopened, "F203 after the error the same modeless Edit Automation form stays open")
            check(
                keptName == "Renamed after rule edits" && keptShortcut == "j",
                "F203 the typed name and shortcut are still in the fields")
            check(unchangedOnFailure, "F203 the failed Save left the stored library untouched")
            let after = try stored()
            check(
                after.workflows[0].name == "Renamed after rule edits"
                    && after.workflows[0].steps == [Step(kind: .removeBlankLines)]
                    && after.workflows[0].id == library.workflows[0].id,
                "F203 the second Save stores the new name together with the rule edits made before the error")
            check(after.workflows[0].shortcut == nil, "F70 a blank shortcut field is stored as no shortcut")
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
            let first = (object?["workflows"] as? [[String: Any]])?.first
            check(
                first?["name"] as? String == "Renamed after rule edits" && first?["shortcut"] == nil,
                "F70 the stored automation has no shortcut key at all")
            check(
                after.workflows[1] == library.workflows[1],
                "F70 an empty-string shortcut on another automation does not collide with a keyless menu command")
            check(NSApp.modalWindow == nil, "no modal session is left open after Edit Automation")
        }

        Checks.section("G384 Create Automation goes through the settings step") {
            let before = try Data(contentsOf: path), countBefore = try stored().workflows.count
            var stage = 0, settingsShown = false, unsavedAtSettings = false, unsavedAfterDeclining = false
            let created = drivingModal(
                timeout: 20,
                { modal, views in
                    switch stage {
                    case 0:
                        guard let create = button("automation.create", in: views) else { return false }
                        stage = 1
                        create.performClick(nil)
                    case 1:
                        guard let use = button("automation.settings.save", in: views),
                            let name = field("automation.settings.name", in: views),
                            let shortcut = field("automation.settings.shortcut", in: views)
                        else { return false }
                        name.selectText(nil)
                        typeKeys("Created through settings", in: modal)
                        shortcut.selectText(nil)
                        typeKeys("q", in: modal)
                        modal.makeFirstResponder(nil)
                        settingsShown =
                            modal.title == "New Automation" && name.stringValue == "Created through settings"
                        unsavedAtSettings = (try? Data(contentsOf: path)) == before
                        stage = 2
                        use.performClick(nil)
                    case 2:
                        guard let save = button("automation.manager.save", in: views), save.isEnabled else {
                            return false
                        }
                        stage = 3
                        save.performClick(nil)
                    case 3:
                        guard button("automation.settings.saveEmpty", in: views) != nil,
                            let cancel = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Cancel" })
                        else { return false }
                        stage = 4
                        cancel.performClick(nil)
                    case 4:
                        guard let save = button("automation.manager.save", in: views), save.isEnabled else {
                            return false
                        }
                        unsavedAfterDeclining = (try? Data(contentsOf: path)) == before
                        stage = 5
                        save.performClick(nil)
                    case 5:
                        guard let confirm = button("automation.settings.saveEmpty", in: views) else { return false }
                        stage = 6
                        confirm.performClick(nil)
                        return true
                    default: break
                    }
                    return false
                }
            ) { controller.manage() }
            check(created.acted && !created.timedOut && stage == 6, "the Create Automation chain was driven to Save")
            check(
                settingsShown,
                "G384 Add opens editable automation settings before any saved-library change")
            check(unsavedAtSettings, "G384 using new settings changes only the manager working copy")
            check(unsavedAfterDeclining, "G384 declining to save an automation with no rules saves nothing")
            let after = try stored()
            check(
                after.workflows.count == countBefore + 1 && after.workflows.last?.name == "Created through settings"
                    && after.workflows.last?.shortcut == "q" && after.workflows.last?.steps == []
                    && after.workflows.last?.input == .document && after.workflows.last?.output == .editor,
                "G384 explicit manager Save stores the new automation with its chosen settings")
            let saved = try Data(contentsOf: path)
            stage = 0
            let abandoned = drivingModal(
                timeout: 20,
                { _, views in
                    switch stage {
                    case 0:
                        guard let create = button("automation.create", in: views) else { return false }
                        stage = 1
                        create.performClick(nil)
                    case 1:
                        guard let cancel = button("automation.settings.cancel", in: views) else { return false }
                        stage = 2
                        cancel.performClick(nil)
                    case 2:
                        guard let cancel = button("automation.manager.cancel", in: views), cancel.isEnabled else {
                            return false
                        }
                        stage = 3
                        cancel.performClick(nil)
                        return true
                    default: break
                    }
                    return false
                }
            ) { controller.manage() }
            check(
                try abandoned.acted && !abandoned.timedOut && Data(contentsOf: path) == saved,
                "G384 Cancel in the settings dialog of a new automation saves nothing")
        }

        Checks.section("G364 and G381: Advanced JSON, Insert Example and Restore Default Automations") {
            try controller.persistLibrary(AutomationLibrary(workflows: []))
            let empty = try Data(contentsOf: path)
            var stage = 0, initialJSON = "", referenceText = "", helpShown = false
            var afterFirst: AutomationLibrary?, afterSecond: AutomationLibrary?
            let advanced = drivingAdvanced(
                timeout: 20, controller: controller, commit: false,
                { _, views in
                    guard let json = textView("Automation library JSON", in: views),
                        let example = button("automation.json.example", in: views),
                        let cancel = button("automation.json.cancel", in: views)
                    else { return false }
                    switch stage {
                    case 0:
                        stage = 1
                        initialJSON = json.string
                        referenceText = textView("Rule kinds reference", in: views)?.string ?? ""
                        helpShown = shows(AutomationDefinition.advancedHelp, in: views)
                        example.performClick(nil)
                    case 1:
                        stage = 2
                        afterFirst = try? AutomationLibrary.decode(Data(json.string.utf8))
                        example.performClick(nil)
                    case 2:
                        stage = 3
                        afterSecond = try? AutomationLibrary.decode(Data(json.string.utf8))
                        cancel.performClick(nil)
                        return true
                    default: break
                    }
                    return false
                }
            )
            check(advanced.acted && !advanced.timedOut && stage == 3, "the Advanced JSON dialog was driven")
            check(
                (try? AutomationLibrary.decode(Data(initialJSON.utf8)))?.workflows.isEmpty == true,
                "G364 an empty library is shown as an empty library, not pre-filled with the example")
            check(
                afterFirst?.workflows == [AutomationDefinition.example],
                "G364 Insert Example adds the example automation to the JSON in the editor")
            check(
                afterSecond?.workflows.count == 2 && afterSecond?.workflows[1].id != AutomationDefinition.example.id
                    && afterSecond?.workflows[1].steps == AutomationDefinition.example.steps,
                "G364 a second Insert Example gets its own identifier")
            check(
                (try Data(contentsOf: path)) == empty, "G364 Insert Example followed by Cancel saves nothing")
            check(
                helpShown && referenceText == AutomationDefinition.ruleKindReference
                    && Step.Kind.allCases.allSatisfy { referenceText.contains($0.rawValue) },
                "G381 the Advanced JSON dialog shows the generated help and every rule kind")
            var correctedDefinition = AutomationDefinition.example
            correctedDefinition.name = "Library JSON retry"
            let correctedLibrary = AutomationLibrary(workflows: [correctedDefinition])
            let correctedJSON = String(decoding: try correctedLibrary.encoded(), as: UTF8.self)
            let invalidJSON = "{ keep this invalid JSON draft"
            var jsonStage = 0, nestedJSONError = false, retryKeptDraft = false
            var retryKeptStorage = false, inlineJSONError = false
            var jsonWindow: NSWindow?
            let retryJSON = drivingAdvanced(
                timeout: 20, controller: controller, commit: true,
                { window, views in
                    if jsonStage == 1, window !== jsonWindow {
                        nestedJSONError = true
                        NSApp.abortModal()
                        return false
                    }
                    guard let json = textView("Automation library JSON", in: views),
                        let save = button("automation.json.save", in: views)
                    else { return false }
                    switch jsonStage {
                    case 0:
                        jsonWindow = window
                        json.string = invalidJSON
                        jsonStage = 1
                        save.performClick(nil)
                    case 1:
                        retryKeptDraft = json.string == invalidJSON
                        retryKeptStorage = (try? Data(contentsOf: path)) == empty
                        inlineJSONError = json.accessibilityHelp()?.isEmpty == false
                        json.string = correctedJSON
                        jsonStage = 2
                        save.performClick(nil)
                        return true
                    default: break
                    }
                    return false
                }
            )
            check(
                retryJSON.acted && !retryJSON.timedOut && jsonStage == 2, "F155 JSON retry completes after correction")
            check(retryKeptDraft && retryKeptStorage, "F155 rejected JSON keeps the draft and saved library unchanged")
            check(
                !nestedJSONError && inlineJSONError,
                "F155 invalid library JSON is marked in its editor without a nested error modal")
            check(try stored() == correctedLibrary, "F155 corrected JSON saves only on the explicit second Save")
            var importedDefinition = correctedDefinition
            importedDefinition.id = UUID()
            importedDefinition.name = "Imported library draft"
            let importedLibrary = AutomationLibrary(workflows: [importedDefinition])
            let importURL = path.deletingLastPathComponent().appendingPathComponent("library-import.json")
            let exportURL = path.deletingLastPathComponent().appendingPathComponent("library-export.json")
            try importedLibrary.encoded().write(to: importURL)
            let beforeImport = try Data(contentsOf: path)
            let originalPanels = controller.jsonFilePanels
            defer { controller.jsonFilePanels = originalPanels }
            var chosenImport: URL? = importURL, exportNames: [String] = []
            controller.jsonFilePanels = .init(
                importURL: { chosenImport },
                exportURL: { name in
                    exportNames.append(name)
                    return exportURL
                })
            var fileStage = 0, importedOnlyDraft = false, exportedOnlyDraft = false
            let files = drivingAdvanced(
                timeout: 20, controller: controller, commit: false,
                { _, views in
                    guard let json = textView("Automation library JSON", in: views),
                        let load = button("automation.json.import", in: views),
                        let export = button("automation.json.export", in: views),
                        let cancel = button("automation.json.cancel", in: views)
                    else { return false }
                    switch fileStage {
                    case 0:
                        fileStage = 1
                        load.performClick(nil)
                    case 1:
                        importedOnlyDraft =
                            (try? AutomationLibrary.decode(Data(json.string.utf8))) == importedLibrary
                            && (try? Data(contentsOf: path)) == beforeImport
                        fileStage = 2
                        export.performClick(nil)
                    case 2:
                        exportedOnlyDraft =
                            (try? AutomationLibrary.decode(Data(contentsOf: exportURL))) == importedLibrary
                            && (try? Data(contentsOf: path)) == beforeImport
                        fileStage = 3
                        cancel.performClick(nil)
                        return true
                    default: break
                    }
                    return false
                }
            )
            check(
                files.acted && !files.timedOut && fileStage == 3,
                "F155 Automation Import and Export run through isolated file choices")
            check(
                importedOnlyDraft && exportedOnlyDraft,
                "F155 import and export only change or copy the Automation draft")
            check(
                try Data(contentsOf: path) == beforeImport && stored() == correctedLibrary,
                "F155 Cancel after import and export leaves the saved Automation library untouched")
            check(exportNames == ["TextTank-Automations.json"], "F155 Automation export keeps its documented filename")
            let refusedURL = path.deletingLastPathComponent().appendingPathComponent("library-import-link.json")
            try FileManager.default.createSymbolicLink(at: refusedURL, withDestinationURL: importURL)
            chosenImport = refusedURL
            fileStage = 0
            var refusedDraft = false, clearedImportError = false
            let refusedImport = drivingAdvanced(
                timeout: 20, controller: controller, commit: true,
                { _, views in
                    guard let json = textView("Automation library JSON", in: views),
                        let load = button("automation.json.import", in: views),
                        let save = button("automation.json.save", in: views)
                    else { return false }
                    switch fileStage {
                    case 0:
                        json.string = correctedJSON + "\n "
                        fileStage = 1
                        load.performClick(nil)
                    case 1:
                        refusedDraft =
                            json.string == correctedJSON + "\n "
                            && json.accessibilityHelp()?.isEmpty == false
                            && (try? Data(contentsOf: path)) == beforeImport
                        chosenImport = importURL
                        fileStage = 2
                        load.performClick(nil)
                    case 2:
                        clearedImportError =
                            json.accessibilityHelp() == nil
                            && (try? AutomationLibrary.decode(Data(json.string.utf8))) == importedLibrary
                        fileStage = 3
                        save.performClick(nil)
                        return true
                    default: break
                    }
                    return false
                }
            )
            check(
                refusedImport.acted && !refusedImport.timedOut && refusedDraft,
                "F155 refused symlink import keeps the Automation draft and saved bytes")
            check(clearedImportError, "F155 a corrected import clears the previous inline error")
            check(
                try stored() == importedLibrary
                    && controller.menu().items.contains {
                        $0.representedObject as? String == importedDefinition.id.uuidString
                    }, "F155 explicit imported Save persists and rebuilds the Automation menu")
            check(
                try Data(contentsOf: importURL) == importedLibrary.encoded()
                    && FileManager.default.destinationOfSymbolicLink(atPath: refusedURL.path) == importURL.path,
                "F155 a refused import preserves the link and its target")
            let suggestedRecovery = "Keep this isolated JSON draft and choose Cancel."
            let suggestedError = NSError(
                domain: "Fixture.JSONRecovery", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Fixture JSON operation failed",
                    NSLocalizedRecoverySuggestionErrorKey: suggestedRecovery
                ])
            var suggestionStage = 0, sawNativeSuggestion = false, suggestionSaves = 0
            var suggestionWindow: NSWindow?
            let suggestionDraft = AutomationLibrary(workflows: [])
            let suggestionRun = try drivingModal(
                timeout: 10,
                { window, views in
                    if suggestionStage == 1, window !== suggestionWindow {
                        sawNativeSuggestion = shows(suggestedRecovery, in: views)
                        if let accept = views.compactMap({ $0 as? NSButton }).first(where: { $0.keyEquivalent == "\r" })
                        {
                            accept.performClick(nil)
                        } else {
                            NSApp.abortModal()
                        }
                        return false
                    }
                    guard let save = button("fixture.json.save", in: views),
                        let cancel = button("fixture.json.cancel", in: views)
                    else { return false }
                    if suggestionStage == 0 {
                        suggestionWindow = window
                        suggestionStage = 1
                        MainRunLoop.perform { save.performClick(nil) }
                    } else if suggestionStage == 1 {
                        suggestionStage = 2
                        cancel.performClick(nil)
                        return true
                    }
                    return false
                }
            ) {
                try JSONLibraryEditor.edit(
                    suggestionDraft,
                    configuration: .init(
                        title: "Fixture JSON recovery", information: "Isolated error recovery check.",
                        accessibilityLabel: "Fixture library JSON", exportName: "fixture.json",
                        identifier: "fixture.json", size: NSSize(width: 420, height: 160)),
                    read: { _ in Data() },
                    save: { _ in
                        suggestionSaves += 1
                        throw suggestedError
                    })
            }
            check(
                suggestionRun.acted && !suggestionRun.timedOut && suggestionStage == 2 && suggestionSaves == 1,
                "F155 a shared JSON operation failure returns to its unchanged draft")
            check(
                sawNativeSuggestion,
                "F155 shared JSON errors retain native recovery suggestions even without a recovery attempter")
            let restoreItem = controller.menu().items.first { $0.title == "Restore Default Automations…" }
            check(
                restoreItem != nil && restoreItem?.target === controller
                    && restoreItem.map(controller.validateMenuItem) == true,
                "G364 the Automations menu has an enabled Restore Default Automations command")
            // Keep one edited automation, then restore twice.
            var mine = AutomationDefinition.example
            mine.name = "My edited cleanup"
            mine.steps = [Step(kind: .trimWhitespace)]
            try controller.persistLibrary(AutomationLibrary(workflows: [mine]))
            func restore(confirming: Bool) -> Bool {
                let run = drivingModal(
                    timeout: 10,
                    { _, views in
                        guard let confirm = button("automation.restore.confirm", in: views),
                            let cancel = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Cancel" })
                        else { return false }
                        (confirming ? confirm : cancel).performClick(nil)
                        return true
                    }
                ) { controller.restoreDefaultAutomations() }
                return run.acted && !run.timedOut
            }
            check(
                try restore(confirming: false) && stored().workflows == [mine],
                "G364 cancelling Restore Default Automations changes nothing")
            check(restore(confirming: true), "Restore Default Automations was confirmed")
            let restored = try stored()
            let presets = AutomationDefinition.firstRunPresets
            check(
                restored.workflows.count == 3 && restored.workflows[0] == mine
                    && restored.workflows.dropFirst().map(\.name) == presets.map(\.name)
                    && restored.workflows.dropFirst().map(\.steps) == presets.map(\.steps)
                    && restored.workflows.dropFirst().map(\.output) == presets.map(\.output),
                "G364 restoring appends the current presets and keeps the edited automation as it was")
            check(
                Set(restored.workflows.map(\.id)).count == 3
                    && restored.workflows.dropFirst().allSatisfy { copy in !presets.contains { $0.id == copy.id } },
                "G364 restored presets get new identifiers")
            check(
                try restore(confirming: true) && stored().workflows.count == 5
                    && Array(stored().workflows.prefix(3)) == restored.workflows,
                "G364 restoring again appends again and overwrites nothing")
        }

        Checks.section("F75 a failed first write does not block the session") {
            let locked = root.appendingPathComponent("package15-locked", isDirectory: true)
            let lockedSupport = locked.appendingPathComponent("support", isDirectory: true)
            let lockedPath = lockedSupport.appendingPathComponent("Automations.json")
            try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
            setenv("TEXTTANK_SUPPORT_DIRECTORY", lockedSupport.path, 1)
            let blocked = AutomationController(editorProvider: { nil }, newDocument: { _ in })
            setenv("TEXTTANK_SUPPORT_DIRECTORY", support.path, 1)
            try require(
                !FileManager.default.fileExists(atPath: lockedPath.path),
                "fixture: the first write of the presets failed")
            check(
                blocked.toolbarIdentifiers().count == 2
                    && blocked.menu().items.contains { $0.title == AutomationDefinition.example.name },
                "F75 the presets are available in memory after a failed first write")
            // Manage reports the failure once, then opens as usual.
            var reports: [String] = [], manageOpened = 0
            func manageAndCancel() -> Bool {
                var stage = 0
                let run = drivingModal(
                    timeout: 10,
                    { _, views in
                        if stage == 0, let ok = errorAlertButton(in: views) {
                            stage = 1
                            reports.append(errorAlertText(in: views))
                            ok.performClick(nil)
                            return false
                        }
                        guard let cancel = button("automation.manager.cancel", in: views) else { return false }
                        manageOpened += 1
                        cancel.performClick(nil)
                        return true
                    }
                ) { blocked.manage() }
                return run.acted && !run.timedOut
            }
            check(manageAndCancel() && manageAndCancel(), "Manage Automations opened twice while the folder was locked")
            check(
                reports.count == 1 && reports[0].contains("could not be saved yet") && manageOpened == 2,
                "F75 the failed first write is reported once and Manage Automations still opens")
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
            var renamed = AutomationLibrary(workflows: AutomationDefinition.firstRunPresets)
            renamed.workflows[0].name = "Saved after the folder was unlocked"
            try blocked.persistLibrary(renamed)
            check(
                (try AutomationLibrary.decode(Data(contentsOf: lockedPath))) == renamed,
                "F75 once the folder is writable the next save succeeds")
            // The other branch: an existing library that cannot be read still blocks every write.
            let unreadable = root.appendingPathComponent("package15-unreadable", isDirectory: true)
            try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
            let unreadablePath = unreadable.appendingPathComponent("Automations.json")
            let damaged = Data("{ not a library".utf8)
            try damaged.write(to: unreadablePath)
            setenv("TEXTTANK_SUPPORT_DIRECTORY", unreadable.path, 1)
            let refusing = AutomationController(editorProvider: { nil }, newDocument: { _ in })
            setenv("TEXTTANK_SUPPORT_DIRECTORY", support.path, 1)
            rejects("F75 an existing unreadable library still refuses every save") {
                try refusing.persistLibrary(renamed)
            }
            check(
                (try Data(contentsOf: unreadablePath)) == damaged && refusing.toolbarIdentifiers().isEmpty,
                "F75 an existing unreadable library is never overwritten and no presets are substituted")
        }
    }
    @MainActor static func horizontalDialogChecks() throws {
        let ownership = TTAlert()
        let alertObject: AnyObject = ownership
        check(!(alertObject is NSAlert), "F304 the horizontal dialog owns its panel instead of subclassing NSAlert")
        ownership.addButton(withTitle: "OK")
        let acknowledgmentRoles = ownership.keyRoles()
        check(
            acknowledgmentRoles.returnIndex == 0 && acknowledgmentRoles.escapeIndex == 0,
            "F16 a single acknowledgment has both Return and Escape as a way out")
        let localizedCancel = TTAlert()
        localizedCancel.addButton(withTitle: "Proceed")
        localizedCancel.addButton(withTitle: "Annuler", role: .cancel)
        check(localizedCancel.keyRoles().escapeIndex == 1, "F16 an explicit cancel role is independent of its title")
        check(
            TTAlert.Result(.abort) == .dismissed && TTAlert.Result(.stop) == .dismissed,
            "F16 unexpected modal termination is a typed dismissal, never a Save choice")
        let recoveryError = NSError(
            domain: "Fixture.Error", code: 7,
            userInfo: [
                NSLocalizedDescriptionKey: "Fixture failure",
                NSLocalizedRecoverySuggestionErrorKey: "Try the fixture again.",
                NSLocalizedRecoveryOptionsErrorKey: ["Retry Fixture", "Cancel Fixture"],
                NSRecoveryAttempterErrorKey: NSObject()
            ])
        let nativeError = TTAlert.errorAlert(recoveryError)
        check(
            nativeError.messageText == "Fixture failure"
                && nativeError.informativeText.contains("Try the fixture again.")
                && nativeError.buttons.map(\.title) == ["Retry Fixture", "Cancel Fixture"],
            "F325 shared error presentation preserves native recovery suggestion and choices")
        let recoverySpy = Audit24RecoverySpy()
        let recoverable = NSError(
            domain: "Fixture.NativeRecovery", code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "Fixture recoverable error",
                NSLocalizedRecoverySuggestionErrorKey: "Retry this isolated fixture.",
                NSLocalizedRecoveryOptionsErrorKey: ["Retry Fixture", "Cancel Fixture"],
                NSRecoveryAttempterErrorKey: recoverySpy
            ])
        let recoveryDeadline = Date().addingTimeInterval(10)
        var recoveryPressed = false
        func recoveryButtons(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(recoveryButtons)
        }
        let recoveryAnswer = Timer(timeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let content = presentedFormWindow?.contentView else { return }
                if Date() > recoveryDeadline {
                    NSApp.abortModal()
                    return
                }
                guard !recoveryPressed,
                    let retry = recoveryButtons(content).first(where: { $0.title == "Retry Fixture" })
                else { return }
                recoveryPressed = true
                retry.performClick(nil)
            }
        }
        RunLoop.main.add(recoveryAnswer, forMode: .modalPanel)
        TTAlert.present(recoverable)
        recoveryAnswer.invalidate()
        check(
            recoveryPressed && recoverySpy.attempts == [0],
            "F325 shared native error presentation invokes the original recovery attempter with the chosen option")
        let sheetParent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled],
            backing: .buffered, defer: false)
        sheetParent.isReleasedWhenClosed = false
        defer { sheetParent.close() }
        let sheet = TTAlert()
        sheet.messageText = "Fixture recovery notice"
        sheet.addButton(withTitle: "Close")
        var sheetResponse: NSApplication.ModalResponse?
        sheet.beginSheetModal(for: sheetParent) { sheetResponse = $0 }
        check(sheet.window.sheetParent === sheetParent, "F304 the owned dialog presents as a native sheet")
        sheet.buttons[0].performClick(nil)
        spinUntil("the fixture sheet ends after its button") { sheetResponse != nil }
        check(
            sheetResponse == .alertFirstButtonReturn && sheetParent.attachedSheet == nil,
            "F304 a native sheet ends with its original button response")
        weak var releasedSheet: TTAlert?
        var ephemeralResponse: NSApplication.ModalResponse?
        autoreleasepool {
            let ephemeral = TTAlert()
            ephemeral.addButton(withTitle: "Close")
            releasedSheet = ephemeral
            ephemeral.beginSheetModal(for: sheetParent) { ephemeralResponse = $0 }
        }
        check(releasedSheet != nil, "F304 a native sheet survives the caller's local alert scope")
        autoreleasepool { releasedSheet?.buttons[0].performClick(nil) }
        spinUntil("the locally scoped sheet completes and releases its owner") { releasedSheet == nil }
        check(
            ephemeralResponse == .alertFirstButtonReturn && releasedSheet == nil,
            "F304 a locally scoped sheet still responds and releases its owner on completion")
        // A negative lifetime probe can leave an ownerless sheet: clean only this fixture
        // after observing its failure so later modal checks still report their own results.
        if let orphan = sheetParent.attachedSheet { sheetParent.endSheet(orphan, returnCode: .abort) }
        let alert = TTAlert()
        alert.messageText = "Horizontal action regression"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 28))
        field.stringValue = "Draft survives reopening"
        alert.accessoryView = field
        for title in ["Save", "Cancel", "Reset Defaults"] { alert.addButton(withTitle: title) }
        for index in [2, 1, 0] {
            var aligned = false
            // The fixture and action are main-actor isolated. Timer transports only this
            // Sendable actor-bound function, not the non-Sendable dialog object itself.
            let chooseButton: @MainActor @Sendable () -> Void = {
                let frames = alert.buttons.map { $0.convert($0.bounds, to: alert.window.contentView) }
                print("ACTION_GEOMETRY", index, frames)
                fflush(stdout)
                aligned =
                    frames.allSatisfy { abs($0.midY - frames[0].midY) < 1 } && frames[2].maxX < frames[1].minX
                    && frames[1].maxX < frames[0].minX
                alert.buttons[index].performClick(nil)
            }
            let timer = Timer(timeInterval: 0.1, repeats: false) { _ in
                MainActor.assumeIsolated { chooseButton() }
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            let response = alert.runModal()
            timer.invalidate()
            check(
                response.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index,
                "horizontal dialog preserves response index \(index)")
            check(aligned, "horizontal dialog actions remain side by side on presentation \(index)")
            check(
                field.stringValue == "Draft survives reopening",
                "horizontal dialog preserves accessory on presentation \(index)")
        }
    }
    static func staleModelessJSONCheck() throws {
        let isolated = try IsolatedSupportDirectory("ModelessUnicodeConfiguration")
        defer { isolated.restore() }
        let controller = AutomationController(editorProvider: { nil }, newDocument: { _ in })
        var definition = AutomationDefinition.example
        definition.name = "Caf\u{e9}"
        let original = AutomationLibrary(workflows: [definition])
        try controller.persistLibrary(original)
        controller.manageAdvanced()
        let window = try requireValue(FormPanel.frontWindow, "fixture: native advanced configuration window")
        let views = descendants(try requireValue(window.contentView, "fixture: advanced content"))
        let text = try requireValue(textView("Automation library JSON", in: views), "fixture: advanced JSON text")
        check(NSApp.modalWindow == nil && window.isVisible, "DG advanced JSON is a real modeless editor")
        var pending = original
        pending.workflows[0].name = "Pending name"
        let pendingText = String(decoding: try pending.encoded(), as: UTF8.self)
        text.string = pendingText
        var intervening = original
        intervening.workflows[0].name = "Cafe\u{301}"
        try controller.persistLibrary(intervening)
        let path = isolated.url.appendingPathComponent("Automations.json")
        let saved = try Data(contentsOf: path)
        button("automation.json.save", in: views)?.performClick(nil)
        check(
            window.isVisible && text.string == pendingText,
            "DG an intervening native controller write preserves pending JSON and its window")
        let after = try Data(contentsOf: path)
        let held = try AutomationLibrary.decode(saved)
        check(
            after == saved && Data(held.workflows[0].name.utf8) == Data("Cafe\u{301}".utf8),
            "DG byte-distinct NFC/NFD controller saves cannot be overwritten by an older modeless form")
        check(
            text.accessibilityHelp()?.contains("changed while this window was open") == true,
            "DG the stale JSON field is marked with the conflict and how to recover")
        button("automation.json.cancel", in: views)?.performClick(nil)
        if let manager = FormPanel.frontWindow, manager.identifier?.rawValue == "automation.manager" {
            button("automation.manager.cancel", in: descendants(manager.contentView!))?.performClick(nil)
        }
    }

    static func main() {
        Checks.run("AutomationControllerChecks") {
            let isolatedSupport = try IsolatedSupportDirectory("TextTankAutomationControllerChecks"),
                root = isolatedSupport.url
            defer { isolatedSupport.restore() }
            NativeFixtureEnvironment.install()
            defer { NativeFixtureEnvironment.restore() }
            _ = NSApplication.shared
            Checks.section("horizontal dialog actions") { try horizontalDialogChecks() }
            Checks.section("modeless Unicode controller conflict") { try staleModelessJSONCheck() }
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered,
                defer: false)
            let editor = TTEditor(frame: window.contentView!.bounds)
            window.contentView = editor
            var newDocumentCalls = 0
            let controller = AutomationController(
                editorProvider: { editor }, newDocument: { _ in newDocumentCalls += 1 })
            let path = root.appendingPathComponent("Automations.json")
            var saved = try AutomationLibrary.decode(Data(contentsOf: path))
            // The toolbar host and the pinned identifier outlive the section that installs them.
            let toolbarHost = AutomationToolbarHost(controller)
            var pinnedIdentifier: NSToolbarItem.Identifier?
            Checks.section("direct cleanup, toolbar and recipe safety") {
                check(saved.workflows.count == 2, "new configuration seeds two ordinary saved workflows")
                check(
                    saved.workflows[0].output == .editor && saved.workflows[1].output == .reminders,
                    "separate cleanup and send definitions")
                check(controller.toolbarIdentifiers().count == 2, "two individual pinned toolbar buttons available")
                let source = "# Ingredients\n- **2 eggs**\n- ½ cup flour\n"
                editor.text = source
                editor.resetUndoHistory()
                editor.setSavePoint()
                // F278, F302: a macro recording is discarded when an automation runs, not when
                // the palette asks which editor is current and is then cancelled.
                var invocations = 0
                controller.onInvocation = { invocations += 1 }
                let palette = drivingModal(
                    timeout: 20,
                    { paletteWindow, views in
                        guard let cancel = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Cancel" })
                        else { return false }
                        if let filter = field("automation.palette.filter", in: views),
                            let table = views.compactMap({ $0 as? NSTableView }).first
                        {
                            filter.selectText(nil)
                            typeKeys(AutomationDefinition.example.name, in: paletteWindow)
                            paletteWindow.makeFirstResponder(table)
                            check(
                                invocations == 0 && table.numberOfRows == 1,
                                "DG typing and leaving the actual automation filter never invokes it")
                        }
                        cancel.performClick(nil)
                        return true
                    }
                ) { controller.showPalette() }
                check(
                    palette.acted && !palette.timedOut && invocations == 0 && editor.text == source,
                    "opening and cancelling the automation palette is not an invocation")
                try controller.runSavedAutomation(id: AutomationDefinition.example.id)
                check(invocations == 1, "running a saved automation reports one invocation")
                check(
                    editor.text == "2 eggs\n½ cup flour\n",
                    "cleanup applies directly to actual editor without preview dialog")
                editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
                check(editor.text == source, "direct cleanup is one Undo action")
                saved.workflows[0].name = "My recipe tidy"
                saved.workflows[0].shortcut = "k"
                saved.workflows[0].previewBeforeApply = nil
                try controller.persistLibrary(saved)
                let identifier = try requireValue(
                    controller.toolbarIdentifiers().first, "fixture: a pinned toolbar identifier exists")
                pinnedIdentifier = identifier
                let toolbar = NSToolbar(identifier: "TextTank.AutomationControllerChecks")
                toolbar.delegate = toolbarHost
                window.toolbar = toolbar
                let button = try requireValue(
                    toolbar.items.first(where: { $0.itemIdentifier == identifier }),
                    "fixture: standard toolbar item is installed")
                check(
                    button.toolbar === toolbar && button.view == nil,
                    "named automation is installed as a standard native toolbar item")
                check(button.label == "My recipe tidy", "renaming updates individual toolbar item label")
                editor.text = source
                editor.resetUndoHistory()
                check(
                    NSApp.sendAction(button.action!, to: button.target, from: button),
                    "toolbar action reaches shared stable-ID dispatcher")
                check(
                    editor.text == "2 eggs\n½ cup flour\n", "absent preview flag applies same saved definition directly"
                )
                let browserInput = try String(
                    contentsOf: TestPaths.fixtures.appendingPathComponent("recipe-browser-plain-input.txt"),
                    encoding: .utf8)
                let browserExpected = try String(
                    contentsOf: TestPaths.fixtures.appendingPathComponent("recipe-browser-cleaned-expected.txt"),
                    encoding: .utf8)
                let windowCount = NSApp.windows.count
                editor.text = browserInput
                editor.resetUndoHistory()
                editor.setSavePoint()
                check(
                    NSApp.sendAction(button.action!, to: button.target, from: button),
                    "observed browser recipe runs through actual named toolbar button")
                let cleanedRows = editor.text.components(separatedBy: .newlines).filter { !$0.isEmpty }
                check(cleanedRows.count == 28, "observed full browser recipe produces all 28 ingredient rows")
                check(
                    editor.text == browserExpected,
                    "native recipe output exactly preserves quantities options duplicates and copied spacing")
                check(
                    editor.window === window && window.contentView === editor && NSApp.windows.count == windowCount,
                    "recipe cleanup stays in same editor and window")
                check(newDocumentCalls == 0, "recipe cleanup never invokes new-document output")
                editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
                check(editor.text == browserInput, "one native Undo restores exact original browser clipboard text")
                let ambiguous = browserInput + "\nunmarked ingredient continuation\n"
                editor.text = ambiguous
                editor.resetUndoHistory()
                editor.setSavePoint()
                let unchangedRevision = editor.revision
                var rejectedAmbiguous = false
                do { try controller.runSavedAutomation(id: AutomationDefinition.example.id) } catch {
                    rejectedAmbiguous = true
                }
                check(rejectedAmbiguous, "unknown unmarked recipe row rejects cleanup")
                check(
                    editor.text == ambiguous && editor.revision == unchangedRevision && !editor.modified,
                    "ambiguous recipe rejection leaves original bytes undo and dirty state untouched")
                var slowPattern = saved
                slowPattern.workflows[0].steps = [.init(kind: .clearLinesMatching, find: "(a+)+$")]
                try controller.persistLibrary(slowPattern)
                let slowInput = String(repeating: "a", count: 32) + "!"
                editor.text = slowInput
                editor.resetUndoHistory()
                editor.setSavePoint()
                let slowRevision = editor.revision, started = ProcessInfo.processInfo.systemUptime
                var rejectedSlow = false
                do { try controller.runSavedAutomation(id: AutomationDefinition.example.id) } catch {
                    rejectedSlow = true
                }
                check(
                    rejectedSlow && ProcessInfo.processInfo.systemUptime - started < 2,
                    "pathological user regex stops promptly before native apply")
                check(
                    editor.text == slowInput && editor.revision == slowRevision && !editor.modified,
                    "regex timeout leaves exact native document and dirty state untouched")
            }
            try controller.persistLibrary(saved)
            let beforeReload = try Data(contentsOf: path)
            let restarted = AutomationController(
                editorProvider: { editor }, newDocument: { _ in fatalError("unexpected output") })
            Checks.section("restart, menu, selections and output targets") {
                check(
                    try Data(contentsOf: path) == beforeReload,
                    "existing named configuration is not replaced or rewritten by presets")
                check(
                    restarted.makeToolbarItem(
                        identifier: try requireValue(
                            pinnedIdentifier, "fixture: the pinned toolbar identifier was captured"))?.label
                        == "My recipe tidy", "toolbar stable identity survives configuration reload")
                let menuItem = try requireValue(
                    restarted.menu().items.first(where: {
                        ($0.representedObject as? String) == AutomationDefinition.example.id.uuidString
                    }), "fixture: the automation has a menu item")
                check(
                    menuItem.title == "My recipe tidy" && menuItem.keyEquivalent == "k",
                    "menu and shortcut use renamed saved definition")
                saved.workflows[0].input = .selection
                try restarted.persistLibrary(saved)
                let selectionSource = "before\n- 2 eggs\n- ½ cup flour\nafter"
                editor.text = selectionSource
                editor.resetUndoHistory()
                check(
                    editor.setSelectionAnchor(
                        "before\n".utf8.count, caret: "before\n- 2 eggs\n- ½ cup flour\n".utf8.count),
                    "selection test captures exact ingredient range")
                try restarted.runSavedAutomation(id: AutomationDefinition.example.id)
                check(
                    editor.text == "before\n2 eggs\n½ cup flour\nafter",
                    "configured selection cleanup preserves surrounding document")
                editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
                check(editor.text == selectionSource, "selection cleanup undoes together")
                let multiSource = "- 2 eggs | - ½ cup flour"
                editor.text = multiSource
                editor.resetUndoHistory()
                editor.setSavePoint()
                check(
                    editor.setSelectionRanges([
                        TTSelectionRange(anchor: 0, caret: 8),
                        TTSelectionRange(anchor: multiSource.utf8.count, caret: 11)
                    ]), "set separate reversed Unicode selections")
                try restarted.runSavedAutomation(id: AutomationDefinition.example.id)
                check(
                    editor.text == "2 eggs | ½ cup flour", "automation transforms each captured selection independently"
                )
                editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
                check(editor.text == multiSource, "multiple automation selections undo together")
                saved.workflows[0].steps = [.init(kind: .clearLinesMatching, find: "(a+)+$")]
                try restarted.persistLibrary(saved)
                let multiFailure = "safe | " + String(repeating: "a", count: 32) + "!"
                editor.text = multiFailure
                editor.resetUndoHistory()
                editor.setSavePoint()
                _ = editor.setSelectionRanges([
                    TTSelectionRange(anchor: 0, caret: 4),
                    TTSelectionRange(anchor: 7, caret: multiFailure.utf8.count)
                ])
                rejects("a later selection that times out rejects the whole run") {
                    try restarted.runSavedAutomation(id: AutomationDefinition.example.id)
                }
                check(
                    editor.text == multiFailure && !editor.modified,
                    "later selection failure preserves all earlier selections")
                saved.workflows[0].steps = AutomationDefinition.example.steps
                _ = editor.setSelectionAnchor(0, caret: 0)
                saved.workflows[0].input = .document
                saved.workflows[0].output = .newDocument
                var capturedNewDocument: String?
                let outputController = AutomationController(
                    editorProvider: { editor }, newDocument: { capturedNewDocument = $0 })
                try outputController.persistLibrary(saved)
                editor.text = "- eggs\n- flour"
                editor.resetUndoHistory()
                editor.setSavePoint()
                _ = editor.setSelectionRanges([
                    TTSelectionRange(anchor: 0, caret: 6),
                    TTSelectionRange(anchor: 7, caret: 14)
                ])
                try outputController.runSavedAutomation(id: AutomationDefinition.example.id)
                check(
                    editor.text == "- eggs\n- flour" && !editor.modified && capturedNewDocument == "eggs\nflour",
                    "document input external output never mutates multi-selection editor")
                saved.workflows[0].output = .editor
                try restarted.persistLibrary(saved)
                _ = editor.setSelectionAnchor(0, caret: 0)
                editor.readOnly = true
                rejects("read-only editor rejects the automation as read-only", message: "This document is read-only") {
                    try restarted.runSavedAutomation(id: AutomationDefinition.example.id)
                }
                check(
                    editor.text == "- eggs\n- flour" && !editor.modified,
                    "read-only automation explicitly rejects without changes")
                // G369: the read-only reason comes before any parameter prompt or preview.
                let unprompted = saved
                saved.workflows[0].steps = [
                    .init(kind: .replaceLiteral, find: "eggs", replacement: "milk", askForFind: true)
                ]
                saved.workflows[0].previewBeforeApply = true
                try restarted.persistLibrary(saved)
                var prompted = false, refusal = ""
                let lockedRun = drivingModal(
                    timeout: 10,
                    { _, _ in
                        prompted = true
                        NSApp.abortModal()
                        return true
                    }
                ) {
                    do { try restarted.runSavedAutomation(id: AutomationDefinition.example.id) } catch {
                        refusal = error.localizedDescription
                    }
                }
                check(
                    !prompted && !lockedRun.timedOut && refusal.contains("This document is read-only"),
                    "a read-only document refuses an automation before its prompts and preview")
                check(
                    editor.text == "- eggs\n- flour" && !editor.modified,
                    "an automation refused before its prompts changes nothing")
                saved = unprompted
                try restarted.persistLibrary(saved)
                editor.readOnly = false
                // F207: while a Reminders export runs, automation commands say so instead of doing nothing.
                restarted.exportInProgress = true
                rejects(
                    "running an automation during a Reminders export says an export is in progress",
                    message: "A Reminders export is in progress"
                ) { try restarted.runSavedAutomation(id: AutomationDefinition.example.id) }
                var explained = ""
                let managing = drivingModal(
                    timeout: 10,
                    { modal, views in
                        explained = views.compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: "\n")
                        NSApp.abortModal()
                        return true
                    }
                ) { restarted.manage() }
                check(
                    managing.acted && !managing.timedOut && explained.contains("A Reminders export is in progress"),
                    "Manage Automations during a Reminders export explains why it does not open")
                check(
                    editor.text == "- eggs\n- flour" && !editor.modified,
                    "commands refused during a Reminders export change nothing")
                restarted.exportInProgress = false
                saved.workflows[0].pinToToolbar = false
                try restarted.persistLibrary(saved)
                check(restarted.toolbarIdentifiers().count == 1, "toolbar pin setting hides only configured workflow")
            }
            Checks.section("user recipe samples") {
                // Four literal user examples run through a persisted named automation.
                // No connector or new-document output is invoked by recipe cleanup.
                let preservedWorkflow = saved.workflows[0]
                saved.workflows[0].name = "My ingredient cleanup"
                saved.workflows[0].input = .document
                saved.workflows[0].output = .editor
                saved.workflows[0].previewBeforeApply = false
                saved.workflows[0].steps =
                    try AutomationRuleSet.decode(
                        Data(contentsOf: TestPaths.fixtures.appendingPathComponent("recipe-user-samples.rules.json"))
                    ).steps
                try restarted.persistLibrary(saved)
                let sampleWindows = NSApp.windows.count
                for sample in 1...4 {
                    let input = try String(
                        contentsOf: TestPaths.fixtures.appendingPathComponent("recipe-user-sample\(sample)-input.txt"),
                        encoding: .utf8)
                    let expected = try String(
                        contentsOf: TestPaths.fixtures.appendingPathComponent(
                            "recipe-user-sample\(sample)-expected.txt"), encoding: .utf8)
                    editor.text = input
                    editor.resetUndoHistory()
                    editor.setSavePoint()
                    _ = editor.setSelectionAnchor(0, caret: 0)
                    try require(editor.setBookmarks([0]), "fixture: sample \(sample) bookmark")
                    try restarted.runSavedAutomation(id: preservedWorkflow.id)
                    check(
                        editor.text.utf8.elementsEqual(expected.utf8),
                        "sample \(sample) native exact literal expected bytes")
                    check(editor.bookmarkLines == [0], "sample \(sample) document automation keeps the bookmark")
                    check(
                        editor.window === window && window.contentView === editor
                            && NSApp.windows.count == sampleWindows, "sample \(sample) uses same editor and window")
                    editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
                    check(
                        editor.text.utf8.elementsEqual(input.utf8) && !editor.modified,
                        "sample \(sample) one Undo restores original bytes and savepoint")
                }
                check(newDocumentCalls == 0, "all four samples avoid new-document output")
                saved.workflows[0] = preservedWorkflow
                try restarted.persistLibrary(saved)
            }
            Checks.section("reminder export matching") {
                let now = Date()
                let confirmed = ReminderBatch(
                    id: UUID(), destinationID: "list-a", destinationTitle: "Shopping", destinationSource: "Local",
                    rows: [ReminderRow(id: UUID(), title: "2 eggs", status: .confirmed, reminderID: "fake-1")],
                    createdAt: now)
                let uncertain = ReminderBatch(
                    id: UUID(), destinationID: "list-a", destinationTitle: "Shopping", destinationSource: "Local",
                    rows: [ReminderRow(id: UUID(), title: "2 eggs", status: .uncertain)],
                    createdAt: now.addingTimeInterval(1))
                check(
                    AutomationController.matchingExport(
                        rows: ["2 eggs"], destinationID: "list-a", batches: [confirmed, uncertain])?.id == uncertain.id,
                    "repeated identical export resolves existing durable uncertain batch")
                check(
                    AutomationController.matchingExport(rows: ["3 eggs"], destinationID: "list-a", batches: [confirmed])
                        == nil, "changed content is distinct export")
                check(
                    AutomationController.matchingExport(rows: ["2 eggs"], destinationID: "list-b", batches: [confirmed])
                        == nil, "different destination is distinct export")
                check(
                    AutomationController.matchingExport(
                        rows: ["2 eggs", "2 eggs"], destinationID: "list-a", batches: [confirmed]) == nil,
                    "intentional duplicate rows retain identity")

                // What a new export does about the recorded history, without the modal dialogs.
                func precheck(_ rows: [String], _ batches: [ReminderBatch], _ issues: [ReminderJournalIssue]) -> String
                {
                    switch AutomationController.exportPrecheck(
                        rows: rows, destinationID: "list-a", batches: batches, issues: issues)
                    {
                    case .match(let batch): return "match \(batch.id)"
                    case .needsConfirmation(let found): return "confirm \(found.map(\.url.lastPathComponent))"
                    case .clear: return "clear"
                    }
                }
                let issue = ReminderJournalIssue(url: URL(fileURLWithPath: "/tmp/notes.json"), message: "unreadable")
                check(
                    precheck(["3 eggs"], [confirmed], [issue]) == "confirm [\"notes.json\"]",
                    "an unreadable journal and no matching export needs confirmation before sending")
                check(
                    precheck(["2 eggs"], [confirmed, uncertain], [issue]) == "match \(uncertain.id)",
                    "a readable matching export is offered for review even beside an unreadable journal")
                check(
                    precheck(["3 eggs"], [confirmed], []) == "clear" && precheck(["3 eggs"], [], []) == "clear",
                    "a readable history without a match lets the export proceed")
                check(precheck(["2 eggs"], [], [issue]) == "confirm [\"notes.json\"]", "only unreadable history asks")
                let older = ReminderBatch(
                    id: UUID(), destinationID: "list-a", destinationTitle: "Shopping", destinationSource: "Local",
                    rows: [
                        ReminderRow(id: UUID(), title: "tea", status: .confirmed, reminderID: "fake-2"),
                        ReminderRow(id: UUID(), title: "jam", status: .failed)
                    ], createdAt: now.addingTimeInterval(-60))
                check(
                    AutomationController.clearableBatches([confirmed, uncertain, older]).map(\.id) == [confirmed.id],
                    "only batches whose every row is confirmed are offered for clearing")
                check(
                    AutomationController.historyOrder([older, uncertain, confirmed]).map(\.id)
                        == [uncertain.id, confirmed.id, older.id], "export history lists the newest batch first")
                let manyIssues = (0..<12).map {
                    ReminderJournalIssue(url: URL(fileURLWithPath: "/tmp/bad-\($0).json"), message: "unreadable")
                }
                let summary = AutomationController.issueSummary(manyIssues)
                check(
                    summary.contains("bad-0.json: unreadable") && summary.contains("bad-9.json")
                        && !summary.contains("bad-10.json") && summary.hasSuffix("and 2 more"),
                    "unreadable journals are named, ten at most, with a count of the rest")
                check(
                    AutomationController.journalFailureHeader(CocoaError(.fileWriteNoPermission)).contains("uncertain")
                        && AutomationController.journalFailureHeader(CocoaError(.fileWriteNoPermission)).contains(
                            CocoaError(.fileWriteNoPermission).localizedDescription),
                    "the journal failure header names the cause and the uncertain item in Export History")

                // Clearing through the connector, with an injected store: no EventKit access.
                let exportsFolder = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "TextTankReminderClear-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: exportsFolder) }
                let store = ClearCheckStore()
                let connector = RemindersConnector(storageURL: exportsFolder, store: store)
                var exported: ReminderBatch?, retained: ReminderBatch?, failure: Error?
                let work = Task { @MainActor in
                    do {
                        exported = try await connector.export(
                            rows: ["2 eggs"], destinationID: "list-a", batchID: UUID())
                        store.uncertain = true
                        retained = try await connector.export(
                            rows: ["2 eggs"], destinationID: "list-a", batchID: UUID())
                    } catch { failure = error }
                }
                spinUntil("reminder fixture exports finish") { exported != nil && retained != nil || failure != nil }
                _ = work
                let first = try requireValue(exported, "fixture: confirmed export \(String(describing: failure))")
                let kept = try requireValue(retained, "fixture: uncertain export")
                let removed = try connector.deleteConfirmedBatches(ids: [first.id, kept.id])
                check(removed == [first.id] && store.saves == 2, "clear removes the confirmed batch and sends nothing")
                check(
                    AutomationController.matchingExport(
                        rows: ["2 eggs"], destinationID: "list-a", batches: try connector.scanBatches().batches)?.id
                        == kept.id,
                    "after a clear the retained uncertain batch with the same rows is still matched")
                check(
                    try connector.deleteConfirmedBatches(ids: [kept.id]).isEmpty
                        && AutomationController.matchingExport(
                            rows: ["2 eggs"], destinationID: "list-a",
                            batches: try connector.scanBatches().batches.filter { $0.id != kept.id }) == nil,
                    "an uncertain batch cannot be cleared; without it the cleared rows no longer match")
            }
            Checks.section("modal keyboard chain") {
                let beforeModal = try Data(contentsOf: path)
                try modalKeyboardChecks(restarted)
                check(
                    try Data(contentsOf: path) == beforeModal,
                    "Cancel from keyboard-edited rule draft preserves saved definitions")
            }
            Checks.section("rule list editing") { ruleListChecks() }
            Checks.section("audit package 15") { try package15Checks(root: root) }
            Checks.section("large-input worker path") {
                // F124 and G409: every run is on a worker; one that outlasts the short wait gets the
                // modal progress panel, whatever the size of its input.
                let slowRules =
                    Array(repeating: AutomationDefinition.Step(kind: .trimWhitespace), count: 25)
                    + [.init(kind: .removeBlankLines)]
                let workflowID = saved.workflows[0].id
                var large = saved
                large.workflows[0].input = .document
                large.workflows[0].output = .editor
                large.workflows[0].previewBeforeApply = false
                large.workflows[0].steps = slowRules
                try restarted.persistLibrary(large)
                let rows = (0..<100000).map { "row \($0)" }
                let largeInput = rows.map { "  \($0)  " }.joined(separator: "\n\n") + "\n",
                    largeExpected = rows.joined(separator: "\n") + "\n"
                try require(
                    largeInput.utf8.count > 4 * 262144, "fixture: the input is well over the 256 KiB worker threshold")
                func load(_ text: String) -> UInt {
                    editor.text = text
                    editor.resetUndoHistory()
                    editor.setSavePoint()
                    _ = editor.setSelectionAnchor(0, caret: 0)
                    return editor.revision
                }
                _ = load(largeInput)
                var progressCancelKey: String?
                let applied = try drivingModal(
                    timeout: 60,
                    { _, views in
                        guard let cancel = button("automation.transform.cancel", in: views) else { return false }
                        progressCancelKey = cancel.keyEquivalent
                        return true
                    }
                ) { try restarted.runSavedAutomation(id: workflowID) }
                check(
                    applied.acted && !applied.timedOut,
                    "a run that outlasts the short wait runs behind the modal progress panel, which closes itself")
                check(progressCancelKey == "\u{1b}", "Escape presses Cancel in the automation progress panel")
                check(editor.text == largeExpected, "the worker result replaces the large document exactly")
                editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
                check(
                    editor.text == largeInput && !editor.modified,
                    "a large-input automation is one Undo back to the save point")
                // Cancel while a step that checks for cancellation is running.
                large.workflows[0].steps = Array(repeating: .init(kind: .trimWhitespace), count: 100)
                try restarted.persistLibrary(large)
                var revision = load(largeInput)
                var clickedAt: TimeInterval?, cancelError: Error?
                var cancelled = drivingModal(
                    timeout: 60,
                    { _, views in
                        guard let cancel = button("automation.transform.cancel", in: views) else { return false }
                        clickedAt = ProcessInfo.processInfo.systemUptime
                        cancel.performClick(nil)
                        return true
                    }
                ) { do { try restarted.runSavedAutomation(id: workflowID) } catch { cancelError = error } }
                var afterCancel = ProcessInfo.processInfo.systemUptime - (clickedAt ?? 0)
                check(
                    cancelled.acted && !cancelled.timedOut && cancelError != nil,
                    "Cancel in the progress panel ends a large run with an error")
                check(afterCancel < 1, "Cancel during a line-by-line step returns within a second")
                check(
                    editor.text == largeInput && editor.revision == revision && !editor.modified,
                    "a cancelled large run leaves text, revision and save point untouched")
                // F110: Cancel ends the modal itself. One Markdown pass over this single line takes
                // seconds and cannot be interrupted, so before the repair the panel stayed up until the
                // pass had finished. Should that pass ever become fast, no panel appears and the first
                // check below fails: pick another long uninterruptible step then.
                let stubbornInput = String(repeating: "*a ", count: 6000)
                large.workflows[0].steps = [.init(kind: .removeMarkdownFormatting)]
                try restarted.persistLibrary(large)
                revision = load(stubbornInput)
                clickedAt = nil
                cancelError = nil
                cancelled = drivingModal(
                    timeout: 120,
                    { _, views in
                        guard let cancel = button("automation.transform.cancel", in: views) else { return false }
                        clickedAt = ProcessInfo.processInfo.systemUptime
                        cancel.performClick(nil)
                        return true
                    }
                ) { do { try restarted.runSavedAutomation(id: workflowID) } catch { cancelError = error } }
                afterCancel = ProcessInfo.processInfo.systemUptime - (clickedAt ?? 0)
                check(
                    cancelled.acted && !cancelled.timedOut
                        && cancelError?.localizedDescription == "Automation cancelled. Nothing was changed.",
                    "Cancel during an uninterruptible step ends the run with the cancellation error")
                check(
                    editor.text == stubbornInput && editor.revision == revision && !editor.modified,
                    "a run cancelled during an uninterruptible step leaves text, revision and save point untouched")
                check(
                    afterCancel < 1,
                    "F110 Cancel during an uninterruptible step closes the progress panel within a second")
                check(NSApp.modalWindow == nil, "no modal session is left open after Cancel")
                // F118: the panel is ended through the run loop, so a run started from a main-queue
                // block still completes. The main queue is not drained while that block is in a modal.
                large.workflows[0].steps = slowRules
                try restarted.persistLibrary(large)
                _ = load(largeInput)
                var nestedFinished = false, nestedActed = false, nestedTimedOut = false, nestedError: Error?
                DispatchQueue.main.async {
                    let nested = drivingModal(
                        timeout: 60, { _, views in button("automation.transform.cancel", in: views) != nil }
                    ) { do { try restarted.runSavedAutomation(id: workflowID) } catch { nestedError = error } }
                    nestedActed = nested.acted
                    nestedTimedOut = nested.timedOut
                    nestedFinished = true
                }
                spinUntil(timeout: 120, "the run started from a main-queue block") { nestedFinished }
                check(
                    nestedActed && !nestedTimedOut && nestedError == nil,
                    "F118 a run started from a main-queue block closes its own progress panel")
                check(editor.text == largeExpected, "F118 the run started from a main-queue block applies its result")
                // G409: a small input also runs on the worker. This one grows and shrinks for a long
                // time; before the repair it ran on the main thread with no panel and no Cancel.
                let grow: [AutomationDefinition.Step] = (0..<12).map {
                    .init(
                        kind: .replaceLiteral, find: $0 % 2 == 0 ? "a" : "b", replacement: $0 % 2 == 0 ? "bb" : "aa")
                }
                let shrink = AutomationDefinition.Step(
                    kind: .replaceLiteral, find: String(repeating: "a", count: 4096), replacement: "a")
                large.workflows[0].steps = Array((0..<7).map { _ in grow + [shrink] }.joined())
                try restarted.persistLibrary(large)
                let smallInput = String(repeating: "a", count: 1024)
                revision = load(smallInput)
                clickedAt = nil
                cancelError = nil
                cancelled = drivingModal(
                    timeout: 300,
                    { _, views in
                        guard let cancel = button("automation.transform.cancel", in: views) else { return false }
                        clickedAt = ProcessInfo.processInfo.systemUptime
                        cancel.performClick(nil)
                        return true
                    }
                ) { do { try restarted.runSavedAutomation(id: workflowID) } catch { cancelError = error } }
                afterCancel = ProcessInfo.processInfo.systemUptime - (clickedAt ?? 0)
                check(
                    cancelled.acted && !cancelled.timedOut,
                    "G409 a long run on a 1 KiB input shows the progress panel with a Cancel button")
                check(
                    cancelError?.localizedDescription == "Automation cancelled. Nothing was changed.",
                    "G409 Cancel on a small-input run reports the cancellation")
                check(afterCancel < 10, "G409 the cancelled small-input run returns well inside the hang guard")
                check(
                    editor.text == smallInput && editor.revision == revision && !editor.modified
                        && NSApp.modalWindow == nil,
                    "G409 the cancelled small-input run leaves text, revision and save point untouched")
                editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
                check(editor.text == smallInput, "G409 the cancelled small-input run left nothing to undo")
                try restarted.persistLibrary(saved)
            }
            Checks.section("clipboard input flavours") {
                // F141: a private pasteboard; the person's general pasteboard is never touched.
                let board = NSPasteboard.withUniqueName()
                defer { board.releaseGlobally() }
                board.clearContents()
                board.setString("plain ½ cup", forType: .string)
                check(
                    AutomationController.plainText(from: board) == "plain ½ cup",
                    "a plain-text clipboard is read exactly")
                let attributed = NSAttributedString(string: "2 eggs\n½ cup flour")
                let rtf = try attributed.data(
                    from: NSRange(location: 0, length: attributed.length),
                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
                board.clearContents()
                board.setData(rtf, forType: .rtf)
                // The system offers plain text for an RTF-only pasteboard, so RTF arrives through the
                // plain-text flavour; the local RTF reader is the fallback and gives the same text.
                check(
                    AutomationController.plainText(from: board)
                        == (try NSAttributedString(
                            data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf],
                            documentAttributes: nil
                        ).string) && AutomationController.plainText(from: board) == "2 eggs\n½ cup flour",
                    "an RTF-only clipboard still gives the text the local RTF reader gives")
                let markup =
                    #"<ul><li>2 eggs</li><li>½ cup flour</li></ul><img src="http://127.0.0.1:1/x.png"><script>document.title="x"</script>"#
                board.clearContents()
                board.setData(Data(markup.utf8), forType: .html)
                try require(
                    board.string(forType: .string) == nil, "fixture: the HTML-only pasteboard has no plain text")
                let fromHTML = AutomationController.plainText(from: board)
                check(
                    fromHTML == "2 eggs\n½ cup flour\n",
                    "an HTML-only clipboard gives its rows with no object character and no script text")
                // The same clipboard through a saved clipboard-input automation.
                var clipboardLibrary = saved
                clipboardLibrary.workflows[0].input = .clipboard
                clipboardLibrary.workflows[0].output = .editor
                clipboardLibrary.workflows[0].previewBeforeApply = false
                clipboardLibrary.workflows[0].steps = [.init(kind: .removeBlankLines)]
                try restarted.persistLibrary(clipboardLibrary)
                restarted.pasteboard = board
                defer { restarted.pasteboard = nil }
                editor.text = "before"
                editor.resetUndoHistory()
                _ = editor.setSelectionAnchor(0, caret: 6)
                try restarted.runSavedAutomation(id: clipboardLibrary.workflows[0].id)
                check(
                    editor.text == "2 eggs\n½ cup flour\n",
                    "a clipboard-input automation runs on the text of an HTML-only clipboard")
                board.clearContents()
                check(AutomationController.plainText(from: board) == nil, "an empty clipboard has no text")
                board.setData(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), forType: .png)
                check(AutomationController.plainText(from: board) == nil, "an image-only clipboard has no text")
                board.clearContents()
                board.setData(Data(#"<img src="http://127.0.0.1:1/x.png">"#.utf8), forType: .html)
                editor.text = "kept"
                let keptRevision = editor.revision
                rejects(
                    "a clipboard with no text is reported and nothing is changed",
                    message: "The clipboard does not contain supported text."
                ) { try restarted.runSavedAutomation(id: clipboardLibrary.workflows[0].id) }
                check(
                    editor.text == "kept" && editor.revision == keptRevision,
                    "the refused clipboard run left the editor alone")
                try restarted.persistLibrary(saved)
            }
            Checks.section("oversized transform") {
                var growingLibrary = saved
                growingLibrary.workflows[0].steps = [
                    .init(kind: .replaceLiteral, find: "x", replacement: String(repeating: "y", count: 7 * 1024 * 1024))
                ]
                growingLibrary.workflows[0].previewBeforeApply = false
                try restarted.persistLibrary(growingLibrary)
                editor.text = "xxxxx"
                editor.resetUndoHistory()
                editor.setSavePoint()
                let growthRevision = editor.revision
                var growthRejected = false
                do { try restarted.runSavedAutomation(id: growingLibrary.workflows[0].id) } catch {
                    growthRejected = true
                }
                check(
                    growthRejected && editor.text == "xxxxx" && editor.revision == growthRevision && !editor.modified,
                    "production oversized transform leaves native text revision Undo and savepoint unchanged")
                try restarted.persistLibrary(saved)
            }
            Checks.section("unsafe configuration files") {
                let unsafeConfigRoot = root.appendingPathComponent("unsafe-config")
                try FileManager.default.createDirectory(at: unsafeConfigRoot, withIntermediateDirectories: true)
                let unsafeConfig = unsafeConfigRoot.appendingPathComponent("Automations.json")
                setenv("TEXTTANK_SUPPORT_DIRECTORY", unsafeConfigRoot.path, 1)
                defer { setenv("TEXTTANK_SUPPORT_DIRECTORY", root.path, 1) }
                try require(mkfifo(unsafeConfig.path, 0o600) == 0, "fixture: configuration FIFO created")
                let fifoStart = ProcessInfo.processInfo.systemUptime
                let fifoController = AutomationController(editorProvider: { nil }, newDocument: { _ in })
                var rejectedFIFO = false
                do { try fifoController.persistLibrary(saved) } catch { rejectedFIFO = true }
                check(
                    rejectedFIFO && ProcessInfo.processInfo.systemUptime - fifoStart < 1,
                    "FIFO configuration startup rejects promptly and prevents overwrite")
                try FileManager.default.removeItem(at: unsafeConfig)
                let externalConfig = unsafeConfigRoot.appendingPathComponent("external.json")
                let validConfiguration = try saved.encoded()
                try validConfiguration.write(to: externalConfig)
                try FileManager.default.createSymbolicLink(at: unsafeConfig, withDestinationURL: externalConfig)
                let symlinkController = AutomationController(editorProvider: { nil }, newDocument: { _ in })
                var rejectedSymlink = false
                do { try symlinkController.persistLibrary(saved) } catch { rejectedSymlink = true }
                check(
                    try rejectedSymlink && (try Data(contentsOf: externalConfig)) == validConfiguration,
                    "configuration startup does not follow symlink or overwrite target")
                try FileManager.default.removeItem(at: unsafeConfig)
                let oversizedFD = open(unsafeConfig.path, O_CREAT | O_WRONLY, mode_t(0o600))
                try require(oversizedFD >= 0, "fixture: oversized configuration file opened")
                let grown = ftruncate(oversizedFD, off_t(AutomationLibrary.maximumBytes + 1)) == 0
                close(oversizedFD)
                try require(grown, "fixture: oversized configuration file sized")
                let oversizedController = AutomationController(editorProvider: { nil }, newDocument: { _ in })
                var rejectedOversized = false
                do { try oversizedController.persistLibrary(saved) } catch { rejectedOversized = true }
                check(rejectedOversized, "oversized existing configuration is rejected and preserved")
            }
            withExtendedLifetime(toolbarHost) {}
            Checks.summary { "PASS AutomationControllerChecks: \(Checks.count) native assertions; no Reminders access" }
        }
    }
}

/// Injected store for the reminder clearing check; nothing here reaches EventKit.
@MainActor final class ClearCheckStore: ReminderStore {
    var permission: ReminderPermission = .authorized
    var saves = 0
    var uncertain = false
    func requestAccess() async throws {}
    func destinations() throws -> [ReminderDestination] {
        [ReminderDestination(id: "list-a", title: "Shopping", source: "Local", writable: true)]
    }
    func save(title: String, destinationID: String) throws -> String {
        saves += 1
        if uncertain { throw ReminderConnectorError.uncertain("outcome unknown") }
        return "fake-\(saves)"
    }
}
