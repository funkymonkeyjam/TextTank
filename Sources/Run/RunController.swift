// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

final class RunController: NSObject, NSMenuItemValidation {
    var editor: () -> TTEditor? = { nil }, file: () -> URL? = { nil }
    /// Called when a configured command is actually started and again before its result is
    /// applied to the document. Neither is ever part of a macro recording.
    var onUnrecordableAction: () -> Void = {}
    private var commands: [ConfiguredRun] = [], loadError: Error?, execution: RunExecution?
    private let menu = NSMenu(title: "Run")
    private var resultWindow: NSWindow?
    private weak var applyButton: NSButton?
    private var pending: (TTEditor, UInt, String, Bool, Int, Int)?
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
            guard let self, let pending = self.pending, pending.0 === note.object as? TTEditor else { return }
            if !pending.3, let successor = note.userInfo?[TTEditorSuccessorKey] as? TTEditor {
                // A whole-document result does not depend on which view shows the document.
                self.pending?.0 = successor
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
            ("Configure Command…", #selector(configure(_:))), ("Add Sample Text Extension", #selector(addSample(_:))),
            ("Cancel Running Command", #selector(cancel(_:)))
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
    @objc private func addSample(_ sender: Any?) {
        do {
            if let error = loadError { throw error }
            if !commands.contains(where: { $0.extensionMode && $0.executable == "/usr/bin/tr" }) {
                try persist(commands + [.uppercaseSample])
            }
        } catch { NSAlert(error: error).runModal() }
    }
    @objc private func configure(_ sender: Any?) {
        if let error = loadError {
            NSAlert(error: error).runModal()
            return
        }
        let alert = TTAlert()
        alert.messageText = "Configure Run Command"
        alert.informativeText =
            "Runs only when explicitly selected. Arguments stay separate; use {file}, {directory}, or {selection} as a complete argument. Shell mode deliberately executes the argument as shell code."
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
    @objc private func run(_ sender: NSMenuItem) {
        guard execution == nil, let id = sender.representedObject as? String,
            let configured = commands.first(where: { $0.id.uuidString == id })
        else { return }
        pending = nil
        applyButton?.isEnabled = false
        resultWindow?.close()
        resultWindow = nil
        onUnrecordableAction()
        let target = editor(), selected = (target?.selectionStart != target?.selectionEnd),
            revision = target?.revision ?? 0
        let anchor = target?.selectionAnchor ?? 0, caret = target?.selectionCaret ?? 0
        do {
            if configured.extensionMode && (target == nil || target?.selectionCount != 1 || target?.readOnly == true) {
                throw RunFailure.invalid
            }
            let command = try configured.resolved(file: file(), selection: target?.selectedText ?? "")
            let input =
                configured.extensionMode
                ? Data((selected ? (target?.selectedText ?? "") : (target?.text ?? "")).utf8) : Data()
            let run = RunExecution()
            execution = run
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let outcome = Result { try run.execute(command, input: input) }
                DispatchQueue.main.async {
                    self?.execution = nil
                    self?.show(
                        outcome, command: command, target: target, revision: revision, selection: selected,
                        anchor: anchor, caret: caret)
                }
            }
        } catch { NSAlert(error: error).runModal() }
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
            let status =
                "Exit \(result.status) · \(result.cancelled ? "cancelled/timed out":"finished")\(result.truncated ? " · output truncated":"")"
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
            if command.extensionMode, result.status == 0, !result.cancelled, !result.truncated, let target, let output {
                pending = (target, revision, output, selection, anchor, caret)
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
        guard sender === applyButton else { return }
        guard let (target, revision, output, selection, anchor, caret) = pending, target.window != nil,
            target.revision == revision, !target.readOnly, target.selectionCount == 1,
            (!selection || (target.selectionAnchor == anchor && target.selectionCaret == caret))
        else {
            pending = nil
            sender.isEnabled = false
            NSSound.beep()
            return
        }
        onUnrecordableAction()
        target.beginUndoGroup()
        defer { target.endUndoGroup() }
        if selection { target.replaceSelection(output) } else { target.text = output }
        pending = nil
        sender.isEnabled = false
    }
}
