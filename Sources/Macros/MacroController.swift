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
    private var recordingEditor: TTEditor?
    private var recorded: [RecordedMacro.Step] = []
    private var lastRecording: RecordedMacro?
    private var captureError: Error?
    private var playing = false
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
                // The bridge reports what it cannot replay; the name is for the person. This kind is
                // never a Step.Kind, so it cannot arrive through an imported file.
                if raw["kind"] as? String == "unsupported" {
                    let name =
                        raw["name"] as? String ?? "An editing action (Scintilla message \(raw["message"] ?? "unknown"))"
                    throw MacroError.invalid("\(name) is not recordable yet. No partial macro will be saved.")
                }
                let data = try JSONSerialization.data(withJSONObject: raw)
                let step = try JSONDecoder().decode(RecordedMacro.Step.self, from: data)
                try step.validate()
                guard self.recorded.count < 10000 else { throw MacroError.invalid("Recording exceeded 10000 steps.") }
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
        let viewOnly: Set<String> = [
            "zoomIn", "zoomOut", "foldAll", "unfoldAll", "showWhitespace", "toggleEOL", "toggleLineNumbers"
        ]
        if !RecordedMacro.Step.commands.contains(command) && !viewOnly.contains(command) {
            invalidateRecording(
                reason: "The command ‘\(command)’ is not recordable yet. No partial macro will be saved.")
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
    /// Root calls only after application-layer literal find; parameters are captured, not read at playback.
    /// A find that did not match changed nothing and would stop playback, so it is left out (F68).
    func recordFind(text: String, matchCase: Bool, backwards: Bool, matched: Bool, editor: TTEditor) {
        guard matched else { return }
        append(.init(kind: .findLiteral, text: text, matchCase: matchCase, backwards: backwards), editor: editor)
    }
    func recordSearch(_ search: RecordedMacro.Search, editor: TTEditor) {
        append(.init(kind: .search, search: search), editor: editor)
    }
    /// The bridge's target-based replaceSelection is not SCN_MACRORECORD text input.
    func recordReplace(text: String, editor: TTEditor) {
        append(.init(kind: .replaceSelection, text: text), editor: editor)
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
            guard recorded.count < 10000 else { throw MacroError.invalid("Recording exceeded 10000 steps.") }
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
            "Repeat count (1–10000). Playback changes the captured editor as one Undo group. Find steps (literal find and Find-window Next or Previous) stop the macro on no match; earlier edits remain undoable. Replace All with no matches is skipped. Clipboard commands operate on the current clipboard. No shell or external workflow runs."
        alert.addButton(withTitle: "Play").identifier = NSUserInterfaceItemIdentifier("macro.play.confirm")
        alert.addButton(withTitle: "Cancel", role: .cancel).identifier = NSUserInterfaceItemIdentifier(
            "macro.play.cancel")
        let count = NSTextField(string: "1")
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
            guard let repeats = Int(count.stringValue), repeats > 0, repeats <= 10000,
                macro.steps.count <= 100000 / repeats
            else { throw MacroError.invalid("Choose a valid count; at most 100000 total steps per invocation.") }
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
    @objc private func saveLast() {
        guard var macro = lastRecording else { return }
        do { guard try StoreRecovery.ensureWritable(loadState) else { return } } catch {
            TTAlert.present(error)
            return
        }
        let alert = TTAlert()
        alert.messageText = "Name Recorded Macro"
        alert.addButton(withTitle: "Save").identifier = NSUserInterfaceItemIdentifier("macro.save.confirm")
        alert.addButton(withTitle: "Cancel", role: .cancel).identifier = NSUserInterfaceItemIdentifier(
            "macro.save.cancel")
        let name = NSTextField(string: macro.name)
        name.frame = NSRect(x: 0, y: 0, width: 400, height: 24)
        name.identifier = NSUserInterfaceItemIdentifier("macro.save.name")
        alert.accessoryView = name
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            macro.name = name.stringValue
            var proposed = library
            if let i = proposed.macros.firstIndex(where: { $0.id == macro.id }) {
                proposed.macros[i] = macro
            } else {
                proposed.macros.append(macro)
            }
            try persist(proposed)
            lastRecording = macro
        } catch { TTAlert.present(error) }
    }
    @objc private func manage() {
        guard !playing, recordingEditor == nil else { return }
        do { guard try StoreRecovery.ensureWritable(loadState) else { return } } catch {
            TTAlert.present(error)
            return
        }
        let alert = TTAlert()
        alert.messageText = "Manage Saved Macros"
        alert.informativeText =
            "Edit names or steps, or remove entries. Preserve id to rename. Only validated text, editor commands and literal find/replace steps are accepted. Saving never executes macros."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel", role: .cancel)
        alert.addButton(withTitle: "Import…")
        alert.addButton(withTitle: "Export…")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 650, height: 400))
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds)
        text.isRichText = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        text.string = String(data: (try? library.encoded()) ?? Data(), encoding: .utf8) ?? ""
        alert.accessoryView = scroll
        while true {
            enum LibraryChoice { case save, cancel, importFile, exportFile }
            guard let response = alert.choice([LibraryChoice.save, .cancel, .importFile, .exportFile]),
                response != .cancel
            else { return }
            if response == .cancel { return }
            do {
                if response == .importFile {
                    let panel = NSOpenPanel()
                    panel.allowsMultipleSelection = false
                    panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url {
                        text.string = String(
                            data: try MacroLibrary.decode(
                                PrivateFileStore.read(
                                    url, maximumBytes: MacroLibrary.maximumBytes, parent: .selectedInput)
                            ).encoded(), encoding: .utf8)!
                    }
                    continue
                }
                let proposed = try MacroLibrary.decode(Data(text.string.utf8))
                if response == .exportFile {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = "TextTank-Macros.json"
                    if panel.runModal() == .OK, let url = panel.url {
                        try proposed.encoded().write(to: url, options: .atomic)
                    }
                    continue
                }
                try persist(proposed)
                return
            } catch { TTAlert.present(error) }
        }
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
        guard editor.window != nil, editor.selectionCount == 1, repeats > 0, repeats <= 10000,
            macro.steps.count <= 100000 / repeats
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
            guard performed < 100000 else {
                throw MacroError.invalid("Macro stopped at the 100000-step limit. Prior edits remain undoable.")
            }
            let step = macro.steps[index]
            switch step.kind {
            case .search:
                guard let searchPlayback else {
                    throw MacroError.invalid("Search playback is not available. Prior edits remain undoable.")
                }
                try searchPlayback(step.search!, editor)
            case .findLiteral:
                guard editor.find(step.text!, matchCase: step.matchCase!, backwards: step.backwards!) else {
                    throw MacroError.invalid("Macro stopped: literal find did not match. Prior edits remain undoable.")
                }
            case .replaceSelection:
                guard editor.replaceSelection(step.text!) else {
                    throw MacroError.invalid("The editor rejected a macro step. Prior edits remain undoable.")
                }
            case .insertText, .command:
                let data = try JSONEncoder().encode(step)
                let dictionary = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                guard editor.executeMacroStep(dictionary) else {
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
