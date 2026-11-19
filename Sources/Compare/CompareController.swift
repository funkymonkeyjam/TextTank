// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import TextTankCore
import EditorBridge

@MainActor enum CompareCommand:String,CaseIterable {
    case previous,next,sideBySide,unified,linked,collapse,expandAll,whitespace,wrap,refresh,cancel
    var title:String {
        switch self {
        case .previous:return "Previous Change"
        case .next:return "Next Change"
        case .sideBySide:return "Side by Side"
        case .unified:return "Unified"
        case .linked:return "Linked Scrolling"
        case .collapse:return "Collapse Unchanged"
        case .expandAll:return "Expand All Unchanged Lines"
        case .whitespace:return "Show Whitespace"
        case .wrap:return "Wrap Lines"
        case .refresh:return "Refresh Comparison"
        case .cancel:return "Cancel Comparison"
        }
    }
    var symbol:String {
        switch self {
        case .previous:return "chevron.up"
        case .next:return "chevron.down"
        case .sideBySide:return "rectangle.split.2x1"
        case .unified:return "list.bullet"
        case .linked:return "link"
        case .collapse:return "arrow.up.and.down.righttriangle.up.righttriangle.down"
        case .expandAll:return "arrow.up.left.and.arrow.down.right"
        case .whitespace:return "paragraphsign"
        case .wrap:return "arrow.turn.down.left"
        case .refresh:return "arrow.clockwise"
        case .cancel:return "xmark"
        }
    }
}
@MainActor final class CompareController:NSWindowController,CompareWindowScope,NSWindowDelegate,
    NSToolbarDelegate,NSMenuItemValidation,NSToolbarItemValidation,NSTableViewDataSource,NSTableViewDelegate {
    static var key:CompareController? { NSApp?.keyWindow?.windowController as? CompareController }
    weak var service:CompareService?
    private(set) var original:CompareSource?
    private(set) var modified:CompareSource?
    private(set) var projection:CompareProjection?
    private(set) var isClosed=false
    private(set) var isBusy=false
    private(set) var outOfDate=false
    private(set) var statusText=""
    let left=ComparePane(frame:.zero),right=ComparePane(frame:.zero)
    private let split=NSSplitView(),table=ActivatingTableView(),tableScroll=NSScrollView()
    private let sourceLabels=[NSTextField(wrappingLabelWithString:""),NSTextField(wrappingLabelWithString:"")]
    private let status=AnnouncingLabel(labelWithString:"")
    private let progress=NSProgressIndicator()
    private let cancelButton=NSButton(title:"Cancel",target:nil,action:nil)
    private var navigation=CompareNavigation(count:0)
    private var unifiedMode=false,linked=true,collapsed=false,whitespace=false,wrapped=false
    private var expanded=Set<Int>()
    private var unifiedRows:[CompareUnifiedRow]=[]
    private var rowTops:[Int]=[]
    private var rowIndices:[Int]=[]
    private var token=ReviewCancellation()
    private var generation=UUID()
    private var worker:Task<Void,Never>?,geometry:Task<Void,Never>?,refreshTask:Task<Void,Never>?
    private var sourceTimer:Timer?
    private var wheelMonitor:Any?
    private var arranging=false
    private var geometryRequested=false
    init(service:CompareService,original:CompareSource,modified:CompareSource) {
        self.service=service;self.original=original;self.modified=modified
        let panel=ToolPanel(contentRect:NSRect(x:0,y:0,width:1000,height:680),styleMask:[.titled,.closable,.resizable])
        super.init(window:panel)
        panel.title="Compare Text";panel.listedInWindowMenu=true;panel.contentMinSize=NSSize(width:720,height:420)
        panel.delegate=self;panel.animationBehavior = .none
        let toolbar=NSToolbar(identifier:"TextTank.Compare");toolbar.delegate=self;toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization=true;panel.toolbar=toolbar
        let root=NSView();panel.contentView=root
        let labels=NSStackView(views:sourceLabels);labels.orientation = .horizontal;labels.distribution = .fillEqually
        split.isVertical=true;split.dividerStyle = .thin
        split.addArrangedSubview(left);split.addArrangedSubview(right)
        left.editor.accessibilityDocumentName="Original comparison text"
        right.editor.accessibilityDocumentName="Modified comparison text"
        progress.style = .spinning;progress.controlSize = .small;progress.isDisplayedWhenStopped=false
        cancelButton.target=self;cancelButton.action=#selector(cancel(_:));cancelButton.setAccessibilityLabel("Cancel comparison computation")
        let bottom=NSStackView(views:[status,progress,cancelButton]);bottom.orientation = .horizontal
        for view in [labels,split,tableScroll,bottom] { view.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(view) }
        NSLayoutConstraint.activate([
            labels.topAnchor.constraint(equalTo:root.topAnchor,constant:8),labels.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:12),
            labels.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-12),labels.heightAnchor.constraint(greaterThanOrEqualToConstant:44),
            split.topAnchor.constraint(equalTo:labels.bottomAnchor,constant:6),split.leadingAnchor.constraint(equalTo:root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo:root.trailingAnchor),split.bottomAnchor.constraint(equalTo:bottom.topAnchor,constant:-6),
            tableScroll.topAnchor.constraint(equalTo:split.topAnchor),tableScroll.bottomAnchor.constraint(equalTo:split.bottomAnchor),
            tableScroll.leadingAnchor.constraint(equalTo:split.leadingAnchor),tableScroll.trailingAnchor.constraint(equalTo:split.trailingAnchor),
            bottom.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:12),bottom.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-12),
            bottom.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-8),bottom.heightAnchor.constraint(greaterThanOrEqualToConstant:28),
            left.widthAnchor.constraint(greaterThanOrEqualToConstant:240),right.widthAnchor.constraint(greaterThanOrEqualToConstant:240)
        ])
        let column=NSTableColumn(identifier:.init("comparison"));column.title="Original / Modified changes";column.width=2400
        table.addTableColumn(column);table.headerView=nil;table.delegate=self;table.dataSource=self
        table.rowHeight=28;table.usesAlternatingRowBackgroundColors=true
        table.setAccessibilityLabel("Unified comparison changes");table.onActivate={ [weak self] row in self?.activateUnified(row) }
        tableScroll.documentView=table;tableScroll.hasVerticalScroller=true;tableScroll.hasHorizontalScroller=true;tableScroll.isHidden=true
        for (side,pane) in [(CompareSide.original,left),(.modified,right)] {
            pane.onScroll={ [weak self] top in
                guard let self,!self.arranging else { return }
                if self.linked { (side == .original ? self.right : self.left).setTop(top) }
            }
            pane.onResize={ [weak self] in self?.requestGeometry() }
            pane.onExpand={ [weak self] fold in self?.expanded.insert(fold);self?.requestGeometry() }
        }
        wheelMonitor=NSEvent.addLocalMonitorForEvents(matching:[.scrollWheel,.keyDown]) { [weak self] event in
            guard let self,event.window === self.window,!self.unifiedMode else { return event }
            let point=self.split.convert(event.locationInWindow,from:nil)
            let pane=point.x<self.left.frame.maxX ? self.left : self.right
            if event.type == .scrollWheel,abs(event.scrollingDeltaY)>=abs(event.scrollingDeltaX) {
                pane.scrollWheel(with:event);return nil
            }
            if event.type == .keyDown,event.modifierFlags.intersection([.command,.option,.control]).isEmpty,
                let responder=self.window?.firstResponder as? NSView,
                responder.isDescendant(of:pane.editor) {
                if event.keyCode==116 { pane.scroll(by:-pane.visibleRows);return nil }
                if event.keyCode==121 { pane.scroll(by:pane.visibleRows);return nil }
            }
            return event
        }
        loadSources(original,modified)
        WindowFrames.track(panel,as:"TextTank.Compare")
        sourceTimer=Timer.scheduledTimer(withTimeInterval:0.25,repeats:true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollSources() }
        }
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func loadSources(_ a:CompareSource,_ b:CompareSource) {
        original=a;modified=b
        for (source,pane) in [(a,left),(b,right)] {
            pane.editor.readOnly=false
            pane.editor.text=ReviewUTF8.text(source.snapshot.bytes) ?? ""
            pane.editor.resetUndoHistory();pane.editor.setSavePoint();pane.editor.readOnly=true
            pane.isEmpty=source.snapshot.bytes.isEmpty
        }
        updateLabels()
    }
    private func updateLabels() {
        for (i,source) in [original,modified].enumerated() {
            let value=(i==0 ? "Original: " : "Modified: ")+(source?.label ?? "Closed")
            if sourceLabels[i].stringValue != value { sourceLabels[i].stringValue=value;sourceLabels[i].setAccessibilityLabel(value) }
        }
    }
    private func showStatus(_ text:String) {
        statusText=text;status.stringValue=text;status.toolTip=text
        status.setAccessibilityLabel(text)
    }
    func showQueued() { isBusy=true;showStatus("Waiting to compare…");progress.startAnimation(nil);cancelButton.isHidden=false }
    func run(job:UUID,engine:any ReviewDiffing,finished:@escaping @MainActor ()->Void) {
        guard !isClosed,let a=original,let b=modified else { finished();return }
        generation=job;token=ReviewCancellation();let cancellation=token
        let x=a.snapshot,y=b.snapshot
        showStatus("Comparing…")
        worker=Task { [weak self] in
            let result=await engine.compare(x,y,policy:.default,token:cancellation,hooks:.init())
            do {
                try Task.checkCancellation()
                guard !cancellation.isCancelled else { throw CompareFailure.cancelled }
                let p:CompareProjection?
                if result.completeness == .complete { p=try await CompareProjection.build(original:x,modified:y,changes:result,token:cancellation) }
                else { p=nil }
                guard let self,!self.isClosed,self.generation==job else { finished();return }
                try a.validate();try b.validate()
                guard !a.isStale,!b.isStale else { throw ReviewRejection.revisionChanged }
                self.isBusy=false;self.progress.stopAnimation(nil);self.cancelButton.isHidden=true
                if let p { self.projection=p;self.navigation=CompareNavigation(count:p.changes.blocks.count);self.outOfDate=false;self.requestGeometry();self.showResultStatus() }
                else { self.showStatus("Incomplete comparison. \(Self.reason(result.completeness)) No document was changed.") }
            } catch {
                if let self,!self.isClosed,self.generation==job {
                    self.isBusy=false;self.progress.stopAnimation(nil);self.cancelButton.isHidden=true
                    self.showStatus(CompareService.message(error))
                }
            }
            finished()
        }
    }
    static func reason(_ completeness:ReviewCompleteness)->String {
        switch completeness { case .complete:return "Complete.";case .cancelled:return "Computation was cancelled.";case .budgetStopped:return "The size, time or work limit was reached." }
    }
    private func showResultStatus() {
        guard let p=projection else { return }
        let base=p.changes.identical ? "Byte-identical text. The decoded text matches byte for byte. File encodings or byte-order marks may differ."
            : String(format:p.changes.blocks.count==1 ? "1 change." : "%ld changes.",p.changes.blocks.count)
        showStatus((outOfDate ? "Out of date. Refresh explicitly. " : "")+base+(p.inlineLimited ? " Some changed spans could not be refined; line changes remain visible." : ""))
    }
    func pollSources() {
        guard !isClosed else { return };updateLabels()
        if original?.isStale==true || modified?.isStale==true {
            outOfDate=true
            if isBusy { cancel(nil);showStatus("Out of date. A source changed or closed. Refresh explicitly.") }
            else { showResultStatus() }
        }
    }
    @objc func cancel(_ sender:Any?) {
        token.cancel();worker?.cancel();refreshTask?.cancel();geometry?.cancel()
        generation=UUID();isBusy=false;arranging=false
        progress.stopAnimation(nil);cancelButton.isHidden=true
        if projection != nil { outOfDate=true }
        showStatus("Comparison cancelled. No document was changed.")
    }
    func windowWillClose(_ notification:Notification) {
        guard !isClosed else { return };isClosed=true;cancel(nil)
        sourceTimer?.invalidate();sourceTimer=nil
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor);self.wheelMonitor=nil }
        original=nil;modified=nil;projection=nil;unifiedRows=[];rowTops=[];rowIndices=[]
        left.releaseContent();right.releaseContent();service?.closed(self)
    }
    func requestGeometry() {
        guard !isClosed,projection != nil,!geometryRequested else { return }
        geometryRequested=true
        geometry=Task { [weak self] in
            await Task.yield()
            guard let self,!self.isClosed else { return };self.geometryRequested=false
            do { try await self.arrange() }
            catch { self.arranging=false;self.showStatus("Incomplete presentation. The display limit was reached. No document was changed.") }
        }
    }
    private func arrange() async throws {
        guard let p=projection,!isClosed else { return }
        arranging=true;defer { arranging=false }
        let stamp=generation,oldLeft=left.top,oldRight=right.top
        for pane in [left,right] { pane.editor.clearComparisonPresentation();pane.editor.wrap=wrapped;pane.editor.setComparisonWhitespaceVisible(whitespace) }
        window?.contentView?.layoutSubtreeIfNeeded();window?.displayIfNeeded()
        var hiddenA=IndexSet(),hiddenB=IndexSet(),tokens:[(row:Int?,fold:Int?)]=[]
        var i=0,foldIndex=0,operations=0
        func valid() throws { try Task.checkCancellation();guard !isClosed,generation==stamp else { throw CompareFailure.cancelled } }
        while i<p.rows.count {
            if collapsed,foldIndex<p.folds.count,i==p.folds[foldIndex].rows.lowerBound,!expanded.contains(foldIndex) {
                let range=p.folds[foldIndex].rows
                for row in p.rows[range] {
                    if let a=row.original { hiddenA.insert(a) };if let b=row.modified { hiddenB.insert(b) }
                    operations+=1;if operations%512==0 { try valid();await Task.yield() }
                }
                tokens.append((nil,foldIndex));i=range.upperBound;foldIndex+=1
            } else {
                tokens.append((i,nil));i+=1
                while foldIndex<p.folds.count && p.folds[foldIndex].rows.upperBound<=i { foldIndex+=1 }
            }
            operations+=1;if operations%512==0 { try valid();await Task.yield() }
        }
        // Scintilla's synthetic line after a final EOL contributes no source row.
        if let byte=p.original.bytes.last,(byte==10 || byte==13),!p.originalLines.isEmpty { hiddenA.insert(p.originalLines.count) }
        if let byte=p.modified.bytes.last,(byte==10 || byte==13),!p.modifiedLines.isEmpty { hiddenB.insert(p.modifiedLines.count) }
        guard left.editor.setComparisonHiddenLines(hiddenA),right.editor.setComparisonHiddenLines(hiddenB) else { throw CompareFailure.invalid }
        var gapsA:[Int:Int]=[:],gapsB:[Int:Int]=[:],lastA:Int?,lastB:Int?,leadA=0,leadB=0,top=0
        var folds:[(top:Int,height:Int,count:Int,index:Int)]=[],tops:[Int]=[],indices:[Int]=[]
        func gap(_ line:Int?,_ count:Int,_ gaps:inout [Int:Int],_ leading:inout Int) throws {
            guard count>=0 else { throw CompareFailure.invalid }
            if let line { let value=(gaps[line] ?? 0)+count;guard value<=32760 else { throw CompareFailure.budget(.output) };gaps[line]=value }
            else { leading+=count }
        }
        for (n,value) in tokens.enumerated() {
            try valid()
            if let fold=value.fold {
                let height=max(1,Int(ceil(28/Double(left.lineHeight))))
                folds.append((top,height,p.folds[fold].count,fold))
                try gap(lastA,height,&gapsA,&leadA);try gap(lastB,height,&gapsB,&leadB);top+=height
            } else if let index=value.row {
                let row=p.rows[index],a=row.original.map { max(1,left.editor.comparisonWrapCount(forLine:$0)) } ?? 0
                let b=row.modified.map { max(1,right.editor.comparisonWrapCount(forLine:$0)) } ?? 0
                let height=max(1,max(a,b));tops.append(top);indices.append(index)
                if let line=row.original { lastA=line;try gap(line,height-a,&gapsA,&leadA) } else { try gap(lastA,height,&gapsA,&leadA) }
                if let line=row.modified { lastB=line;try gap(line,height-b,&gapsB,&leadB) } else { try gap(lastB,height,&gapsB,&leadB) }
                top+=height
                if let change=row.change {
                    for (side,line,pane) in [(CompareSide.original,row.original,left),(.modified,row.modified,right)] {
                        guard let line else { continue }
                        let r=p.lines(side)[line].range
                        let spans=p.inlineSpans[change].compactMap { span -> TTByteRange? in
                            let s=side == .original ? span.original : span.modified
                            let lo=max(r.lower,s.lower),hi=min(r.upper,s.upper)
                            return hi>lo ? TTByteRange(location:lo,length:hi-lo) : nil
                        }
                        guard spans.count<=512,pane.editor.addComparisonHighlights([TTByteRange(location:r.lower,length:r.upper-r.lower)],inlineRanges:spans,
                            kind:p.changes.blocks[change].kind == .modify ? 2 : side == .original ? 1 : 0) else { throw CompareFailure.budget(.output) }
                    }
                }
            }
            if n%512==0 { await Task.yield() }
        }
        for (pane,gaps) in [(left,gapsA),(right,gapsB)] {
            for (n,pair) in gaps.enumerated() { try valid();guard pane.editor.setComparisonGapAfterLine(pair.key,rows:pair.value) else { throw CompareFailure.invalid };if n%512==0 { await Task.yield() } }
        }
        try valid()
        rowTops=tops;rowIndices=indices
        for (pane,leading,old) in [(left,leadA,oldLeft),(right,leadB,oldRight)] { pane.leadingRows=leading;pane.totalRows=max(1,top);pane.foldRows=folds;pane.setTop(old) }
        // Unified cells are source-mapped values, never a synthetic patch string or document.
        unifiedRows=p.unified.filter { row in
            guard collapsed else { return true }
            let map=row.side == .original ? p.originalToRow : p.modifiedToRow
            let index=map[row.line]
            return !p.folds.enumerated().contains { !expanded.contains($0.offset) && $0.element.rows.contains(index) }
        }
        table.reloadData();showResultStatus()
    }
    func numberOfRows(in tableView:NSTableView)->Int { unifiedRows.count }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
        guard let p=projection,unifiedRows.indices.contains(row) else { return nil }
        let value=unifiedRows[row],line=p.lines(value.side)[value.line],snapshot=p.snapshot(value.side)
        let text=ReviewUTF8.text(snapshot.bytes.subdata(in:line.range.lower..<line.contentEnd)) ?? ""
        let cue=value.change == nil ? "=" : value.side == .original ? "- Deleted" : "+ Inserted"
        let ending=line.ending.isEmpty ? "Missing final newline" : line.ending
        let shown=whitespace ? text.replacingOccurrences(of:" ",with:"·").replacingOccurrences(of:"\t",with:"→") : text
        let cell=(tableView.makeView(withIdentifier:.init("source-row"),owner:self) as? NSTextField) ?? NSTextField(labelWithString:"")
        cell.identifier = .init("source-row");cell.font = .monospacedSystemFont(ofSize:NSFont.systemFontSize,weight:.regular)
        cell.stringValue="\(cue) · \(value.side == .original ? "Original" : "Modified") line \(value.line+1)  \(shown)  [\(ending)]"
        cell.setAccessibilityLabel(cell.stringValue);cell.lineBreakMode = .byClipping
        return cell
    }
    private func activateUnified(_ row:Int) {
        guard unifiedRows.indices.contains(row),let change=unifiedRows[row].change else { return }
        navigation=CompareNavigation(count:projection?.changes.blocks.count ?? 0)
        for _ in 0...change { navigation.move(next:true) };announcePosition()
    }
    private func announcePosition() {
        guard let current=navigation.current else { return }
        let text=String(format:"Change %ld of %ld",current+1,navigation.count);Announce.say(text)
        if let p=projection,p.changeRows.indices.contains(current),let index=rowIndices.firstIndex(of:p.changeRows[current]) { left.setTop(rowTops[index]);right.setTop(rowTops[index]) }
    }
    @objc func performCompareCommand(_ sender:Any?) {
        let raw=(sender as? NSMenuItem)?.representedObject as? String ?? (sender as? NSToolbarItem)?.itemIdentifier.rawValue ?? (sender as? NSButton)?.identifier?.rawValue
        guard let raw,let command=CompareCommand(rawValue:raw),enabled(command) else { return }
        perform(command)
    }
    func perform(_ command:CompareCommand) {
        guard enabled(command) else { return }
        switch command {
        case .next:navigation.move(next:true);announcePosition()
        case .previous:navigation.move(next:false);announcePosition()
        case .sideBySide,.unified:unifiedMode=command == .unified;split.isHidden=unifiedMode;tableScroll.isHidden = !unifiedMode
        case .linked:linked.toggle()
        case .collapse:collapsed.toggle();requestGeometry()
        case .expandAll:collapsed=false;expanded.removeAll();requestGeometry()
        case .whitespace:whitespace.toggle();requestGeometry()
        case .wrap:wrapped.toggle();requestGeometry()
        case .refresh:refresh()
        case .cancel:cancel(nil)
        }
        window?.toolbar?.validateVisibleItems()
    }
    private func refresh() {
        guard let a=original,let b=modified,let service else { return }
        do {
            let x=try a.refreshInput(),y=try b.refreshInput();let stamp=UUID();generation=stamp
            token.cancel();worker?.cancel();outOfDate=true;isBusy=true;showStatus("Refreshing…");progress.startAnimation(nil);cancelButton.isHidden=false
            refreshTask=Task { [weak self,weak service] in
                do {
                    guard let service else { return }
                    let pair=try await service.capturePair(x,y,token:ReviewCancellation())
                    guard let self,!self.isClosed,self.generation==stamp else { return }
                    self.loadSources(pair.0,pair.1);self.projection=nil;self.expanded.removeAll();service.enqueue(self)
                } catch { if let self,!self.isClosed,self.generation==stamp { self.isBusy=false;self.progress.stopAnimation(nil);self.cancelButton.isHidden=true;self.showStatus("Out of date. "+CompareService.message(error)) } }
            }
        } catch { showStatus(CompareService.message(error)) }
    }
    private func enabled(_ command:CompareCommand)->Bool {
        guard !isClosed else { return false }
        if command == .cancel { return isBusy || arranging }
        if command == .refresh { return !isBusy && original?.canRefresh==true && modified?.canRefresh==true }
        guard projection != nil,!isBusy,!arranging else { return false }
        switch command { case .next:return navigation.hasNext;case .previous:return navigation.hasPrevious;default:return true }
    }
    private func checked(_ command:CompareCommand)->Bool {
        switch command { case .sideBySide:return !unifiedMode;case .unified:return unifiedMode;case .linked:return linked;case .collapse:return collapsed;case .whitespace:return whitespace;case .wrap:return wrapped;default:return false }
    }
    func validateMenuItem(_ item:NSMenuItem)->Bool {
        guard let raw=item.representedObject as? String,let command=CompareCommand(rawValue:raw) else { return false }
        item.state=checked(command) ? .on : .off;return enabled(command)
    }
    func validateToolbarItem(_ item:NSToolbarItem)->Bool { CompareCommand(rawValue:item.itemIdentifier.rawValue).map(enabled) ?? false }
    func toolbarAllowedItemIdentifiers(_ toolbar:NSToolbar)->[NSToolbarItem.Identifier] { CompareCommand.allCases.map { .init($0.rawValue) }+[.flexibleSpace] }
    func toolbarDefaultItemIdentifiers(_ toolbar:NSToolbar)->[NSToolbarItem.Identifier] { [CompareCommand.previous,.next,.sideBySide,.unified,.linked,.collapse,.whitespace,.wrap,.refresh].map { .init($0.rawValue) } }
    func toolbar(_ toolbar:NSToolbar,itemForItemIdentifier id:NSToolbarItem.Identifier,willBeInsertedIntoToolbar flag:Bool)->NSToolbarItem? {
        guard let command=CompareCommand(rawValue:id.rawValue) else { return nil }
        let item=NSToolbarItem(itemIdentifier:id);item.label=command.title;item.toolTip=command.title
        item.image=NSImage(systemSymbolName:command.symbol,accessibilityDescription:command.title)
        item.target=self;item.action=#selector(performCompareCommand(_:));return item
    }
}
