// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Darwin

extension Notification.Name { static let textTankAutomationsDidChange = Notification.Name("TextTankAutomationsDidChange") }

final class AutomationController: NSObject, NSMenuDelegate {
    private let editorProvider: () -> TTEditor?
    private let newDocument: (String) -> Void
    private let storage: URL
    private var library = AutomationLibrary(workflows: [])
    private var loadError: Error?
    private var busy = false
    private var exportInProgress = false
    private var exportTask: Task<Void,Never>?
    private lazy var automationMenu: NSMenu = { let m = NSMenu(title: "Automations"); m.delegate = self; return m }()

    init(editorProvider: @escaping () -> TTEditor?, newDocument: @escaping (String) -> Void) {
        self.editorProvider = editorProvider; self.newDocument = newDocument
        let base: URL
        if let isolated = ProcessInfo.processInfo.environment["TEXTTANK_SUPPORT_DIRECTORY"] { base = URL(fileURLWithPath: isolated, isDirectory: true) }
        else { base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TextTank", isDirectory: true) }
        storage = base.appendingPathComponent("Automations.json")
        super.init()
        if FileManager.default.fileExists(atPath: storage.path) {
            do { library = try AutomationLibrary.decode(Data(contentsOf: storage)) } catch { loadError = error }
        } else {
            // Presets are ordinary editable definitions, installed only for a new configuration.
            do { try persistLibrary(AutomationLibrary(workflows: [.example, .remindersExample])) }
            catch { loadError = error }
        }
    }
    func menu() -> NSMenu { rebuild(); return automationMenu }
    func menuNeedsUpdate(_ menu: NSMenu) { if menu === automationMenu { rebuild() } else { populateInvocations(menu) } }
    /// Fresh menus all dispatch by stable ID and resolve the currently saved definition at invocation.
    func contextMenu() -> NSMenu { invocationMenu(title: "Run Automation") }
    func makeToolbarItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier:NSToolbarItem.Identifier("TextTank.Automations"))
        item.label = "Automations"; item.paletteLabel = "Automations"
        let button = NSPopUpButton(frame:NSRect(x:0,y:0,width:165,height:30),pullsDown:true)
        button.menu = invocationMenu(title:"Automation Launcher")
        button.setAccessibilityLabel("Automations"); button.toolTip = "Run a saved automation or manage your workflows"
        item.view = button
        return item
    }
    func toolbarIdentifiers() -> [NSToolbarItem.Identifier] {
        library.workflows.filter { $0.pinToToolbar == true }.map { .init("TextTank.Automation." + $0.id.uuidString) }
    }
    func makeToolbarItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        let prefix = "TextTank.Automation."
        guard identifier.rawValue.hasPrefix(prefix),
              let id = UUID(uuidString: String(identifier.rawValue.dropFirst(prefix.count))),
              let workflow = library.workflows.first(where: { $0.id == id }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = workflow.name; item.paletteLabel = workflow.name
        item.toolTip = workflow.output == .reminders ? "Send the current text to a Reminders list you choose" : "Run \(workflow.name)"
        let button = NSButton(title: workflow.name, target: self, action: #selector(runToolbarButton(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
        button.bezelStyle = .rounded; button.setAccessibilityLabel(workflow.name)
        item.view = button
        return item
    }
    @objc private func runToolbarButton(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue, let id = UUID(uuidString:value) else { return }
        do { try runSavedAutomation(id: id) } catch { showError(error) }
    }
    /// Every menu, shortcut, toolbar and palette resolves the current saved definition by UUID.
    func runSavedAutomation(id: UUID) throws {
        guard !busy, !exportInProgress else { return }
        guard let workflow = library.workflows.first(where: { $0.id == id }) else { throw AutomationError.invalid("This automation no longer exists.") }
        busy = true; defer { busy = false }
        try run(workflow, capturedEditor: editorProvider())
    }
    private func invocationMenu(title: String) -> NSMenu {
        let result = NSMenu(title: title); result.delegate = self
        populateInvocations(result); return result
    }
    private func populateInvocations(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu.title == "Automation Launcher" { menu.addItem(withTitle:"Automations",action:nil,keyEquivalent:"") }
        for workflow in library.workflows.sorted(by: { ($0.pinToToolbar == true ? 0 : 1) < ($1.pinToToolbar == true ? 0 : 1) }) {
            let item = NSMenuItem(title: (workflow.pinToToolbar == true ? "★ " : "") + workflow.name, action: #selector(runAction(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = workflow.id.uuidString; menu.addItem(item)
        }
        let manage = NSMenuItem(title: "Manage Automations…", action: #selector(manageAction), keyEquivalent: "")
        manage.target = self; menu.addItem(manage)
    }
    func showPalette() {
        guard !busy, !exportInProgress else { return }
        guard !library.workflows.isEmpty else { manage(); return }
        busy = true; defer { busy = false }
        let alert = NSAlert(); alert.messageText = "Run Automation"
        alert.informativeText = "Choose a saved automation. Its current saved definition will run. Preview is optional; Reminders always asks you to choose a destination and Send."
        alert.addButton(withTitle: "Run"); alert.addButton(withTitle: "Cancel")
        let choice = NSPopUpButton(frame: NSRect(x:0,y:0,width:400,height:28), pullsDown:false)
        for workflow in library.workflows { let item = NSMenuItem(title: workflow.name, action: nil, keyEquivalent: ""); item.representedObject = workflow.id.uuidString; choice.menu?.addItem(item) }
        alert.accessoryView = choice
        // Preserve editor context before the palette becomes the key window.
        let capturedEditor = editorProvider()
        guard alert.runModal() == .alertFirstButtonReturn, let id = choice.selectedItem?.representedObject as? String, let workflow = library.workflows.first(where: {$0.id.uuidString == id}) else { return }
        do { try run(workflow, capturedEditor: capturedEditor) } catch { showError(error) }
    }
    private func rebuild() {
        automationMenu.removeAllItems()
        let manage = NSMenuItem(title: "Manage Automations…", action: #selector(manageAction), keyEquivalent: "")
        manage.target = self; automationMenu.addItem(manage)
        let palette = NSMenuItem(title: "Choose Automation…", action: #selector(paletteAction), keyEquivalent: "")
        palette.target = self; automationMenu.addItem(palette)
        let history = NSMenuItem(title: "Review Reminder Export History…", action: #selector(reminderHistory), keyEquivalent: "")
        history.target = self; automationMenu.addItem(history)
        if !library.workflows.isEmpty { automationMenu.addItem(.separator()) }
        for workflow in library.workflows {
            let item = NSMenuItem(title: workflow.name, action: #selector(runAction(_:)), keyEquivalent: workflow.shortcut ?? "")
            item.keyEquivalentModifierMask = [.command, .option]
            item.target = self; item.representedObject = workflow.id.uuidString; automationMenu.addItem(item)
        }
    }
    @objc private func manageAction() { manage() }
    @objc private func paletteAction() { showPalette() }
    func manage() {
        guard !busy, !exportInProgress else { return }
        if let loadError { showError(loadError); return }
        guard !library.workflows.isEmpty else { createAutomation(); return }
        busy = true; defer { busy = false }
        let choose = NSAlert(); choose.messageText = "Manage Automations"
        choose.informativeText = "Rename an automation, choose its input and output, and choose its preview and favorite status. Edit Rules opens a visual rule list with sample testing. JSON is optional for advanced users."
        for title in ["Edit", "Cancel", "Advanced JSON…", "Create Automation…", "Delete Automation"] { choose.addButton(withTitle:title) }
        let selection = NSPopUpButton(frame:NSRect(x:0,y:0,width:550,height:28),pullsDown:false)
        for workflow in library.workflows { selection.addItem(withTitle:workflow.name); selection.lastItem?.representedObject = workflow.id.uuidString }
        choose.accessoryView = selection
        let response = choose.runModal()
        if response.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 2 { busy = false; manageAdvanced(); return }
        if response.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 3 { busy = false; createAutomation(); return }
        if response.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 4 {
            if let id = selection.selectedItem?.representedObject as? String {
                let confirm = NSAlert(); confirm.messageText = "Delete this automation?"; confirm.informativeText = "Its saved definition and trigger bindings will be removed. Documents and exported reminders are unchanged."; confirm.addButton(withTitle:"Delete"); confirm.addButton(withTitle:"Cancel")
                if confirm.runModal() == .alertFirstButtonReturn { do { var proposed = library; proposed.workflows.removeAll { $0.id.uuidString == id }; try persistLibrary(proposed) } catch { showError(error) } }
            }; return
        }
        guard response == .alertFirstButtonReturn,
              let id = selection.selectedItem?.representedObject as? String,
              let index = library.workflows.firstIndex(where: { $0.id.uuidString == id }) else { return }
        var workflow = library.workflows[index]
        let edit = NSAlert(); edit.messageText = "Edit Automation"
        edit.informativeText = "The name changes its labels, not its behavior. Editor changes can be undone. Reminders always requires an explicit destination and Send."
        edit.addButton(withTitle:"Save"); edit.addButton(withTitle:"Cancel"); edit.addButton(withTitle:"Edit Rules & Test…")
        let name = NSTextField(string:workflow.name)
        let shortcut = NSTextField(string:workflow.shortcut ?? ""); shortcut.placeholderString = "Lowercase letter for Command-Option; blank for none"
        let input = NSPopUpButton(); let output = NSPopUpButton()
        for value in ["document","selection","clipboard","file"] { input.addItem(withTitle:value) }
        for value in ["editor","clipboard","newDocument","file","reminders"] { output.addItem(withTitle:value) }
        input.selectItem(withTitle:workflow.input.rawValue); output.selectItem(withTitle:workflow.output.rawValue)
        let preview = NSButton(checkboxWithTitle:"Preview before applying",target:nil,action:nil); preview.state = workflow.previewBeforeApply == true ? .on : .off
        let pinned = NSButton(checkboxWithTitle:"Favorite in the Automations menu",target:nil,action:nil); pinned.state = workflow.pinToToolbar == true ? .on : .off
        edit.accessoryView = settingsView(rows:[("Name",name),("Input",input),("Output",output),("Shortcut",shortcut)],options:[preview,pinned])
        while true {
            let response = edit.runModal()
            if response.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 2 { edit.window.makeFirstResponder(nil); workflow.name = name.stringValue; if let revised = AutomationStepEditor.edit(workflow, savedWorkflows:library.workflows) { workflow.steps = revised.steps; workflow.name = revised.name; name.stringValue = revised.name }; continue }
            guard response == .alertFirstButtonReturn else { return }; break
        }
        do {
            edit.window.makeFirstResponder(nil)
            workflow.name = name.stringValue
            workflow.shortcut = shortcut.stringValue
            if let value = input.titleOfSelectedItem, let typed = AutomationDefinition.Input(rawValue:value) { workflow.input = typed }
            if let value = output.titleOfSelectedItem, let typed = AutomationDefinition.Output(rawValue:value) { workflow.output = typed }
            workflow.previewBeforeApply = preview.state == .on; workflow.pinToToolbar = pinned.state == .on
            var proposed = library; proposed.workflows[index] = workflow
            try checkShortcutCollisions(proposed); try persistLibrary(proposed)
        } catch { showError(error) }
    }
    private func createAutomation() {
        guard !busy, !exportInProgress else { return }
        busy = true; defer { busy = false }
        let definition = AutomationDefinition(id:UUID(),name:"My Automation",input:.document,steps:[],output:.editor,pinToToolbar:false)
        do {
            guard let edited = AutomationStepEditor.edit(definition,savedWorkflows:library.workflows) else { return }
            var proposed = library; proposed.workflows.append(edited); try persistLibrary(proposed)
        } catch { showError(error) }
    }
    @objc func addRecipeButtons() {
        guard !busy, !exportInProgress else { return }
        if let loadError { showError(loadError); return }
        busy = true; defer { busy = false }
        let alert = NSAlert(); alert.messageText = "Add Recipe Buttons"
        alert.informativeText = "The first button cleans the current document in place, with Undo. The second sends its nonblank rows to a Reminders list you choose. Name them however you like. Existing automations are kept."
        alert.addButton(withTitle:"Add Buttons"); alert.addButton(withTitle:"Cancel")
        let cleanName = NSTextField(string:AutomationDefinition.example.name)
        let sendName = NSTextField(string:AutomationDefinition.remindersExample.name)
        let preview = NSButton(checkboxWithTitle:"Preview cleanup before applying (optional)",target:nil,action:nil)
        alert.accessoryView = settingsView(rows:[("Cleanup name",cleanName),("Send name",sendName)],options:[preview])
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            alert.window.makeFirstResponder(nil)
            var clean = AutomationDefinition.example; clean.id = UUID(); clean.name = cleanName.stringValue
            clean.previewBeforeApply = preview.state == .on; clean.pinToToolbar = true
            var send = AutomationDefinition.remindersExample; send.id = UUID(); send.name = sendName.stringValue; send.pinToToolbar = true
            var proposed = library; proposed.workflows.append(contentsOf:[clean,send])
            try checkShortcutCollisions(proposed); try persistLibrary(proposed)
        } catch { showError(error) }
    }
    private func settingsView(rows: [(String,NSView)], options:[NSView]) -> NSView {
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        for (title,control) in rows {
            let label = NSTextField(labelWithString:title)
            label.translatesAutoresizingMaskIntoConstraints = false; control.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant:110).isActive = true
            control.widthAnchor.constraint(equalToConstant:420).isActive = true
            let row = NSStackView(views:[label,control]); row.spacing = 10; stack.addArrangedSubview(row)
        }
        for option in options { stack.addArrangedSubview(option) }
        stack.frame = NSRect(x:0,y:0,width:550,height:CGFloat(rows.count * 34 + options.count * 28))
        return stack
    }
    func manageAdvanced() {
        guard !busy, !exportInProgress else { return }
        if let loadError { showError(AutomationError.invalid("Saved automations could not be loaded: \(loadError.localizedDescription)\nThe original file is preserved. Export or repair it outside TextTank before replacing it.")); return }
        busy = true; defer { busy = false }
        let alert = NSAlert(); alert.messageText = "Advanced Automation Configuration"
        alert.informativeText = "Edit the JSON below. Rename by changing name, keeping id unchanged. Input: selection, document, clipboard, file. Output: editor, clipboard, newDocument, file, reminders. Steps: removeListMarkers, removeCheckboxMarkers, removeMarkdownHeadings, removeMarkdownFormatting, removeNoteReferences, keepMarkedListRows, removeBlankLines, sortLines, deduplicateLines, replaceLiteral (find/replacement), removeMatchingLines (whole-line regex find). Optional shortcut: a lowercase letter, bound to Command-Option. Set previewBeforeApply true for a preview, false or omit to apply directly. Set pinToToolbar true for a named toolbar button. Mixed line endings are retained unless a line-reordering step requires a uniform format. No automation runs when saved or imported."
        for title in ["Save", "Cancel", "Import…", "Export…"] { alert.addButton(withTitle: title) }
        let text = makeTextView(height: 400)
        let initial = library.workflows.isEmpty ? AutomationLibrary(workflows: [.example]) : library
        text.editor.string = String(data: (try? initial.encoded()) ?? Data(), encoding: .utf8) ?? ""
        alert.accessoryView = text.scroll
        while true {
            let response = alert.runModal()
            if response == .alertSecondButtonReturn { return }
            do {
                if response.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 2 {
                    let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url {
                        let imported = try AutomationLibrary.decode(Data(contentsOf: url))
                        text.editor.string = String(data: try imported.encoded(), encoding: .utf8)!
                    }
                    continue
                }
                let proposed = try AutomationLibrary.decode(Data(text.editor.string.utf8))
                if response.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 3 {
                    let panel = NSSavePanel(); panel.nameFieldStringValue = "TextTank-Automations.json"
                    if panel.runModal() == .OK, let url = panel.url { try proposed.encoded().write(to: url, options: .atomic) }
                    continue
                }
                try checkShortcutCollisions(proposed)
                try persistLibrary(proposed); return
            } catch { showError(error) }
        }
    }
    /// Shared private persistence for edited workflows and explicitly selected destinations.
    func persistLibrary(_ proposed: AutomationLibrary) throws {
        if let loadError { throw loadError } // Never overwrite an unreadable existing library.
        let data = try proposed.encoded()
        let directory = storage.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: directory.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw AutomationError.invalid("Automation storage must be a regular directory.") }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if FileManager.default.fileExists(atPath: storage.path) {
            // attributesOfItem performs a fresh lstat; URL resource values may be cached
            // across an externally replaced path and must not authorize the write.
            let attributes = try FileManager.default.attributesOfItem(atPath: storage.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw AutomationError.invalid("Automation storage must be a regular file.") }
        }
        let temporary = directory.appendingPathComponent(".automations-" + UUID().uuidString)
        let descriptor = open(temporary.path,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW,mode_t(0o600))
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let handle = FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at:temporary) }
        try handle.write(contentsOf:data); try handle.synchronize(); try handle.close()
        guard rename(temporary.path,storage.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        library = proposed; rebuild(); NotificationCenter.default.post(name: .textTankAutomationsDidChange, object: self)
    }
    private func checkShortcutCollisions(_ proposed: AutomationLibrary) throws {
        func existing(_ menu: NSMenu) -> Set<String> {
            if menu === automationMenu { return [] }
            var keys = Set<String>()
            for item in menu.items {
                if item.keyEquivalentModifierMask.intersection([.command,.option,.control,.shift]) == [.command,.option] { keys.insert(item.keyEquivalent) }
                if let submenu = item.submenu { keys.formUnion(existing(submenu)) }
            }
            return keys
        }
        let keys = NSApp.mainMenu.map(existing) ?? []
        for workflow in proposed.workflows {
            if let key = workflow.shortcut, keys.contains(key) { throw AutomationError.invalid("Command-Option-\(key.uppercased()) is already assigned to an application command.") }
        }
    }
    @objc private func runAction(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String, let id = UUID(uuidString: identifier) else { return }
        do { try runSavedAutomation(id: id) } catch { showError(error) }
    }
    private func run(_ original: AutomationDefinition, capturedEditor: TTEditor?) throws {
        let workflow = original
        // Capture once before showing the preview. Never re-query the frontmost editor on Apply.
        let editor = capturedEditor
        let revision = editor?.revision
        let start = editor?.selectionStart
        let end = editor?.selectionEnd
        let selections = editor?.selectionRanges
        if workflow.input == .selection || workflow.output == .editor {
            guard let editor else { throw AutomationError.invalid("This automation requires an open editor document.") }
            guard editor.selectionCount == 1 || (workflow.input == .selection && workflow.output == .editor) else { throw AutomationError.invalid("Multiple selections require selection input and editor output. Other outputs are not changed.") }
        }
        guard let resolved = try workflow.resolvingParameters({ index, label, initial in
            let alert = NSAlert(); alert.messageText = "\(workflow.name) — Step \(index + 1)"; alert.informativeText = label
            alert.addButton(withTitle:"Continue"); alert.addButton(withTitle:"Cancel")
            let field = NSTextField(string:initial); field.frame = NSRect(x:0,y:0,width:500,height:28); alert.accessoryView = field
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            alert.window.makeFirstResponder(nil)
            return field.stringValue
        }) else { return }
        if workflow.input == .selection, workflow.output == .editor, let editor, editor.selectionCount > 1, let revision, let selections {
            let bytes = Data(editor.text.utf8)
            var outputs:[String] = []
            for (index,range) in selections.enumerated() {
                guard let anchor = range["anchor"]?.intValue, let caret = range["caret"]?.intValue, anchor != caret,
                      min(anchor,caret) >= 0,max(anchor,caret) <= bytes.count,
                      let text = String(data:bytes.subdata(in:min(anchor,caret)..<max(anchor,caret)),encoding:.utf8) else { throw AutomationError.invalid("Select text in every selection before running this automation.") }
                var output = try transformWithProgress(resolved,input:text)
                if workflow.previewBeforeApply == true {
                    let alert = NSAlert(); alert.messageText = "\(workflow.name) — Selection \(index + 1) of \(selections.count)"; alert.informativeText = "All selections apply together after every preview is accepted. Cancel preserves the entire editor."; alert.addButton(withTitle:"Accept"); alert.addButton(withTitle:"Cancel")
                    let preview = makeTextView(height:250); preview.editor.string = output; alert.accessoryView = preview.scroll
                    guard alert.runModal() == .alertFirstButtonReturn else { return }; output = preview.editor.string
                }
                outputs.append(output)
            }
            guard editor.window != nil, editor.selectionRanges == selections, editor.replaceSelections(outputs,expectedRevision:revision) else { throw AutomationError.invalid("The document or selections changed, closed or became read-only. Nothing was replaced.") }
            return
        }
        let input: String
        switch workflow.input {
        case .selection:
            guard let editor, start != end else { throw AutomationError.invalid("Select text before running this automation.") }
            input = editor.selectedText
        case .document:
            guard let editor else { throw AutomationError.invalid("This automation requires an open editor document.") }
            input = editor.text
        case .file:
            let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let url = panel.url else { return }
            // File input explicitly accepts valid UTF-8 only; never guess or replace invalid bytes.
            input = try AutomationFileInput.read(url)
        case .clipboard:
            guard let value = plainClipboardText() else { throw AutomationError.invalid("The clipboard does not contain supported text.") }
            input = value
        }
        var output = try transformWithProgress(resolved,input:input)
        if workflow.previewBeforeApply == true {
            let alert = NSAlert(); alert.messageText = workflow.name
            let scope = workflow.input == .document ? "entire captured document" : "captured selection"
            let destination = workflow.output == .editor ? "Replace \(scope)" : "Output: \(workflow.output.rawValue)"
            alert.informativeText = "Input: \(workflow.input.rawValue). \(destination). Edit the preview; delete rows you do not want. Apply commits it. Cancel makes no changes. You can turn this preview off in Manage Automations."
            alert.addButton(withTitle: "Apply"); alert.addButton(withTitle: "Cancel")
            let preview = makeTextView(height: 350); preview.editor.string = output; alert.accessoryView = preview.scroll
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            output = preview.editor.string
        }
        switch workflow.output {
        case .editor:
            guard let editor, editor.window != nil, !editor.readOnly, editor.revision == revision else { throw AutomationError.invalid("The original document changed or closed. Run the automation again with the current text.") }
            guard editor.selectionCount == 1, editor.selectionStart == start, editor.selectionEnd == end else { throw AutomationError.invalid("The editor selection changed. No text was replaced.") }
            if workflow.input == .document { editor.text = output }
            else { editor.replaceSelection(output) }
        case .clipboard:
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(output, forType: .string) else { throw AutomationError.invalid("The clipboard could not be updated.") }
        case .newDocument: newDocument(output)
        case .reminders:
            beginReminderExport(output, workflow: workflow)
        case .file:
            let panel = NSSavePanel(); panel.nameFieldStringValue = "Automation-output.txt"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try Data(output.utf8).write(to: url, options: .atomic)
        }
    }
    private var runControl: AutomationRunControl?
    @objc private func cancelTransform() { runControl?.cancel() }
    private func transformWithProgress(_ workflow:AutomationDefinition,input:String) throws -> String {
        // Small recipe workflows stay synchronous and preserve their one-click interaction.
        guard input.utf8.count > 262144 else { return try workflow.transform(input) }
        let control = AutomationRunControl(); runControl = control
        defer { runControl = nil }
        let panel = NSPanel(contentRect:NSRect(x:0,y:0,width:420,height:130),styleMask:[.titled],backing:.buffered,defer:false)
        panel.title = workflow.name
        let status = NSTextField(labelWithString:"Processing captured text…"); status.frame = NSRect(x:20,y:85,width:380,height:24)
        let progress = NSProgressIndicator(frame:NSRect(x:20,y:60,width:380,height:18)); progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = Double(max(1,workflow.steps.count))
        let cancel = NSButton(title:"Cancel",target:self,action:#selector(cancelTransform)); cancel.frame = NSRect(x:290,y:15,width:110,height:30)
        panel.contentView?.addSubview(status); panel.contentView?.addSubview(progress); panel.contentView?.addSubview(cancel)
        var outcome: Result<String,Error>?
        control.onProgress = { completed,total in DispatchQueue.main.async { progress.doubleValue = Double(completed); status.stringValue = "Processing step \(min(completed+1,total)) of \(total)…" } }
        DispatchQueue.global(qos:.userInitiated).async {
            let result = Result { try workflow.transform(input,control:control) }
            DispatchQueue.main.async { outcome = result; if NSApp.modalWindow === panel { NSApp.stopModal() } }
        }
        panel.center(); NSApp.runModal(for:panel); panel.orderOut(nil)
        guard let outcome else { control.cancel(); throw AutomationError.invalid("Automation cancelled. Nothing was changed.") }
        return try outcome.get()
    }
    private func beginReminderExport(_ text: String, workflow: AutomationDefinition) {
        let rows = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !rows.isEmpty else { showError(AutomationError.invalid("There are no nonblank reminder rows to send.")); return }
        guard !exportInProgress else { return }
        exportInProgress = true // Acquire before scheduling, so double-clicks cannot queue two exports.
        exportTask = Task { @MainActor in
            defer { self.exportInProgress = false; self.exportTask = nil }
            do {
                let connector = RemindersConnector(storageURL: self.storage.deletingLastPathComponent().appendingPathComponent("ReminderExports", isDirectory: true))
                try await connector.requestAccess()
                let destinations = try connector.destinations()
                let writable = destinations.filter { $0.writable }
                guard !writable.isEmpty else { throw AutomationError.invalid("No writable Reminders lists are available.") }
                let alert = NSAlert(); alert.messageText = "Send \(rows.count) Reminder Items"
                alert.informativeText = "Choose the destination list and account. List identifiers distinguish duplicate names. The batch is recorded before external writes; uncertain results will not be silently retried."
                alert.addButton(withTitle: "Send \(rows.count) Items"); alert.addButton(withTitle: "Cancel")
                let choice = NSPopUpButton(frame: NSRect(x:0,y:0,width:650,height:28), pullsDown: false)
                for destination in writable {
                    choice.addItem(withTitle: "\(destination.title) — \(destination.source) [\(destination.id)]")
                    choice.lastItem?.representedObject = destination.id
                }
                if let saved = workflow.destinationID, let index = writable.firstIndex(where: { $0.id == saved }) { choice.selectItem(at:index) }
                else if workflow.destinationID != nil { alert.informativeText += " The previously saved list is unavailable. Explicitly choose a new destination."; choice.select(nil) }
                alert.accessoryView = choice
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                guard let destinationID = choice.selectedItem?.representedObject as? String else { throw AutomationError.invalid("Choose a writable list before sending.") }
                // Persist chosen default only after explicit Send intent. Failure prevents send.
                if let index = self.library.workflows.firstIndex(where: {$0.id == workflow.id}) {
                    var proposed = self.library; proposed.workflows[index].destinationID = destinationID
                    try self.persistLibrary(proposed)
                }
                let existing = Self.matchingExport(rows: rows, destinationID: destinationID, batches: try connector.storedBatches())
                if let existing {
                    let repeated = NSAlert(); repeated.messageText = "These items have already been sent or attempted"
                    repeated.informativeText = "An export with the same rows and destination already exists. Review its confirmed, failed and uncertain results to avoid duplicates. Send Another Copy intentionally creates another set."
                    repeated.addButton(withTitle: "Review Existing Export"); repeated.addButton(withTitle: "Cancel"); repeated.addButton(withTitle: "Send Another Copy")
                    let response = repeated.runModal()
                    if response == .alertFirstButtonReturn { self.showReminderResults(existing); return }
                    guard response.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 2 else { return }
                }
                let progress = self.exportProgressPanel(total:rows.count); defer { progress.panel.orderOut(nil) }
                let batch = try await connector.export(rows:rows, destinationID:destinationID, batchID:UUID(),progress:progress.update)
                self.showReminderResults(batch)
            } catch { self.showError(error) }
        }
    }
    @objc private func cancelExport() { exportTask?.cancel() }
    private func exportProgressPanel(total:Int) -> (panel:NSPanel,update:(Int,Int)->Void) {
        let panel = NSPanel(contentRect:NSRect(x:0,y:0,width:440,height:130),styleMask:[.titled],backing:.buffered,defer:false); panel.title = "Sending to Reminders"
        let label = NSTextField(labelWithString:"Preparing \(total) items…"); label.frame = NSRect(x:20,y:85,width:400,height:24)
        let indicator = NSProgressIndicator(frame:NSRect(x:20,y:60,width:400,height:16)); indicator.isIndeterminate = false; indicator.maxValue = Double(total)
        let cancel = NSButton(title:"Stop Sending",target:self,action:#selector(cancelExport)); cancel.frame = NSRect(x:280,y:15,width:140,height:30)
        panel.contentView?.addSubview(label); panel.contentView?.addSubview(indicator); panel.contentView?.addSubview(cancel); panel.center(); panel.makeKeyAndOrderFront(nil)
        return (panel,{ completed,total in label.stringValue = "Processed \(completed) of \(total). Sent items remain in Reminders."; indicator.doubleValue = Double(completed) })
    }
    static func matchingExport(rows: [String], destinationID: String, batches: [ReminderBatch]) -> ReminderBatch? {
        batches.filter { $0.destinationID == destinationID && $0.rows.map(\.title) == rows }
            .max { $0.createdAt < $1.createdAt }
    }
    @MainActor private func showReminderResults(_ batch: ReminderBatch) {
        let alert = NSAlert(); alert.messageText = "Reminder Export Results"
        alert.informativeText = "Batch \(batch.id). Confirmed items are not resent. Uncertain items require inspection in Reminders and are never automatically retried. Failed and unsent pending items remain available in Export History. Resume retries those items only. Editor Undo does not affect reminders."
        let text = makeTextView(height:300); text.editor.isEditable = false
        text.editor.string = "Destination: \(batch.destinationTitle) — \(batch.destinationSource) [\(batch.destinationID)]\n\n" + batch.rows.map { row in "[\(row.status.rawValue)] \(row.title)\(row.message.map { " — " + $0 } ?? "")" }.joined(separator:"\n")
        alert.accessoryView = text.scroll; alert.addButton(withTitle:"Done"); alert.runModal()
    }
    @objc private func reminderHistory() {
        guard !busy, !exportInProgress else { return }
        exportInProgress = true
        exportTask = Task { @MainActor in
            defer { self.exportInProgress = false; self.exportTask = nil }
            do {
                let connector = RemindersConnector(storageURL:self.storage.deletingLastPathComponent().appendingPathComponent("ReminderExports",isDirectory:true))
                let batches = try connector.storedBatches()
                guard !batches.isEmpty else { throw AutomationError.invalid("There are no recorded reminder exports.") }
                let alert = NSAlert(); alert.messageText = "Reminder Export History"
                alert.informativeText = "Choose a recorded batch to inspect its durable per-item results. Reading this history does not request system access."
                alert.addButton(withTitle:"Review"); alert.addButton(withTitle:"Cancel"); alert.addButton(withTitle:"Request Access and Resume Unsent")
                let choice = NSPopUpButton(frame:NSRect(x:0,y:0,width:650,height:28),pullsDown:false)
                for batch in batches { choice.addItem(withTitle:"\(batch.destinationTitle) — \(batch.destinationSource) · \(batch.rows.count) rows · \(batch.id)"); choice.lastItem?.representedObject = batch.id.uuidString }
                alert.accessoryView = choice
                let response = alert.runModal()
                guard response != .alertSecondButtonReturn, let id = choice.selectedItem?.representedObject as? String, let batch = batches.first(where: {$0.id.uuidString == id}) else { return }
                if response.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 2 {
                    // The explicit retry choice authorizes a new access request, never a new batch ID.
                    try await connector.requestAccess()
                    let progress = self.exportProgressPanel(total:batch.rows.count); defer { progress.panel.orderOut(nil) }
                    let retried = try await connector.export(rows:batch.rows.map(\.title),destinationID:batch.destinationID,batchID:batch.id,retryFailed:true,progress:progress.update)
                    self.showReminderResults(retried)
                } else { self.showReminderResults(batch) }
            } catch { self.showError(error) }
        }
    }
    private func plainClipboardText() -> String? {
        if let string = NSPasteboard.general.string(forType: .string) { return string }
        for (type, format) in [(NSPasteboard.PasteboardType.rtf, NSAttributedString.DocumentType.rtf), (.html, .html)] {
            if let data = NSPasteboard.general.data(forType: type), let rich = try? NSAttributedString(data: data, options: [.documentType: format], documentAttributes: nil) { return rich.string }
        }
        return nil
    }
    private func makeTextView(height: CGFloat) -> (scroll: NSScrollView, editor: NSTextView) {
        let scroll = NSScrollView(frame: NSRect(x:0,y:0,width:650,height:height)); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let editor = NSTextView(frame: scroll.bounds); editor.isRichText = false; editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular); editor.autoresizingMask = [.width]; editor.isVerticallyResizable = true; editor.textContainer?.widthTracksTextView = true
        scroll.documentView = editor; return (scroll, editor)
    }
    private func showError(_ error: Error) { let alert = NSAlert(error: error); alert.runModal() }
}
