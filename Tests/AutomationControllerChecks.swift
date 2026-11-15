// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

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
            guard let modal = NSApp.modalWindow, let content = modal.contentView else { return }
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
        let result = AutomationStepEditor.editStep(.init(kind: .removeBlankLines))
        timer.invalidate()
        return (actionSent, fieldsEnabled, result)
    }
    static func modalKeyboardChecks(_ controller: AutomationController) throws {
        var stage = 0, nameAccepted = false, sampleAccepted = false, reentryBlocked = false, timedOut = false
        var nestedRule: (Bool, Bool, AutomationDefinition.Step?) = (false, false, nil)
        let deadline = Date().addingTimeInterval(8)
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            guard let modal = NSApp.modalWindow, let content = modal.contentView else { return }
            let views = descendants(content), buttons = views.compactMap { $0 as? NSButton }
            if Date() > deadline {
                timedOut = true
                NSApp.abortModal()
                return
            }
            if stage == 0, let create = buttons.first(where: { $0.identifier?.rawValue == "automation.create" }) {
                stage = 1
                create.performClick(nil)
            } else if stage == 1,
                let name = views.compactMap({ $0 as? NSTextField }).first(where: {
                    $0.stringValue == "My Automation" && $0.isEditable
                })
            {
                stage = 2
                name.selectText(nil)
                typeKeys("Keyboard Recipe", in: modal)
                modal.makeFirstResponder(nil)
                nameAccepted = name.stringValue == "Keyboard Recipe" && name.isEditable
                // A guarded management call must return without creating another modal.
                // A nested watchdog closes a regression-created alert so the test never hangs.
                var openedNested = false
                let guardTimer = Timer(timeInterval: 0.1, repeats: false) { _ in
                    if NSApp.modalWindow !== modal {
                        openedNested = true
                        NSApp.abortModal()
                    }
                }
                RunLoop.main.add(guardTimer, forMode: .modalPanel)
                controller.manage()
                guardTimer.invalidate()
                reentryBlocked = !openedNested && NSApp.modalWindow === modal
            } else if stage == 2, let cancel = buttons.first(where: { $0.title == "Cancel" }),
                let sample = views.compactMap({ $0 as? NSTextView }).first(where: {
                    $0.accessibilityLabel() == "Sample input"
                })
            {
                stage = 3
                modal.makeFirstResponder(sample)
                typeKeys("2 eggs", in: modal)
                sampleAccepted = sample.string == "2 eggs" && modal.firstResponder === sample
                nestedRule = ruleKeyboardCheck()
                cancel.performClick(nil)
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        controller.manage()
        timer.invalidate()
        check(!timedOut && stage == 3, "native Create Automation and Rules modal chain completed")
        check(nameAccepted, "Create Automation name accepts dispatched keyboard events")
        check(sampleAccepted, "Sample Input accepts dispatched keyboard events")
        check(reentryBlocked, "management cannot open another dialog during Create Automation")
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
            guard let modal = NSApp.modalWindow, let content = modal.contentView else { return }
            if Date() > deadline {
                timedOut = true
                NSApp.abortModal()
                return
            }
            if !acted { acted = act(modal, descendants(content)) }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }
        let value = try body()
        return (value, acted, timedOut)
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
        let edited = drivingModal(
            timeout: 10,
            { _, views in
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
                let nested = Timer(timeInterval: 0.1, repeats: false) { _ in
                    guard let alert = NSApp.modalWindow?.contentView,
                        let save = button("rule.save", in: descendants(alert))
                    else {
                        NSApp.abortModal()
                        return
                    }
                    nestedSaved = true
                    save.performClick(nil)
                }
                RunLoop.main.add(nested, forMode: .modalPanel)
                add.performClick(nil)
                nested.invalidate()
                note()
                up.performClick(nil)
                note()
                use.performClick(nil)
                return true
            }
        ) { AutomationStepEditor.edit(definition) }
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
        // The Configure Rule dialog writes both ask flags as false on the rule it returns.
        check(
            edited.value?.steps == [
                literal("a"), literal("a"), .init(kind: .removeBlankLines, askForFind: false, askForReplacement: false),
                literal("c")
            ], "Use These Rules returns the rules in the edited order")
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
        ) { AutomationStepEditor.edit(definition) }
        check(
            cancelled.acted && !cancelled.timedOut && cancelled.value == nil,
            "Cancel after removing a rule returns no draft")
    }
    static func horizontalDialogChecks() throws {
        let alert = TTAlert()
        alert.messageText = "Horizontal action regression"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 28))
        field.stringValue = "Draft survives reopening"
        alert.accessoryView = field
        for title in ["Save", "Cancel", "Reset Defaults"] { alert.addButton(withTitle: title) }
        for index in [2, 1, 0] {
            var aligned = false
            let timer = Timer(timeInterval: 0.1, repeats: false) { _ in
                let frames = alert.buttons.map { $0.convert($0.bounds, to: alert.window.contentView) }
                print("ACTION_GEOMETRY", index, frames)
                fflush(stdout)
                aligned =
                    frames.allSatisfy { abs($0.midY - frames[0].midY) < 1 } && frames[2].maxX < frames[1].minX
                    && frames[1].maxX < frames[0].minX
                alert.buttons[index].performClick(nil)
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
    static func main() {
        Checks.run("AutomationControllerChecks") {
            let isolatedSupport = try IsolatedSupportDirectory("TextTankAutomationControllerChecks"),
                root = isolatedSupport.url
            defer { isolatedSupport.restore() }
            _ = NSApplication.shared
            Checks.section("horizontal dialog actions") { try horizontalDialogChecks() }
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
                try controller.runSavedAutomation(id: AutomationDefinition.example.id)
                check(
                    editor.text == "2 eggs\n½ cup flour\n",
                    "cleanup applies directly to actual editor without preview dialog")
                editor.executeCommand("undo")
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
                    toolbar.items.first(where: { $0.itemIdentifier == identifier })?.view as? NSButton,
                    "fixture: direct toolbar button is installed")
                check(button.window === window, "named automation button is installed in native window toolbar")
                check(button.title == "My recipe tidy", "renaming updates individual toolbar button label")
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
                editor.executeCommand("undo")
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
                slowPattern.workflows[0].steps = [.init(kind: .removeMatchingLines, find: "(a+)+$")]
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
                    editor.find("- 2 eggs\n- ½ cup flour\n", matchCase: true, backwards: false),
                    "selection test captures exact ingredient range")
                try restarted.runSavedAutomation(id: AutomationDefinition.example.id)
                check(
                    editor.text == "before\n2 eggs\n½ cup flour\nafter",
                    "configured selection cleanup preserves surrounding document")
                editor.executeCommand("undo")
                check(editor.text == selectionSource, "selection cleanup undoes together")
                let multiSource = "- 2 eggs | - ½ cup flour"
                editor.text = multiSource
                editor.resetUndoHistory()
                editor.setSavePoint()
                check(
                    editor.setSelectionRanges([
                        ["anchor": NSNumber(value: 0), "caret": NSNumber(value: 8)],
                        ["anchor": NSNumber(value: multiSource.utf8.count), "caret": NSNumber(value: 11)]
                    ]), "set separate reversed Unicode selections")
                try restarted.runSavedAutomation(id: AutomationDefinition.example.id)
                check(
                    editor.text == "2 eggs | ½ cup flour", "automation transforms each captured selection independently"
                )
                editor.executeCommand("undo")
                check(editor.text == multiSource, "multiple automation selections undo together")
                saved.workflows[0].steps = [.init(kind: .removeMatchingLines, find: "(a+)+$")]
                try restarted.persistLibrary(saved)
                let multiFailure = "safe | " + String(repeating: "a", count: 32) + "!"
                editor.text = multiFailure
                editor.resetUndoHistory()
                editor.setSavePoint()
                _ = editor.setSelectionRanges([
                    ["anchor": NSNumber(value: 0), "caret": NSNumber(value: 4)],
                    ["anchor": NSNumber(value: 7), "caret": NSNumber(value: multiFailure.utf8.count)]
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
                    ["anchor": NSNumber(value: 0), "caret": NSNumber(value: 6)],
                    ["anchor": NSNumber(value: 7), "caret": NSNumber(value: 14)]
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
                saved.workflows[0].steps = AutomationDefinition.shoppingRecipeSteps
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
                    editor.executeCommand("undo")
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
            }
            Checks.section("modal keyboard chain") {
                let beforeModal = try Data(contentsOf: path)
                try modalKeyboardChecks(restarted)
                check(
                    try Data(contentsOf: path) == beforeModal,
                    "Cancel from keyboard-edited rule draft preserves saved definitions")
            }
            Checks.section("rule list editing") { ruleListChecks() }
            Checks.section("large-input worker path") {
                // F124: over 256 KiB the transform runs on a worker behind a modal progress panel.
                let workflowID = saved.workflows[0].id
                var large = saved
                large.workflows[0].input = .document
                large.workflows[0].output = .editor
                large.workflows[0].previewBeforeApply = false
                large.workflows[0].steps = [.init(kind: .trimWhitespace), .init(kind: .removeBlankLines)]
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
                let applied = try drivingModal(
                    timeout: 60, { _, views in button("automation.transform.cancel", in: views) != nil }
                ) { try restarted.runSavedAutomation(id: workflowID) }
                check(
                    applied.acted && !applied.timedOut,
                    "an input over 256 KiB runs behind the modal progress panel, which closes itself")
                check(editor.text == largeExpected, "the worker result replaces the large document exactly")
                editor.executeCommand("undo")
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
                // F110: Keep marked list rows never checks for cancellation and Cancel cannot end the
                // modal itself, so the panel stays up until the step finishes (seconds here).
                let marker = "- " + String(repeating: "x", count: 40)
                let markedInput = (0..<12000).map { marker + String($0) }.joined(separator: "\n") + "\n"
                try require(markedInput.utf8.count > 262144, "fixture: the marked list is over the worker threshold")
                large.workflows[0].steps = [.init(kind: .keepMarkedListRows)]
                try restarted.persistLibrary(large)
                revision = load(markedInput)
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
                    cancelled.acted && !cancelled.timedOut && cancelError != nil,
                    "Cancel during Keep marked list rows still ends in an error, not a result")
                check(
                    editor.text == markedInput && editor.revision == revision && !editor.modified,
                    "a late cancellation still leaves text, revision and save point untouched")
                knownDefect(
                    "F110", "Cancel during Keep marked list rows closes the progress panel within a second",
                    fixed: afterCancel < 1)
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
