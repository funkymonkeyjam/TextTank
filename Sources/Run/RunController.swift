import TextTankCore
import EditorBridge
import NativeSearch
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

@MainActor final class RunController: NSObject, NSMenuItemValidation {
    var editor: () -> TTEditor? = { nil }
    var file: () -> URL? = { nil }
    /// Called when a configured command is actually started and again before its result is
    /// applied to the document. Neither is ever part of a macro recording.
    var onUnrecordableAction: () -> Void = {}
    var confirmFirstRun: @MainActor (_ invocation: ConfiguredRun, _ directory: URL) -> Bool = RunController
        .askBeforeRunning
    private var askingBeforeRun = false
    private var commands: [ConfiguredRun] = []
    let loadState: StoreLoadState
    private var loadError: Error? {
        get { loadState.error }
        set { loadState.error = newValue }
    }
    private var execution: RunExecution? { didSet { manager?.refresh() } }
    private let menu = NSMenu(title: "Run")
    private var resultWindow: NSWindow?
    private weak var applyButton: NSButton?
    /// The result that Apply would insert. The editor is weak: a result window must not keep a
    /// closed document's editor alive, and a worker thread must never hold its last reference.
    private struct Pending {
        weak var editor: TTEditor?
        let revision: UInt, output: String, selection: Bool, anchor: Int, caret: Int
    }
    private var pending: Pending?
    private var retirementObserver: NSObjectProtocol?
    let storage: URL
    override init() {
        storage = AppStorage.url(.commands)
        loadState = StoreLoadState(url: storage, displayName: "Run commands")
        super.init()
        retirementObserver = NotificationCenter.default.addObserver(
            forName: .TTEditorWillRetire, object: nil, queue: nil
        ) { [weak self] note in
            // TTEditor posts retirement synchronously from its main-thread-only route.
            precondition(Thread.isMainThread)
            let retiring = note.object as? TTEditor
            let successor = note.userInfo?[TTEditorSuccessorKey] as? TTEditor
            MainActor.assumeIsolated {
                guard let self, let pending = self.pending, let retiring,
                    pending.editor === retiring
                else { return }
                if !pending.selection, let successor {
                    // A whole-document result does not depend on which view shows the document.
                    self.pending?.editor = successor
                } else {
                    // A selection result belongs to the closed view's selection and cannot be applied.
                    self.pending = nil
                    self.applyButton?.isEnabled = false
                }
            }
        }
        do {
            commands = try ConfiguredRun.decodeLibrary(
                WorkspaceStore.readRegularFile(storage, maximumBytes: ConfiguredRun.maximumLibraryBytes))
        } catch  where error.isFileNotFound {} catch {
            loadError = error
            commands = []
        }
    }
    deinit {
        precondition(Thread.isMainThread)
        MainActor.assumeIsolated {
            if let retirementObserver { NotificationCenter.default.removeObserver(retirementObserver) }
        }
    }
    func makeMenu() -> NSMenu {
        rebuild()
        return menu
    }
    private func rebuild() {
        menu.removeAllItems()
        for (title, action) in [
            ("Configure Command…", #selector(configure(_:))), ("Manage Commands…", #selector(manage(_:))),
            ("Add Sample Text Extension", #selector(addSample(_:))), ("Cancel Running Command", #selector(cancel(_:)))
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for command in commands {
            let item = NSMenuItem(title: command.menuTitle, action: #selector(run(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command.id.uuidString
            // The name is free text; the tooltip says what choosing the item executes.
            item.toolTip = command.summary()
            menu.addItem(item)
        }
    }
    func persist(_ updated: [ConfiguredRun]) throws {
        try loadState.requireWritable()
        let data = try ConfiguredRun.encodeLibrary(updated)
        try PrivateFileStore.prepareDirectory(storage.deletingLastPathComponent())
        try PrivateFileStore.write(
            data, to: storage, maximumBytes: ConfiguredRun.maximumLibraryBytes, temporaryPrefix: ".commands-")
        commands = updated
        loadError = nil
        rebuild()
    }
    /// The saved commands as the text Manage Commands shows: the version-1 library, indented.
    func libraryText() throws -> String {
        try ConfiguredRun.validateLibrary(commands)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(commands), as: UTF8.self)
    }
    /// Replaces the saved commands with an edited library. Refuses while the file on disk could
    /// not be read, so unreadable bytes are never overwritten. Nothing is executed.
    func replaceLibrary(json: Data) throws {
        if let loadError { throw loadError }
        // Indentation is not counted against the 1 MiB limit; persist applies that limit to the
        // compact form that is stored. This bound only keeps the decoder's input finite.
        guard json.count <= 4 * ConfiguredRun.maximumLibraryBytes else { throw RunFailure.configurationTooLarge }
        let updated = try JSONInputFailure.decode([ConfiguredRun].self, from: json, context: "Run commands")
        // Compare stable encoded models, not Swift String equality: canonically equivalent
        // Unicode strings can carry distinct command bytes (V32-02). Both encodes keep every
        // existing validation and byte ceiling; default persistence formatting is unchanged.
        let updatedBytes = try ConfiguredRun.encodeLibrary(updated, sortedKeys: true)
        let currentBytes = try ConfiguredRun.encodeLibrary(commands, sortedKeys: true)
        guard updatedBytes != currentBytes else { return }
        try persist(updated)
    }
    static let manageHelp =
        "Each entry is one saved command: name, executable (an absolute path), arguments, shellMode and extensionMode. Edit an entry to change it, or remove an entry to delete it. Keep id to keep a command's identity. Saving never runs a command."
    private var manager: LibraryManager?
    @objc private func manage(_ sender: Any?) {
        if let manager {
            manager.form.window.makeKeyAndOrderFront(nil)
            return
        }
        do {
            guard try StoreRecovery.ensureWritable(loadState) else { return }
            var working = commands
            let baseline = try SavedConfiguration.bytes(commands)
            let panel = LibraryManager(title: "Run Commands", identifier: "run.manager") {
                (try? SavedConfiguration.bytes(working)) != baseline
            }
            manager = panel
            panel.retainController(self)
            panel.onClose = { [weak self] in self?.manager = nil }
            panel.rows = { working.map { .init(id: $0.id, name: $0.name) } }
            panel.canEdit = { [weak self] in self.map { !$0.isRunning } ?? false }
            panel.rename = { id, name in
                if let i = working.firstIndex(where: { $0.id == id }) { working[i].name = name }
            }
            panel.save = { [weak self, weak panel] in
                guard let self, !self.isRunning else { throw FormFailure.busy }
                for command in working {
                    do { try command.validate() } catch {
                        panel?.reveal(command.id)
                        throw error
                    }
                }
                try ConfiguredRun.validateLibrary(working)
                try SavedConfiguration.requireUnchanged(self.commands, since: baseline)
                guard try StoreRecovery.ensureWritable(self.loadState) else { return false }
                try SavedConfiguration.requireUnchanged(self.commands, since: baseline)
                // The existing byte-exact no-op path preserves file identity and Unicode bytes.
                let encoder = JSONEncoder()
                try self.replaceLibrary(json: encoder.encode(working))
                return true
            }
            panel.add = { [weak self, weak panel] in
                guard let self, let panel else { return }
                self.editCommand(nil, parent: panel.form.window) { command in
                    working.append(command)
                    panel.reload(select: command.id)
                }
            }
            panel.action("Add…", identifier: "run.manager.add") { [weak panel] in panel?.beginAdd() }
            panel.action("Edit…", identifier: "run.manager.edit", needsSelection: true) { [weak self, weak panel] in
                guard let self, let panel, let id = panel.selectedID,
                    let command = working.first(where: { $0.id == id })
                else { return }
                self.editCommand(command, parent: panel.form.window) { updated in
                    if let i = working.firstIndex(where: { $0.id == id }) { working[i] = updated }
                    panel.reload(select: id)
                }
            }
            panel.action("Duplicate", identifier: "run.manager.duplicate", needsSelection: true) { [weak panel] in
                guard let panel, let id = panel.selectedID, var command = working.first(where: { $0.id == id }) else {
                    return
                }
                command.id = UUID()
                working.append(command)
                panel.reload(select: command.id)
            }
            panel.action("Delete…", identifier: "run.manager.delete", needsSelection: true) { [weak panel] in
                panel?.confirmDelete { id in working.removeAll { $0.id == id } }
            }
            panel.secondaryAction("Advanced JSON…", identifier: "run.manager.advanced") { [weak panel] in
                guard let panel, panel.canEdit() else { return }
                let form = FormPanel(
                    title: "Advanced Run Command Configuration", identifier: "run.json",
                    size: NSSize(width: 700, height: 530))
                form.note(Self.manageHelp)
                let text = JSONLibraryEditor.makeTextView(size: NSSize(width: 640, height: 330))
                ControlPresentation.label("Saved Run commands as JSON", control: text.editor)
                text.editor.identifier = NSUserInterfaceItemIdentifier("run.manage.text")
                do {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                    text.editor.string = String(decoding: try encoder.encode(working), as: UTF8.self)
                } catch {
                    panel.form.showValidation(error)
                    return
                }
                form.add(text.scroll)
                text.scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
                form.button("Use Changes", identifier: "run.json.save") {
                    guard form.commitEditing() else { return }
                    do {
                        let data = Data(text.editor.string.utf8)
                        guard data.count <= 4 * ConfiguredRun.maximumLibraryBytes else {
                            throw RunFailure.configurationTooLarge
                        }
                        let updated = try JSONInputFailure.decode(
                            [ConfiguredRun].self, from: data, context: "Run commands")
                        _ = try ConfiguredRun.encodeLibrary(updated)
                        working = updated
                        form.close()
                        panel.reload()
                    } catch { form.showValidation(error, field: text.editor) }
                }
                form.button("Cancel", identifier: "run.json.cancel", cancel: true) { form.close() }
                form.show(parent: panel.form.window)
                panel.refresh()
            }
            panel.show()
        } catch { TTAlert.present(error) }
    }
    @objc private func addSample(_ sender: Any?) {
        do {
            if let error = loadError { throw error }
            if !commands.contains(where: { $0.extensionMode && $0.executable == "/usr/bin/tr" }) {
                try persist(commands + [.uppercaseSample])
            }
        } catch { TTAlert.present(error) }
    }
    static let configureHelp =
        "Runs only when explicitly selected. Arguments stay separate; use {file}, {directory}, or {selection} as a complete argument. A selection that begins with - is read by the tool as an option, so put -- or the tool's own pattern flag (for example -e) before {selection} where the tool supports it. The command starts in the saved document's folder, or in your home folder. Shell mode deliberately executes the argument as shell code."
    @objc private func configure(_ sender: Any?) {
        manage(sender)
        manager?.beginAdd()
        manager?.refresh()
    }
    private func editCommand(_ initial: ConfiguredRun?, parent: NSWindow, accept: @escaping (ConfiguredRun) -> Void) {
        let form = FormPanel(
            title: initial == nil ? "New Run Command" : "Edit Run Command", identifier: "run.command",
            size: NSSize(width: 720, height: 520))
        form.window.contentMinSize = NSSize(width: 680, height: 440)
        form.note(Self.configureHelp)
        form.note(
            "Use Changes returns to the manager. The command runs only when you explicitly invoke its saved definition."
        )
        let name = form.field("Name", value: initial?.name ?? "", identifier: "run.command.name")
        let path = form.field(
            "Executable", value: initial?.executable ?? "/usr/bin/printf", identifier: "run.command.executable")
        let argumentText: String
        if let initial {
            argumentText =
                initial.shellMode
                ? initial.arguments[1]
                : String(decoding: (try? JSONEncoder().encode(initial.arguments)) ?? Data(), as: UTF8.self)
        } else {
            argumentText = "[\"%s\\n\",\"{file}\"]"
        }
        let args = form.field("Arguments", value: argumentText, identifier: "run.command.arguments")
        let shell = NSButton(checkboxWithTitle: "Intentional shell mode (/bin/zsh -c)", target: nil, action: nil)
        shell.identifier = NSUserInterfaceItemIdentifier("run.command.shell")
        shell.state = initial?.shellMode == true ? .on : .off
        shell.setAccessibilityLabel("Intentional shell mode for this Run command")
        shell.cell?.setAccessibilityLabel("Intentional shell mode for this Run command")
        let ext = NSButton(
            checkboxWithTitle: "Text extension (input → preview → explicit Apply)", target: nil, action: nil)
        ext.identifier = NSUserInterfaceItemIdentifier("run.command.extension")
        ext.state = initial?.extensionMode == true ? .on : .off
        ext.setAccessibilityLabel("Text extension mode for this Run command")
        ext.cell?.setAccessibilityLabel("Text extension mode for this Run command")
        form.add(shell)
        form.add(ext)
        let id = initial?.id ?? UUID()
        form.button("Use Changes", identifier: "run.command.save") {
            guard form.commitEditing() else { return }
            do {
                let shellMode = shell.state == .on
                let argv =
                    shellMode
                    ? ["-c", args.stringValue]
                    : try JSONInputFailure.decode(
                        [String].self, from: Data(args.stringValue.utf8), context: "Arguments")
                var command = ConfiguredRun(
                    name: name.stringValue, executable: shellMode ? "/bin/zsh" : path.stringValue, arguments: argv,
                    shellMode: shellMode, extensionMode: ext.state == .on)
                command.id = id
                try command.validate()
                accept(command)
                form.close()
            } catch {
                let field: NSView
                if case RunFailure.configuration(let invalid, _) = error {
                    switch invalid {
                    case .name: field = name
                    case .executable: field = path
                    case .arguments, .argument: field = args
                    case .mode, .shell: field = ext
                    default: field = name
                    }
                } else {
                    field = args
                }
                form.showValidation(error, field: field)
            }
        }
        form.button("Cancel", identifier: "run.command.cancel", cancel: true) { form.close() }
        form.window.initialFirstResponder = name
        form.show(parent: parent)
    }
    @objc private func cancel(_ sender: Any?) { execution?.cancel() }
    /// True while a configured command is running.
    var isRunning: Bool { execution != nil }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // Cancel Running Command is available only while there is something to cancel.
        if item.action == #selector(cancel(_:)) { return isRunning }
        if item.action == #selector(configure(_:)) { return !isRunning }
        return true
    }
    /// For quitting: stops a running command and waits, on the worker's own signal, until its
    /// process group is gone. It does not depend on the main queue, so it may block the main thread.
    func cancelAndWait(timeout: TimeInterval) -> Bool { execution?.cancelAndWait(timeout: timeout) ?? true }
    /// Where a command starts: the saved document's folder, or the home folder when the document
    /// is unsaved or its folder is no longer there (a missing folder would fail the launch).
    static func workingDirectory(for file: URL?) -> URL {
        if let directory = file?.deletingLastPathComponent() {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue
            {
                return directory
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
    private static func askBeforeRunning(_ command: ConfiguredRun, directory: URL) -> Bool {
        let alert = TTAlert()
        alert.messageText = "Run “" + command.name + "”?"
        alert.informativeText =
            command.shellMode
            ? "Shell mode runs the script argument through /bin/zsh. Confirm only if you intend to run the full script shown below."
            : "Review the executable, arguments and working directory. TextTank will remember this command after it runs."
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        struct Invocation: Encodable { let argv: [String], workingDirectory: String, mode: String }
        let value = Invocation(
            argv: [command.executable] + command.arguments, workingDirectory: directory.path,
            mode: command.shellMode ? "Shell" : command.extensionMode ? "Text extension" : "Executable")
        guard let bytes = try? encoder.encode(value) else { return false }
        let text = NSTextView()
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.string = String(decoding: bytes, as: UTF8.self)
        text.setAccessibilityLabel("Full command and working directory")
        text.identifier = .init("run.approval.invocation")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 180))
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        text.frame = scroll.contentView.bounds
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        alert.accessoryView = scroll
        let run = alert.addButton(withTitle: "Run Command")
        run.identifier = .init("run.approval.confirm")
        run.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel", role: .cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
            let configured = commands.first(where: { $0.id.uuidString == id })
        else { return }
        do { try start(configured) } catch { TTAlert.present(error) }
    }
    /// Starts one configured command. Throws, starting nothing, while another is running, when the
    /// configuration cannot be resolved, or when an extension has no writable single selection.
    func start(_ configured: ConfiguredRun) throws {
        guard execution == nil, !askingBeforeRun else { throw RunFailure.busy }
        let target = editor(), selected = (target?.selectionStart != target?.selectionEnd),
            revision = target?.revision ?? 0
        let anchor = target?.selectionAnchor ?? 0, caret = target?.selectionCaret ?? 0
        do {
            if configured.extensionMode {
                guard let target else { throw RunFailure.noDocument }
                try target.requireWritable()
                guard target.selectionCount == 1 else { throw RunFailure.multipleSelections }
            }
            let document = file()
            let command = try configured.resolved(file: document, selection: target?.selectedText ?? "")
            let directory = Self.workingDirectory(for: document)
            let approvalFolder = storage.deletingLastPathComponent().appendingPathComponent(
                "RunApprovals", isDirectory: true)
            let approvalFile = approvalFolder.appendingPathComponent(configured.id.uuidString + ".sha256")
            let digest = try configured.approvalDigest()
            // An unavailable approval record never authorizes a command. Explicit review still works.
            let known = (try? PrivateFileStore.read(approvalFile, maximumBytes: 32)) == digest
            if !known {
                let fromLibrary = commands.contains { $0.id == configured.id }
                askingBeforeRun = true
                let approved = confirmFirstRun(command, directory)
                askingBeforeRun = false
                guard approved else { return }
                let current = commands.first { $0.id == configured.id }
                guard try !fromLibrary || current?.approvalDigest() == digest else {
                    throw RunFailure.configuration(
                        field: .identity,
                        message: "The saved command changed while it was being reviewed. Choose it again.")
                }
                guard file() == document, editor() === target, target?.revision ?? 0 == revision,
                    target?.selectionAnchor ?? 0 == anchor, target?.selectionCaret ?? 0 == caret
                else { throw RunFailure.documentChanged }
            }
            let input =
                configured.extensionMode
                ? Data((selected ? (target?.selectedText ?? "") : (target?.text ?? "")).utf8) : Data()
            pending = nil
            applyButton?.isEnabled = false
            resultWindow?.close()
            resultWindow = nil
            let run = RunExecution()
            execution = run
            onUnrecordableAction()
            // Capture weak UI references on main; the worker holds only this delivery
            // and immutable command/input values, never strengthening an editor/controller.
            let deliver: @MainActor @Sendable (Result<RunResult, Error>) -> Void = { [weak self, weak target] outcome in
                self?.execution = nil
                var approvalError: Error?
                if !known, case .success(let result) = outcome, result.didLaunch {
                    do {
                        try PrivateFileStore.prepareDirectory(approvalFolder)
                        try PrivateFileStore.write(digest, to: approvalFile, maximumBytes: 32)
                    } catch { approvalError = error }
                }
                self?.show(
                    outcome, command: command, target: target, revision: revision, selection: selected,
                    anchor: anchor, caret: caret)
                if let approvalError { TTAlert.present(approvalError) }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = Result { try run.execute(command, input: input, workingDirectory: directory) }
                DispatchQueue.main.async { deliver(outcome) }
            }
        }
    }
    func show(
        _ outcome: Result<RunResult, Error>, command: ConfiguredRun, target: TTEditor?, revision: UInt, selection: Bool,
        anchor: Int, caret: Int
    ) {
        pending = nil
        applyButton?.isEnabled = false
        resultWindow?.close()
        resultWindow = nil
        switch outcome {
        case .failure(let error): TTAlert.present(error)
        case .success(let result):
            let decoded = String(decoding: result.stdout, as: UTF8.self)
            let output: String? = decoded.utf8.elementsEqual(result.stdout) ? decoded : nil
            let status = result.statusLine
            let view = NSTextView()
            view.isEditable = false
            view.isRichText = false
            view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            view.string =
                status + "\n\n" + (output ?? "Output is not valid UTF-8") + "\n\nStandard error:\n"
                + String(decoding: result.stderr, as: UTF8.self)
            let scroll = NSScrollView()
            scroll.documentView = view
            scroll.hasVerticalScroller = true
            view.autoresizingMask = [.width]
            view.isVerticallyResizable = true
            let button = NSButton(title: "Apply Extension Result", target: self, action: #selector(apply(_:)))
            button.identifier = NSUserInterfaceItemIdentifier("run.apply")
            applyButton = button
            pending = nil
            if command.extensionMode, result.status == 0, result.reason == .finished, let target, let output {
                pending = Pending(
                    editor: target, revision: revision, output: output, selection: selection, anchor: anchor,
                    caret: caret)
            }
            button.isEnabled = pending != nil
            let stack = NSStackView(views: [scroll, button])
            stack.orientation = .vertical
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
            // A panel, so the document window stays main while the result is key, and one that
            // stays on screen when the application is deactivated. Escape closes it, except
            // while it holds a result that has not been applied: that would discard the result.
            // Apply is deliberately not the default button. This window takes the keyboard when
            // the command finishes, and a Return typed for the editor must not change the document.
            let window = ToolPanel(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 450), styleMask: [.titled, .closable, .resizable])
            window.allowsEscapeToClose = { [weak self] in self?.pending == nil }
            window.listedInWindowMenu = true
            window.title = command.name
            window.isReleasedWhenClosed = false
            window.contentView = stack
            window.initialFirstResponder = view
            WindowFrames.track(window, as: "TextTank.RunResult")
            resultWindow = window
            window.makeKeyAndOrderFront(nil)
        }
    }
    @objc func apply(_ sender: NSButton) {
        do { try applyResult(sender) } catch { TTAlert.present(error) }
    }
    /// Applies the pending extension result. A result that can no longer be applied is dropped and
    /// the reason is thrown; a click on the button of a replaced preview does nothing.
    func applyResult(_ sender: NSButton) throws {
        guard sender === applyButton, let result = pending else { return }
        let target: TTEditor
        do {
            // The editor is held weakly, and one that is gone belonged to a closed document. A
            // closed document is also marked read-only and may still sit in its closed window,
            // so closure is recognised first and reported as what it is.
            guard let editor = result.editor, EditorLifetime.isOpen(editor) else { throw RunFailure.documentClosed }
            try editor.requireWritable()
            guard editor.revision == result.revision, editor.selectionCount == 1,
                !result.selection
                    || (editor.selectionAnchor == result.anchor && editor.selectionCaret == result.caret)
            else { throw RunFailure.documentChanged }
            target = editor
        } catch {
            pending = nil
            sender.isEnabled = false
            throw error
        }
        onUnrecordableAction()
        target.beginUndoGroup()
        defer { target.endUndoGroup() }
        if result.selection { target.replaceSelection(result.output) } else { target.text = result.output }
        pending = nil
        sender.isEnabled = false
    }
}
