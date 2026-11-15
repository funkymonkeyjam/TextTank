// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import UniformTypeIdentifiers

extension AutomationDefinition.Step.Kind {
    /// One line shown in the Configure Rule dialog for the selected kind.
    var guidance: String {
        switch self {
        case .removeListMarkers:
            return
                "Removes a leading -, * or • and the spaces after it. Leading numbers stay, because “2 eggs” is a quantity."
        case .removeBlankLines:
            return
                "Drops lines that are empty or hold only spaces and tabs. The text must use one kind of line ending; mixed endings are refused."
        case .sortLines:
            return
                "Sorts by character code: capitals come before lowercase and accented letters after z. Use Sort lines in locale order for dictionary order. Mixed line endings are refused."
        case .sortLinesLocalized:
            return
                "Sorts as Finder does in your language: case and accents are secondary, and numbers inside a line sort by value. Mixed line endings are refused."
        case .deduplicateLines:
            return
                "Keeps the first of each identical line and drops later repeats. Leave this rule out when repeated rows should stay. Mixed line endings are refused."
        case .replaceLiteral:
            return
                "Replaces exact, case-sensitive text. Leave Replace with empty to remove it. Special characters are ordinary text."
        case .clearLinesEqualTo, .clearLinesContaining, .clearLinesStartingWith:
            return
                "Matches literal, case-sensitive text. A matching line becomes empty and stays in place; add Remove empty lines afterward to drop it."
        case .trimWhitespace:
            return
                "Removes spaces and tabs, including no-break spaces, from both ends of every line. Spacing inside a line is kept."
        case .clearLinesMatching:
            return
                "A regular expression. Only a match covering the entire line empties it; the line stays in place. Add Remove empty lines afterward to drop it."
        case .clearMarkdownHeadings:
            return
                "Empties lines that start with one to six # marks and a space. The emptied line stays in place; add Remove empty lines afterward to drop it."
        case .removeMarkdownFormatting:
            return
                "Removes emphasis marks and code ticks and replaces a link with its label. A mark that has no partner is left as typed."
        case .removeCheckboxMarkers:
            return "Removes a leading checkbox such as ☐, ☑, [ ] or [x]. The rest of the line is kept."
        case .removeNoteReferences:
            return
                "Removes references such as “(Note 2)” or “see Notes 1 and 3”. Other text in parentheses is kept."
        case .keepMarkedListRows:
            return
                "Keeps only rows that start with a bullet or checkbox. Any other non-blank row must be a # heading or a label ending in a colon, or the run stops with nothing changed. A list with no marked rows is left as it is."
        }
    }
}

