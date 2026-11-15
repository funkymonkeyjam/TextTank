// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

extension AutomationDefinition.Step.Kind {
    var label: String {
        switch self {
        case .removeListMarkers: return "Remove bullet markers"
        case .removeBlankLines: return "Remove empty lines"
        case .sortLines: return "Sort lines alphabetically"
        case .deduplicateLines: return "Remove duplicate lines"
        case .replaceLiteral: return "Find and replace text"
        case .removeLinesEqualTo: return "Clear lines equal to text"
        case .removeLinesContaining: return "Clear lines containing text"
        case .removeLinesStartingWith: return "Clear lines starting with text"
        case .trimWhitespace: return "Trim spaces at line edges"
        case .removeMatchingLines: return "Clear lines matching a pattern (advanced)"
        case .removeMarkdownHeadings: return "Clear Markdown headings"
        case .removeMarkdownFormatting: return "Remove Markdown formatting"
        case .removeCheckboxMarkers: return "Remove checkbox markers"
        case .removeNoteReferences: return "Remove numbered note references"
        case .keepMarkedListRows: return "Keep marked list rows (strict)"
        }
    }
    var acceptsFind: Bool { [.replaceLiteral, .removeMatchingLines, .removeLinesEqualTo, .removeLinesContaining, .removeLinesStartingWith].contains(self) }
    var guidance: String {
        switch self {
        case .removeMatchingLines: return "Advanced regular expression: only a match covering the entire line clears it. Add Remove empty lines to compact the result."
        case .removeLinesEqualTo, .removeLinesContaining, .removeLinesStartingWith: return "Matches literal, case-sensitive text. Matching lines become empty; add Remove empty lines afterward. No regular expression is needed."
        case .replaceLiteral: return "Replace exact, case-sensitive text. Leave Replace with empty to remove it. Special characters are ordinary text."
        case .keepMarkedListRows: return "Requires every non-heading ingredient to have a bullet or checkbox. Mixed marked/unmarked ingredients are rejected without changes."
        case .deduplicateLines: return "Explicitly removes repeated rows. Leave this rule out when repeated ingredients should stay."
        default: return "Runs on captured text in the listed order. Test with a full example below before saving."
        }
    }
}

