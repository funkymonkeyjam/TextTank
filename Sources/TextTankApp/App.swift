import AppKit

#if !TESTING
@main
struct TextTankMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        _ = NSDocumentController.shared
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

#endif

final class AppDelegate: NSObject, NSApplicationDelegate {
    let workspace = WorkspaceController()
    let workspaceBrowser = WorkspaceBrowserController()
    let settings = SettingsController()
    lazy var folderSearch:FolderSearchController = {
        let controller=FolderSearchController();controller.workspaceRoots={ [weak self] in self?.workspaceBrowser.store.state.folders ?? [] };return controller
    }()
    weak var lastDocumentController:EditorWindowController?
    var currentEditor:TTEditor? {
        if let controller=NSApp.mainWindow?.windowController as? EditorWindowController { lastDocumentController=controller }
        guard let controller=lastDocumentController,controller.document != nil else { return nil }
        return controller.activeEditor
    }
    lazy var languages=LanguageController(editorProvider:{ [weak self] in self?.currentEditor },languageProvider:{ [weak self] in (self?.lastDocumentController?.document as? TextDocument)?.languageIdentifier ?? "normal" },setLanguage:{ [weak self] id in (self?.lastDocumentController?.document as? TextDocument)?.languageIdentifier=id })
    lazy var runner:RunController = {
        let controller=RunController()
        controller.editor={ [weak self] in
            self?.macros.invalidateRecording(reason:"External execution is never recorded in macros.")
            return self?.currentEditor
        }
        controller.file={ [weak self] in (self?.lastDocumentController?.document as? TextDocument)?.fileURL }
        return controller
    }()
    lazy var utilities=UtilityController(activeEditor:{ [weak self] in
        self?.macros.invalidateRecording(reason:"Text utilities are not recorded in macros yet.")
        return self?.currentEditor
    })
    lazy var searchController:SearchController = {
        let controller=SearchController()
        controller.currentEditor={ [weak self] in self?.currentEditor }
        controller.openEditors={ NSDocumentController.shared.documents.compactMap { ($0 as? TextDocument)?.editor } }
        return controller
    }()
    lazy var macros = MacroController(editorProvider: { (NSApp.mainWindow?.windowController as? EditorWindowController)?.activeEditor })
    lazy var automations = AutomationController(editorProvider: { [weak self] in
        self?.macros.invalidateRecording(reason:"An automation was invoked during macro recording. Automation side effects are not recorded.")
        return (NSApp.mainWindow?.windowController as? EditorWindowController)?.activeEditor
    }, newDocument: { text in
        let doc = TextDocument(); NSDocumentController.shared.addDocument(doc); doc.makeWindowControllers(); doc.editor.text=text; doc.showWindows(); doc.windowControllers.first?.window?.makeFirstResponder(doc.editor)
    })
    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenus()
        settings.apply()
        searchController.onCommand={ [weak self] options,action,editor in
            self?.macros.recordSearch(.init(query:options.query,replacement:options.replacement,mode:options.mode.rawValue,matchCase:options.matchCase,wholeWord:options.wholeWord,dotMatchesNewline:options.dotMatchesNewline,wrap:options.wrap,action:action),editor:editor)
        }
        searchController.onUnrecordableCommand={ [weak self] reason in self?.macros.invalidateRecording(reason:reason) }
        macros.searchPlayback={ [weak self] search,editor in
            guard let self else {throw MacroError.invalid("Search controller unavailable.")}
            var options=SearchOptions();options.query=search.query;options.replacement=search.replacement;options.mode=SearchOptions.Mode(rawValue:search.mode) ?? .normal
            options.matchCase=search.matchCase;options.wholeWord=search.wholeWord;options.dotMatchesNewline=search.dotMatchesNewline;options.wrap=search.wrap
            try self.searchController.playRecorded(options:options,action:search.action,on:editor)
        }
        if let error=settings.loadError { NSAlert(error:error).runModal() }
        NSApp.activate(ignoringOtherApps: true)
        if NSDocumentController.shared.documents.isEmpty { newDocument(nil) }
        else { for document in NSDocumentController.shared.documents { if document.windowControllers.isEmpty { document.makeWindowControllers() }; document.showWindows() } }
        restoreRecovery()
    }
    @objc func newDocument(_ sender:Any?) {
        let doc=TextDocument(); NSDocumentController.shared.addDocument(doc);doc.makeWindowControllers();doc.showWindows()
        doc.windowControllers.first?.window?.makeFirstResponder(doc.editor)
    }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let documents=NSDocumentController.shared.documents
        if documents.allSatisfy({ !$0.isDocumentEdited }) {
            for document in documents { document.close() }
            return .terminateNow
        }
        DispatchQueue.main.async {
            NSDocumentController.shared.reviewUnsavedDocuments(withAlertTitle: "Quit TextTank?", cancellable: true, delegate: self, didReviewAllSelector: #selector(self.reviewed(_:didReviewAll:contextInfo:)), contextInfo: nil)
        }
        return .terminateLater
    }
    @objc func reviewed(_ controller: NSDocumentController, didReviewAll: Bool, contextInfo: UnsafeMutableRawPointer?) {
        if didReviewAll { for document in NSDocumentController.shared.documents { document.close() } }
        NSApp.reply(toApplicationShouldTerminate: didReviewAll)
    }
    private func buildMenus() {
        let bar = NSMenu(); NSApp.mainMenu = bar
        func menu(_ title: String) -> NSMenu { let item = NSMenuItem(); item.title = title; let m = NSMenu(title: title); item.submenu = m; bar.addItem(item); return m }
        func item(_ m: NSMenu, _ title: String, _ action: Selector, _ key: String = "", _ object: String? = nil) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key); i.representedObject = object; m.addItem(i)
        }
        let app = menu("TextTank")
        item(app, "About TextTank", #selector(about));
        let preferences=NSMenuItem(title:"Settings…",action:#selector(SettingsController.showSettings(_:)),keyEquivalent:",");preferences.target=settings;app.addItem(preferences); app.addItem(.separator()); item(app, "Quit TextTank", #selector(NSApplication.terminate(_:)), "q")
        let file = menu("File")
        item(file, "New", #selector(newDocument(_:)), "n")
        item(file, "Open…", #selector(NSDocumentController.openDocument(_:)), "o")
        item(file, "Save", #selector(NSDocument.save(_:)), "s")
        item(file, "Save As…", #selector(NSDocument.saveAs(_:)), "S")
        item(file,"Save Copy…",#selector(TextDocument.saveCopy(_:)))
        item(file,"Save All",#selector(NSDocumentController.saveAllDocuments(_:)))
        item(file, "Revert to Saved…", #selector(NSDocument.revertToSaved(_:)))
        item(file,"Check for External Changes",#selector(TextDocument.checkExternalChanges(_:)))
        item(file,"Read Only",#selector(TextDocument.toggleReadOnly(_:)))
        item(file, "Close", #selector(NSWindow.performClose(_:)), "w")
        file.addItem(.separator())
        item(file,"Page Setup…",#selector(NSDocument.runPageLayout(_:)))
        item(file,"Print…",#selector(NSDocument.printDocument(_:)),"p")
        let saveSession=NSMenuItem(title:"Save Session Snapshot…",action:#selector(WorkspaceController.saveSession(_:)),keyEquivalent:"");saveSession.target=workspace;file.addItem(saveSession)
        let openSession=NSMenuItem(title:"Open Session Snapshot…",action:#selector(WorkspaceController.openSession(_:)),keyEquivalent:"");openSession.target=workspace;file.addItem(openSession)
        let workspaceRoot=NSMenuItem();workspaceRoot.title="Workspace";workspaceRoot.submenu=workspaceBrowser.menu();bar.addItem(workspaceRoot)
        let encoding = menu("Encoding")
        for (title,code) in [("UTF-8","utf8"),("UTF-8 with BOM","utf8bom"),("UTF-16 LE with BOM","utf16LE"),("UTF-16 BE with BOM","utf16BE"),("Windows-1252","windows1252"),("ISO-8859-1","latin1")] { item(encoding,"Convert to \(title)",#selector(TextDocument.convertEncoding(_:)),"",code) }
        encoding.addItem(.separator())
        for value in FileEncoding.allCases { item(encoding,"Reload as \(value.rawValue)…",#selector(TextDocument.reloadEncoding(_:)),"",value.rawValue) }
        let edit = menu("Edit")
        for (label,id,key) in [("Undo","undo","z"),("Redo","redo","Z"),("Cut","cut","x"),("Copy","copy","c"),("Paste","paste","v"),("Select All","selectAll","a"),("Duplicate Line","duplicateLine","d"),("Delete Line","deleteLine",""),("Transpose Lines","transposeLine",""),("Indent","indent","]"),("Unindent","unindent","["),("Uppercase","upper",""),("Lowercase","lower","")] {
            let nativeActions:[String:Selector]=["undo":NSSelectorFromString("undo:"),"redo":NSSelectorFromString("redo:"),"cut":#selector(NSText.cut(_:)),"copy":#selector(NSText.copy(_:)),"paste":#selector(NSText.paste(_:)),"selectAll":#selector(NSText.selectAll(_:))]
            item(edit,label,nativeActions[id] ?? #selector(EditorWindowController.command(_:)),key,id)
        }
        for comment in CommentCommand.allCases { item(edit,comment.title,#selector(EditorWindowController.comment(_:)),"",comment.rawValue) }
        for transform in EditorTransform.allCases { item(edit,transform.title,#selector(EditorWindowController.command(_:)),"","transform."+transform.rawValue) }
        for (title,id) in [("Rectangular Selection","rectangularSelection"),("Stream Selection","streamSelection"),("Add Next Occurrence","addNextOccurrence"),("Select All Occurrences","selectAllOccurrences"),("Clear Additional Selections","clearAdditionalSelections"),("Duplicate Selection","duplicateSelection"),("Delete Word Left","deleteWordLeft"),("Delete Word Right","deleteWordRight"),("Delete to Line Start","deleteLineLeft"),("Delete to Line End","deleteLineRight")] { item(edit,title,#selector(EditorWindowController.command(_:)),"",id) }
        item(edit,"Column Insert / Number…",#selector(EditorWindowController.columnInsert(_:)))
        let search = menu("Search")
        for (title,action,key) in [("Find and Replace…",#selector(SearchController.showSearch(_:)),"f"),("Find Next",#selector(SearchController.next(_:)),"g"),("Find Previous",#selector(SearchController.previous(_:)),"G")] {
            let entry=NSMenuItem(title:title,action:action,keyEquivalent:key);entry.target=searchController;search.addItem(entry)
        }
        let runRoot=NSMenuItem();runRoot.title="Run";runRoot.submenu=runner.makeMenu();bar.addItem(runRoot)
        let utilityRoot=NSMenuItem();utilityRoot.title="Text Utilities";utilityRoot.submenu=utilities.makeMenu();bar.addItem(utilityRoot)
        let folderSearchItem=NSMenuItem(title:"Find in Folder…",action:#selector(FolderSearchController.showSearch(_:)),keyEquivalent:"F");folderSearchItem.target=folderSearch;search.addItem(folderSearchItem)
        let view = menu("View"); item(view,"Clone in Split View",#selector(EditorWindowController.clone(_:))); item(view,"Close Split View",#selector(EditorWindowController.closeSplit(_:))); item(view,"Wrap Lines",#selector(EditorWindowController.toggleWrap(_:))); item(view,"Zoom In",#selector(EditorWindowController.command(_:)),"+","zoomIn"); item(view,"Zoom Out",#selector(EditorWindowController.command(_:)),"-","zoomOut")
        for (label,id) in [("Move Line Up","moveLineUp"),("Move Line Down","moveLineDown"),("Join Selected Lines","joinLines"),("Trim Trailing Whitespace","trimTrailing"),("Toggle Overtype","toggleOvertype")] { item(edit,label,#selector(EditorWindowController.command(_:)),"",id) }
        for (label,id) in [("Fold All","foldAll"),("Unfold All","unfoldAll"),("Show Whitespace","showWhitespace"),("Show Line Endings","toggleEOL"),("Show Line Numbers","toggleLineNumbers")] { item(view,label,#selector(EditorWindowController.command(_:)),"",id) }
        for (label,id) in [("Matching Brace","gotoMatchingBrace"),("Select to Matching Brace","selectMatchingBrace"),("Toggle Bookmark","bookmarkToggle"),("Next Bookmark","bookmarkNext"),("Previous Bookmark","bookmarkPrevious")] { item(search,label,#selector(EditorWindowController.command(_:)),"",id) }
        for mode in ["LF","CRLF","CR"] { item(edit,"Convert Line Endings to \(mode)",#selector(EditorWindowController.convertEOL(_:)),"",mode) }
        let languageRoot=NSMenuItem();languageRoot.title="Language";languageRoot.submenu=languages.menu();bar.addItem(languageRoot)
        let macroRoot=NSMenuItem();macroRoot.title="Macros";macroRoot.submenu=macros.menu();bar.addItem(macroRoot)
        let automationRoot=NSMenuItem(); automationRoot.title="Automations";automationRoot.submenu=automations.menu();bar.addItem(automationRoot)
        item(search,"Automation Palette…",#selector(palette(_:)),"P")
        let window = menu("Window"); NSApp.windowsMenu = window
        let nextTab=NSMenuItem(title:"Next Tab",action:#selector(nextDocumentTab(_:)),keyEquivalent:"\t");nextTab.target=self;nextTab.keyEquivalentModifierMask=[.control];window.addItem(nextTab)
        let previousTab=NSMenuItem(title:"Previous Tab",action:#selector(previousDocumentTab(_:)),keyEquivalent:"\t");previousTab.target=self;previousTab.keyEquivalentModifierMask=[.control,.shift];window.addItem(previousTab)
        item(window,"Open Documents…",#selector(showDocumentTabs(_:)))
        window.addItem(.separator()); item(window,"Minimize",#selector(NSWindow.performMiniaturize(_:)),"m"); item(window,"Zoom",#selector(NSWindow.performZoom(_:)))
    }
    @objc func nextDocumentTab(_ sender:Any?) {cycleDocumentTab(1)}
    @objc func previousDocumentTab(_ sender:Any?) {cycleDocumentTab(-1)}
    private func cycleDocumentTab(_ direction:Int) {
        let windows=DocumentTabWindow.documents
        guard !windows.isEmpty else{return}
        let index=windows.firstIndex(where:{$0.isVisible}) ?? 0
        windows[(index+direction+windows.count)%windows.count].makeKeyAndOrderFront(nil)
    }
    @objc func showDocumentTabs(_ sender:Any?) {
        let windows=DocumentTabWindow.documents
        guard !windows.isEmpty else{return}
        let alert=TTAlert();alert.messageText="Open Documents"
        let choice=documentTabChoices(windows)
        choice.selectItem(at:windows.firstIndex(where:{$0.isVisible}) ?? 0)
        alert.accessoryView=choice;alert.addButton(withTitle:"Switch");alert.addButton(withTitle:"Cancel")
        guard alert.runModal() == .alertFirstButtonReturn,let index=choice.selectedItem?.tag,windows.indices.contains(index),DocumentTabWindow.documents.contains(where:{$0 === windows[index]}) else{return}
        windows[index].makeKeyAndOrderFront(nil)
    }
    func documentTabChoices(_ windows:[NSWindow]) -> NSPopUpButton {
        let choice=NSPopUpButton(frame:NSRect(x:0,y:0,width:420,height:30))
        for (index,window) in windows.enumerated() {
            let path=(window.windowController?.document as? NSDocument)?.fileURL?.deletingLastPathComponent().path
            let title=window.title+(window.isDocumentEdited ? " •" : "")+(path.map {" — \($0)"} ?? "")
            let item=NSMenuItem(title:title,action:nil,keyEquivalent:"");item.tag=index
            choice.menu?.addItem(item)
        }
        return choice
    }
    private func restoreRecovery() {
        do {
            let scan = try TextDocument.recovery.scan()
            let snapshots = scan.snapshots
            if !scan.issues.isEmpty { let warning=TTAlert();warning.messageText="Some recovery files need review";warning.informativeText=scan.issues.map { $0.url.lastPathComponent+": "+$0.message }.joined(separator:"\n");warning.runModal() }
            guard !snapshots.isEmpty else { return }
            let alert=TTAlert(); alert.messageText="Recover unsaved documents?"; alert.informativeText="Found \(snapshots.count) recovery snapshots. Recovered content opens as new unsaved documents; original files are not changed.";alert.addButton(withTitle:"Recover");alert.addButton(withTitle:"Later")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            for snapshot in snapshots {
                let (base,overflow)=snapshot.revision.addingReportingOverflow(1)
                guard !overflow else { throw RecoveryError.invalidSnapshot }
                let doc=TextDocument(); doc.recoveryID=snapshot.id; doc.recoveryBase=base; doc.format=snapshot.format
                NSDocumentController.shared.addDocument(doc);doc.makeWindowControllers();doc.editor.text=snapshot.text;doc.updateChangeCount(.changeDone);doc.showWindows()
            }
        } catch { NSAlert(error:error).runModal() }
    }
    @objc func palette(_ sender:Any?) { automations.showPalette() }
    @objc func about() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName:"TextTank",.applicationVersion:"0.1 — INCOMPLETE PREVIEW",.credits:NSAttributedString(string:"Plain text. Sharp tools.\nNative Mac editor · Carbon Caret\nFull Notepad++ parity remains in development.\nGPL-3.0-or-later · Scintilla and Lexilla notices included.")])
    }
}

final class TextDocument: NSDocument {
    static let recovery: RecoveryStore = {
        let env=ProcessInfo.processInfo.environment["TEXTTANK_SUPPORT_DIRECTORY"]
        let root=env.map { URL(fileURLWithPath:$0,isDirectory:true) } ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("TextTank",isDirectory:true)
        return RecoveryStore(directory:root.appendingPathComponent("Recovery",isDirectory:true))
    }()
    var recoveryID = UUID()
    var recoveryBase: UInt64 = 0
    private var recoveryTimer: Timer?
    private var recoveryDeadlineTimer: Timer?
    private let recoveryWriter=RecoveryWriter()
    private var recoveryGeneration=0
    private var recoveryClosed=false
    #if TESTING
    var automaticRecoveryDelay: TimeInterval=0.5
    var maximumRecoveryDelay: TimeInterval=5
    #else
    private let automaticRecoveryDelay: TimeInterval=0.5
    private let maximumRecoveryDelay: TimeInterval=5
    #endif
    let editor = TTEditor(frame: NSRect(x:0,y:0,width:900,height:600))
    var savedFormat = FileFormat(encoding:.utf8,bom:false)
    var format = FileFormat(encoding: .utf8, bom: false) {
        didSet { if !loading && format != oldValue { recoveryBase += 1; updateChangeCount(format != savedFormat || editor.modified || !savepointMatchesDisk ? .changeDone : .changeCleared) } }
    }
    private var diskBytes: Data?
    private var savePayload: Data?
    private var savepointMatchesDisk=true
    #if TESTING
    var afterWriteForTesting: (() throws -> Void)?
    #endif
    var originalDiskFingerprint:String? { diskBytes.map(WorkspaceStore.fingerprint) }
    var languageIdentifier="null"
    private var loading = false
    enum DiskState: Equatable { case unchanged, changed, missing }
    func diskState() throws -> DiskState {
        guard let url=fileURL,let diskBytes else { return .unchanged }
        do { return try WorkspaceStore.readRegularFile(url,maximumBytes:Int.max) == diskBytes ? .unchanged : .changed }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == 2 { return .missing }
    }
    @objc func toggleReadOnly(_ sender:NSMenuItem) {
        editor.readOnly.toggle()
        windowControllers.compactMap { $0 as? EditorWindowController }.forEach { $0.secondary?.readOnly=editor.readOnly }
        sender.state=editor.readOnly ? .on : .off
    }
    @objc func checkExternalChanges(_ sender:Any?) {
        do {
            let state=try diskState(); let alert=TTAlert()
            alert.messageText=state == .unchanged ? "File is unchanged" : state == .missing ? "File is missing" : "File changed outside TextTank"
            alert.informativeText=state == .unchanged ? "The on-disk bytes match the last read or save." : "Your editor contents are preserved. Use Save As to keep your edits, or Revert to Saved to reload the disk version."
            alert.runModal()
        } catch { presentError(error) }
    }
    /// Explicit reinterpretation is a reload, not encoding conversion. Unsaved edits
    /// require a native confirmation before this method is called with discard=true.
    func reload(using encoding:FileEncoding,discard:Bool=false) throws {
        guard let url=fileURL else { throw NSError(domain:"TextTank",code:2,userInfo:[NSLocalizedDescriptionKey:"Save the document before reloading its disk bytes."]) }
        if isDocumentEdited && !discard { throw NSError(domain:"TextTank",code:3,userInfo:[NSLocalizedDescriptionKey:"Reload would discard unsaved changes."]) }
        let bytes=try WorkspaceStore.readRegularFile(url,maximumBytes:Int.max)
        let decoded=try FileCodec.decode(bytes,encoding:encoding)
        loadDecoded(decoded,bytes:bytes)
        updateChangeCount(.changeCleared); flushRecovery()
    }
    @objc func reloadEncoding(_ sender:NSMenuItem) {
        guard let raw=sender.representedObject as? String,let encoding=FileEncoding(rawValue:raw) else { return }
        if isDocumentEdited {
            let alert=TTAlert();alert.messageText="Discard unsaved changes and reload?";alert.informativeText="The disk bytes will be interpreted as \(raw). Use Convert to change the save encoding while keeping your text."
            alert.addButton(withTitle:"Cancel");alert.addButton(withTitle:"Discard and Reload")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        do { try reload(using:encoding,discard:true) } catch { presentError(error) }
    }
    override init() {
        super.init()
        hasUndoManager = false
        editor.onChange = { [weak self] in
            guard let self, !self.loading else { return }
            self.updateChangeCount(self.editor.modified || self.format != self.savedFormat || !self.savepointMatchesDisk ? .changeDone : .changeCleared)
            self.recoveryTimer?.invalidate()
            self.recoveryGeneration+=1
            self.recoveryTimer=Timer.scheduledTimer(withTimeInterval:self.automaticRecoveryDelay,repeats:false) { [weak self] _ in self?.enqueueRecovery() }
            if self.recoveryDeadlineTimer == nil {
                self.recoveryDeadlineTimer=Timer.scheduledTimer(withTimeInterval:self.maximumRecoveryDelay,repeats:false) { [weak self] _ in self?.enqueueRecovery() }
            }
        }
    }
    private func cancelRecoveryTimers() {
        recoveryTimer?.invalidate();recoveryTimer=nil
        recoveryDeadlineTimer?.invalidate();recoveryDeadlineTimer=nil
    }
    private func recoveryOperation() -> () throws -> Void {
        let store=Self.recovery,id=recoveryID,revision=recoveryBase+UInt64(editor.revision)
        if isDocumentEdited || editor.modified || format != savedFormat {
            let snapshot=RecoverySnapshot(id:id,text:editor.text,format:format,originalURL:fileURL?.absoluteString,revision:revision)
            return {try store.save(snapshot)}
        }
        return {try store.remove(id:id,throughRevision:revision)}
    }
    private func reportRecovery(_ error:Error?) {
        let message=error.map {"Recovery failed: \($0.localizedDescription)"} ?? ((isDocumentEdited ? "Draft saved for session restore" : fileURL == nil ? "Ready" : "Saved")+" · Incomplete preview")
        windowControllers.compactMap{$0 as? EditorWindowController}.forEach{$0.status.stringValue=message}
    }
    private func enqueueRecovery() {
        guard !recoveryClosed else{return}
        cancelRecoveryTimers()
        let generation=recoveryGeneration,operation=recoveryOperation()
        recoveryWriter.submit { [weak self] in
            let error:Error?
            do {try operation();error=nil} catch let failure {error=failure}
            DispatchQueue.main.async { [weak self] in
                guard let self,!self.recoveryClosed,self.recoveryGeneration == generation else{return}
                self.reportRecovery(error)
            }
        }
    }
    func flushRecovery() {
        guard !recoveryClosed else{return}
        cancelRecoveryTimers();recoveryGeneration+=1
        do {try recoveryWriter.finish(recoveryOperation());reportRecovery(nil)}catch{reportRecovery(error)}
    }
    override func close() {
        (NSApp.delegate as? AppDelegate)?.macros.editorWillReset(editor,reason:"The recording document was closed.")
        cancelRecoveryTimers();recoveryGeneration+=1;recoveryClosed=true
        editor.readOnly=true
        windowControllers.compactMap { $0 as? EditorWindowController }.forEach { $0.prepareForClose() }
        // NSDocument only reaches close after the user has chosen Save or Discard.
        let store=Self.recovery,id=recoveryID,revision=recoveryBase+UInt64(editor.revision)
        try? recoveryWriter.finish {try store.remove(id:id,throughRevision:revision)}
        super.close()
    }
    override class var autosavesInPlace: Bool { false }
    override func makeWindowControllers() { addWindowController(EditorWindowController(document:self)) }
    override func read(from data: Data, ofType typeName: String) throws {
        let decoded = try FileCodec.decode(data)
        loadDecoded(decoded,bytes:data)
    }
    private func loadDecoded(_ decoded:DecodedFile,bytes:Data) {
        (NSApp.delegate as? AppDelegate)?.macros.editorWillReset(editor,reason:"The recording document was reloaded.")
        loading=true
        let locked=editor.readOnly;editor.readOnly=false
        editor.text=decoded.text;editor.resetUndoHistory();format=decoded.format;savedFormat=format;diskBytes=bytes;savepointMatchesDisk=true;editor.setSavePoint()
        editor.readOnly=locked;loading=false
        if let app=NSApp.delegate as? AppDelegate,let id=app.languages.detect(filename:fileURL?.lastPathComponent ?? "",text:decoded.text),app.languages.apply(identifier:id,to:editor){languageIdentifier=id}
    }
    @objc func saveCopy(_ sender:Any?) {
        let panel=NSSavePanel(); panel.nameFieldStringValue=(fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled")+"-copy.txt"
        guard panel.runModal() == .OK, let url=panel.url else { return }
        do { try writeSafely(to:url,ofType:fileType ?? "Plain Text",for:.saveToOperation) } catch { presentError(error) }
    }
    @objc func convertEncoding(_ sender:NSMenuItem) {
        guard let code=sender.representedObject as? String else { return }
        let target:FileFormat
        switch code {
        case "utf8bom":target=FileFormat(encoding:.utf8,bom:true)
        case "utf16LE":target=FileFormat(encoding:.utf16LE,bom:true)
        case "utf16BE":target=FileFormat(encoding:.utf16BE,bom:true)
        case "windows1252":target=FileFormat(encoding:.windows1252,bom:false)
        case "latin1":target=FileFormat(encoding:.latin1,bom:false)
        default:target=FileFormat(encoding:.utf8,bom:false)
        }
        do { _ = try FileCodec.encode(editor.text,format:target); format=target; flushRecovery(); windowControllers.compactMap { $0 as? EditorWindowController }.forEach { $0.refreshStatusDetails() } }
        catch { presentError(error) }
    }
    override func printOperation(withSettings printSettings:[NSPrintInfo.AttributeKey:Any]) throws -> NSPrintOperation {
        let settings=printInfo.copy() as! NSPrintInfo
        settings.dictionary().addEntries(from:printSettings)
        settings.horizontalPagination = .fit;settings.verticalPagination = .automatic
        settings.isHorizontallyCentered=false;settings.isVerticallyCentered=false
        let width=max(72,settings.paperSize.width-settings.leftMargin-settings.rightMargin)
        // A static print representation, never a second editable document model.
        let printable=NSTextView(frame:NSRect(x:0,y:0,width:width,height:100))
        printable.isRichText=false;printable.font = .monospacedSystemFont(ofSize:10,weight:.regular)
        printable.textColor = .black;printable.backgroundColor = .white;printable.textContainerInset = .zero
        printable.isHorizontallyResizable=false;printable.isVerticallyResizable=true
        printable.textContainer?.containerSize=NSSize(width:width,height:CGFloat.greatestFiniteMagnitude)
        printable.textContainer?.widthTracksTextView=true;printable.string=editor.text
        if let container=printable.textContainer,let layout=printable.layoutManager {
            layout.ensureLayout(for:container);printable.setFrameSize(NSSize(width:width,height:max(1,ceil(layout.usedRect(for:container).height))))
        }
        let operation=NSPrintOperation(view:printable,printInfo:settings)
        operation.jobTitle=displayName;return operation
    }
    override func data(ofType typeName: String) throws -> Data { if let savePayload {return savePayload};return try FileCodec.encode(editor.text, format: format) }
    override func writeSafely(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) throws {
        if url == fileURL, let diskBytes {
            let current = try WorkspaceStore.readRegularFile(url,maximumBytes:Int.max)
            guard current == diskBytes else { throw NSError(domain:"TextTank",code:1,userInfo:[NSLocalizedDescriptionKey:"The file changed outside TextTank. Use Save As to preserve your edits, or revert to inspect the disk version."]) }
        }
        let submitted=try FileCodec.encode(editor.text,format:format),submittedFormat=format,submittedRevision=editor.revision
        savePayload=submitted;defer {savePayload=nil}
        try super.writeSafely(to:url,ofType:typeName,for:saveOperation)
        #if TESTING
        try afterWriteForTesting?()
        #endif
        if saveOperation != .saveToOperation {
            diskBytes=submitted;savedFormat=submittedFormat
            if editor.revision == submittedRevision && format == submittedFormat {savepointMatchesDisk=true;editor.setSavePoint();updateChangeCount(.changeCleared)}
            else {savepointMatchesDisk=false;updateChangeCount(.changeDone)}
            flushRecovery()
        }
    }

}

/// Borderless native buttons preserve keyboard and accessibility activation.
private final class StatusBadge: NSButton {
    var activate:((StatusBadge)->Void)?
    init(_ text:String) {
        super.init(frame:.zero)
        title=text;isBordered=false;bezelStyle = .regularSquare
        font = .monospacedDigitSystemFont(ofSize:11,weight:.regular)
        contentTintColor = .secondaryLabelColor
        toolTip=text+" — click for options"
        setButtonType(.momentaryChange)
        target=self;action=#selector(showOptions)
    }
    @objc private func showOptions() {activate?(self)}
    required init?(coder:NSCoder) {fatalError("init(coder:) not used")}
    var preferredWidth:CGFloat {ceil((title as NSString).size(withAttributes:[.font:font!]).width)+20}
    override func draw(_ dirtyRect:NSRect) {
        NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.10 : 0.035).setFill()
        NSBezierPath(roundedRect:bounds,xRadius:3,yRadius:3).fill()
        super.draw(dirtyRect)
    }
    override func viewDidChangeEffectiveAppearance() {super.viewDidChangeEffectiveAppearance();needsDisplay=true}
}

private final class StatusBadgeRow: NSView {
    var onActivate:((String,NSView)->Void)?
    private var values:[String]=[]
    private var badges:[StatusBadge]=[]
    private var identities:[String]=[]
    private var measuredWidth:CGFloat = -1
    override var isFlipped:Bool {true}
    func update(_ fields:[String],keys:[String]) {
        var counts:[String:Int]=[:]
        let ids=keys.map {key -> String in let n=counts[key,default:0];counts[key]=n+1;return "\(key).\(n)"}
        guard fields != values || ids != identities else{return}
        let existing=Dictionary(uniqueKeysWithValues:zip(identities,badges))
        let updated=zip(zip(fields,keys),ids).map { entry,id -> StatusBadge in
            let (text,key)=entry
            let badge=existing[id] ?? StatusBadge(text)
            badge.title=text;badge.toolTip=text+" — click for options"
            badge.activate = { [weak self] button in self?.onActivate?(key,button) }
            if badge.superview == nil {addSubview(badge)}
            return badge
        }
        for (id,badge) in existing where !ids.contains(id) {badge.removeFromSuperview()}
        values=fields;identities=ids;badges=updated
        invalidateIntrinsicContentSize();needsLayout=true
    }
    private func rows() -> [[StatusBadge]] {
        let width=max(1,bounds.width)
        var result:[[StatusBadge]]=[],row:[StatusBadge]=[];var used:CGFloat=0
        for badge in badges {
            let size=min(width,badge.preferredWidth)
            if !row.isEmpty && used+6+size > width {result.append(row);row=[];used=0}
            if !row.isEmpty {used+=6};row.append(badge);used+=size
        }
        if !row.isEmpty {result.append(row)}
        return result
    }
    override var intrinsicContentSize:NSSize {NSSize(width:NSView.noIntrinsicMetric,height:CGFloat(max(1,rows().count))*26-4)}
    override func layout() {
        super.layout()
        if measuredWidth != bounds.width {measuredWidth=bounds.width;invalidateIntrinsicContentSize()}
        for (index,row) in rows().enumerated() {
            let width=row.reduce(CGFloat(0)){$0+min(bounds.width,$1.preferredWidth)}+CGFloat(max(0,row.count-1))*6
            var x=bounds.width-width
            for badge in row {let size=min(bounds.width,badge.preferredWidth);badge.frame=NSRect(x:x,y:CGFloat(index)*26,width:size,height:22);x+=size+6}
        }
    }
}

/// Each document retains its native window and save lifecycle; only the selected tab is visible.
private final class DocumentTabWindow: NSWindow {
    static var documents: [NSWindow] {
        NSDocumentController.shared.documents.flatMap { $0.windowControllers.compactMap { $0.window } }.filter { $0 is DocumentTabWindow }
    }
    override func makeKeyAndOrderFront(_ sender:Any?) {
        let others=Self.documents.filter{$0 !== self}
        let sharedFrame=others.first(where:{$0.isVisible})?.frame
        others.forEach{$0.orderOut(nil)}
        super.makeKeyAndOrderFront(sender)
        contentView?.layoutSubtreeIfNeeded()
        if let sharedFrame {setFrame(sharedFrame,display:true)}
        (windowController as? EditorWindowController)?.refreshStatusDetails()
        if let controller=windowController as? EditorWindowController {makeFirstResponder(controller.activeEditor)}
    }
    override func close() {
        let wasVisible=isVisible
        let closingFrame=frame
        let next=Self.documents.first{$0 !== self}
        super.close()
        if wasVisible {
            next?.makeKeyAndOrderFront(nil)
            // Ordering a hidden window can apply AppKit's screen constraints.
            // Restore the shared frame after that layout transition, as on tab selection.
            next?.contentView?.layoutSubtreeIfNeeded()
            next?.setFrame(closingFrame,display:true)
        }
    }
}
private final class DocumentTabActionButton: NSButton {
    weak var documentWindow: NSWindow?
}

private final class DocumentTabButton: NSButton {
    weak var documentWindow: NSWindow?
}
private final class DocumentTabBackground: NSView {
    override func draw(_ dirtyRect:NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.15).setFill();bounds.fill()
        NSColor.controlAccentColor.setFill();NSRect(x:0,y:isFlipped ? bounds.height-3 : 0,width:bounds.width,height:3).fill()
    }
}

private final class DocumentTabStrip: NSView {
    private let scroll = NSScrollView()
    private let row = NSView()
    private var signature = ""
    weak var owner: NSWindow?
    override init(frame:NSRect) {
        super.init(frame:frame)
        scroll.drawsBackground=false;scroll.hasHorizontalScroller=true;scroll.autohidesScrollers=true
        scroll.documentView=row;addSubview(scroll)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) not used") }
    override func layout() { super.layout();scroll.frame=bounds }
    func refresh() {
        guard let owner else{return}
        let windows=DocumentTabWindow.documents
        let key=windows.map { "\(ObjectIdentifier($0)):\($0.title):\($0.isDocumentEdited):\($0 === owner)" }.joined(separator:"|")
        guard key != signature else{return};signature=key
        row.subviews.forEach{$0.removeFromSuperview()}
        var x:CGFloat=0
        var activeRect=NSRect.zero
        for window in windows {
            let title=window.title+(window.isDocumentEdited ? "  •" : "")
            let width=min(220,max(130,ceil((title as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:13)]).width)+66))
            let button=DocumentTabButton(title:title,target:self,action:#selector(selectTab(_:)))
            button.isBordered=false;button.font = .systemFont(ofSize:13,weight:window === owner ? .semibold : .regular)
            button.alignment = .left;button.image=NSImage(systemSymbolName:"doc.text",accessibilityDescription:nil);button.imagePosition = .imageLeading
            button.lineBreakMode = .byTruncatingTail;button.toolTip=window.title;button.setAccessibilityLabel(window.title+(window === owner ? ", active tab" : ", tab"))
            button.documentWindow=window;button.frame=NSRect(x:x+8,y:0,width:width-34,height:36)
            // The highlighted area includes the close control.
            if window === owner {let cell=DocumentTabBackground(frame:NSRect(x:x,y:0,width:width,height:36));activeRect=cell.frame;row.addSubview(cell)}
            row.addSubview(button)
            let close=DocumentTabActionButton(image:NSImage(systemSymbolName:"xmark",accessibilityDescription:"Close \(window.title)")!,target:self,action:#selector(closeTab(_:)))
            close.isBordered=false;close.documentWindow=window;close.frame=NSRect(x:x+width-26,y:7,width:22,height:22);close.toolTip="Close \(window.title)";row.addSubview(close)
            x+=width
        }
        let add=NSButton(image:NSImage(systemSymbolName:"plus",accessibilityDescription:"New tab")!,target:self,action:#selector(newTab(_:)))
        add.isBordered=false;add.contentTintColor = .controlAccentColor;add.toolTip="New tab (⌘N)";add.frame=NSRect(x:x+4,y:3,width:32,height:30);row.addSubview(add)
        row.frame=NSRect(x:0,y:0,width:x+40,height:36)
        row.scrollToVisible(activeRect)
    }
    @objc private func selectTab(_ sender:NSButton) {
        guard owner != nil else{return};let windows=DocumentTabWindow.documents
        guard let target=(sender as? DocumentTabButton)?.documentWindow,windows.contains(where:{$0 === target}) else{return}
        target.makeKeyAndOrderFront(nil)
    }
    @objc private func closeTab(_ sender:NSButton) {
        guard owner != nil else{return};let windows=DocumentTabWindow.documents
        guard let target=(sender as? DocumentTabActionButton)?.documentWindow,windows.contains(where:{$0 === target}) else{return}
        target.makeKeyAndOrderFront(nil)
        target.performClose(sender)
    }
    @objc private func newTab(_ sender:Any?) { (NSApp.delegate as? AppDelegate)?.newDocument(sender) }
}

final class EditorWindowController: NSWindowController, NSToolbarDelegate {
    let split = NSSplitView()
    let findField = NSSearchField()
    let replaceField = NSTextField()
    let caseBox = NSButton(checkboxWithTitle:"Match case",target:nil,action:nil)
    let status = NSTextField(labelWithString:"Ready · Incomplete preview")
    private let statusDetails = StatusBadgeRow()
    private let documentTabs = DocumentTabStrip()
    private var statusTimer: Timer?
    private(set) var statusRefreshCount=0
    private var statusRevision: UInt?
    private var statusMetricsPending=false
    private var cachedCharacterCount = 0
    private var cachedSelectionKey = ""
    private var cachedSelectedCount = 0
    private var cachedEndings = "LF"
    var secondary: TTEditor?
    weak var lastEditor: TTEditor?
    var focusObserver: NSObjectProtocol?
    var automationObserver: NSObjectProtocol?
    let primaryEditor: TTEditor
    var activeEditor: TTEditor {
        if let secondary, let responder = window?.firstResponder as? NSView, responder.isDescendant(of: secondary) { lastEditor=secondary; return secondary }
        if let responder=window?.firstResponder as? NSView, responder.isDescendant(of:primaryEditor) { lastEditor=primaryEditor }
        return lastEditor ?? primaryEditor
    }
    init(document: TextDocument) {
        primaryEditor = document.editor
        let window = DocumentTabWindow(contentRect:NSRect(x:0,y:0,width:1080,height:720),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        super.init(window:window)
        lastEditor = document.editor
        document.editor.onFocus = { [weak self, weak document] in
            guard let editor=document?.editor else { return }
            self?.lastEditor=editor;(NSApp.delegate as? AppDelegate)?.lastDocumentController=self;(NSApp.delegate as? AppDelegate)?.macros.editorDidFocus(editor)
        }
        if let app=NSApp.delegate as? AppDelegate {
            app.settings.apply(to:document.editor)
            document.editor.menu=app.automations.contextMenu()
            let toolbar=NSToolbar(identifier:"TextTankToolbar");toolbar.delegate=self;toolbar.displayMode = .iconOnly;window.toolbar=toolbar
            automationObserver = NotificationCenter.default.addObserver(forName:.textTankAutomationsDidChange,object:app.automations,queue:.main) { [weak self] _ in self?.refreshAutomationToolbar() }
        }
        focusObserver = NotificationCenter.default.addObserver(forName:NSWindow.didUpdateNotification,object:window,queue:.main) { [weak self] _ in _ = self?.activeEditor }
        window.title = "TextTank"; window.center(); window.tabbingMode = .disallowed
        window.titleVisibility = .visible; window.titlebarAppearsTransparent = false
        for button in [NSWindow.ButtonType.closeButton,.miniaturizeButton,.zoomButton] { window.standardWindowButton(button)?.isHidden = false }
        window.contentMinSize=NSSize(width:800,height:500)
        let root = NSView(frame:NSRect(origin:.zero,size:window.contentLayoutRect.size)); window.contentView = root
        split.isVertical = true; split.dividerStyle = .thin; split.addArrangedSubview(document.editor)
        findField.placeholderString = "Find literal text"; replaceField.placeholderString = "Replace with"
        let findButton = NSButton(title:"Next",target:self,action:#selector(findNext(_:)))
        let replaceButton = NSButton(title:"Replace Selection",target:self,action:#selector(replaceSelection(_:)))
        let search = NSStackView(views:[findField,replaceField,caseBox,findButton,replaceButton]); search.spacing = 8
        documentTabs.owner=window
        [documentTabs,search,split,status,statusDetails].forEach { $0.translatesAutoresizingMaskIntoConstraints=false;root.addSubview($0) }
        NSLayoutConstraint.activate([split.heightAnchor.constraint(greaterThanOrEqualToConstant:200),documentTabs.topAnchor.constraint(equalTo:root.topAnchor),documentTabs.leadingAnchor.constraint(equalTo:root.leadingAnchor),documentTabs.trailingAnchor.constraint(equalTo:root.trailingAnchor),documentTabs.heightAnchor.constraint(equalToConstant:36),search.topAnchor.constraint(equalTo:documentTabs.bottomAnchor,constant:10),search.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:12),search.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-12),findField.widthAnchor.constraint(greaterThanOrEqualToConstant:200),replaceField.widthAnchor.constraint(greaterThanOrEqualToConstant:160),split.topAnchor.constraint(equalTo:search.bottomAnchor,constant:10),split.leadingAnchor.constraint(equalTo:root.leadingAnchor),split.trailingAnchor.constraint(equalTo:root.trailingAnchor),split.bottomAnchor.constraint(equalTo:statusDetails.topAnchor,constant:-5),statusDetails.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:12),statusDetails.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-12),statusDetails.bottomAnchor.constraint(equalTo:status.topAnchor,constant:-2),status.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-12),status.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:12),status.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-6)])
        status.font = .systemFont(ofSize:11); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        statusDetails.onActivate = { [weak self] key,view in self?.showStatusOptions(key,at:view) }
        statusTimer=Timer.scheduledTimer(withTimeInterval:0.2,repeats:true) { [weak self] _ in
            guard let self,self.window?.isVisible == true else{return}
            self.refreshStatusDetails()
        }
        refreshStatusDetails(for:document)
    }
    func refreshStatusDetails(for suppliedDocument:TextDocument? = nil) {
        guard let doc=suppliedDocument ?? document as? TextDocument else { return }
        statusRefreshCount+=1
        documentTabs.refresh()
        let editor=activeEditor, info=editor.statusInfo
        if statusRevision != doc.editor.revision && !statusMetricsPending {
            // Capture authoritative bytes once on main; scans/temporary allocations
            // happen off-main. One in-flight task bounds work for rapid edits.
            let revision=doc.editor.revision,text=doc.editor.text
            statusMetricsPending=true
            DispatchQueue.global(qos:.utility).async { [weak self,weak doc] in
                let count=text.unicodeScalars.count
                var cr=false,lf=false,crlf=false,priorCR=false
                for byte in text.utf8 {
                    if byte == 13 {if priorCR {cr=true};priorCR=true}
                    else {if byte == 10 {if priorCR {crlf=true}else{lf=true}} else if priorCR {cr=true};priorCR=false}
                }
                if priorCR {cr=true}
                let endings=[crlf ? "CRLF" : nil,lf ? "LF" : nil,cr ? "CR" : nil].compactMap{$0}
                let eol=endings.count>1 ? "Mixed EOL" : endings.first ?? ""
                DispatchQueue.main.async { [weak self,weak doc] in
                    guard let self else{return};self.statusMetricsPending=false
                    guard let doc,self.document === doc,doc.editor.revision == revision else{return}
                    self.cachedCharacterCount=count;self.cachedEndings=eol;self.statusRevision=revision
                    if self.window?.isVisible == true {self.refreshStatusDetails()}
                }
            }
        }
        let encoding:[FileEncoding:String]=[.utf8:"UTF-8",.utf16LE:"UTF-16 LE",.utf16BE:"UTF-16 BE",.windows1252:"Windows-1252",.latin1:"Latin-1"]
        let language=(NSApp.delegate as? AppDelegate)?.languages.profile(identifier:doc.languageIdentifier)?.title ?? (doc.languageIdentifier == "null" ? "Plain Text" : doc.languageIdentifier)
        let eol=cachedEndings.isEmpty ? ([0:"CRLF",1:"CR",2:"LF"][info["eol"]?.intValue ?? 2] ?? "LF") : cachedEndings
        let indentation=(info["useTabs"]?.boolValue == true ? "Tabs" : "Spaces")+": \(info["tabWidth"]?.intValue ?? 4)"
        var fields=[doc.displayName+(doc.isDocumentEdited ? " *" : ""),"\(doc.editor.bookmarkLines.count) Bookmarks",language,
                    "Ln \(info["line"]?.intValue ?? 1), Col \(info["column"]?.intValue ?? 1)","\(cachedCharacterCount) chars","\(info["lines"]?.intValue ?? 1) lines"]
        let selectionKey="\(ObjectIdentifier(editor))-\(doc.editor.revision)-\(editor.selectionRanges)"
        if cachedSelectionKey != selectionKey {cachedSelectedCount=editor.selectedCharacterCount;cachedSelectionKey=selectionKey}
        var keys=["document","bookmarks","language","position","count","count"]
        if cachedSelectedCount > 0 { fields.append("\(cachedSelectedCount) selected");keys.append("selection") }
        if editor.selectionCount > 1 {fields.append("\(editor.selectionCount) selections");keys.append("selection")}
        fields += [String(format:"Base %g pt",info["fontSize"]?.doubleValue ?? 14),indentation,(encoding[doc.format.encoding] ?? "UTF-8")+(doc.format.bom ? " BOM" : ""),eol,editor.wrap ? "Wrap" : "No Wrap"]
        keys += ["font","indent","encoding","eol","wrap"]
        if editor.readOnly {fields.append("Read Only");keys.append("document")}
        statusDetails.update(fields,keys:keys)
    }
    private func showStatusOptions(_ key:String,at view:NSView) {
        guard let doc=document as? TextDocument else{return}
        let editor=activeEditor, info=editor.statusInfo
        let app=NSApp.delegate as? AppDelegate
        app?.lastDocumentController=self
        let menu=NSMenu();menu.autoenablesItems=false
        func add(_ title:String,_ action:Selector,_ target:AnyObject,_ value:String?=nil,_ checked:Bool=false,_ enabled:Bool=true) {
            let item=NSMenuItem(title:title,action:action,keyEquivalent:"");item.target=target;item.representedObject=value
            item.state=checked ? .on : .off;item.isEnabled=enabled;menu.addItem(item)
        }
        func heading(_ title:String) {let item=NSMenuItem(title:title,action:nil,keyEquivalent:"");item.isEnabled=false;menu.addItem(item)}
        switch key {
        case "encoding":
            heading("Re-read using encoding…")
            let options:[(String,String)]=[("UTF-8","utf8"),("UTF-16 LE","utf16LE"),("UTF-16 BE","utf16BE"),("Latin-1","latin1"),("Windows-1252","windows1252")]
            for (name,code) in options {add(name,#selector(TextDocument.reloadEncoding(_:)),doc,code,doc.format.encoding.rawValue==code,doc.fileURL != nil)}
            menu.addItem(.separator());heading("Convert document encoding (save separately)")
            for (name,code) in [("UTF-8","utf8"),("UTF-8 with BOM","utf8bom"),("UTF-16 LE with BOM","utf16LE"),("UTF-16 BE with BOM","utf16BE"),("Latin-1","latin1"),("Windows-1252","windows1252")] {
                let current=doc.format.encoding == .utf8 && doc.format.bom ? "utf8bom" : doc.format.encoding.rawValue
                add(name,#selector(TextDocument.convertEncoding(_:)),doc,code,current==code,!editor.readOnly)
            }
        case "indent":
            heading("Indentation for this view")
            add("Tabs",#selector(statusOption(_:)),self,"tabs",info["useTabs"]?.boolValue == true)
            add("Spaces",#selector(statusOption(_:)),self,"spaces",info["useTabs"]?.boolValue == false)
            menu.addItem(.separator())
            for n in [2,3,4,8] {add("Width: \(n)",#selector(statusOption(_:)),self,"width.\(n)",info["tabWidth"]?.intValue == n)}
            if let settings=app?.settings {menu.addItem(.separator());add("Default Editor Settings…",#selector(SettingsController.showSettings(_:)),settings)}
        case "eol":
            heading("Convert document line endings")
            for (name,code) in [("LF — Unix / macOS","LF"),("CRLF — Windows","CRLF"),("CR — Classic Mac","CR")] {
                let current=cachedEndings.isEmpty ? [0:"CRLF",1:"CR",2:"LF"][info["eol"]?.intValue ?? 2] : cachedEndings
                add(name,#selector(convertEOL(_:)),self,code,current==code,!editor.readOnly)
            }
        case "wrap":
            add("Wrap Lines",#selector(statusOption(_:)),self,"wrap.on",editor.wrap)
            add("No Wrap",#selector(statusOption(_:)),self,"wrap.off",!editor.wrap)
        case "font":
            heading("Text size for this view")
            add("Larger",#selector(statusOption(_:)),self,"zoomIn")
            add("Smaller",#selector(statusOption(_:)),self,"zoomOut")
            if let languages=app?.languages {menu.addItem(.separator());let languageMenu=languages.menu();if let style=languageMenu.items.first(where:{$0.title == "Syntax Style Settings…"}) {menu.addItem(style.copy() as! NSMenuItem)}}
        case "language":
            if let languages=app?.languages {
                let source=languages.menu()
                for item in source.items where item.representedObject is String {
                    let copy=item.copy() as! NSMenuItem;copy.state=(copy.representedObject as? String)==doc.languageIdentifier ? .on : .off;menu.addItem(copy)
                }
            }
        case "bookmarks":
            for (name,code) in [("Toggle Bookmark on Current Line","bookmarkToggle"),("Next Bookmark","bookmarkNext"),("Previous Bookmark","bookmarkPrevious")] {add(name,#selector(statusOption(_:)),self,code)}
        case "position":
            add("Go to Line…",#selector(statusOption(_:)),self,"goToLine")
        case "document":
            add("Save…",#selector(NSDocument.save(_:)),doc)
            add("Save As…",#selector(NSDocument.saveAs(_:)),doc)
            add("Read Only",#selector(TextDocument.toggleReadOnly(_:)),doc,nil,editor.readOnly)
        default:
            add("Select All",#selector(statusOption(_:)),self,"selectAll")
            add("Clear Selection",#selector(statusOption(_:)),self,"clearSelection")
        }
        menu.popUp(positioning:nil,at:NSPoint(x:0,y:view.bounds.height),in:view)
        refreshStatusDetails()
    }
    @objc private func statusOption(_ sender:NSMenuItem) {
        guard let id=sender.representedObject as? String else{return}
        let editor=activeEditor,info=editor.statusInfo
        switch id {
        case "tabs","spaces":editor.configureTabWidth(info["tabWidth"]?.intValue ?? 4,useTabs:id == "tabs")
        case "wrap.on","wrap.off":editor.wrap=id == "wrap.on"
        case "clearSelection":_ = editor.setSelectionAnchor(editor.selectionCaret,caret:editor.selectionCaret)
        case "goToLine":
            let alert=TTAlert();alert.messageText="Go to Line"
            let input=NSTextField(string:String(info["line"]?.intValue ?? 1));input.frame=NSRect(x:0,y:0,width:240,height:24)
            alert.accessoryView=input;alert.addButton(withTitle:"Go");alert.addButton(withTitle:"Cancel")
            alert.window.initialFirstResponder=input
            guard alert.runModal() == .alertFirstButtonReturn else{return}
            guard editor.window != nil,let line=Int(input.stringValue),line>=1,line<=(editor.statusInfo["lines"]?.intValue ?? 1) else{NSSound.beep();return}
            let text=editor.text,ns=text as NSString
            let breaks=try! NSRegularExpression(pattern:"\\r\\n|\\r|\\n")
            let matches=breaks.matches(in:text,range:NSRange(location:0,length:ns.length))
            guard line == 1 || matches.indices.contains(line-2) else{NSSound.beep();return}
            let offset=line == 1 ? 0 : ns.substring(to:NSMaxRange(matches[line-2].range)).utf8.count
            _ = editor.setSelectionAnchor(offset,caret:offset)
            window?.makeFirstResponder(editor)
        default:
            if id.hasPrefix("width."),let width=Int(id.dropFirst(6)) {editor.configureTabWidth(width,useTabs:info["useTabs"]?.boolValue ?? true)}
            else {(NSApp.delegate as? AppDelegate)?.macros.willExecuteCommand(id,on:editor);editor.executeCommand(id)}
        }
        refreshStatusDetails()
    }
    func toolbarAllowedItemIdentifiers(_ toolbar:NSToolbar)->[NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbarDefaultItemIdentifiers(_ toolbar:NSToolbar)->[NSToolbarItem.Identifier] {
        [.flexibleSpace,.init("TextTank.Automations"),.init("TextTank.CloseTab")]
    }
    func toolbar(_ toolbar:NSToolbar,itemForItemIdentifier identifier:NSToolbarItem.Identifier,willBeInsertedIntoToolbar:Bool)->NSToolbarItem? {
        if identifier.rawValue == "TextTank.CloseTab" {
            let item=NSToolbarItem(itemIdentifier:identifier);item.label="Close Tab";item.paletteLabel="Close Tab"
            let button=NSButton(title:"Close Tab",image:NSImage(systemSymbolName:"xmark",accessibilityDescription:"Close Tab")!,target:self,action:#selector(closeTab(_:)))
            button.bezelStyle = .rounded;button.imagePosition = .imageLeading;button.toolTip="Close this tab (⌘W). Unsaved changes will be reviewed."
            item.view=button;return item
        }
        guard let automations=(NSApp.delegate as? AppDelegate)?.automations else { return nil }
        return identifier.rawValue == "TextTank.Automations" ? automations.makeToolbarItem() : automations.makeToolbarItem(identifier:identifier)
    }
    func refreshAutomationToolbar() {
        guard let toolbar=window?.toolbar else { return }
        while !toolbar.items.isEmpty { toolbar.removeItem(at:0) }
        for (index,id) in toolbarDefaultItemIdentifiers(toolbar).enumerated() { toolbar.insertItem(withItemIdentifier:id,at:index) }
    }
    @objc func closeTab(_ sender:Any?) { window?.performClose(sender) }
    func prepareForClose() {
        statusTimer?.invalidate();statusTimer=nil
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver);self.focusObserver=nil }
        if let automationObserver { NotificationCenter.default.removeObserver(automationObserver);self.automationObserver=nil }
        primaryEditor.onFocus=nil;secondary?.onFocus=nil;secondary?.readOnly=true
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) not used") }
    override func windowDidLoad() { super.windowDidLoad() }
    @objc func command(_ sender:NSMenuItem) {
        guard let id=sender.representedObject as? String else { return }
        if let field=(NSApp.modalWindow ?? NSApp.keyWindow)?.firstResponder as? NSTextView {
            switch id { case "cut": field.cut(nil); case "copy": field.copy(nil); case "paste": field.paste(nil); case "selectAll": field.selectAll(nil); case "undo": field.undoManager?.undo(); case "redo": field.undoManager?.redo(); default: NSSound.beep() }
            return
        }
        let editor=activeEditor
        if id.hasPrefix("transform."),let transform=EditorTransform(rawValue:String(id.dropFirst(10))) {
            (NSApp.delegate as? AppDelegate)?.macros.invalidateRecording(reason:"This text transform is not yet recorded.")
            do {try transform.apply(to:editor)} catch {NSAlert(error:error).runModal()};return
        }
        (NSApp.delegate as? AppDelegate)?.macros.willExecuteCommand(id,on:editor)
        editor.executeCommand(id)
    }
    deinit { statusTimer?.invalidate(); if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }; if let automationObserver { NotificationCenter.default.removeObserver(automationObserver) } }
    @objc func language(_ sender:NSMenuItem) { if let id=sender.representedObject as? String { activeEditor.setLanguage(id); (document as? TextDocument)?.languageIdentifier=id; refreshStatusDetails() } }
    @objc func showFind(_ sender:Any?) { _ = activeEditor; window?.makeFirstResponder(findField) }
    @objc func findNext(_ sender:Any?) { performFind(backwards:false) }
    @objc func findPrevious(_ sender:Any?) { performFind(backwards:true) }
    func performFind(backwards:Bool) {
        let editor=activeEditor;window?.makeFirstResponder(nil)
        let query=findField.stringValue;guard !query.isEmpty else { return }
        if !editor.find(query,matchCase:caseBox.state == .on,backwards:backwards) { NSSound.beep() }
        (NSApp.delegate as? AppDelegate)?.macros.recordFind(text:query,matchCase:caseBox.state == .on,backwards:backwards,editor:editor)
    }
    @objc func replaceSelection(_ sender:Any?) {
        let editor=activeEditor;window?.makeFirstResponder(nil);let text=replaceField.stringValue
        editor.replaceSelection(text); (NSApp.delegate as? AppDelegate)?.macros.recordReplace(text:text,editor:editor)
    }
    @objc func clone(_ sender:Any?) { guard secondary == nil else { return }; let clone=TTEditor(frame:split.bounds); clone.shareDocument(with:primaryEditor); clone.readOnly=primaryEditor.readOnly; if let app=NSApp.delegate as? AppDelegate,let doc=document as? TextDocument { app.settings.apply(to:clone);clone.menu=app.automations.contextMenu();_ = app.languages.apply(identifier:doc.languageIdentifier,to:clone) }; secondary=clone;clone.onFocus = { [weak self, weak clone] in guard let clone else { return };self?.lastEditor=clone;(NSApp.delegate as? AppDelegate)?.lastDocumentController=self;(NSApp.delegate as? AppDelegate)?.macros.editorDidFocus(clone) };split.addArrangedSubview(clone);split.adjustSubviews();split.layoutSubtreeIfNeeded();clone.layoutSubtreeIfNeeded();window?.makeFirstResponder(clone) }
    @objc func closeSplit(_ sender:Any?) { lastEditor=primaryEditor; window?.makeFirstResponder(primaryEditor); secondary?.removeFromSuperview(); secondary=nil }
    @objc func toggleWrap(_ sender:Any?) { activeEditor.wrap.toggle() }
    @objc func comment(_ sender:NSMenuItem) {
        guard let raw=sender.representedObject as? String,let command=CommentCommand(rawValue:raw),let app=NSApp.delegate as? AppDelegate,let document=document as? TextDocument,let profile=app.languages.profile(identifier:document.languageIdentifier) else {NSSound.beep();return}
        app.macros.invalidateRecording(reason:"Language-specific comments are not yet recorded.")
        do {try command.apply(to:activeEditor,profile:profile)}catch{NSAlert(error:error).runModal()}
    }
    @objc func columnInsert(_ sender:Any?) {
        let editor=activeEditor;let revision=editor.revision,selections=editor.selectionRanges
        let alert=TTAlert();alert.messageText="Insert into Each Selection";alert.informativeText="Use Option-drag for a rectangle or add multiple carets. Text replaces each selected range; numbering follows selection order."
        let text=NSTextField(string:"");text.placeholderString="Text to insert"
        let number=NSButton(checkboxWithTitle:"Insert sequential numbers",target:nil,action:nil)
        let start=NSTextField(string:"1"),step=NSTextField(string:"1")
        let stack=NSStackView(views:[text,number,NSTextField(labelWithString:"Start"),start,NSTextField(labelWithString:"Increment"),step]);stack.orientation = .vertical;stack.alignment = .leading;stack.frame=NSRect(x:0,y:0,width:400,height:180)
        alert.accessoryView=stack;alert.addButton(withTitle:"Insert");alert.addButton(withTitle:"Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else{return}
        var values=Array(repeating:text.stringValue,count:editor.selectionCount)
        if number.state == .on {
            guard let first=Int(start.stringValue),let increment=Int(step.stringValue) else {NSSound.beep();return}
            values=[];var value=first
            for i in 0..<editor.selectionCount { values.append(String(value));if i+1<editor.selectionCount { let(next,overflow)=value.addingReportingOverflow(increment);guard !overflow else {NSSound.beep();return};value=next } }
        }
        (NSApp.delegate as? AppDelegate)?.macros.invalidateRecording(reason:"Column insertion is not yet recorded.")
        if !Self.applyColumn(values,to:editor,revision:revision,selections:selections) {let error=TTAlert();error.messageText="Selections changed or are not writable";error.informativeText="No column insertion was applied.";error.runModal()}
    }
    static func applyColumn(_ values:[String],to editor:TTEditor,revision:UInt,selections:[[String:NSNumber]])->Bool {
        guard editor.window != nil,editor.selectionRanges==selections else{return false}
        return editor.replaceSelections(values,expectedRevision:revision)
    }
    @objc func convertEOL(_ sender:NSMenuItem) {
        guard let mode=sender.representedObject as? String else { return }
        (NSApp.delegate as? AppDelegate)?.macros.invalidateRecording(reason:"Line-ending conversion is not yet recorded.")
        activeEditor.convertLineEndings(mode)
    }
}
