// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Darwin

final class MacroController: NSObject, NSMenuDelegate {
    private let editorProvider: () -> TTEditor?
    private var library = MacroLibrary(macros: [])
    private let storage: URL
    let loadState: StoreLoadState
    private(set) var loadingError: Error? {
        get { loadState.error }
        set { loadState.error = newValue }
    }
    private var recordingEditor: TTEditor? {
        didSet {
            manager?.refresh()
            namePanel?.setActionEnabled("macro.save.confirm", recordingEditor == nil)
        }
    }
    private var recorded: [RecordedMacro.Step] = []
    private var lastRecording: RecordedMacro?
    private var captureError: Error?
    private var playing = false { didSet { manager?.refresh() } }
    private var playbackCancelled = false
    /// Called once, at the moment a recording becomes unsaveable, with the reason (F67).
    var onInvalidated: ((String) -> Void)?
    /// Why the recording in progress can no longer be saved; nil while it is still good.
    var discardReason: String? { recordingEditor == nil ? nil : captureError?.localizedDescription }
    var searchPlayback: ((RecordedMacro.Search, TTEditor) throws -> Void)?
    private lazy var macroMenu = NSMenu(title: "Macros")
    init(editorProvider: @escaping () -> TTEditor?) {
        self.editorProvider = editorProvider
        storage = AppStorage.url(.macros)
        loadState = StoreLoadState(url: storage, displayName: "Saved macros")
        super.init()
        macroMenu.delegate = self
        do {
            library = try MacroLibrary.decode(PrivateFileStore.read(storage, maximumBytes: MacroLibrary.maximumBytes))
        } catch  where error.isFileNotFound {} catch { loadingError = error }
    }
    func menu() -> NSMenu {
        rebuild()
        return macroMenu
    }
    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }
    /// No item in this menu has a key equivalent, so a key press never needs it brought up to date.
    func menuHasKeyEquivalent(
        _ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
        action: UnsafeMutablePointer<Selector?>
    ) -> Bool { false }
    private func rebuild() {
        macroMenu.removeAllItems()
        macroMenu.autoenablesItems = false
        macroMenu.addItem(
            title: "Start Recording", action: #selector(startRecording), target: self,
            isEnabled: recordingEditor == nil && !playing)
        macroMenu.addItem(
            title: discardReason == nil ? "Stop Recording" : "Stop Recording (Already Discarded)",
            action: #selector(stopRecording), target: self, isEnabled: recordingEditor != nil)
        macroMenu.addItem(
            title: "Play Last Recording…", action: #selector(playLast), target: self,
            isEnabled: lastRecording != nil && recordingEditor == nil && !playing)
        macroMenu.addItem(
            title: "Save Last Recording…", action: #selector(saveLast), target: self,
            isEnabled: lastRecording != nil && recordingEditor == nil)
        macroMenu.addItem(
            title: "Manage Saved Macros…", action: #selector(manage), target: self,
            isEnabled: recordingEditor == nil && !playing)
        if !library.macros.isEmpty { macroMenu.addItem(.separator()) }
        for macro in library.macros {
            macroMenu.addItem(
                title: macro.name, action: #selector(playSaved(_:)), target: self,
                representedObject: macro.id.uuidString, isEnabled: recordingEditor == nil && !playing)
        }
    }
    @objc func startRecording() {
        guard recordingEditor == nil, !playing, let editor = editorProvider() else { return }
        recordingEditor = editor
        recorded = []
        captureError = nil
        // The previous recording stays playable and saveable until a new one finishes (F67).
        editor.onMacroStep = { [weak self, weak editor] raw in
            guard let self, let editor, self.recordingEditor === editor, !self.playing else { return }
            do {
                let step: RecordedMacro.Step
                switch raw.kind {
                case .unsupported:
                    let name = raw.name ?? "An editing action (Scintilla message \(raw.message))"
                    throw MacroError.invalid("\(name) is not recordable yet. No partial macro will be saved.")
                case .insertText:
                    guard let text = raw.text else {
                        throw MacroError.invalid("Text macro step has invalid parameters.")
                    }
                    step = .insertText(text)
                case .command:
                    guard let command = raw.command else {
                        throw MacroError.invalid("Unrecognized or unsafe macro command.")
                    }
                    step = .command(command.rawValue)
                @unknown default: throw MacroError.invalid("Unrecognized captured editing action.")
                }
                try step.validate()
                guard self.recorded.count < MacroLimits.recordedActions else {
                    throw MacroError.invalid(
                        "Recording exceeded \(Strings.number(MacroLimits.recordedActions)) actions.")
                }
                self.recorded.append(step)
            } catch {
                self.discard(error, editor: editor)
            }
        }
        editor.startRecording()
        rebuild()
    }
    /// Invalidated recordings remain stoppable, but can never become a saved partial macro.
    func invalidateRecording(reason: String) {
        guard let editor = recordingEditor, !playing else { return }
        discard(MacroError.invalid(reason), editor: editor)
    }
    /// The first reason wins and is reported at once; capture stops so nothing more is collected.
    private func discard(_ error: Error, editor: TTEditor) {
        guard captureError == nil else { return }
        captureError = error
        // Stopping settles a pending margin click, which can report again; the guard above ends that.
        editor.stopRecording()
        editor.onMacroStep = nil
        rebuild()
        onInvalidated?(error.localizedDescription)
    }
    /// An application-layer caret jump (Go to Line, Clear Selection, a function-list or result
    /// row) has no recordable step. The recording is discarded at the point of mutation, and only
    /// when the jump changed the selection or the text: a cancelled dialog or a jump to where the
    /// caret already is leaves a valid recording alone (F277).
    @discardableResult func unrecordedJump(in editor: TTEditor, reason: String, _ jump: () -> Bool) -> Bool {
        guard recordingEditor != nil, !playing else { return jump() }
        let before = (editor.revision, editor.selectionCount, editor.selectionAnchor, editor.selectionCaret)
        let moved = jump()
        if before != (editor.revision, editor.selectionCount, editor.selectionAnchor, editor.selectionCaret) {
            invalidateRecording(reason: reason)
        }
        return moved
    }
    func editorDidFocus(_ editor: TTEditor) {
        if let recordingEditor, recordingEditor !== editor {
            invalidateRecording(
                reason: "The active editor changed during recording. Recording across views is not supported.")
        }
    }
    /// `editor` is any view of the document being reloaded or closed. The recording may have been
    /// started in another view of that document, so this compares documents, unlike the focus
    /// rule in editorDidFocus, which is deliberately per view.
    func editorWillReset(_ editor: TTEditor, reason: String) {
        if let recordingEditor, recordingEditor.sharesDocument(with: editor) { invalidateRecording(reason: reason) }
    }
    func willExecuteCommand(_ command: String, on editor: TTEditor) {
        guard recordingEditor != nil else { return }
        editorDidFocus(editor)
        let viewOnly = EditorCommand.viewOnlyIdentifiers
        if !RecordedMacro.Step.commands.contains(command) && !viewOnly.contains(command) {
            let title = EditorCommand(rawValue: command)?.title ?? "Unavailable command"
            invalidateRecording(
                reason: "The command ‘\(title)’ is not recordable yet. No partial macro will be saved.")
        }
    }
    /// Testable finish path used by the Stop menu. Invalidations are errors, never partial success.
    func finishRecording() throws -> RecordedMacro? {
        guard let editor = recordingEditor else { return nil }
        editor.stopRecording()
        editor.onMacroStep = nil
        recordingEditor = nil
        defer { rebuild() }
        if let captureError {
            throw MacroError.invalid("Recording was discarded: \(captureError.localizedDescription)")
        }
        guard !recorded.isEmpty else { throw MacroError.invalid("No supported editing actions were recorded.") }
        let macro = RecordedMacro(id: UUID(), name: "Recorded Macro", steps: recorded)
        lastRecording = macro
        return macro
    }
    @objc func stopRecording() {
        do { _ = try finishRecording() } catch { TTAlert.present(error) }
    }
    func recordSearch(_ search: RecordedMacro.Search, editor: TTEditor) {
        append(.search(search), editor: editor)
    }
    private func append(_ step: RecordedMacro.Step, editor: TTEditor) {
        guard recordingEditor != nil, !playing, captureError == nil else { return }
        editorDidFocus(editor)
        guard recordingEditor === editor, captureError == nil else { return }
        guard editor.selectionCount == 1 else {
            invalidateRecording(reason: "Multiple-selection transforms cannot be recorded safely yet.")
            return
        }
        do {
            try step.validate()
            guard recorded.count < MacroLimits.recordedActions else {
                throw MacroError.invalid("Recording exceeded \(Strings.number(MacroLimits.recordedActions)) actions.")
            }
            recorded.append(step)
        } catch {
            discard(error, editor: editor)
        }
    }
    @objc private func playLast() { if let lastRecording { choosePlayback(lastRecording) } }
    @objc private func playSaved(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String,
            let macro = library.macros.first(where: { $0.id.uuidString == id })
        {
            choosePlayback(macro)
        }
    }
    /// The editor a macro may play into, checked before the playback dialog opens: nil while
    /// recording or playing, and the read-only error for a read-only document.
    func playbackEditor() throws -> TTEditor? {
        guard !playing, recordingEditor == nil, let editor = editorProvider() else { return nil }
        try editor.requireWritable()
        return editor
    }
    private func choosePlayback(_ macro: RecordedMacro) {
        let editor: TTEditor
        do {
            guard let target = try playbackEditor() else { return }
            editor = target
        } catch {
            TTAlert.present(error)
            return
        }
        let revision = editor.revision
        let selectionStart = editor.selectionStart
        let selectionEnd = editor.selectionEnd
        let alert = TTAlert()
        alert.messageText = "Play \(macro.name)"
        alert.informativeText =
            "Repeat count (1–\(Strings.number(MacroLimits.repeatCount))). Playback changes the captured editor as one Undo group. Find steps (literal find and Find-window Next or Previous) stop the macro on no match; earlier edits remain undoable. Replace All with no matches is skipped. Clipboard commands operate on the current clipboard. No shell command or automation runs."
        alert.addButton(withTitle: "Play").identifier = NSUserInterfaceItemIdentifier("macro.play.confirm")
        alert.addButton(withTitle: "Cancel", role: .cancel).identifier = NSUserInterfaceItemIdentifier(
            "macro.play.cancel")
        let count = NSTextField(string: "1")
        count.setAccessibilityLabel("Macro repeat count")
        NumericInput.configure(count)
        count.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        count.identifier = NSUserInterfaceItemIdentifier("macro.play.count")
        let untilEnd = NSButton(checkboxWithTitle: "Repeat until end of document", target: nil, action: nil)
        let controls = NSStackView(views: [count, untilEnd])
        controls.orientation = .vertical
        controls.frame = NSRect(x: 0, y: 0, width: 400, height: 60)
        alert.accessoryView = controls
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            guard editor.revision == revision, editor.selectionStart == selectionStart,
                editor.selectionEnd == selectionEnd
            else { throw MacroError.invalid("The editor changed while choosing playback. Run the macro again.") }
            guard let repeats = NumericInput.integer(count), repeats > 0, repeats <= MacroLimits.repeatCount,
                macro.steps.count <= MacroLimits.playbackActions / repeats
            else {
                throw MacroError.invalid(
                    "Choose a valid count; at most \(Strings.number(MacroLimits.playbackActions)) total actions per invocation."
                )
            }
            try playInteractively(macro, on: editor, repeats: repeats, untilEnd: untilEnd.state == .on)
        } catch { TTAlert.present(error) }
    }
    @objc private func cancelPlayback() { playbackCancelled = true }
    private func playInteractively(_ macro: RecordedMacro, on editor: TTEditor, repeats: Int, untilEnd: Bool) throws {
        guard !playing, recordingEditor == nil else { throw MacroError.invalid("Macro playback is unavailable.") }
        let session = try MacroPlayback(
            macro: macro, editor: editor, repeats: repeats, untilEnd: untilEnd, searchPlayback: searchPlayback)
        playing = true
        playbackCancelled = false
        editor.beginUndoGroup()
        defer {
            editor.endUndoGroup()
            playing = false
            rebuild()
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 120), styleMask: [.titled], backing: .buffered,
            defer: false)
        panel.title = macro.name
        let status = NSTextField(labelWithString: "Playing recorded editing steps…")
        status.frame = NSRect(x: 20, y: 70, width: 400, height: 24)
        let stop = NSButton(title: "Stop", target: self, action: #selector(cancelPlayback))
        // The panel has only this button; Escape presses it.
        stop.keyEquivalent = "\u{1b}"
        stop.frame = NSRect(x: 310, y: 20, width: 110, height: 30)
        panel.contentView?.addSubview(status)
        panel.contentView?.addSubview(stop)
        var failure: Error?
        let timer = Timer(timeInterval: 0.005, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                NSApp.stopModal()
                return
            }
            do {
                let finished = try session.advance(budget: 50, shouldCancel: { self.playbackCancelled })
                status.stringValue = "Played \(session.performed) steps. Stop preserves one Undo."
                if finished {
                    timer.invalidate()
                    NSApp.stopModal()
                }
            } catch {
                failure = error
                timer.invalidate()
                NSApp.stopModal()
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        panel.center()
        NSApp.runModal(for: panel)
        timer.invalidate()
        panel.orderOut(nil)
        if let failure { throw failure }
    }
    func play(
        _ macro: RecordedMacro, on editor: TTEditor, repeats: Int = 1, untilEnd: Bool = false,
        shouldCancel: () -> Bool = { false }
    ) throws {
        guard !playing, recordingEditor == nil else { throw MacroError.invalid("Macro playback is unavailable.") }
        let session = try MacroPlayback(
            macro: macro, editor: editor, repeats: repeats, untilEnd: untilEnd, searchPlayback: searchPlayback)
        playing = true
        editor.beginUndoGroup()
        defer {
            editor.endUndoGroup()
            playing = false
            rebuild()
        }
        while try !session.advance(budget: 100, shouldCancel: shouldCancel) {}
    }
    private var namePanel: FormPanel?
    @objc private func saveLast() {
        if let namePanel {
            namePanel.window.makeKeyAndOrderFront(nil)
            return
        }
        guard let recorded = lastRecording, recordingEditor == nil else { return }
        do {
            guard try StoreRecovery.ensureWritable(loadState) else { return }
            let baseline = try SavedConfiguration.bytes(library)
            let recordingBaseline = try SavedConfiguration.bytes(lastRecording)
            let form = FormPanel(
                title: "Name Recorded Macro", identifier: "macro.save", size: NSSize(width: 540, height: 300))
            namePanel = form
            form.retainPresentationOwner(self)
            form.onClose = { [weak self] in self?.namePanel = nil }
            let name = form.field("Macro name", value: recorded.name, identifier: "macro.save.name")
            form.button("Save", identifier: "macro.save.confirm") { [weak self] in
                guard let self, form.commitEditing() else { return }
                do {
                    guard self.recordingEditor == nil else { throw FormFailure.busy }
                    var macro = recorded
                    macro.name = name.stringValue
                    var proposed = self.library
                    if let i = proposed.macros.firstIndex(where: { $0.id == macro.id }) {
                        proposed.macros[i] = macro
                    } else {
                        proposed.macros.append(macro)
                    }
                    try proposed.validate()
                    try SavedConfiguration.requireUnchanged(self.library, since: baseline)
                    try SavedConfiguration.requireUnchanged(self.lastRecording, since: recordingBaseline)
                    guard try StoreRecovery.ensureWritable(self.loadState) else { return }
                    try SavedConfiguration.requireUnchanged(self.library, since: baseline)
                    try SavedConfiguration.requireUnchanged(self.lastRecording, since: recordingBaseline)
                    try self.persist(proposed)
                    self.lastRecording = macro
                    form.close()
                } catch { form.showValidation(error, field: name) }
            }.keyEquivalent = "\r"
            form.button("Cancel", identifier: "macro.save.cancel", cancel: true) { form.close() }
            form.window.initialFirstResponder = name
            form.show()
        } catch { TTAlert.present(error) }
    }
    var jsonFilePanels = JSONLibraryEditor.FilePanels.standard
    private var manager: LibraryManager?
    @objc private func manage() {
        if let manager {
            manager.form.window.makeKeyAndOrderFront(nil)
            return
        }
        guard !playing, recordingEditor == nil else { return }
        do {
            guard try StoreRecovery.ensureWritable(loadState) else { return }
            var working = library
            let baseline = try SavedConfiguration.bytes(library)
            let panel = LibraryManager(title: "Saved Macros", identifier: "macro.manager")
            manager = panel
            panel.retainController(self)
            panel.onClose = { [weak self] in self?.manager = nil }
            panel.rows = { working.macros.map { .init(id: $0.id, name: $0.name) } }
            panel.canEdit = { [weak self] in self.map { !$0.playing && $0.recordingEditor == nil } ?? false }
            panel.rename = { id, name in
                if let index = working.macros.firstIndex(where: { $0.id == id }) { working.macros[index].name = name }
            }
            panel.save = { [weak self, weak panel] in
                guard let self, !self.playing, self.recordingEditor == nil else { throw FormFailure.busy }
                for macro in working.macros {
                    do { try macro.validate() } catch {
                        panel?.reveal(macro.id)
                        throw error
                    }
                }
                try working.validate()
                try SavedConfiguration.requireUnchanged(self.library, since: baseline)
                guard try StoreRecovery.ensureWritable(self.loadState) else { return false }
                try SavedConfiguration.requireUnchanged(self.library, since: baseline)
                try self.persist(working)
                return true
            }
            panel.action("Add…", identifier: "macro.manager.add") { [weak panel] in
                guard let panel else { return }
                let form = FormPanel(title: "New Macro", identifier: "macro.new", size: NSSize(width: 620, height: 430))
                form.note(
                    "Create a macro that inserts this text. Saving a macro never runs it. Record editing actions from the Macros menu to capture more complex macros."
                )
                let name = form.field("Name", value: "My Macro", identifier: "macro.new.name")
                let text = JSONLibraryEditor.makeTextView(size: NSSize(width: 560, height: 180))
                ControlPresentation.label("Text inserted by the new macro", control: text.editor)
                text.editor.identifier = NSUserInterfaceItemIdentifier("macro.new.text")
                form.add(text.scroll)
                text.scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
                form.button("Add Macro", identifier: "macro.new.save") {
                    guard form.commitEditing() else { return }
                    do {
                        guard !text.editor.string.isEmpty else {
                            throw MacroError.invalid("Enter the text this macro will insert. Nothing has been saved.")
                        }
                        let macro = RecordedMacro(
                            id: UUID(), name: name.stringValue, steps: [.insertText(text.editor.string)])
                        try macro.validate()
                        working.macros.append(macro)
                        form.close()
                        panel.reload(select: macro.id)
                    } catch { form.showValidation(error, field: name.stringValue.isEmpty ? name : text.editor) }
                }
                form.button("Cancel", identifier: "macro.new.cancel", cancel: true) {
                    form.close()
                    panel.refresh()
                }
                form.show(parent: panel.form.window)
            }
            panel.action("Duplicate", identifier: "macro.manager.duplicate", needsSelection: true) { [weak panel] in
                guard let panel, let id = panel.selectedID, var copy = working.macros.first(where: { $0.id == id })
                else { return }
                copy.id = UUID()
                working.macros.append(copy)
                panel.reload(select: copy.id)
            }
            panel.action("Delete…", identifier: "macro.manager.delete", needsSelection: true) { [weak panel] in
                panel?.confirmDelete { id in working.macros.removeAll { $0.id == id } }
            }
            panel.secondaryAction("Advanced JSON…", identifier: "macro.manager.advanced") { [weak self, weak panel] in
                guard let self, let panel, panel.canEdit() else { return }
                do {
                    try JSONLibraryEditor.edit(
                        working,
                        configuration: .init(
                            title: "Advanced Macro Configuration",
                            information:
                                "Changes return to the macro manager. Choose Save in the manager to save the library. Saving never runs macros.",
                            accessibilityLabel: "Macro library JSON", exportName: "TextTank-Macros.json",
                            identifier: "macro.json", size: NSSize(width: 650, height: 400), saveTitle: "Use Changes"),
                        panels: self.jsonFilePanels, parent: panel.form.window, current: { working },
                        read: {
                            try PrivateFileStore.read(
                                $0, maximumBytes: MacroLibrary.maximumBytes, parent: .selectedInput)
                        },
                        save: { proposed in
                            working = proposed
                            panel.reload()
                        })
                    panel.refresh()
                } catch { panel.form.showValidation(error) }
            }
            panel.show()
        } catch { TTAlert.present(error) }
    }
    /// One guarded save boundary for the manager, recording commands and native checks.
    func persist(_ proposed: MacroLibrary) throws {
        try loadState.requireWritable()
        let data = try proposed.encoded()
        try PrivateFileStore.prepareDirectory(storage.deletingLastPathComponent())
        try PrivateFileStore.write(
            data, to: storage, maximumBytes: MacroLibrary.maximumBytes, temporaryPrefix: ".macros-")
        library = proposed
        rebuild()
    }

}

