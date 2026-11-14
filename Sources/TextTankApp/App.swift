import AppKit
func startupTrace(_ message:String) {
    let url=URL(fileURLWithPath:"/tmp/TextTank-startup.log")
    let line="\(Date()) pid=\(ProcessInfo.processInfo.processIdentifier) \(message)\n"
    if !FileManager.default.fileExists(atPath:url.path) { FileManager.default.createFile(atPath:url.path,contents:nil) }
    if let handle=try? FileHandle(forWritingTo:url) { handle.seekToEndOfFile();handle.write(Data(line.utf8));try? handle.close() }
}

#if !TESTING
@main
struct TextTankMain {
    static func main() {
        startupTrace("main before shared")
        let app = NSApplication.shared
        startupTrace("main after shared")
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        _ = NSDocumentController.shared
        startupTrace("before run")
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

#endif

final class AppDelegate: NSObject, NSApplicationDelegate {
    lazy var automations = AutomationController(editorProvider: { (NSApp.mainWindow?.windowController as? EditorWindowController)?.activeEditor }, newDocument: { text in
        let doc = TextDocument(); NSDocumentController.shared.addDocument(doc); doc.makeWindowControllers(); doc.editor.text=text; doc.showWindows()
    })
    func applicationDidFinishLaunching(_ notification: Notification) {
        startupTrace("didFinish before menus")
        buildMenus()
        startupTrace("didFinish after menus")
        startupTrace("before recovery docs=\(NSDocumentController.shared.documents.count) windows=\(NSApp.windows.count)")
        NSApp.activate(ignoringOtherApps: true)
        if NSDocumentController.shared.documents.isEmpty { newDocument(nil) }
        else { for document in NSDocumentController.shared.documents { if document.windowControllers.isEmpty { document.makeWindowControllers() }; document.showWindows() } }
        startupTrace("before recovery scan")
        restoreRecovery()
        startupTrace("finished launch windows=\(NSApp.windows.map { "\($0.title):\($0.isVisible):\($0.frame)" })")
    }
    @objc func newDocument(_ sender:Any?) {
        startupTrace("new before document")
        let doc=TextDocument(); startupTrace("new after document"); NSDocumentController.shared.addDocument(doc);doc.makeWindowControllers(); startupTrace("new after controller");doc.showWindows(); startupTrace("new shown")
        doc.windowControllers.first?.window?.makeFirstResponder(doc.editor)
    }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        NSDocumentController.shared.reviewUnsavedDocuments(withAlertTitle: "Quit TextTank?", cancellable: true, delegate: self, didReviewAllSelector: #selector(reviewed(_:didReviewAll:contextInfo:)), contextInfo: nil)
        return .terminateLater
    }
    @objc func reviewed(_ controller: NSDocumentController, didReviewAll: Bool, contextInfo: UnsafeMutableRawPointer?) { NSApp.reply(toApplicationShouldTerminate: didReviewAll) }
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
        item(file, "Revert to Saved…", #selector(NSDocument.revertToSaved(_:)))
        item(file, "Close", #selector(NSWindow.performClose(_:)), "w")
        let edit = menu("Edit")
        for (label,id,key) in [("Undo","undo","z"),("Redo","redo","Z"),("Cut","cut","x"),("Copy","copy","c"),("Paste","paste","v"),("Select All","selectAll","a"),("Duplicate Line","duplicateLine","d"),("Delete Line","deleteLine",""),("Transpose Lines","transposeLine",""),("Indent","indent","]"),("Unindent","unindent","["),("Uppercase","upper",""),("Lowercase","lower","")] {
            item(edit,label,#selector(EditorWindowController.command(_:)),key,id)
        }
        let search = menu("Search"); item(search,"Find and Replace…",#selector(EditorWindowController.showFind(_:)),"f"); item(search,"Find Next",#selector(EditorWindowController.findNext(_:)),"g"); item(search,"Find Previous",#selector(EditorWindowController.findPrevious(_:)),"G")
        let view = menu("View"); item(view,"Clone in Split View",#selector(EditorWindowController.clone(_:))); item(view,"Close Split View",#selector(EditorWindowController.closeSplit(_:))); item(view,"Wrap Lines",#selector(EditorWindowController.toggleWrap(_:))); item(view,"Zoom In",#selector(EditorWindowController.command(_:)),"+","zoomIn"); item(view,"Zoom Out",#selector(EditorWindowController.command(_:)),"-","zoomOut")
        for (label,id) in [("Move Line Up","moveLineUp"),("Move Line Down","moveLineDown"),("Join Selected Lines","joinLines"),("Trim Trailing Whitespace","trimTrailing"),("Toggle Overtype","toggleOvertype")] { item(edit,label,#selector(EditorWindowController.command(_:)),"",id) }
        for (label,id) in [("Fold All","foldAll"),("Unfold All","unfoldAll"),("Show Whitespace","showWhitespace"),("Show Line Endings","toggleEOL"),("Show Line Numbers","toggleLineNumbers")] { item(view,label,#selector(EditorWindowController.command(_:)),"",id) }
        for (label,id) in [("Matching Brace","gotoMatchingBrace"),("Select to Matching Brace","selectMatchingBrace"),("Toggle Bookmark","bookmarkToggle"),("Next Bookmark","bookmarkNext"),("Previous Bookmark","bookmarkPrevious")] { item(search,label,#selector(EditorWindowController.command(_:)),"",id) }
        let language = menu("Language")
        for (label,id) in [("Plain Text","null"),("C / C++","cpp"),("Python","python"),("JSON","json"),("HTML","hypertext"),("SQL","sql"),("Markdown","markdown"),("Swift","swift"),("Rust","rust"),("YAML","yaml")] { item(language,label,#selector(EditorWindowController.language(_:)),"",id) }
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
                let doc=TextDocument(); doc.recoveryID=snapshot.id; doc.recoveryBase=snapshot.revision+1; doc.format=snapshot.format
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
    var format = FileFormat(encoding: .utf8, bom: false)
    private var diskBytes: Data?
    private var loading = false
    override init() {
        super.init()
        hasUndoManager = false
        editor.onChange = { [weak self] in
            guard let self, !self.loading else { return }
            self.updateChangeCount(self.editor.modified ? .changeDone : .changeCleared)
            self.recoveryTimer?.invalidate()
            self.recoveryTimer=Timer.scheduledTimer(withTimeInterval:0.5,repeats:false) { [weak self] _ in self?.flushRecovery() }
        }
    }
    func flushRecovery() {
        do {
            if editor.modified {
                try Self.recovery.save(RecoverySnapshot(id:recoveryID,text:editor.text,format:format,originalURL:fileURL?.absoluteString,revision:recoveryBase+UInt64(editor.revision)))
            } else { try Self.recovery.remove(id:recoveryID,throughRevision:recoveryBase+UInt64(editor.revision)) }
        } catch { windowControllers.compactMap { $0 as? EditorWindowController }.forEach { $0.status.stringValue="Recovery failed: \(error.localizedDescription)" } }
    }
    override func close() {
        recoveryTimer?.invalidate()
        // NSDocument only reaches close after the user has chosen Save or Discard.
        try? Self.recovery.remove(id:recoveryID,throughRevision:recoveryBase+UInt64(editor.revision))
        super.close()
    }
    override class var autosavesInPlace: Bool { false }
    override func makeWindowControllers() { addWindowController(EditorWindowController(document: self)) }
    override func read(from data: Data, ofType typeName: String) throws {
        let decoded = try FileCodec.decode(data)
        loading = true; defer { loading = false }
        editor.text = decoded.text; editor.resetUndoHistory(); format = decoded.format; diskBytes = data; editor.setSavePoint()
    }
    override func data(ofType typeName: String) throws -> Data { try FileCodec.encode(editor.text, format: format) }
    override func writeSafely(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) throws {
        if url == fileURL, let diskBytes {
            let current = try Data(contentsOf: url)
            guard current == diskBytes else { throw NSError(domain:"TextTank",code:1,userInfo:[NSLocalizedDescriptionKey:"The file changed outside TextTank. Use Save As to preserve your edits, or revert to inspect the disk version."]) }
        }
        try super.writeSafely(to:url,ofType:typeName,for:saveOperation)
        if saveOperation != .saveToOperation { diskBytes = try Data(contentsOf:url); editor.setSavePoint(); flushRecovery() }
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
    var textDocument: TextDocument { document as! TextDocument }
    var activeEditor: TTEditor {
        if let secondary, let responder = window?.firstResponder as? NSView, responder.isDescendant(of: secondary) { lastEditor=secondary; return secondary }
        if let responder=window?.firstResponder as? NSView, responder.isDescendant(of:textDocument.editor) { lastEditor=textDocument.editor }
        return lastEditor ?? textDocument.editor
    }
    init(document: TextDocument) {
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1080,height:720),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        super.init(window:window)
        self.document = document
        lastEditor = document.editor
        document.editor.onFocus = { [weak self, weak document] in self?.lastEditor=document?.editor }
        if let app=NSApp.delegate as? AppDelegate {
            document.editor.menu=app.automations.contextMenu()
            let toolbar=NSToolbar(identifier:"TextTankToolbar");toolbar.delegate=self;window.toolbar=toolbar
        }
        focusObserver = NotificationCenter.default.addObserver(forName:NSWindow.didUpdateNotification,object:window,queue:.main) { [weak self] _ in _ = self?.activeEditor }
        window.title = "TextTank"; window.center(); window.tabbingMode = .preferred
        let root = NSView(); window.contentView = root
        split.isVertical = true; split.dividerStyle = .thin; split.addArrangedSubview(document.editor)
        findField.placeholderString = "Find literal text"; replaceField.placeholderString = "Replace with"
        let findButton = NSButton(title:"Next",target:self,action:#selector(findNext(_:)))
        let replaceButton = NSButton(title:"Replace Selection",target:self,action:#selector(replaceSelection(_:)))
        let search = NSStackView(views:[findField,replaceField,caseBox,findButton,replaceButton]); search.spacing = 8
        [search,split,status].forEach { $0.translatesAutoresizingMaskIntoConstraints=false;root.addSubview($0) }
        NSLayoutConstraint.activate([search.topAnchor.constraint(equalTo:root.topAnchor,constant:10),search.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:12),search.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-12),findField.widthAnchor.constraint(greaterThanOrEqualToConstant:200),replaceField.widthAnchor.constraint(greaterThanOrEqualToConstant:160),split.topAnchor.constraint(equalTo:search.bottomAnchor,constant:10),split.leadingAnchor.constraint(equalTo:root.leadingAnchor),split.trailingAnchor.constraint(equalTo:root.trailingAnchor),split.bottomAnchor.constraint(equalTo:status.topAnchor,constant:-6),status.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:12),status.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-6)])
        status.font = .systemFont(ofSize:11); status.textColor = .secondaryLabelColor
    }
    func toolbarAllowedItemIdentifiers(_ toolbar:NSToolbar)->[NSToolbarItem.Identifier] { [.init("TextTank.Automations"),.flexibleSpace] }
    func toolbarDefaultItemIdentifiers(_ toolbar:NSToolbar)->[NSToolbarItem.Identifier] { [.flexibleSpace,.init("TextTank.Automations")] }
    func toolbar(_ toolbar:NSToolbar,itemForItemIdentifier identifier:NSToolbarItem.Identifier,willBeInsertedIntoToolbar:Bool)->NSToolbarItem? { (NSApp.delegate as? AppDelegate)?.automations.makeToolbarItem() }
    required init?(coder:NSCoder) { fatalError("init(coder:) not used") }
    override func windowDidLoad() { super.windowDidLoad() }
    @objc func command(_ sender:NSMenuItem) {
        guard let id=sender.representedObject as? String else { return }
        if let field=NSApp.keyWindow?.firstResponder as? NSTextView {
            switch id { case "cut": field.cut(nil); case "copy": field.copy(nil); case "paste": field.paste(nil); case "selectAll": field.selectAll(nil); case "undo": field.undoManager?.undo(); case "redo": field.undoManager?.redo(); default: NSSound.beep() }
            return
        }
        activeEditor.executeCommand(id)
    }
    deinit { if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) } }
    @objc func language(_ sender:NSMenuItem) { if let id=sender.representedObject as? String { activeEditor.setLanguage(id); status.stringValue="\(id) · INCOMPLETE PREVIEW" } }
    @objc func showFind(_ sender:Any?) { _ = activeEditor; window?.makeFirstResponder(findField) }
    @objc func findNext(_ sender:Any?) { performFind(backwards:false) }
    @objc func findPrevious(_ sender:Any?) { performFind(backwards:true) }
    func performFind(backwards:Bool) { guard !findField.stringValue.isEmpty else { return }; if !activeEditor.find(findField.stringValue,matchCase:caseBox.state == .on,backwards:backwards) { NSSound.beep() } }
    @objc func replaceSelection(_ sender:Any?) { activeEditor.replaceSelection(replaceField.stringValue) }
    @objc func clone(_ sender:Any?) { guard secondary == nil else { return }; let clone=TTEditor(frame:split.bounds); clone.shareDocument(with:textDocument.editor); secondary=clone;clone.onFocus = { [weak self, weak clone] in self?.lastEditor=clone };split.addArrangedSubview(clone);split.adjustSubviews() }
    @objc func closeSplit(_ sender:Any?) { lastEditor=textDocument.editor; window?.makeFirstResponder(textDocument.editor); secondary?.removeFromSuperview(); secondary=nil }
    @objc func toggleWrap(_ sender:Any?) { activeEditor.wrap.toggle() }
}
