// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Darwin

final class AutomationController: NSObject, NSMenuDelegate {
    private let editorProvider: () -> TTEditor?
    private let newDocument: (String) -> Void
    private let storage: URL
    private var library = AutomationLibrary(workflows: [])
    private var loadError: Error?
    private var busy = false
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
        }
    }
    func menu() -> NSMenu { rebuild(); return automationMenu }
    func menuNeedsUpdate(_ menu: NSMenu) { if menu === automationMenu { rebuild() } else { populateInvocations(menu) } }
    /// Fresh menus all dispatch by stable ID and resolve the currently saved definition at invocation.
    func contextMenu() -> NSMenu { invocationMenu(title: "Run Automation") }
    func makeToolbarItem() -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: NSToolbarItem.Identifier("TextTank.Automations"))
        item.label = "Automations"; item.paletteLabel = "Automations"
        item.image = NSImage(systemSymbolName: "bolt", accessibilityDescription: "Run Automation")
        item.menu = invocationMenu(title: "Automations")
        return item
    }
    private func invocationMenu(title: String) -> NSMenu {
        let result = NSMenu(title: title); result.delegate = self
        populateInvocations(result); return result
    }
    private func populateInvocations(_ menu: NSMenu) {
        menu.removeAllItems()
        for workflow in library.workflows {
            let item = NSMenuItem(title: workflow.name, action: #selector(runAction(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = workflow.id.uuidString; menu.addItem(item)
        }
        let manage = NSMenuItem(title: "Manage Automations…", action: #selector(manageAction), keyEquivalent: "")
        manage.target = self; menu.addItem(manage)
    }
    func showPalette() {
        guard !busy else { return }
        guard !library.workflows.isEmpty else { manage(); return }
        let alert = NSAlert(); alert.messageText = "Run Automation"
        alert.informativeText = "Choose a saved automation. Its current definition will run with an editable preview."
        alert.addButton(withTitle: "Run"); alert.addButton(withTitle: "Cancel")
        let choice = NSPopUpButton(frame: NSRect(x:0,y:0,width:400,height:28), pullsDown:false)
        for workflow in library.workflows { let item = NSMenuItem(title: workflow.name, action: nil, keyEquivalent: ""); item.representedObject = workflow.id.uuidString; choice.menu?.addItem(item) }
        alert.accessoryView = choice
        // Preserve editor context before the palette becomes the key window.
        let capturedEditor = editorProvider()
        guard alert.runModal() == .alertFirstButtonReturn, let id = choice.selectedItem?.representedObject as? String, let workflow = library.workflows.first(where: {$0.id.uuidString == id}) else { return }
        busy = true; defer { busy = false }
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
        guard !busy else { return }
        if let loadError { showError(AutomationError.invalid("Saved automations could not be loaded: \(loadError.localizedDescription)\nThe original file is preserved. Export or repair it outside TextTank before replacing it.")); return }
        busy = true; defer { busy = false }
        let alert = NSAlert(); alert.messageText = "Manage Automations"
        alert.informativeText = "Edit the JSON below. Rename by changing name, keeping id unchanged. Input: selection, document, clipboard, file. Output: editor, clipboard, newDocument, file, reminders. Steps: removeListMarkers, removeBlankLines, sortLines, deduplicateLines, replaceLiteral (find/replacement). Optional shortcut: a lowercase letter, bound to Command-Option. Mixed line endings are retained unless a line-reordering step requires a uniform format. No automation runs when saved or imported."
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
        library = proposed; rebuild()
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
        guard let identifier = sender.representedObject as? String, let workflow = library.workflows.first(where: {$0.id.uuidString == identifier}), !busy else { return }
        busy = true; defer { busy = false }
        do { try run(workflow, capturedEditor: editorProvider()) } catch { showError(error) }
    }
    private func run(_ workflow: AutomationDefinition, capturedEditor: TTEditor?) throws {
        // Capture once before showing the preview. Never re-query the frontmost editor on Apply.
        let editor = capturedEditor
        let revision = editor?.revision
        let start = editor?.selectionStart
        let end = editor?.selectionEnd
        if workflow.input == .selection || workflow.output == .editor {
            guard let editor else { throw AutomationError.invalid("This automation requires an open editor document.") }
            guard editor.selectionCount == 1 else { throw AutomationError.invalid("This automation supports a single selection. Multiple or rectangular selections are not changed.") }
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
            let bytes = try Data(contentsOf: url)
            guard let value = String(data: bytes, encoding: .utf8) else { throw AutomationError.invalid("Automation file input requires valid UTF-8. Open the file in the editor with its encoding first.") }
            input = value
        case .clipboard:
            guard let value = plainClipboardText() else { throw AutomationError.invalid("The clipboard does not contain supported text.") }
            input = value
        }
        let transformed = try workflow.transform(input)
        let alert = NSAlert(); alert.messageText = workflow.name
        let scope = workflow.input == .document ? "entire captured document" : "captured selection"
        let destination = workflow.output == .editor ? "Replace \(scope)" : "Output: \(workflow.output.rawValue)"
        alert.informativeText = "Input: \(workflow.input.rawValue). \(destination). Edit the preview below; delete rows you do not want. Apply commits the preview. Cancel makes no changes."
        alert.addButton(withTitle: "Apply"); alert.addButton(withTitle: "Cancel")
        let preview = makeTextView(height: 350); preview.editor.string = transformed; alert.accessoryView = preview.scroll
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let output = preview.editor.string
        switch workflow.output {
        case .editor:
            guard let editor, editor.window != nil, editor.revision == revision else { throw AutomationError.invalid("The original document changed or closed during preview. Run the automation again to review fresh text.") }
            guard editor.selectionCount == 1, editor.selectionStart == start, editor.selectionEnd == end else { throw AutomationError.invalid("The editor selection changed during preview. No text was replaced.") }
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
    private func beginReminderExport(_ text: String, workflow: AutomationDefinition) {
        let rows = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !rows.isEmpty else { showError(AutomationError.invalid("There are no nonblank reminder rows to send.")); return }
        let permission = NSAlert(); permission.messageText = "Choose a Reminders destination"
        permission.informativeText = "TextTank will request Reminders access if needed, then show available lists. No reminder is created until you choose a list and press Send. Each nonblank preview row creates one item; blank rows are excluded. This is an external action; editor Undo cannot remove sent reminders."
        permission.addButton(withTitle: "Request Access and Choose List"); permission.addButton(withTitle: "Cancel")
        guard permission.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor in
            self.busy = true; defer { self.busy = false }
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
                let batch = try await connector.export(rows:rows, destinationID:destinationID, batchID:UUID())
                self.showReminderResults(batch)
            } catch { self.showError(error) }
        }
    }
    @MainActor private func showReminderResults(_ batch: ReminderBatch) {
        let alert = NSAlert(); alert.messageText = "Reminder Export Results"
        alert.informativeText = "Batch \(batch.id). Confirmed items are not resent. Uncertain items require inspection in Reminders and are never automatically retried. Failed items remain available in Export History. Editor Undo does not affect reminders."
        let text = makeTextView(height:300); text.editor.isEditable = false
        text.editor.string = "Destination: \(batch.destinationTitle) — \(batch.destinationSource) [\(batch.destinationID)]\n\n" + batch.rows.map { row in "[\(row.status.rawValue)] \(row.title)\(row.message.map { " — " + $0 } ?? "")" }.joined(separator:"\n")
        alert.accessoryView = text.scroll; alert.addButton(withTitle:"Done"); alert.runModal()
    }
    @objc private func reminderHistory() {
        guard !busy else { return }
        Task { @MainActor in
            self.busy = true; defer { self.busy = false }
            do {
                let connector = RemindersConnector(storageURL:self.storage.deletingLastPathComponent().appendingPathComponent("ReminderExports",isDirectory:true))
                let batches = try connector.storedBatches()
                guard !batches.isEmpty else { throw AutomationError.invalid("There are no recorded reminder exports.") }
                let alert = NSAlert(); alert.messageText = "Reminder Export History"
                alert.informativeText = "Choose a recorded batch to inspect its durable per-item results. Reading this history does not request system access."
                alert.addButton(withTitle:"Review"); alert.addButton(withTitle:"Cancel"); alert.addButton(withTitle:"Request Access and Retry Failed")
                let choice = NSPopUpButton(frame:NSRect(x:0,y:0,width:650,height:28),pullsDown:false)
                for batch in batches { choice.addItem(withTitle:"\(batch.destinationTitle) — \(batch.destinationSource) · \(batch.rows.count) rows · \(batch.id)"); choice.lastItem?.representedObject = batch.id.uuidString }
                alert.accessoryView = choice
                let response = alert.runModal()
                guard response != .alertSecondButtonReturn, let id = choice.selectedItem?.representedObject as? String, let batch = batches.first(where: {$0.id.uuidString == id}) else { return }
                if response.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 2 {
                    // The explicit retry choice authorizes a new access request, never a new batch ID.
                    try await connector.requestAccess()
                    let retried = try await connector.export(rows:batch.rows.map(\.title),destinationID:batch.destinationID,batchID:batch.id,retryFailed:true)
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