/// Bounded incremental playback shared by native progress UI and deterministic tests.
private final class MacroPlayback {
    let macro: RecordedMacro, editor: TTEditor
    let repeats: Int, untilEnd: Bool
    let searchPlayback: ((RecordedMacro.Search, TTEditor) throws -> Void)?
    var performed = 0
    private var index = 0, iterations = 0
    private var cycleCaret: Int, cycleRevision: UInt
    init(
        macro: RecordedMacro, editor: TTEditor, repeats: Int, untilEnd: Bool,
        searchPlayback: ((RecordedMacro.Search, TTEditor) throws -> Void)?
    ) throws {
        try macro.validate()
        try editor.requireWritable()
        guard editor.window != nil, editor.selectionCount == 1, repeats > 0, repeats <= MacroLimits.repeatCount,
            macro.steps.count <= MacroLimits.playbackActions / repeats
        else { throw MacroError.invalid("Macro playback is unavailable for this editor or repeat count.") }
        self.macro = macro
        self.editor = editor
        self.repeats = repeats
        self.untilEnd = untilEnd
        self.searchPlayback = searchPlayback
        cycleCaret = editor.selectionCaret
        cycleRevision = editor.revision
    }
    func advance(budget: Int, shouldCancel: () -> Bool) throws -> Bool {
        let started = ProcessInfo.processInfo.systemUptime
        for offset in 0..<budget {
            if offset > 0 && ProcessInfo.processInfo.systemUptime - started >= 0.02 { return false }
            if shouldCancel() { throw MacroError.invalid("Macro stopped. Prior edits remain in one Undo group.") }
            guard editor.window != nil, !editor.readOnly, editor.selectionCount == 1 else {
                throw MacroError.invalid(
                    "The macro editor closed, became read-only or changed selection mode. Prior edits remain undoable.")
            }
            if index == 0 && untilEnd && editor.selectionCaret >= editor.byteLength { return true }
            guard performed < MacroLimits.playbackActions else {
                throw MacroError.invalid(
                    "Macro stopped at the \(Strings.number(MacroLimits.playbackActions))-action limit. Prior edits remain undoable."
                )
            }
            let step = macro.steps[index]
            switch step {
            case .search(let search):
                guard let searchPlayback else {
                    throw MacroError.invalid("Search playback is not available. Prior edits remain undoable.")
                }
                try searchPlayback(search, editor)
            case .findLiteral(let text, let matchCase, let backwards):
                guard
                    try SearchController.playLegacyFind(
                        text: text, matchCase: matchCase, backwards: backwards, in: editor)
                else {
                    throw MacroError.invalid("Macro stopped: literal find did not match. Prior edits remain undoable.")
                }
            case .replaceSelection(let text):
                guard editor.replaceSelection(text) else {
                    throw MacroError.invalid("The editor rejected a macro step. Prior edits remain undoable.")
                }
            case .insertText(let text):
                guard editor.executeMacroStep(TTMacroAction.insertText(text)) else {
                    throw MacroError.invalid("The editor rejected a macro step. Prior edits remain undoable.")
                }
            case .command(let command):
                guard editor.executeMacroStep(TTMacroAction.command(TTEditorCommandIdentifier(rawValue: command)))
                else {
                    throw MacroError.invalid("The editor rejected a macro step. Prior edits remain undoable.")
                }
            }
            performed += 1
            index += 1
            if index == macro.steps.count {
                iterations += 1
                index = 0
                if !untilEnd && iterations >= repeats { return true }
                if untilEnd && editor.selectionCaret == cycleCaret && editor.revision == cycleRevision {
                    throw MacroError.invalid(
                        "Macro stopped because a repetition made no progress toward the end of the document.")
                }
                cycleCaret = editor.selectionCaret
                cycleRevision = editor.revision
            }
        }
        return false
    }
}

/// Capture immutable options once for both the bar and the advanced Find window.
extension RecordedMacro.Search {
    init(options: SearchOptions, action: String) {
        self.init(
            query: options.query, replacement: options.replacement, mode: options.mode.rawValue,
            matchCase: options.matchCase, wholeWord: options.wholeWord,
            dotMatchesNewline: options.dotMatchesNewline, wrap: options.wrap, action: action)
    }
}
