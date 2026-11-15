// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

final class RunController: NSObject {
    var editor: () -> TTEditor? = { nil }, file: () -> URL? = { nil }
    private var commands: [ConfiguredRun] = [], loadError: Error?, execution: RunExecution?
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
    let storage: URL
    override init() {
        let support =
            ProcessInfo.processInfo.environment["TEXTTANK_SUPPORT_DIRECTORY"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TextTank")
        storage = support.appendingPathComponent("RunCommands.json")
        super.init()
        do {
            commands = try ConfiguredRun.decodeLibrary(
                WorkspaceStore.readRegularFile(storage, maximumBytes: ConfiguredRun.maximumLibraryBytes))
        } catch let e as NSError where e.domain == NSPOSIXErrorDomain && e.code == ENOENT {} catch {
            loadError = error
            commands = []
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
        try persist(try JSONDecoder().decode([ConfiguredRun].self, from: json))
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
        guard execution == nil, let id = sender.representedObject as? String,
            let configured = commands.first(where: { $0.id.uuidString == id })
        else { return }
        pending = nil
        applyButton?.isEnabled = false
        resultWindow?.close()
        resultWindow = nil
        let target = editor(), selected = (target?.selectionStart != target?.selectionEnd),
            revision = target?.revision ?? 0
        let anchor = target?.selectionAnchor ?? 0, caret = target?.selectionCaret ?? 0
        do {
            if configured.extensionMode && (target == nil || target?.selectionCount != 1 || target?.readOnly == true) {
                throw RunFailure.invalid
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
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 450), styleMask: [.titled, .closable, .resizable],
                backing: .buffered, defer: false)
            window.title = command.name
            window.isReleasedWhenClosed = false
            window.contentView = stack
            resultWindow = window
            window.makeKeyAndOrderFront(nil)
        }
    }
    @objc func apply(_ sender: NSButton) {
        guard sender === applyButton else { return }
        guard let result = pending, let target = result.editor, target.window != nil,
            target.revision == result.revision, !target.readOnly, target.selectionCount == 1,
            (!result.selection
                || (target.selectionAnchor == result.anchor && target.selectionCaret == result.caret))
        else {
            pending = nil
            sender.isEnabled = false
            NSSound.beep()
            return
        }
        target.beginUndoGroup()
        defer { target.endUndoGroup() }
        if result.selection { target.replaceSelection(result.output) } else { target.text = result.output }
        pending = nil
        sender.isEnabled = false
    }
}
