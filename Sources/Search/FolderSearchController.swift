// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// Coalesces worker progress before scheduling main-thread work.
private final class FolderProgressGate: @unchecked Sendable {
    private let lock=NSLock()
    private var last=Date.distantPast
    func admit()->Bool {
        lock.lock();defer{lock.unlock()}
        let now=Date();guard now.timeIntervalSince(last)>=0.1 else{return false};last=now;return true
    }
}

final class FolderSearchController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let queryField=NSTextField(),extensionField=NSTextField()
    let caseButton=NSButton(checkboxWithTitle:"Match case",target:nil,action:nil)
    let recursiveButton=NSButton(checkboxWithTitle:"Include subfolders",target:nil,action:nil)
    let folderLabel=NSTextField(labelWithString:"Choose a folder to search")
    let status=NSTextField(labelWithString:"Literal search · UTF-8/UTF-16 · hidden files and symlinks skipped")
    let table=NSTableView(),details=NSTextView()
    private var folder:URL?
    private var matches:[FolderSearchMatch]=[]
    private var searchedQuery="",searchedCase=true
    private var generation=UUID()
    private var cancellation:FolderSearchCancellation?
    private var work:Task<Void,Never>?
    private var searchButton:NSButton!,cancelButton:NSButton!

    init() {
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:960,height:620),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        super.init(window:window);window.title="Find in Folder — Literal Search";window.delegate=self;window.isReleasedWhenClosed=false
        window.minSize=NSSize(width:760,height:480)
        let choose=NSButton(title:"Choose Folder…",target:self,action:#selector(chooseFolder(_:)))
        searchButton=NSButton(title:"Search",target:self,action:#selector(startSearch(_:)))
        cancelButton=NSButton(title:"Cancel Search",target:self,action:#selector(cancelSearch(_:)));cancelButton.isEnabled=false
        queryField.placeholderString="Literal text (not a regular expression)";extensionField.placeholderString="Extensions: txt, swift (blank = all)"
        queryField.target=self;queryField.action=#selector(startSearch(_:));recursiveButton.state = .on;caseButton.state = .on
        folderLabel.lineBreakMode = .byTruncatingMiddle
        let location=NSStackView(views:[choose,folderLabel])
        let options=NSStackView(views:[caseButton,recursiveButton,extensionField,searchButton,cancelButton]);options.spacing=8
        for (id,title,width) in [("file","File",300.0),("line","Line:Column",100.0),("preview","Preview",500.0)] {
            let column=NSTableColumn(identifier:.init(id));column.title=title;column.width=width;table.addTableColumn(column)
        }
        table.delegate=self;table.dataSource=self;table.target=self;table.doubleAction=#selector(openResult(_:));table.usesAlternatingRowBackgroundColors=true
        let results=NSScrollView();results.documentView=table;results.hasVerticalScroller=true;results.hasHorizontalScroller=true
        details.isEditable=false;details.isSelectable=true;details.font = .monospacedSystemFont(ofSize:11,weight:.regular)
        let detailScroll=NSScrollView();detailScroll.documentView=details;detailScroll.hasVerticalScroller=true
        details.autoresizingMask=[.width];details.isVerticallyResizable=true
        let root=NSStackView(views:[location,queryField,options,status,results,detailScroll]);root.orientation = .vertical;root.alignment = .leading;root.spacing=10;root.edgeInsets=NSEdgeInsets(top:12,left:12,bottom:12,right:12)
        window.contentView=root
        for view in [location,queryField,options,status,results,detailScroll] { view.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-24).isActive=true }
        detailScroll.heightAnchor.constraint(equalToConstant:100).isActive=true
        results.heightAnchor.constraint(greaterThanOrEqualToConstant:180).isActive=true
        extensionField.widthAnchor.constraint(greaterThanOrEqualToConstant:200).isActive=true
    }
    required init?(coder:NSCoder){fatalError("init(coder:) not supported")}
    @objc func showSearch(_ sender:Any?){showWindow(sender);window?.makeKeyAndOrderFront(sender)}
    @objc private func chooseFolder(_ sender:Any?) {
        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK,let url=panel.url else{return};folder=url;folderLabel.stringValue=url.path
    }
    @objc private func startSearch(_ sender:Any?) {
        guard let folder else{status.stringValue="Choose a folder first.";return}
        let query=queryField.currentEditor()?.string ?? queryField.stringValue
        guard !query.isEmpty else{status.stringValue="Enter nonempty literal text.";return}
        cancelSearch(nil);let token=UUID();generation=token
        let extensions=Set((extensionField.currentEditor()?.string ?? extensionField.stringValue).split(whereSeparator:{$0 == "," || $0.isWhitespace}).map(String.init))
        var request=FolderSearchRequest(directory:folder,query:query);request.matchCase=caseButton.state == .on;request.recursive=recursiveButton.state == .on;request.extensions=extensions
        let flag=FolderSearchCancellation(),gate=FolderProgressGate();cancellation=flag
        matches=[];table.reloadData();details.string="Limits: 10,000 files · 100,000 entries · 32 MiB/file · 256 MiB total · 10,000 results. Hidden files and symbolic links are excluded."
        searchedQuery=query;searchedCase=request.matchCase;searchButton.isEnabled=false;cancelButton.isEnabled=true;status.stringValue="Searching…"
        work=Task { @MainActor [weak self] in
            do {
                let report=try await FolderSearch.search(request,cancellation:flag,progress:{ [weak self] progress in
                    guard gate.admit() else{return}
                    Task { @MainActor [weak self] in
                        guard let self,self.generation==token,self.cancellation != nil else{return}
                        self.status.stringValue="Searching: \(progress.filesSearched) files · \(progress.matches) matches · \(progress.bytesRead) bytes"
                    }
                })
                guard let self,self.generation==token else{return}
                self.matches=report.matches;self.table.reloadData()
                self.status.stringValue="\(report.matches.count) matches · \(report.filesSearched) files searched · \(report.skipped.count) skipped" + (report.wasCancelled ? " · Cancelled (partial results)" : "") + (report.reachedLimit.map{" · Limit reached: \($0.rawValue) (partial results)"} ?? "")
                self.details.string += "\n" + report.skipped.map { "\($0.url.path): \(String(describing:$0.reason))" }.joined(separator:"\n")
                self.finish()
            } catch {
                guard let self,self.generation==token else{return};self.status.stringValue=error.localizedDescription;self.finish()
            }
        }
    }
    private func finish(){searchButton.isEnabled=true;cancelButton.isEnabled=false;work=nil;cancellation=nil}
    @objc private func cancelSearch(_ sender:Any?){cancellation?.cancel();work?.cancel()}
    func windowWillClose(_ notification:Notification){cancelSearch(nil);generation=UUID();finish()}
    func numberOfRows(in tableView:NSTableView)->Int{matches.count}
    func tableView(_ tableView:NSTableView,objectValueFor tableColumn:NSTableColumn?,row:Int)->Any? {
        guard matches.indices.contains(row) else{return nil};let match=matches[row]
        switch tableColumn?.identifier.rawValue {case "file":return match.url.path;case "line":return "\(match.line):\(match.columnUTF16)";default:return match.preview.replacingOccurrences(of:"\n",with:" ↵ ").replacingOccurrences(of:"\r",with:" ↵ ")}
    }
    /// Validates both recorded offsets against the live buffer, including dirty documents.
    static func validatedRange(_ match:FolderSearchMatch,text:String,query:String,matchCase:Bool)->NSRange? {
        let bytes=Array(text.utf8),span=match.utf8Range
        guard !query.isEmpty,span.location>=0,span.length>0,span.location<=bytes.count,span.length<=bytes.count-span.location else{return nil}
        let selected=String(decoding:bytes[span.location..<span.location+span.length],as:UTF8.self)
        guard Array(selected.utf8)==Array(bytes[span.location..<span.location+span.length]) else{return nil}
        let prefix=String(decoding:bytes[..<span.location],as:UTF8.self)
        guard prefix.utf8.count==span.location,prefix.utf16.count==match.utf16Range.location,selected.utf16.count==match.utf16Range.length else{return nil}
        let options:NSString.CompareOptions=matchCase ? [.literal] : [.literal,.caseInsensitive]
        let found=(selected as NSString).range(of:query,options:options)
        guard found.location==0,found.length==(selected as NSString).length else{return nil}
        return NSRange(location:span.location,length:span.length)
    }
    @discardableResult static func selectResult(_ match:FolderSearchMatch,in document:TextDocument,query:String,matchCase:Bool)->Bool {
        guard let range=validatedRange(match,text:document.editor.text,query:query,matchCase:matchCase) else{return false}
        let editor=(document.windowControllers.first as? EditorWindowController)?.activeEditor ?? document.editor
        return editor.setSelectionAnchor(range.location,caret:range.location+range.length)
    }
    @objc private func openResult(_ sender:Any?) {
        let row=table.clickedRow;guard matches.indices.contains(row) else{return}
        let match=matches[row],query=searchedQuery,matchCase=searchedCase,token=generation
        NSDocumentController.shared.openDocument(withContentsOf:match.url,display:true) { [weak self] document,_,error in
            Task { @MainActor [weak self] in
                guard let self,self.generation==token else{return}
                if let error {self.status.stringValue=error.localizedDescription;return}
                guard let document=document as? TextDocument else{self.status.stringValue="This result could not be opened as a text document.";return}
                guard Self.selectResult(match,in:document,query:query,matchCase:matchCase) else{self.status.stringValue="Result is stale in the current buffer. Search again; selection was not changed.";return}
                let editor=(document.windowControllers.first as? EditorWindowController)?.activeEditor ?? document.editor
                document.showWindows();document.windowControllers.first?.window?.makeFirstResponder(editor)
            }
        }
    }
}
