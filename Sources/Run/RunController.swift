// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

final class RunController: NSObject, NSMenuItemValidation {
    var editor: () -> TTEditor? = { nil }
    var file: () -> URL? = { nil }
    /// Called when a configured command is actually started and again before its result is
    /// applied to the document. Neither is ever part of a macro recording.
    var onUnrecordableAction: () -> Void = {}
    private var commands: [ConfiguredRun] = []
    private var loadError: Error?
    private var execution: RunExecution?
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
        let support =
            ProcessInfo.processInfo.environment["TEXTTANK_SUPPORT_DIRECTORY"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TextTank")
        storage = support.appendingPathComponent("RunCommands.json")
        super.init()
        retirementObserver = NotificationCenter.default.addObserver(
            forName: .TTEditorWillRetire, object: nil, queue: nil
        ) { [weak self] note in
            guard let self, let pending = self.pending, let retiring = note.object as? TTEditor,
                pending.editor === retiring
            else { return }
            if !pending.selection, let successor = note.userInfo?[TTEditorSuccessorKey] as? TTEditor {
                // A whole-document result does not depend on which view shows the document.
                self.pending?.editor = successor
            } else {
                // A selection result belongs to the closed view's selection and cannot be applied.
                self.pending = nil
                self.applyButton?.isEnabled = false
            }
        }
        do {
            commands = try ConfiguredRun.decodeLibrary(
                WorkspaceStore.readRegularFile(storage, maximumBytes: ConfiguredRun.maximumLibraryBytes))
        } catch let e as NSError where e.domain == NSPOSIXErrorDomain && e.code == ENOENT {} catch {
            loadError = error
            commands = []
        }
    }
    deinit { if let retirementObserver { NotificationCenter.default.removeObserver(retirementObserver) } }
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
            let item = NSMenuItem(title: command.name, action: #selector(run(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command.id.uuidString
            // The name is free text; the tooltip says what choosing the item executes.
            item.toolTip = command.summary()
            menu.addItem(item)
        }
    }
    func persist(_ updated: [ConfiguredRun]) throws {
        let data = try ConfiguredRun.encodeLibrary(updated)
        try FileManager.default.createDirectory(
            at: storage.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try WorkspaceStore.writePrivate(data, to: storage)
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
        let updated = try JSONDecoder().decode([ConfiguredRun].self, from: json)
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
    @objc private func manage(_ sender: Any?) {
        if let error = loadError {
            NSAlert(error: error).runModal()
            return
        }
        let alert = TTAlert()
        alert.messageText = "Manage Run Commands"
        alert.informativeText = Self.manageHelp
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 650, height: 400))
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds)
        text.isRichText = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.allowsUndo = true
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        text.identifier = NSUserInterfaceItemIdentifier("run.manage.text")
        text.setAccessibilityLabel("Saved Run commands as JSON")
        scroll.documentView = text
        do { text.string = try libraryText() } catch {
            NSAlert(error: error).runModal()
            return
        }
        alert.accessoryView = scroll
        alert.window.initialFirstResponder = text
        while alert.runModal() == .alertFirstButtonReturn {
            do {
                try replaceLibrary(json: Data(text.string.utf8))
                return
            } catch { NSAlert(error: error).runModal() }
        }
    }
    @objc private func addSample(_ sender: Any?) {
        do {
            if let error = loadError { throw error }
            if !commands.contains(where: { $0.extensionMode && $0.executable == "/usr/bin/tr" }) {
                try persist(commands + [.uppercaseSample])
            }
        } catch { NSAlert(error: error).runModal() }
    }
    static let configureHelp =
        "Runs only when explicitly selected. Arguments stay separate; use {file}, {directory}, or {selection} as a complete argument. A selection that begins with - is read by the tool as an option, so put -- or the tool's own pattern flag (for example -e) before {selection} where the tool supports it. The command starts in the saved document's folder, or in your home folder. Shell mode deliberately executes the argument as shell code."
    @objc private func configure(_ sender: Any?) {
        if let error = loadError {
            NSAlert(error: error).runModal()
            return
        }
        let alert = TTAlert()
        alert.messageText = "Configure Run Command"
        alert.informativeText =
            Self.configureHelp
        let name = NSTextField(string: ""), path = NSTextField(string: "/usr/bin/printf"),
            args = NSTextField(string: "[\"%s\\n\",\"{file}\"]")
        let shell = NSButton(checkboxWithTitle: "Intentional shell mode (/bin/zsh -c)", target: nil, action: nil)
        let ext = NSButton(
            checkboxWithTitle: "Version 1 text extension (stdin → preview → explicit Apply)", target: nil, action: nil)
        let stack = NSStackView(views: [
            NSTextField(labelWithString: "Name"), name, NSTextField(labelWithString: "Executable"), path,
            NSTextField(labelWithString: "Arguments as JSON array (or shell script in shell mode)"), args, shell, ext
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 550, height: 250)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save Command")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let shellMode = shell.state == .on
            let argv =
                shellMode
                ? ["-c", args.stringValue] : try JSONDecoder().decode([String].self, from: Data(args.stringValue.utf8))
            let command = ConfiguredRun(
                name: name.stringValue, executable: shellMode ? "/bin/zsh" : path.stringValue, arguments: argv,
                shellMode: shellMode, extensionMode: ext.state == .on)
            try persist(commands + [command])
        } catch { NSAlert(error: error).runModal() }
    }
    @objc private func cancel(_ sender: Any?) { execution?.cancel() }
    /// True while a configured command is running.
    var isRunning: Bool { execution != nil }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // Cancel Running Command is available only while there is something to cancel.
        item.action == #selector(cancel(_:)) ? isRunning : true
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
    @objc private func run(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
            let configured = commands.first(where: { $0.id.uuidString == id })
        else { return }
        do { try start(configured) } catch { NSAlert(error: error).runModal() }
    }
    /// Starts one configured command. Throws, starting nothing, while another is running, when the
    /// configuration cannot be resolved, or when an extension has no writable single selection.
    func start(_ configured: ConfiguredRun) throws {
        guard execution == nil else { throw RunFailure.busy }
        pending = nil
        applyButton?.isEnabled = false
        resultWindow?.close()
        resultWindow = nil
        onUnrecordableAction()
        let target = editor(), selected = (target?.selectionStart != target?.selectionEnd),
            revision = target?.revision ?? 0
        let anchor = target?.selectionAnchor ?? 0, caret = target?.selectionCaret ?? 0
        do {
            if configured.extensionMode {
                guard let target, target.selectionCount == 1 else { throw RunFailure.invalid }
                try target.requireWritable()
            }
            let document = file()
            let command = try configured.resolved(file: document, selection: target?.selectedText ?? "")
            let directory = Self.workingDirectory(for: document)
            let input =
                configured.extensionMode
                ? Data((selected ? (target?.selectedText ?? "") : (target?.text ?? "")).utf8) : Data()
            let run = RunExecution()
            execution = run
            // The editor is main-thread only, so the worker's block holds it weakly: its last
            // reference must not be dropped on the worker, and a run must not keep it alive.
            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak target] in
                let outcome = Result { try run.execute(command, input: input, workingDirectory: directory) }
                DispatchQueue.main.async { [weak target] in
                    self?.execution = nil
                    self?.show(
                        outcome, command: command, target: target, revision: revision, selection: selected,
                        anchor: anchor, caret: caret)
                }
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
        case .failure(let error): NSAlert(error: error).runModal()
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
        do { try applyResult(sender) } catch { NSAlert(error: error).runModal() }
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
            guard let editor = result.editor, editor.window != nil else { throw RunFailure.documentClosed }
            let controller = editor.window?.windowController
            guard controller == nil || controller?.document != nil else { throw RunFailure.documentClosed }
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
