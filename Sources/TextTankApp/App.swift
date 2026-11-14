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
        let window = menu("Window"); NSApp.windowsMenu = window; item(window,"Minimize",#selector(NSWindow.performMiniaturize(_:)),"m"); item(window,"Zoom",#selector(NSWindow.performZoom(_:)))
    }
    private func restoreRecovery() {
        do {
            let scan = try TextDocument.recovery.scan()
            let snapshots = scan.snapshots
            if !scan.issues.isEmpty { let warning=NSAlert();warning.messageText="Some recovery files need review";warning.informativeText=scan.issues.map { $0.url.lastPathComponent+": "+$0.message }.joined(separator:"\n");warning.runModal() }
            guard !snapshots.isEmpty else { return }
            let alert=NSAlert(); alert.messageText="Recover unsaved documents?"; alert.informativeText="Found \(snapshots.count) recovery snapshots. Recovered content opens as new unsaved documents; original files are not changed.";alert.addButton(withTitle:"Recover");alert.addButton(withTitle:"Later")
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
    let editor = TTEditor(frame: NSRect(x:0,y:0,width:900,height:600))
    var savedFormat = FileFormat(encoding:.utf8,bom:false)
    var format = FileFormat(encoding: .utf8, bom: false) {
        didSet { if !loading && format != oldValue { recoveryBase += 1; updateChangeCount(format != savedFormat || editor.modified ? .changeDone : .changeCleared) } }
    }
    private var diskBytes: Data?
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
            let state=try diskState(); let alert=NSAlert()
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
            let alert=NSAlert();alert.messageText="Discard unsaved changes and reload?";alert.informativeText="The disk bytes will be interpreted as \(raw). Use Convert to change the save encoding while keeping your text."
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
            self.updateChangeCount(self.editor.modified || self.format != self.savedFormat ? .changeDone : .changeCleared)
            self.recoveryTimer?.invalidate()
            self.recoveryTimer=Timer.scheduledTimer(withTimeInterval:0.5,repeats:false) { [weak self] _ in self?.flushRecovery() }
        }
    }
    func flushRecovery() {
        do {
            if isDocumentEdited || editor.modified || format != savedFormat {
                try Self.recovery.save(RecoverySnapshot(id:recoveryID,text:editor.text,format:format,originalURL:fileURL?.absoluteString,revision:recoveryBase+UInt64(editor.revision)))
            } else { try Self.recovery.remove(id:recoveryID,throughRevision:recoveryBase+UInt64(editor.revision)) }
        } catch { windowControllers.compactMap { $0 as? EditorWindowController }.forEach { $0.status.stringValue="Recovery failed: \(error.localizedDescription)" } }
    }
    override func close() {
        (NSApp.delegate as? AppDelegate)?.macros.editorWillReset(editor,reason:"The recording document was closed.")
        recoveryTimer?.invalidate()
        editor.readOnly=true
        windowControllers.compactMap { $0 as? EditorWindowController }.forEach { $0.prepareForClose() }
        // NSDocument only reaches close after the user has chosen Save or Discard.
        try? Self.recovery.remove(id:recoveryID,throughRevision:recoveryBase+UInt64(editor.revision))
        super.close()
    }
    override class var autosavesInPlace: Bool { false }
    override func makeWindowControllers() { addWindowController(EditorWindowController(document: self)) }
    override func read(from data: Data, ofType typeName: String) throws {
        let decoded = try FileCodec.decode(data)
        loadDecoded(decoded,bytes:data)
    }
    private func loadDecoded(_ decoded:DecodedFile,bytes:Data) {
        (NSApp.delegate as? AppDelegate)?.macros.editorWillReset(editor,reason:"The recording document was reloaded.")
        loading=true
        let locked=editor.readOnly;editor.readOnly=false
        editor.text=decoded.text;editor.resetUndoHistory();format=decoded.format;savedFormat=format;diskBytes=bytes;editor.setSavePoint()
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
        do { _ = try FileCodec.encode(editor.text,format:target); format=target; flushRecovery(); windowControllers.compactMap { $0 as? EditorWindowController }.forEach { $0.status.stringValue="\(code) · INCOMPLETE PREVIEW" } }
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
    override func data(ofType typeName: String) throws -> Data { try FileCodec.encode(editor.text, format: format) }
    override func writeSafely(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) throws {
        if url == fileURL, let diskBytes {
            let current = try WorkspaceStore.readRegularFile(url,maximumBytes:Int.max)
            guard current == diskBytes else { throw NSError(domain:"TextTank",code:1,userInfo:[NSLocalizedDescriptionKey:"The file changed outside TextTank. Use Save As to preserve your edits, or revert to inspect the disk version."]) }
        }
        try super.writeSafely(to:url,ofType:typeName,for:saveOperation)
        if saveOperation != .saveToOperation { diskBytes = try Data(contentsOf:url); savedFormat=format; editor.setSavePoint(); updateChangeCount(.changeCleared); flushRecovery() }
    }

}

