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
    lazy var macros = MacroController(editorProvider: { (NSApp.mainWindow?.windowController as? EditorWindowController)?.activeEditor })
    lazy var automations = AutomationController(editorProvider: { [weak self] in
        self?.macros.invalidateRecording(reason:"An automation was invoked during macro recording. Automation side effects are not recorded.")
        return (NSApp.mainWindow?.windowController as? EditorWindowController)?.activeEditor
    }, newDocument: { text in
        let doc = TextDocument(); NSDocumentController.shared.addDocument(doc); doc.makeWindowControllers(); doc.editor.text=text; doc.showWindows(); doc.windowControllers.first?.window?.makeFirstResponder(doc.editor)
    })
    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenus()
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
        item(app, "About TextTank", #selector(about)); app.addItem(.separator()); item(app, "Quit TextTank", #selector(NSApplication.terminate(_:)), "q")
        let file = menu("File")
        item(file, "New", #selector(newDocument(_:)), "n")
        item(file, "Open…", #selector(NSDocumentController.openDocument(_:)), "o")
        item(file, "Save", #selector(NSDocument.save(_:)), "s")
        item(file, "Save As…", #selector(NSDocument.saveAs(_:)), "S")
        item(file,"Save Copy…",#selector(TextDocument.saveCopy(_:)))
        item(file,"Save All",#selector(NSDocumentController.saveAllDocuments(_:)))
        item(file, "Revert to Saved…", #selector(NSDocument.revertToSaved(_:)))
        item(file, "Close", #selector(NSWindow.performClose(_:)), "w")
        file.addItem(.separator())
        item(file,"Page Setup…",#selector(NSDocument.runPageLayout(_:)))
        item(file,"Print…",#selector(NSDocument.printDocument(_:)),"p")
        let saveSession=NSMenuItem(title:"Save Session Snapshot…",action:#selector(WorkspaceController.saveSession(_:)),keyEquivalent:"");saveSession.target=workspace;file.addItem(saveSession)
        let openSession=NSMenuItem(title:"Open Session Snapshot…",action:#selector(WorkspaceController.openSession(_:)),keyEquivalent:"");openSession.target=workspace;file.addItem(openSession)
        let encoding = menu("Encoding")
        for (title,code) in [("UTF-8","utf8"),("UTF-8 with BOM","utf8bom"),("UTF-16 LE with BOM","utf16LE"),("UTF-16 BE with BOM","utf16BE"),("Windows-1252","windows1252"),("ISO-8859-1","latin1")] { item(encoding,"Convert to \(title)",#selector(TextDocument.convertEncoding(_:)),"",code) }
        let edit = menu("Edit")
        for (label,id,key) in [("Undo","undo","z"),("Redo","redo","Z"),("Cut","cut","x"),("Copy","copy","c"),("Paste","paste","v"),("Select All","selectAll","a"),("Duplicate Line","duplicateLine","d"),("Delete Line","deleteLine",""),("Transpose Lines","transposeLine",""),("Indent","indent","]"),("Unindent","unindent","["),("Uppercase","upper",""),("Lowercase","lower","")] {
            let nativeActions:[String:Selector]=["undo":NSSelectorFromString("undo:"),"redo":NSSelectorFromString("redo:"),"cut":#selector(NSText.cut(_:)),"copy":#selector(NSText.copy(_:)),"paste":#selector(NSText.paste(_:)),"selectAll":#selector(NSText.selectAll(_:))]
            item(edit,label,nativeActions[id] ?? #selector(EditorWindowController.command(_:)),key,id)
        }
        let search = menu("Search"); item(search,"Find and Replace…",#selector(EditorWindowController.showFind(_:)),"f"); item(search,"Find Next",#selector(EditorWindowController.findNext(_:)),"g"); item(search,"Find Previous",#selector(EditorWindowController.findPrevious(_:)),"G")
        let view = menu("View"); item(view,"Clone in Split View",#selector(EditorWindowController.clone(_:))); item(view,"Close Split View",#selector(EditorWindowController.closeSplit(_:))); item(view,"Wrap Lines",#selector(EditorWindowController.toggleWrap(_:))); item(view,"Zoom In",#selector(EditorWindowController.command(_:)),"+","zoomIn"); item(view,"Zoom Out",#selector(EditorWindowController.command(_:)),"-","zoomOut")
        for (label,id) in [("Move Line Up","moveLineUp"),("Move Line Down","moveLineDown"),("Join Selected Lines","joinLines"),("Trim Trailing Whitespace","trimTrailing"),("Toggle Overtype","toggleOvertype")] { item(edit,label,#selector(EditorWindowController.command(_:)),"",id) }
        for (label,id) in [("Fold All","foldAll"),("Unfold All","unfoldAll"),("Show Whitespace","showWhitespace"),("Show Line Endings","toggleEOL"),("Show Line Numbers","toggleLineNumbers")] { item(view,label,#selector(EditorWindowController.command(_:)),"",id) }
        for (label,id) in [("Matching Brace","gotoMatchingBrace"),("Select to Matching Brace","selectMatchingBrace"),("Toggle Bookmark","bookmarkToggle"),("Next Bookmark","bookmarkNext"),("Previous Bookmark","bookmarkPrevious")] { item(search,label,#selector(EditorWindowController.command(_:)),"",id) }
        let language = menu("Language")
        for (label,id) in [("Plain Text","null"),("C / C++","cpp"),("Python","python"),("JSON","json"),("HTML","hypertext"),("SQL","sql"),("Markdown","markdown"),("Swift","swift"),("Rust","rust"),("YAML","yaml")] { item(language,label,#selector(EditorWindowController.language(_:)),"",id) }
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
        windowControllers.compactMap { $0 as? EditorWindowController }.forEach { $0.prepareForClose() }
        // NSDocument only reaches close after the user has chosen Save or Discard.
        try? Self.recovery.remove(id:recoveryID,throughRevision:recoveryBase+UInt64(editor.revision))
        super.close()
    }
    override class var autosavesInPlace: Bool { false }
    override func makeWindowControllers() { addWindowController(EditorWindowController(document: self)) }
    override func read(from data: Data, ofType typeName: String) throws {
        let decoded = try FileCodec.decode(data)
        (NSApp.delegate as? AppDelegate)?.macros.editorWillReset(editor,reason:"The recording document was reloaded.")
        loading = true; defer { loading = false }
        editor.text = decoded.text; editor.resetUndoHistory(); format = decoded.format; savedFormat=format; diskBytes = data; editor.setSavePoint()
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
            let current = try Data(contentsOf: url)
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
            self?.lastEditor=editor;(NSApp.delegate as? AppDelegate)?.macros.editorDidFocus(editor)
        }
        if let app=NSApp.delegate as? AppDelegate {
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
        primaryEditor.onFocus=nil;secondary?.onFocus=nil
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
        (NSApp.delegate as? AppDelegate)?.macros.willExecuteCommand(id,on:editor)
        editor.executeCommand(id)
    }
    deinit { if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }; if let automationObserver { NotificationCenter.default.removeObserver(automationObserver) } }
    @objc func language(_ sender:NSMenuItem) { if let id=sender.representedObject as? String { activeEditor.setLanguage(id); (document as? TextDocument)?.languageIdentifier=id; status.stringValue="\(id) · INCOMPLETE PREVIEW" } }
    @objc func showFind(_ sender:Any?) { _ = activeEditor; window?.makeFirstResponder(findField) }
    @objc func findNext(_ sender:Any?) { performFind(backwards:false) }
    @objc func findPrevious(_ sender:Any?) { performFind(backwards:true) }
    func performFind(backwards:Bool) {
        let query=findField.currentEditor()?.string ?? findField.stringValue;guard !query.isEmpty else { return }
        let editor=activeEditor
        if !editor.find(query,matchCase:caseBox.state == .on,backwards:backwards) { NSSound.beep() }
        (NSApp.delegate as? AppDelegate)?.macros.recordFind(text:query,matchCase:caseBox.state == .on,backwards:backwards,editor:editor)
    }
    @objc func replaceSelection(_ sender:Any?) {
        let text=replaceField.currentEditor()?.string ?? replaceField.stringValue;let editor=activeEditor
        editor.replaceSelection(text); (NSApp.delegate as? AppDelegate)?.macros.recordReplace(text:text,editor:editor)
    }
    @objc func clone(_ sender:Any?) { guard secondary == nil else { return }; let clone=TTEditor(frame:split.bounds); clone.shareDocument(with:primaryEditor); secondary=clone;clone.onFocus = { [weak self, weak clone] in guard let clone else { return };self?.lastEditor=clone;(NSApp.delegate as? AppDelegate)?.macros.editorDidFocus(clone) };split.addArrangedSubview(clone);split.adjustSubviews();split.layoutSubtreeIfNeeded();clone.layoutSubtreeIfNeeded();window?.makeFirstResponder(clone) }
    @objc func closeSplit(_ sender:Any?) { lastEditor=primaryEditor; window?.makeFirstResponder(primaryEditor); secondary?.removeFromSuperview(); secondary=nil }
    @objc func toggleWrap(_ sender:Any?) { activeEditor.wrap.toggle() }
}
