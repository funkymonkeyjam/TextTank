// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// Native snapshot search. Workers never access TTEditor; results are revision checked.
final class SearchController:NSWindowController,NSWindowDelegate,NSTableViewDataSource,NSTableViewDelegate {
    var currentEditor:()->TTEditor? = {nil}
    var openEditors:()->[TTEditor] = {[]}
    var onCommand:((SearchOptions,String,TTEditor)->Void)?
    var onUnrecordableCommand:((String)->Void)?
    let queryField=NSTextField(),replacementField=NSTextField()
    let mode=NSPopUpButton(),scope=NSPopUpButton()
    let caseButton=NSButton(checkboxWithTitle:"Match case",target:nil,action:nil)
    let wordButton=NSButton(checkboxWithTitle:"Whole word",target:nil,action:nil)
    let dotButton=NSButton(checkboxWithTitle:"Dot matches newline",target:nil,action:nil)
    let wrapButton=NSButton(checkboxWithTitle:"Wrap",target:nil,action:nil)
    let status=NSTextField(labelWithString:"Search current document, selection or open documents")
    let table=NSTableView()
    private var options=SearchOptions(),generation=UUID(),cancellation:TTSearchCancellation?
    private var task:Task<Void,Never>?
    private struct Buffer { let editor:TTEditor,text:String,revision:UInt,offset:Int,anchor:Int,caret:Int }
    private struct Row { let buffer:Buffer,hit:SearchHit }
    private var rows:[Row]=[]
    private var searchButtons:[NSButton]=[]
    private var lastNavigation:(TTEditor,UInt,NSRange)?
    init() {
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:780,height:470),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        super.init(window:window);window.title="Find and Replace";window.isReleasedWhenClosed=false;window.delegate=self
        queryField.placeholderString="Find";replacementField.placeholderString="Replace with"
        mode.addItems(withTitles:["Normal","Extended (\\n, \\t, \\xNN)","Regular expression (Boost)"])
        scope.addItems(withTitles:["Current document","Selection","All open documents"])
        if let data=UserDefaults.standard.data(forKey:"TextTank.Search.v1"),let saved=try? JSONDecoder().decode(SearchOptions.self,from:data){options=saved}
        queryField.stringValue=options.query;replacementField.stringValue=options.replacement;mode.selectItem(at:options.mode.rawValue)
        caseButton.state=options.matchCase ? .on:.off;wordButton.state=options.wholeWord ? .on:.off;dotButton.state=options.dotMatchesNewline ? .on:.off;wrapButton.state=options.wrap ? .on:.off
        let actions:[(String,Selector)]=[("Previous",#selector(previous(_:))),("Next",#selector(next(_:))),("Find All / Count",#selector(findAll(_:))),("Replace",#selector(replaceOne(_:))),("Replace All",#selector(replaceAll(_:))),("Bookmark Matches",#selector(bookmark(_:))),("Mark Matches",#selector(mark(_:))),("Clear Marks",#selector(clearMarks(_:)))]
        searchButtons=actions.map{NSButton(title:$0.0,target:self,action:$0.1)}
        let cancel=NSButton(title:"Cancel Search",target:self,action:#selector(cancel(_:)))
        let opts=NSStackView(views:[mode,scope]),flags=NSStackView(views:[caseButton,wordButton,dotButton,wrapButton]),buttons=NSStackView(views:Array(searchButtons.prefix(5))+[cancel]);buttons.distribution = .fillProportionally
        let marks=NSStackView(views:Array(searchButtons.suffix(3)));marks.spacing=8
        let col=NSTableColumn(identifier:.init("result"));col.title="Document · UTF-16 offset · Match";col.width=730;table.addTableColumn(col);table.dataSource=self;table.delegate=self;table.target=self;table.doubleAction=#selector(openResult(_:))
        let scroll=NSScrollView();scroll.documentView=table;scroll.hasVerticalScroller=true;table.usesAlternatingRowBackgroundColors=true
        let root=NSStackView(views:[queryField,replacementField,opts,flags,buttons,marks,status,scroll]);root.orientation = .vertical;root.alignment = .leading;root.spacing=8;root.edgeInsets=NSEdgeInsets(top:12,left:12,bottom:12,right:12);window.contentView=root
        for v in [queryField,replacementField,opts,flags,buttons,marks,status,scroll] {v.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-24).isActive=true}
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:150).isActive=true
        window.minSize=NSSize(width:780,height:390)
    }
    required init?(coder:NSCoder){fatalError("init(coder:) not supported")}
    @objc func showSearch(_ sender:Any?){showWindow(sender);window?.makeKeyAndOrderFront(sender);window?.makeFirstResponder(queryField)}
    private func readOptions()->SearchOptions {
        // NSTextFields share the window field editor. Commit it before reading
        // distinct controls, otherwise the focused replacement can become query.
        window?.makeFirstResponder(nil)
        var o=SearchOptions();o.query=queryField.stringValue;o.replacement=replacementField.stringValue
        o.mode=SearchOptions.Mode(rawValue:mode.indexOfSelectedItem) ?? .normal;o.matchCase=caseButton.state == .on;o.wholeWord=wordButton.state == .on;o.dotMatchesNewline=dotButton.state == .on;o.wrap=wrapButton.state == .on
        if let data=try? JSONEncoder().encode(o){UserDefaults.standard.set(data,forKey:"TextTank.Search.v1")};options=o;return o
    }
    @objc func next(_ sender:Any?){run(.next)}
    @objc func previous(_ sender:Any?){run(.previous)}
    @objc func findAll(_ sender:Any?){run(.all)}
    @objc func replaceAll(_ sender:Any?){run(.replaceAll)}
    @objc func replaceOne(_ sender:Any?){run(.replaceOne)}
    @objc func bookmark(_ sender:Any?){run(.bookmark)}
    @objc func mark(_ sender:Any?){onUnrecordableCommand?("Search highlighting is not recorded in macros yet.");run(.mark)}
    @objc func clearMarks(_ sender:Any?){
        onUnrecordableCommand?("Clearing search highlights is not recorded in macros yet.")
        cancellation?.cancel();task?.cancel();generation=UUID();finish()
        let editors=scope.indexOfSelectedItem==2 ? openEditors():currentEditor().map{[$0]} ?? []
        var cleared=Set<ObjectIdentifier>()
        for editor in editors where editor.window != nil {if cleared.insert(ObjectIdentifier(editor)).inserted{editor.clearSearchHighlights()}}
        status.stringValue="Cleared search highlights from \(cleared.count) document(s)."
    }
    @objc func cancel(_ sender:Any?){cancellation?.cancel();task?.cancel();generation=UUID();finish();status.stringValue="Cancelled; no pending replacements applied."}
    func windowWillClose(_ notification:Notification){cancel(nil)}
    private func finish(){searchButtons.forEach{$0.isEnabled=true};cancellation=nil;task=nil}
    private enum Action {case next,previous,all,replaceAll,replaceOne,bookmark,mark}
    private func run(_ action:Action){
        let opts=readOptions();guard !opts.query.isEmpty else{status.stringValue="Enter a search expression.";return}
        var editors=scope.indexOfSelectedItem==2 ? openEditors():currentEditor().map{[$0]} ?? []
        var identities=Set<ObjectIdentifier>();editors=editors.filter{identities.insert(ObjectIdentifier($0)).inserted}
        guard !editors.isEmpty else{status.stringValue="Open a document first.";return}
        if scope.indexOfSelectedItem != 0 {onUnrecordableCommand?("Selection and all-open search operations are not recorded in macros.")}
        let currentDocumentScope=scope.indexOfSelectedItem==0,selectionScope=scope.indexOfSelectedItem==1
        var buffers:[Buffer]=[]
        for e in editors {
            let text=e.text
            if scope.indexOfSelectedItem==1 {
                guard e.selectionCount==1,let r=SearchCore.utf16Range(NSRange(location:e.selectionStart,length:e.selectionEnd-e.selectionStart),in:text),r.length>0 else{status.stringValue="Select one nonempty range first.";return}
                buffers.append(Buffer(editor:e,text:text,revision:e.revision,offset:r.location,anchor:e.selectionAnchor,caret:e.selectionCaret))
            }else{buffers.append(Buffer(editor:e,text:text,revision:e.revision,offset:0,anchor:e.selectionAnchor,caret:e.selectionCaret))}
        }
        let selectionRanges=buffers.map { b -> NSRange in
            if scope.indexOfSelectedItem==1{return SearchCore.utf16Range(NSRange(location:b.editor.selectionStart,length:b.editor.selectionEnd-b.editor.selectionStart),in:b.text)!}
            return NSRange(location:0,length:(b.text as NSString).length)
        }
        cancellation?.cancel();task?.cancel();let token=UUID();generation=token;let flag=TTSearchCancellation();cancellation=flag
        searchButtons.forEach{$0.isEnabled=false};status.stringValue="Searching snapshots…";rows=[];table.reloadData()
        let bookmarkSnapshots=buffers.map{($0.text,$0.offset)}
        let needsBookmarks=action == .bookmark
        let snapshots=zip(buffers,selectionRanges).map{($0.0.text as NSString).substring(with:$0.1)}
        task=Task { @MainActor [weak self] in
            do {
                let computed=try await Task.detached(priority:.userInitiated){
                    let reports=try snapshots.map{try SearchCore.search($0,options:opts,cancellation:flag)}
                    let lines=needsBookmarks ? try zip(bookmarkSnapshots,reports).map { snapshot,report in
                        try SearchCore.bookmarkLines(in:snapshot.0,locations:report.hits.map{$0.range.location+snapshot.1},cancellation:flag)
                    } : []
                    return (reports,lines)
                }.value
                let reports=computed.0
                guard let self,self.generation==token,!flag.cancelled else{return}
                defer{self.finish()}
                self.rows=zip(buffers,reports).flatMap{b,r in r.hits.map{Row(buffer:b,hit:SearchHit(range:NSRange(location:$0.range.location+b.offset,length:$0.range.length),replacement:$0.replacement))}}
                self.table.reloadData();let truncated=reports.contains{$0.truncated}
                self.status.stringValue="\(self.rows.count) matches in \(buffers.count) document(s)"+(truncated ? " · result limit reached":"")
                switch action {
                case .all:break
                case .next,.previous:self.navigate(backwards:action == .previous,wrap:opts.wrap)
                    if currentDocumentScope,let editor=buffers.first?.editor {self.onCommand?(opts,action == .previous ? "previous":"next",editor)}
                case .replaceAll,.replaceOne:
                    guard !truncated else{self.status.stringValue="Result limit reached; replacements were not applied. Narrow the scope.";return}
                    var changed=0,stale=0
                    for buffer in buffers {
                        let hits=self.rows.filter{$0.buffer.editor===buffer.editor}.map{$0.hit}
                        let chosen=action == .replaceOne ? hits.filter{SearchCore.byteRange($0.range,in:buffer.text)==NSRange(location:min(buffer.anchor,buffer.caret),length:abs(buffer.anchor-buffer.caret))}:hits
                        if chosen.isEmpty{continue}
                        if (selectionScope || action == .replaceOne) && (buffer.editor.selectionAnchor != buffer.anchor || buffer.editor.selectionCaret != buffer.caret){stale+=1;continue}
                        if Self.apply(chosen,text:buffer.text,revision:buffer.revision,to:buffer.editor){changed+=chosen.count}else{stale+=1}
                    }
                    self.status.stringValue="Replaced \(changed) matches; \(stale) changed documents skipped. Undo is per document."
                    if changed>0,stale==0,currentDocumentScope,let editor=buffers.first?.editor {self.onCommand?(opts,action == .replaceOne ? "replaceOne":"replaceAll",editor)}
                case .mark:
                    guard !truncated else{self.status.stringValue="Result limit reached; previous highlights were preserved. Narrow the scope.";return}
                    var marked=0,stale=0,zeroWidth=0
                    for b in buffers {
                        let hits=self.rows.filter{$0.buffer.editor===b.editor}.map{$0.hit}
                        if selectionScope && (b.editor.selectionAnchor != b.anchor || b.editor.selectionCaret != b.caret){stale+=1;continue}
                        if Self.highlight(hits,text:b.text,revision:b.revision,in:b.editor){marked+=hits.filter{$0.range.length>0}.count;zeroWidth+=hits.filter{$0.range.length==0}.count}else{stale+=1}
                    }
                    self.status.stringValue="Marked \(marked) matches; \(stale) changed/closed documents skipped."+(zeroWidth>0 ? " \(zeroWidth) zero-width matches have no visible span.":"")
                case .bookmark:
                    var stale=0
                    guard !truncated else{self.status.stringValue="Result limit reached; bookmarks were preserved. Narrow the scope.";return}
                    for (index,b) in buffers.enumerated() {
                        guard b.editor.window != nil,b.editor.revision==b.revision,b.editor.text==b.text,
                              !selectionScope || (b.editor.selectionAnchor==b.anchor && b.editor.selectionCaret==b.caret) else{stale+=1;continue}
                        var lines=Set(b.editor.bookmarkLines.map{$0.intValue})
                        lines.formUnion(computed.1[index])
                        _=b.editor.setBookmarks(lines.sorted().map{NSNumber(value:$0)})
                    };self.status.stringValue="Bookmarked matching lines; \(stale) changed documents skipped."
                }
            }catch{guard let self,self.generation==token else{return};self.status.stringValue=error.localizedDescription;self.finish()}
        }
    }
    /// Macro playback is bounded and has no disk or connector side effects.
    func playRecorded(options:SearchOptions,action:String,on editor:TTEditor)throws {
        let text=editor.text,revision=editor.revision
        let report=try SearchCore.search(text,options:options,timeLimit:0.1)
        guard !report.truncated else{throw NSError(domain:"TextTank.Search",code:4,userInfo:[NSLocalizedDescriptionKey:"Macro search reached the result limit; no edits were applied."])}
        guard let selection=SearchCore.utf16Range(NSRange(location:editor.selectionStart,length:editor.selectionEnd-editor.selectionStart),in:text) else{return}
        if action=="replaceAll" || action=="replaceOne" {
            let hits=action=="replaceAll" ? report.hits:report.hits.filter{$0.range==selection}
            if !hits.isEmpty && !Self.apply(hits,text:text,revision:revision,to:editor){throw NSError(domain:"TextTank.Search",code:5,userInfo:[NSLocalizedDescriptionKey:"Macro replacement encountered a stale buffer or unsupported multiple selection."])}
        }else if action=="next" || action=="previous" {
            let backwards=action=="previous"
            let continuing=lastNavigation.map{$0.0===editor && $0.1==revision && $0.2==selection} ?? false
            let candidates=report.hits.filter{h in backwards ? NSMaxRange(h.range)<=selection.location && !(continuing && h.range==selection):h.range.location>=NSMaxRange(selection) && !(continuing && h.range==selection)}
            let hit=(backwards ? candidates.last:candidates.first) ?? (options.wrap ? (backwards ? report.hits.last:report.hits.first):nil)
            if let hit,let bytes=SearchCore.byteRange(hit.range,in:text),editor.setSelectionAnchor(bytes.location,caret:NSMaxRange(bytes)){lastNavigation=(editor,revision,hit.range)}
        }else{throw NSError(domain:"TextTank.Search",code:6,userInfo:[NSLocalizedDescriptionKey:"Unrecognized recorded search action."])}
    }
    @discardableResult static func highlight(_ hits:[SearchHit],text:String,revision:UInt,in editor:TTEditor)->Bool {
        guard editor.window != nil,editor.revision==revision,editor.text==text,let ranges=SearchCore.byteRanges(hits.map(\.range),in:text) else{return false}
        return editor.setSearchHighlights(ranges.filter{$0.length>0}.map{NSValue(range:$0)})
    }
    @discardableResult static func apply(_ hits:[SearchHit],text:String,revision:UInt,to editor:TTEditor)->Bool {
        guard editor.window != nil,!editor.readOnly,editor.revision==revision,editor.text==text,editor.selectionCount==1,!hits.isEmpty else{return false}
        guard let ranges=SearchCore.byteRanges(hits.map(\.range),in:text) else{return false}
        editor.beginUndoGroup();defer{editor.endUndoGroup()}
        for (hit,range) in zip(hits,ranges).reversed() {
            guard editor.setSelectionAnchor(range.location,caret:NSMaxRange(range)) else{return false}
            editor.replaceSelection(hit.replacement)
        }
        return true
    }
    private func navigate(backwards:Bool,wrap:Bool){
        guard let e=currentEditor(),let selection=SearchCore.utf16Range(NSRange(location:e.selectionStart,length:e.selectionEnd-e.selectionStart),in:e.text) else{return}
        let available=rows.filter{$0.buffer.editor===e}
        let continuing=lastNavigation.map{$0.0===e && $0.1==e.revision && $0.2==selection} ?? false
        let candidates=available.filter{r in backwards ? NSMaxRange(r.hit.range)<=selection.location && !(continuing && r.hit.range==selection):r.hit.range.location>=NSMaxRange(selection) && !(continuing && r.hit.range==selection)}
        if let row=backwards ? candidates.last:candidates.first {select(row)}else if wrap,let row=backwards ? available.last:available.first{select(row)}else{status.stringValue="No further matches."}
    }
    private func select(_ row:Row){let b=row.buffer;guard b.editor.window != nil,b.editor.revision==b.revision,b.editor.text==b.text,let range=SearchCore.byteRange(row.hit.range,in:b.text),b.editor.setSelectionAnchor(range.location,caret:NSMaxRange(range)) else{status.stringValue="Result is stale; search again. Selection unchanged.";return};lastNavigation=(b.editor,b.revision,row.hit.range);b.editor.window?.makeKeyAndOrderFront(nil);b.editor.window?.makeFirstResponder(b.editor)}
    func numberOfRows(in tableView:NSTableView)->Int{rows.count}
    func tableView(_ tableView:NSTableView,objectValueFor tableColumn:NSTableColumn?,row:Int)->Any?{guard rows.indices.contains(row) else{return nil};let r=rows[row];let match=(r.buffer.text as NSString).substring(with:r.hit.range);return "\(r.buffer.editor.window?.title ?? "Document") · \(r.hit.range.location) · \(String(match.prefix(160)).replacingOccurrences(of:"\n",with:" ↵ "))"}
    @objc private func openResult(_ sender:Any?){guard rows.indices.contains(table.clickedRow) else{return};select(rows[table.clickedRow])}
}