/// A draft-only native rule builder. Testing never invokes inputs, outputs or connectors.
final class AutomationStepEditor: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSTextViewDelegate {
    private var draft: AutomationDefinition
    private var accepted = false
    private var previewGeneration = 0
    private var previewControl: AutomationRunControl?
    private let window = NSWindow(contentRect:NSRect(x:0,y:0,width:940,height:700),styleMask:[.titled,.closable],backing:.buffered,defer:false)
    private let table = NSTableView()
    private let sample = NSTextView(), result = NSTextView()
    private let status = NSTextField(wrappingLabelWithString:"Paste sample text, then Test Rules. Testing never changes a document or sends reminders.")
    private var selectionButtons: [NSButton] = []
    private var addButton: NSButton!
    private init(_ definition:AutomationDefinition) { draft = definition; super.init() }
    static func edit(_ original:AutomationDefinition) -> AutomationDefinition? {
        let editor = AutomationStepEditor(original); editor.build()
        NSApp.runModal(for:editor.window)
        editor.window.orderOut(nil)
        return editor.accepted ? editor.draft : nil
    }
    private func button(_ title:String,_ action:Selector) -> NSButton {
        let b = NSButton(title:title,target:self,action:action); b.bezelStyle = .rounded; return b
    }
    private func build() {
        window.title = "Rules — \(draft.name)"; window.isReleasedWhenClosed = false; window.delegate = self
        guard let content = window.contentView else { return }
        let heading = NSTextField(labelWithString:"Rules run from top to bottom")
        heading.font = .boldSystemFont(ofSize:16); heading.frame = NSRect(x:20,y:660,width:880,height:24); content.addSubview(heading)
        let note = NSTextField(labelWithString:"Choose a rule, fill in its fields, then test the result. Changes stay in this draft until you save.")
        note.frame = NSRect(x:20,y:632,width:900,height:22); content.addSubview(note)
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("rule")); column.title = "Processing rules"; column.width = 870; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 30; table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(editRule)
        table.setAccessibilityLabel("Ordered processing rules")
        let scroll = NSScrollView(frame:NSRect(x:20,y:383,width:900,height:240)); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; content.addSubview(scroll)
        addButton = button("Add Rule…",#selector(addRule))
        let edit = button("Edit…",#selector(editRule)), duplicate = button("Duplicate",#selector(duplicateRule)), up = button("Move Up",#selector(moveUp)), down = button("Move Down",#selector(moveDown)), remove = button("Remove",#selector(removeRule))
        selectionButtons = [edit,duplicate,up,down,remove]
        let actions = NSStackView(views:[addButton,edit,duplicate,up,down,remove]); actions.spacing = 8; actions.frame = NSRect(x:20,y:342,width:670,height:32); content.addSubview(actions)
        let recipe = button("Load Recipe Rules…",#selector(loadRecipe)); recipe.frame = NSRect(x:735,y:342,width:185,height:32); content.addSubview(recipe)
        for (title,x) in [("Sample input — paste text to test",20.0),("Test result — read only",480.0)] {
            let label = NSTextField(labelWithString:title); label.frame = NSRect(x:x,y:309,width:440,height:24); content.addSubview(label)
        }
        for (text,x,editable) in [(sample,20.0,true),(result,480.0,false)] {
            text.isRichText = false; text.isEditable = editable; text.font = .monospacedSystemFont(ofSize:12,weight:.regular)
            text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
            text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
            text.setAccessibilityLabel(editable ? "Sample input" : "Test result")
            let scroll = NSScrollView(frame:NSRect(x:x,y:112,width:440,height:190)); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = text
            text.frame = scroll.contentView.bounds; content.addSubview(scroll)
        }
        sample.delegate = self
        let test = button("Test Rules",#selector(testRules)); test.frame = NSRect(x:20,y:70,width:120,height:32); content.addSubview(test)
        status.frame = NSRect(x:150,y:62,width:760,height:44); content.addSubview(status)
        let cancel = button("Cancel",#selector(cancel)); cancel.keyEquivalent = "\u{1b}"; cancel.frame = NSRect(x:680,y:18,width:100,height:32); content.addSubview(cancel)
        let save = button("Use These Rules",#selector(save)); save.keyEquivalent = "\r"; save.frame = NSRect(x:785,y:18,width:135,height:32); content.addSubview(save)
        reload(0); window.center(); window.makeKeyAndOrderFront(nil)
    }
    func numberOfRows(in tableView:NSTableView) -> Int { draft.steps.count }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int) -> NSView? {
        let step = draft.steps[row]
        let detail = step.find.map { "  ·  “\($0.replacingOccurrences(of:"\n",with:"↵").prefix(70))”" } ?? ""
        let label = NSTextField(labelWithString:"\(row+1). \(step.kind.label)\(detail)"); label.lineBreakMode = .byTruncatingTail; return label
    }
    func tableViewSelectionDidChange(_ notification:Notification) { updateButtons() }
    private func updateButtons() {
        let selected = draft.steps.indices.contains(table.selectedRow)
        selectionButtons.forEach { $0.isEnabled = selected }
        if selectionButtons.count == 5 {
            selectionButtons[1].isEnabled = selected && draft.steps.count < 100
            selectionButtons[2].isEnabled = selected && table.selectedRow > 0
            selectionButtons[3].isEnabled = selected && table.selectedRow + 1 < draft.steps.count
        }
        addButton?.isEnabled = draft.steps.count < 100
    }
    private func invalidatePreview() { previewGeneration += 1; previewControl?.cancel(); previewControl = nil; result.string = ""; status.stringValue = "Sample or rules changed. Test again to see the current result." }
    func textDidChange(_ notification:Notification) { invalidatePreview() }
    private func reload(_ row:Int) {
        table.reloadData()
        if !draft.steps.isEmpty { table.selectRowIndexes(IndexSet(integer:max(0,min(row,draft.steps.count-1))),byExtendingSelection:false) }
        updateButtons(); invalidatePreview()
    }
    @objc private func addRule() { guard draft.steps.count < 100 else { return }; if let step = Self.editStep(.init(kind:.removeBlankLines)) { draft.steps.append(step); reload(draft.steps.count-1) } }
    @objc private func editRule() { let i = table.selectedRow; guard draft.steps.indices.contains(i) else { return }; if let step = Self.editStep(draft.steps[i]) { draft.steps[i] = step; reload(i) } }
    @objc private func duplicateRule() { let i = table.selectedRow; guard draft.steps.indices.contains(i),draft.steps.count < 100 else { return }; draft.steps.insert(draft.steps[i],at:i+1); reload(i+1) }
    @objc private func removeRule() { let i = table.selectedRow; guard draft.steps.indices.contains(i) else { return }; draft.steps.remove(at:i); reload(i) }
    @objc private func moveUp() { let i = table.selectedRow; guard i > 0 else { return }; draft.steps.swapAt(i,i-1); reload(i-1) }
    @objc private func moveDown() { let i = table.selectedRow; guard i >= 0,i+1 < draft.steps.count else { return }; draft.steps.swapAt(i,i+1); reload(i+1) }
    @objc private func loadRecipe() {
        let alert = NSAlert(); alert.messageText = "Load recipe rules into this draft?"
        alert.informativeText = "Replaces this draft’s rules with editable heading and note removals for the four supplied recipe samples. Other text and duplicate ingredients are retained. Your saved workflow changes only after you save."
        alert.addButton(withTitle:"Load Rules"); alert.addButton(withTitle:"Cancel")
        if alert.runModal() == .alertFirstButtonReturn { draft.steps = AutomationDefinition.shoppingRecipeSteps; reload(0) }
    }
    @objc private func testRules() {
        window.makeFirstResponder(nil); invalidatePreview()
        let input = sample.string, definition = draft, generation = previewGeneration
        guard input.utf8.count <= 65536 else { status.stringValue = "Use a sample of at most 64 KiB."; return }
        let control = AutomationRunControl(); previewControl = control
        status.stringValue = "Testing rules using saved parameter defaults…"
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let outcome:Result<String,Error> = Result { try definition.testSample(input,control:control) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.previewGeneration == generation else { return }
                self.previewControl = nil
                switch outcome {
                case .success(let text): self.result.string = text; self.status.stringValue = "Test passed using saved parameter defaults. No document or external output was changed."
                case .failure(let error): self.status.stringValue = error.localizedDescription
                }
            }
        }
    }
    @objc private func save() { do { try draft.validate(); accepted = true; invalidatePreview(); NSApp.stopModal() } catch { NSAlert(error:error).runModal() } }
    @objc private func cancel() { invalidatePreview(); NSApp.stopModal() }
    func windowShouldClose(_ sender:NSWindow) -> Bool { cancel(); return false }
    static func editStep(_ initial:AutomationDefinition.Step) -> AutomationDefinition.Step? {
        RuleFields(initial).run()
    }
}

private final class RuleFields: NSObject {
    private let initial:AutomationDefinition.Step
    private let alert = NSAlert(), kind = NSPopUpButton(), find = NSTextField(), replacement = NSTextField()
    private let guidance = NSTextField(wrappingLabelWithString:"")
    private let askFind = NSButton(checkboxWithTitle:"Ask for this text when running",target:nil,action:nil)
    private let askReplacement = NSButton(checkboxWithTitle:"Ask for replacement when running",target:nil,action:nil)
    init(_ initial:AutomationDefinition.Step) { self.initial = initial; super.init() }
    private var selected:AutomationDefinition.Step.Kind { AutomationDefinition.Step.Kind.allCases[kind.indexOfSelectedItem] }
    func run() -> AutomationDefinition.Step? {
        alert.messageText = "Configure Rule"; alert.addButton(withTitle:"Save Rule"); alert.addButton(withTitle:"Cancel")
        for value in AutomationDefinition.Step.Kind.allCases { kind.addItem(withTitle:value.label) }
        kind.selectItem(at:AutomationDefinition.Step.Kind.allCases.firstIndex(of:initial.kind)!)
        kind.target = self; kind.action = #selector(changed)
        find.stringValue = initial.find ?? ""; replacement.stringValue = initial.replacement ?? ""
        askFind.state = initial.askForFind == true ? .on : .off; askReplacement.state = initial.askForReplacement == true ? .on : .off
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        for (label,control) in [("Rule",kind as NSView),("Text to match",find),("Replace with",replacement)] {
            let title = NSTextField(labelWithString:label); title.widthAnchor.constraint(equalToConstant:100).isActive = true
            control.widthAnchor.constraint(equalToConstant:420).isActive = true
            stack.addArrangedSubview(NSStackView(views:[title,control]))
        }
        guidance.widthAnchor.constraint(equalToConstant:530).isActive = true
        stack.addArrangedSubview(askFind); stack.addArrangedSubview(askReplacement); stack.addArrangedSubview(guidance)
        stack.frame = NSRect(x:0,y:0,width:550,height:240); alert.accessoryView = stack; changed()
        while alert.runModal() == .alertFirstButtonReturn {
            alert.window.makeFirstResponder(nil)
            let k = selected
            let step = AutomationDefinition.Step(kind:k,find:k.acceptsFind ? find.stringValue : nil,replacement:k == .replaceLiteral ? replacement.stringValue : nil,askForFind:k.acceptsFind && askFind.state == .on,askForReplacement:k == .replaceLiteral && askReplacement.state == .on)
            var probe = AutomationDefinition.example; probe.steps = [step]
            do { try probe.validate(); return step } catch { NSAlert(error:error).runModal() }
        }
        return nil
    }
    @objc private func changed() {
        find.isEnabled = selected.acceptsFind; askFind.isEnabled = selected.acceptsFind
        replacement.isEnabled = selected == .replaceLiteral; askReplacement.isEnabled = selected == .replaceLiteral
        guidance.stringValue = selected.guidance
    }
}