/// A draft-only native rule builder. Testing never invokes inputs, outputs or connectors.
final class AutomationStepEditor: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate,
    NSTextViewDelegate
{
    static let openingInstruction =
        "Paste sample text, then Test Rules. Testing never changes a document or sends reminders."
    static let staleInstruction = "Sample or rules changed. Test again to see the current result."
    private var draft: AutomationDefinition
    private var list: RuleListDraft
    private let savedWorkflows: [AutomationDefinition]
    private let nameField = NSTextField()
    private var accepted = false
    private var preview = RulePreviewState()
    private var previewControl: AutomationRunControl?
    private let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 940, height: 700), styleMask: [.titled, .closable, .resizable],
        backing: .buffered, defer: false)
    private let table = NSTableView()
    private let sample = NSTextView(), result = NSTextView()
    private let status = AnnouncingLabel(wrappingLabelWithString: AutomationStepEditor.openingInstruction)
    private lazy var addButton = button("Add Rule…", #selector(addRule), "add")
    private lazy var editButton = button("Edit…", #selector(editRule), "edit")
    private lazy var duplicateButton = button("Duplicate", #selector(duplicateRule), "duplicate")
    private lazy var upButton = button("Move Up", #selector(moveUp), "up")
    private lazy var downButton = button("Move Down", #selector(moveDown), "down")
    private lazy var removeButton = button("Remove", #selector(removeRule), "remove")
    /// Set while the table is brought in line with `list`, so the table's own selection
    /// notifications during a reload do not write back.
    private var syncingSelection = false
    private init(_ definition: AutomationDefinition, savedWorkflows: [AutomationDefinition]) {
        draft = definition
        list = RuleListDraft(definition.steps)
        self.savedWorkflows = savedWorkflows
        super.init()
    }
    static func edit(_ original: AutomationDefinition, savedWorkflows: [AutomationDefinition] = [])
        -> AutomationDefinition?
    {
        let editor = AutomationStepEditor(original, savedWorkflows: savedWorkflows)
        editor.build()
        NSApp.runModal(for: editor.window)
        editor.window.orderOut(nil)
        return editor.accepted ? editor.draft : nil
    }
    private func button(_ title: String, _ action: Selector, _ name: String) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.identifier = NSUserInterfaceItemIdentifier("rules." + name)
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }
    private func row(_ views: [NSView], alignment: NSLayoutConstraint.Attribute = .centerY) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = alignment
        stack.distribution = .fill
        stack.spacing = 8
        return stack
    }
    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return view
    }
    private func scroll(_ document: NSView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = document
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        scroll.setContentCompressionResistancePriority(.init(1), for: .vertical)
        scroll.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return scroll
    }
    private func build() {
        // The name is edited in this window, so the title does not repeat a name that may be stale.
        window.title = "Edit Rules"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = NSSize(width: 860, height: 540)
        guard let content = window.contentView else { return }
        let heading = NSTextField(labelWithString: "Automation name")
        heading.font = .boldSystemFont(ofSize: 16)
        heading.setContentHuggingPriority(.required, for: .horizontal)
        nameField.stringValue = draft.name
        nameField.isEditable = true
        nameField.isSelectable = true
        nameField.isBezeled = true
        nameField.setAccessibilityLabel("Automation name")
        nameField.setContentHuggingPriority(.init(1), for: .horizontal)
        let note = NSTextField(
            labelWithString:
                "Choose a rule, fill in its fields, then test the result. Changes stay in this draft until you save.")
        note.lineBreakMode = .byTruncatingTail
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rule"))
        column.title = "Processing rules"
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.headerView = nil
        table.rowHeight = 30
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(editRule)
        table.setAccessibilityLabel("Ordered processing rules")
        let rules = scroll(table)
        let load = button("Load Rules…", #selector(loadRules), "load")
        let export = button("Export Rules…", #selector(exportRules), "export")
        let actions = row([
            addButton, editButton, duplicateButton, upButton, downButton, removeButton, spacer(), load, export
        ])
        var panes: [NSView] = [], paneScrolls: [NSScrollView] = []
        for (text, title, editable) in [
            (sample, "Sample input — paste text to test", true), (result, "Test result — read only", false)
        ] {
            text.isRichText = false
            text.isEditable = editable
            text.isSelectable = true
            text.allowsUndo = editable
            text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            text.isAutomaticQuoteSubstitutionEnabled = false
            text.isAutomaticDashSubstitutionEnabled = false
            text.minSize = .zero
            text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            text.isVerticallyResizable = true
            text.isHorizontallyResizable = false
            text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true
            text.setAccessibilityLabel(editable ? "Sample input" : "Test result")
            let label = NSTextField(labelWithString: title)
            let textScroll = scroll(text)
            let pane = NSStackView(views: [label, textScroll])
            pane.orientation = .vertical
            pane.alignment = .leading
            pane.distribution = .fill
            pane.spacing = 6
            textScroll.leadingAnchor.constraint(equalTo: pane.leadingAnchor).isActive = true
            textScroll.trailingAnchor.constraint(equalTo: pane.trailingAnchor).isActive = true
            panes.append(pane)
            paneScrolls.append(textScroll)
        }
        sample.delegate = self
        let paneRow = row(panes, alignment: .top)
        paneRow.distribution = .fillEqually
        paneRow.spacing = 20
        let test = button("Test Rules", #selector(testRules), "test")
        status.identifier = NSUserInterfaceItemIdentifier("rules.status")
        status.setAccessibilityLabel("Test status")
        status.setContentHuggingPriority(.init(1), for: .horizontal)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let testRow = row([test, status])
        let cancel = button("Cancel", #selector(cancel), "cancel")
        cancel.keyEquivalent = "\u{1b}"
        let save = button("Use These Rules", #selector(save), "use")
        save.keyEquivalent = "\r"
        let body = NSStackView(views: [
            row([heading, nameField]), note, rules, actions, paneRow, testRow, row([spacer(), cancel, save])
        ])
        body.orientation = .vertical
        body.alignment = .leading
        body.distribution = .fill
        body.spacing = 10
        body.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(body)
        var constraints = [
            body.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            body.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            body.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            rules.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            paneScrolls[0].heightAnchor.constraint(greaterThanOrEqualToConstant: 110),
            // The rule list and the two text panes share whatever height the window has.
            paneScrolls[0].heightAnchor.constraint(equalTo: rules.heightAnchor),
            paneScrolls[1].heightAnchor.constraint(equalTo: paneScrolls[0].heightAnchor),
            status.heightAnchor.constraint(greaterThanOrEqualToConstant: 34)
        ]
        // Every row spans the width of the window.
        for view in body.arrangedSubviews {
            constraints.append(view.leadingAnchor.constraint(equalTo: body.leadingAnchor))
            constraints.append(view.trailingAnchor.constraint(equalTo: body.trailingAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        // Opening shows the rules and the opening instruction; nothing is stale yet.
        cancelPreview()
        syncTable()
        window.layoutIfNeeded()
        for text in [sample, result] {
            if let clip = text.enclosingScrollView?.contentView { text.frame = clip.bounds }
        }
        table.sizeLastColumnToFit()
        window.center()
        // The controls are placed by frame. With an initial first responder set, AppKit does not
        // work out the Tab order by itself, so ask for it: every control is then reachable.
        window.recalculateKeyViewLoop()
        window.initialFirstResponder = nameField
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nameField)
        nameField.selectText(nil)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { list.steps.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("rule.cell")
        let label: NSTextField
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            label = reused
        } else {
            label = NSTextField(labelWithString: "")
            label.identifier = identifier
            label.lineBreakMode = .byTruncatingTail
        }
        label.stringValue = "\(row + 1). \(list.steps[row].summary)"
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSelection else { return }
        list.select(table.selectedRow)
        updateButtons()
    }
    private func updateButtons() {
        let selected = list.selected != nil
        editButton.isEnabled = selected
        removeButton.isEnabled = selected
        duplicateButton.isEnabled = list.canDuplicate
        upButton.isEnabled = list.canMoveUp
        downButton.isEnabled = list.canMoveDown
        addButton.isEnabled = list.canAdd
    }
    /// Stops a running test and refuses its late result. Says nothing to the user.
    private func cancelPreview() {
        _ = preview.invalidate()
        previewControl?.cancel()
        previewControl = nil
    }
    /// An edit to the sample or the rules: a result on show, or on its way, no longer describes
    /// them. With nothing shown and nothing running there is nothing to call stale.
    private func markStale() {
        let hadSomething = preview.invalidate()
        previewControl?.cancel()
        previewControl = nil
        guard hadSomething else { return }
        result.string = ""
        status.stringValue = Self.staleInstruction
    }
    func textDidChange(_ notification: Notification) { markStale() }
    /// Brings the table, its selection and the buttons in line with `list`.
    private func syncTable() {
        syncingSelection = true
        table.reloadData()
        if let selected = list.selected {
            table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
            table.scrollRowToVisible(selected)
        } else {
            table.deselectAll(nil)
        }
        syncingSelection = false
        updateButtons()
    }
    private func rulesChanged() {
        syncTable()
        markStale()
    }
    @objc private func addRule() {
        guard list.canAdd, let step = Self.editStep(.init(kind: .removeBlankLines)) else { return }
        if list.add(step) { rulesChanged() }
    }
    @objc private func editRule() {
        guard let selected = list.selected, let step = Self.editStep(list.steps[selected]) else { return }
        if list.replaceSelected(with: step) { rulesChanged() }
    }
    @objc private func duplicateRule() { if list.duplicateSelected() { rulesChanged() } }
    @objc private func removeRule() { if list.removeSelected() { rulesChanged() } }
    @objc private func moveUp() { if list.moveSelectedUp() { rulesChanged() } }
    @objc private func moveDown() { if list.moveSelectedDown() { rulesChanged() } }
    /// A picker with one item for every rule set, in order. Items are built as menu items, because
    /// `addItem(withTitle:)` removes an earlier item with the same title and two saved automations
    /// may share a name. The item's tag is the rule set's index.
    static func ruleSetPopup(
        saved: [AutomationRuleSet], templates: [AutomationRuleSet], savedPrefix: String = "Saved: "
    )
        -> NSPopUpButton
    {
        let choices = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 540, height: 28), pullsDown: false)
        for (index, set) in (saved + templates).enumerated() {
            let item = NSMenuItem(
                title: (index < saved.count ? savedPrefix : "Template: ") + set.name, action: nil, keyEquivalent: "")
            item.tag = index
            choices.menu?.addItem(item)
        }
        choices.setAccessibilityLabel("Rules to load")
        return choices
    }
    /// The rule set the picker's selected item stands for.
    static func selectedRuleSet(in choices: NSPopUpButton, from sets: [AutomationRuleSet]) -> AutomationRuleSet? {
        guard let item = choices.selectedItem, sets.indices.contains(item.tag) else { return nil }
        return sets[item.tag]
    }
    @objc private func loadRules() {
        window.makeFirstResponder(nil)
        let saved = savedWorkflows.map { AutomationRuleSet(name: $0.name, steps: $0.steps) }
        // Templates are bundled rule files, read like an imported one.
        let templates = AutomationTemplates.loadAll()
        let picker = TTAlert()
        picker.messageText = "Load Rules"
        picker.informativeText =
            "Copy rules from any saved automation or template, or import a rule file. Only this draft’s processing steps are replaced; its name, input, output and shortcuts stay unchanged."
        if !templates.problems.isEmpty {
            picker.informativeText +=
                " Some built-in templates could not be read and are not listed: "
                + templates.problems.joined(separator: "; ")
        }
        picker.addButton(withTitle: "Load Selected").identifier = NSUserInterfaceItemIdentifier("rules.load.selected")
        picker.addButton(withTitle: "Cancel", role: .cancel)
        picker.addButton(withTitle: "Import File…")
        let choices = Self.ruleSetPopup(saved: saved, templates: templates.sets)
        picker.accessoryView = choices
        enum LoadChoice { case load, cancel, importFile }
        guard let response = picker.choice([LoadChoice.load, .cancel, .importFile]), response != .cancel else { return }
        do {
            let selected: AutomationRuleSet
            if response == .importFile {
                let panel = NSOpenPanel()
                panel.title = "Import Processing Rules"
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                panel.allowedContentTypes = [.json]
                guard panel.runModal() == .OK, let url = panel.url else { return }
                let imported = try AutomationRuleImport.ruleSets(
                    from: AutomationFileInput.readData(url, limit: 1_048_576))
                guard let chosen = imported.fromLibrary ? Self.chooseFromLibrary(imported.sets) : imported.sets.first
                else { return }
                selected = chosen
            } else if response == .load,
                let chosen = Self.selectedRuleSet(in: choices, from: saved + templates.sets)
            {
                selected = chosen
                try selected.validate()
            } else {
                return
            }
            let confirm = TTAlert()
            confirm.messageText = "Replace this draft’s rules?"
            confirm.informativeText =
                "Load \(selected.steps.count) processing steps from ‘\(selected.name)’. Canceling the builder will still preserve the saved automation."
            confirm.addButton(withTitle: "Replace Rules").identifier = NSUserInterfaceItemIdentifier(
                "rules.load.replace")
            confirm.addButton(withTitle: "Cancel", role: .cancel)
            if confirm.runModal() == .alertFirstButtonReturn {
                list.replaceAll(with: selected.steps)
                rulesChanged()
            }
        } catch { TTAlert.present(error) }
    }
    /// The chosen file is a whole automation library, not a rule file. Its automations are offered
    /// by name; only the chosen one's rules are taken.
    private static func chooseFromLibrary(_ sets: [AutomationRuleSet]) -> AutomationRuleSet? {
        let picker = TTAlert()
        picker.messageText = "This file is an automation library"
        picker.informativeText =
            "It holds \(sets.count == 1 ? "one automation" : "\(sets.count) automations") rather than a single rule set. Choose the automation whose rules to copy. Its name, input, output, shortcut and destination are not imported."
        picker.addButton(withTitle: "Use Its Rules")
        picker.addButton(withTitle: "Cancel", role: .cancel)
        let choices = ruleSetPopup(saved: sets, templates: [], savedPrefix: "Automation: ")
        picker.accessoryView = choices
        guard picker.runModal() == .alertFirstButtonReturn else { return nil }
        return selectedRuleSet(in: choices, from: sets)
    }
    @objc private func exportRules() {
        window.makeFirstResponder(nil)
        do {
            let data = try AutomationRuleSet(name: nameField.stringValue, steps: list.steps).encoded()
            let panel = NSSavePanel()
            panel.title = "Export Processing Rules"
            panel.nameFieldStringValue = "Automation-Rules.json"
            panel.allowedContentTypes = [.json]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
        } catch { TTAlert.present(error) }
    }
    @objc private func testRules() {
        window.makeFirstResponder(nil)
        previewControl?.cancel()
        previewControl = nil
        result.string = ""
        let token = preview.begin()
        // The rules alone are tested; the name field plays no part until Use These Rules.
        let input = sample.string, steps = list.steps
        guard input.utf8.count <= 65536 else {
            _ = preview.finish(token)
            status.stringValue = "Use a sample of at most 64 KiB."
            return
        }
        let control = AutomationRunControl()
        previewControl = control
        status.stringValue = "Testing rules using saved parameter defaults…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome: Result<String, Error> = Result {
                try AutomationDefinition.testRules(steps, sample: input, control: control)
            }
            // Delivered through the run loop, so the result also arrives while a modal started from a
            // main-queue block is open.
            MainRunLoop.perform { [weak self] in
                guard let self, self.preview.finish(token) else { return }
                self.previewControl = nil
                switch outcome {
                case .success(let text):
                    self.result.string = text
                    self.status.stringValue =
                        "Test passed using saved parameter defaults. No document or external output was changed."
                case .failure(let error): self.status.stringValue = error.localizedDescription
                }
            }
        }
    }
    @objc private func save() {
        window.makeFirstResponder(nil)
        var candidate = draft
        candidate.name = nameField.stringValue
        candidate.steps = list.steps
        do {
            try candidate.validate()
            draft = candidate
            accepted = true
            cancelPreview()
            NSApp.stopModal()
        } catch { TTAlert.present(error) }
    }
    @objc private func cancel() {
        cancelPreview()
        NSApp.stopModal()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancel()
        return false
    }
    static func editStep(_ initial: AutomationDefinition.Step) -> AutomationDefinition.Step? {
        let fields = RuleFields(initial)
        return withExtendedLifetime(fields) { fields.run() }
    }
}

private final class RuleFields: NSObject {
    private let initial: AutomationDefinition.Step
    private let alert = TTAlert(), kind = NSPopUpButton(), find = NSTextField(), replacement = NSTextField()
    private let findTitle = NSTextField(labelWithString: "Text to match")
    private let guidance = NSTextField(wrappingLabelWithString: "")
    private let askFind = NSButton(checkboxWithTitle: "Ask for this text when running", target: nil, action: nil)
    private let askReplacement = NSButton(
        checkboxWithTitle: "Ask for replacement when running", target: nil, action: nil)
    init(_ initial: AutomationDefinition.Step) {
        self.initial = initial
        super.init()
    }
    private var selected: AutomationDefinition.Step.Kind {
        AutomationDefinition.Step.Kind.allCases[kind.indexOfSelectedItem]
    }
    func run() -> AutomationDefinition.Step? {
        alert.messageText = "Configure Rule"
        alert.addButton(withTitle: "Save Rule").identifier = NSUserInterfaceItemIdentifier("rule.save")
        alert.addButton(withTitle: "Cancel", role: .cancel)
        // One menu item for every kind, in `allCases` order, so the selected index is the kind.
        for value in AutomationDefinition.Step.Kind.allCases {
            kind.menu?.addItem(NSMenuItem(title: value.label, action: nil, keyEquivalent: ""))
        }
        kind.selectItem(at: AutomationDefinition.Step.Kind.allCases.firstIndex(of: initial.kind)!)
        kind.target = self
        kind.action = #selector(changed)
        kind.setAccessibilityLabel("Rule")
        find.stringValue = initial.find ?? ""
        replacement.stringValue = initial.replacement ?? ""
        replacement.setAccessibilityLabel(AutomationDefinition.Step.Kind.replacementTitle)
        askFind.state = initial.askForFind == true ? .on : .off
        askReplacement.state = initial.askForReplacement == true ? .on : .off
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        for (title, control) in [
            (NSTextField(labelWithString: "Rule"), kind as NSView), (findTitle, find),
            (NSTextField(labelWithString: AutomationDefinition.Step.Kind.replacementTitle), replacement)
        ] {
            title.widthAnchor.constraint(equalToConstant: 100).isActive = true
            control.widthAnchor.constraint(equalToConstant: 420).isActive = true
            stack.addArrangedSubview(NSStackView(views: [title, control]))
        }
        guidance.widthAnchor.constraint(equalToConstant: 530).isActive = true
        stack.addArrangedSubview(askFind)
        stack.addArrangedSubview(askReplacement)
        stack.addArrangedSubview(guidance)
        stack.frame = NSRect(x: 0, y: 0, width: 550, height: 260)
        alert.accessoryView = stack
        changed()
        while alert.runModal() == .alertFirstButtonReturn {
            alert.window.makeFirstResponder(nil)
            let step = AutomationDefinition.Step.configured(
                kind: selected, find: find.stringValue, replacement: replacement.stringValue,
                askForFind: askFind.state == .on, askForReplacement: askReplacement.state == .on, from: initial)
            do {
                try step.validate()
                return step
            } catch { TTAlert.present(error) }
        }
        return nil
    }
    @objc private func changed() {
        let selected = selected
        find.isEnabled = selected.acceptsFind
        askFind.isEnabled = selected.acceptsFind
        replacement.isEnabled = selected.acceptsReplacement
        askReplacement.isEnabled = selected.acceptsReplacement
        findTitle.stringValue = selected.findTitle
        find.setAccessibilityLabel(selected.findTitle)
        guidance.stringValue = selected.guidance
    }
}