final class EditorWindowController: NSWindowController, NSToolbarDelegate {
    let split = NSSplitView()
    let findField = NSSearchField()
    let replaceField = NSTextField()
    let caseBox = NSButton(checkboxWithTitle:"Match case",target:nil,action:nil)
    let status = NSTextField(labelWithString:"UTF-8 · INCOMPLETE PREVIEW")
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
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1080,height:720),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
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
        window.title = "TextTank"; window.center(); window.tabbingMode = .preferred
        window.titleVisibility = .visible; window.titlebarAppearsTransparent = false
        for button in [NSWindow.ButtonType.closeButton,.miniaturizeButton,.zoomButton] { window.standardWindowButton(button)?.isHidden = false }
        window.contentMinSize=NSSize(width:800,height:500)
        let root = NSView(frame:NSRect(origin:.zero,size:window.contentLayoutRect.size)); window.contentView = root
        split.isVertical = true; split.dividerStyle = .thin; split.addArrangedSubview(document.editor)
        findField.placeholderString = "Find literal text"; replaceField.placeholderString = "Replace with"
        let findButton = NSButton(title:"Next",target:self,action:#selector(findNext(_:)))
        let replaceButton = NSButton(title:"Replace Selection",target:self,action:#selector(replaceSelection(_:)))
        let search = NSStackView(views:[findField,replaceField,caseBox,findButton,replaceButton]); search.spacing = 8
        [search,split,status].forEach { $0.translatesAutoresizingMaskIntoConstraints=false;root.addSubview($0) }
        NSLayoutConstraint.activate([split.heightAnchor.constraint(greaterThanOrEqualToConstant:200),search.topAnchor.constraint(equalTo:root.topAnchor,constant:10),search.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:12),search.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-12),findField.widthAnchor.constraint(greaterThanOrEqualToConstant:200),replaceField.widthAnchor.constraint(greaterThanOrEqualToConstant:160),split.topAnchor.constraint(equalTo:search.bottomAnchor,constant:10),split.leadingAnchor.constraint(equalTo:root.leadingAnchor),split.trailingAnchor.constraint(equalTo:root.trailingAnchor),split.bottomAnchor.constraint(equalTo:status.topAnchor,constant:-6),status.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:12),status.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-6)])
        status.font = .systemFont(ofSize:11); status.textColor = .secondaryLabelColor
    }
    func toolbarAllowedItemIdentifiers(_ toolbar:NSToolbar)->[NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbarDefaultItemIdentifiers(_ toolbar:NSToolbar)->[NSToolbarItem.Identifier] {
        ((NSApp.delegate as? AppDelegate)?.automations.toolbarIdentifiers() ?? []) + [.flexibleSpace,.init("TextTank.Automations"),.init("TextTank.CloseTab")]
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
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver);self.focusObserver=nil }
        if let automationObserver { NotificationCenter.default.removeObserver(automationObserver);self.automationObserver=nil }
        primaryEditor.onFocus=nil;secondary?.onFocus=nil;secondary?.readOnly=true
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) not used") }
    override func windowDidLoad() { super.windowDidLoad() }
    @objc func command(_ sender:NSMenuItem) {
        guard let id=sender.representedObject as? String else { return }
        if let field=NSApp.keyWindow?.firstResponder as? NSTextView {
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
    deinit { if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }; if let automationObserver { NotificationCenter.default.removeObserver(automationObserver) } }
    @objc func language(_ sender:NSMenuItem) { if let id=sender.representedObject as? String { activeEditor.setLanguage(id); (document as? TextDocument)?.languageIdentifier=id; status.stringValue="\(id) · INCOMPLETE PREVIEW" } }
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
        let alert=NSAlert();alert.messageText="Insert into Each Selection";alert.informativeText="Use Option-drag for a rectangle or add multiple carets. Text replaces each selected range; numbering follows selection order."
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
        if !Self.applyColumn(values,to:editor,revision:revision,selections:selections) {let error=NSAlert();error.messageText="Selections changed or are not writable";error.informativeText="No column insertion was applied.";error.runModal()}
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
