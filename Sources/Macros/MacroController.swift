// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Darwin

final class MacroController: NSObject, NSMenuDelegate {
    private let editorProvider: ()->TTEditor?
    private var library = MacroLibrary(macros: [])
    private let storage: URL
    private var loadingError: Error?
    private var recordingEditor: TTEditor?
    private var recorded: [RecordedMacro.Step] = []
    private var lastRecording: RecordedMacro?
    private var captureError: Error?
    private var playing = false
    private lazy var macroMenu = NSMenu(title:"Macros")
    init(editorProvider: @escaping ()->TTEditor?) {
        self.editorProvider=editorProvider
        let base = ProcessInfo.processInfo.environment["TEXTTANK_SUPPORT_DIRECTORY"].map { URL(fileURLWithPath:$0,isDirectory:true) } ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("TextTank",isDirectory:true)
        storage=base.appendingPathComponent("Macros.json")
        super.init(); macroMenu.delegate=self
        if FileManager.default.fileExists(atPath:storage.path) {
            do { library=try MacroLibrary.decode(Data(contentsOf:storage)) } catch { loadingError=error }
        }
    }
    func menu()->NSMenu { rebuild();return macroMenu }
    func menuNeedsUpdate(_ menu:NSMenu) { rebuild() }
    private func rebuild() {
        macroMenu.removeAllItems();macroMenu.autoenablesItems=false
        func item(_ title:String,_ action:Selector,_ enabled:Bool=true,_ id:String?=nil) {
            let item=NSMenuItem(title:title,action:action,keyEquivalent:"");item.target=self;item.isEnabled=enabled;item.representedObject=id;macroMenu.addItem(item)
        }
        item("Start Recording",#selector(startRecording),recordingEditor == nil && !playing)
        item("Stop Recording",#selector(stopRecording),recordingEditor != nil)
        item("Play Last Recording…",#selector(playLast),lastRecording != nil && recordingEditor == nil && !playing)
        item("Save Last Recording…",#selector(saveLast),lastRecording != nil && recordingEditor == nil)
        item("Manage Saved Macros…",#selector(manage),recordingEditor == nil && !playing)
        if !library.macros.isEmpty { macroMenu.addItem(.separator()) }
        for macro in library.macros { item(macro.name,#selector(playSaved(_:)),recordingEditor == nil && !playing,macro.id.uuidString) }
    }
    @objc func startRecording() {
        guard recordingEditor == nil,!playing,let editor=editorProvider() else { return }
        recordingEditor=editor;recorded=[];captureError=nil;lastRecording=nil
        editor.onMacroStep = { [weak self, weak editor] raw in
            guard let self,let editor,self.recordingEditor === editor,!self.playing else { return }
            do {
                let data=try JSONSerialization.data(withJSONObject:raw)
                let step=try JSONDecoder().decode(RecordedMacro.Step.self,from:data)
                try step.validate()
                guard self.recorded.count < 10000 else { throw MacroError.invalid("Recording exceeded 10000 steps.") }
                self.recorded.append(step)
            } catch { self.captureError=error; editor.stopRecording() }
        }
        editor.startRecording();rebuild()
    }
    /// Invalidated recordings remain stoppable, but can never become a saved partial macro.
    func invalidateRecording(reason:String) {
        guard let editor=recordingEditor,!playing else { return }
        if captureError == nil { captureError=MacroError.invalid(reason) }
        editor.stopRecording();editor.onMacroStep=nil
    }
    func editorDidFocus(_ editor:TTEditor) {
        if let recordingEditor,recordingEditor !== editor {
            invalidateRecording(reason:"The active editor changed during recording. Recording across views is not supported.")
        }
    }
    func editorWillReset(_ editor:TTEditor,reason:String) {
        if recordingEditor === editor { invalidateRecording(reason:reason) }
    }
    func willExecuteCommand(_ command:String,on editor:TTEditor) {
        guard recordingEditor != nil else { return }
        editorDidFocus(editor)
        let viewOnly:Set<String>=["zoomIn","zoomOut","foldAll","unfoldAll","showWhitespace","toggleEOL","toggleLineNumbers"]
        if !RecordedMacro.Step.commands.contains(command) && !viewOnly.contains(command) {
            invalidateRecording(reason:"The command ‘\(command)’ is not recordable yet. No partial macro will be saved.")
        }
    }
    /// Testable finish path used by the Stop menu. Invalidations are errors, never partial success.
    func finishRecording() throws -> RecordedMacro? {
        guard let editor=recordingEditor else { return nil }
        editor.stopRecording();editor.onMacroStep=nil;recordingEditor=nil
        defer { rebuild() }
        if let captureError { throw MacroError.invalid("Recording was discarded: \(captureError.localizedDescription)") }
        guard !recorded.isEmpty else { throw MacroError.invalid("No supported editing actions were recorded.") }
        let macro=RecordedMacro(id:UUID(),name:"Recorded Macro",steps:recorded)
        lastRecording=macro;return macro
    }
    @objc func stopRecording() {
        do { _ = try finishRecording() } catch { showError(error) }
    }
    /// Root calls only after application-layer literal find; parameters are captured, not read at playback.
    func recordFind(text:String,matchCase:Bool,backwards:Bool,editor:TTEditor) {
        append(.init(kind:.findLiteral,text:text,matchCase:matchCase,backwards:backwards),editor:editor)
    }
    /// The bridge's target-based replaceSelection is not SCN_MACRORECORD text input.
    func recordReplace(text:String,editor:TTEditor) { append(.init(kind:.replaceSelection,text:text),editor:editor) }
    private func append(_ step:RecordedMacro.Step,editor:TTEditor) {
        guard recordingEditor != nil,!playing,captureError == nil else { return }
        editorDidFocus(editor)
        guard recordingEditor === editor,captureError == nil else { return }
        guard editor.selectionCount == 1 else { invalidateRecording(reason:"Multiple-selection transforms cannot be recorded safely yet.");return }
        do { try step.validate();guard recorded.count < 10000 else { throw MacroError.invalid("Recording exceeded 10000 steps.") };recorded.append(step) } catch { captureError=error;editor.stopRecording() }
    }
    @objc private func playLast() { if let lastRecording { choosePlayback(lastRecording) } }
    @objc private func playSaved(_ sender:NSMenuItem) { if let id=sender.representedObject as? String,let macro=library.macros.first(where:{$0.id.uuidString==id}) { choosePlayback(macro) } }
    private func choosePlayback(_ macro:RecordedMacro) {
        guard !playing,recordingEditor == nil,let editor=editorProvider() else { return }
        let revision=editor.revision;let selectionStart=editor.selectionStart;let selectionEnd=editor.selectionEnd
        let alert=NSAlert();alert.messageText="Play \(macro.name)"
        alert.informativeText="Repeat count (1–10000). Playback changes the captured editor as one Undo group. Literal find stops on no match; earlier edits remain undoable. Clipboard commands operate on the current clipboard. No shell or external workflow runs."
        alert.addButton(withTitle:"Play");alert.addButton(withTitle:"Cancel")
        let count=NSTextField(string:"1");count.frame=NSRect(x:0,y:0,width:200,height:24);alert.accessoryView=count
        guard alert.runModal() == .alertFirstButtonReturn else{return}
        do {guard editor.revision == revision,editor.selectionStart == selectionStart,editor.selectionEnd == selectionEnd else {throw MacroError.invalid("The editor changed while choosing playback. Run the macro again.")};guard let repeats=Int(count.stringValue),repeats > 0,repeats <= 10000,macro.steps.count <= 100000/repeats else {throw MacroError.invalid("Choose a valid count; at most 100000 total steps per invocation.")};try play(macro,on:editor,repeats:repeats)}catch{showError(error)}
    }
    func play(_ macro:RecordedMacro,on editor:TTEditor,repeats:Int=1)throws {
        guard !playing,recordingEditor == nil,editor.window != nil,editor.selectionCount == 1,repeats > 0,repeats <= 10000,macro.steps.count <= 100000/repeats else {throw MacroError.invalid("Macro playback is unavailable for this editor or repeat count.")}
        try macro.validate();playing=true;editor.beginUndoGroup()
        defer {editor.endUndoGroup();playing=false;rebuild()}
        for _ in 0..<repeats {
            for step in macro.steps {
                switch step.kind {
                case .findLiteral:
                    guard editor.find(step.text!,matchCase:step.matchCase!,backwards:step.backwards!) else {throw MacroError.invalid("Macro stopped: literal find did not match. Prior edits remain in one Undo group.")}
                case .replaceSelection: editor.replaceSelection(step.text!)
                case .insertText,.command:
                    let data=try JSONEncoder().encode(step)
                    let dictionary=try JSONSerialization.jsonObject(with:data) as! [String:Any]
                    guard editor.executeMacroStep(dictionary) else {throw MacroError.invalid("The editor rejected a macro step. Prior edits remain undoable.")}
                }
            }
        }
    }
    @objc private func saveLast() {
        guard var macro=lastRecording,loadingError == nil else {if let loadingError {showError(loadingError)};return}
        let alert=NSAlert();alert.messageText="Name Recorded Macro";alert.addButton(withTitle:"Save");alert.addButton(withTitle:"Cancel")
        let name=NSTextField(string:macro.name);name.frame=NSRect(x:0,y:0,width:400,height:24);alert.accessoryView=name
        guard alert.runModal() == .alertFirstButtonReturn else{return}
        do {macro.name=name.stringValue;var proposed=library
            if let i=proposed.macros.firstIndex(where:{$0.id==macro.id}) {proposed.macros[i]=macro}else{proposed.macros.append(macro)}
            try persist(proposed);lastRecording=macro
        }catch{showError(error)}
    }
    @objc private func manage() {
        guard !playing,recordingEditor == nil else{return}
        if let loadingError {showError(MacroError.invalid("Saved macros could not be loaded and are preserved: \(loadingError.localizedDescription)"));return}
        let alert=NSAlert();alert.messageText="Manage Saved Macros";alert.informativeText="Edit names or steps, or remove entries. Preserve id to rename. Only validated text, editor commands and literal find/replace steps are accepted. Saving never executes macros."
        alert.addButton(withTitle:"Save");alert.addButton(withTitle:"Cancel")
        let scroll=NSScrollView(frame:NSRect(x:0,y:0,width:650,height:400));scroll.hasVerticalScroller=true
        let text=NSTextView(frame:scroll.bounds);text.isRichText=false;text.isAutomaticQuoteSubstitutionEnabled=false;text.isAutomaticDashSubstitutionEnabled=false;text.font = .monospacedSystemFont(ofSize:12,weight:.regular);text.autoresizingMask=[.width];text.isVerticallyResizable=true;text.textContainer?.widthTracksTextView=true;scroll.documentView=text
        text.string=String(data:(try? library.encoded()) ?? Data(),encoding:.utf8) ?? "";alert.accessoryView=scroll
        while alert.runModal() == .alertFirstButtonReturn {
            do {try persist(MacroLibrary.decode(Data(text.string.utf8)));return}catch{showError(error)}
        }
    }
    private func persist(_ proposed:MacroLibrary)throws {
        let data=try proposed.encoded()
        let directory=storage.deletingLastPathComponent()
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        if FileManager.default.fileExists(atPath:storage.path) {
            let values=try storage.resourceValues(forKeys:[.isSymbolicLinkKey,.isRegularFileKey])
            guard values.isSymbolicLink != true,values.isRegularFile == true else {throw MacroError.invalid("Macro storage must be a regular file.")}
        }
        let temporary=directory.appendingPathComponent(".macros-"+UUID().uuidString)
        let descriptor=open(temporary.path,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW,mode_t(0o600))
        guard descriptor >= 0 else {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
        let handle=FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
        defer {try? handle.close();try? FileManager.default.removeItem(at:temporary)}
        try handle.write(contentsOf:data);try handle.synchronize();try handle.close()
        guard rename(temporary.path,storage.path)==0 else {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
        library=proposed;rebuild()
    }
    private func showError(_ error:Error){NSAlert(error:error).runModal()}
}
