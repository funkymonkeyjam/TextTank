import AppKit
/// Find-window navigation fronts the document window; checks must never put one on screen.
final class OffscreenWindow:NSWindow {override func makeKeyAndOrderFront(_ sender:Any?){}}
@main struct SearchControllerChecks {
    @MainActor static func main()async {
        await Checks.run("SearchControllerChecks") {
        _=NSApplication.shared
        // F255: the controller under test keeps its options in a suite of its own, never in the
        // real defaults domain, so nothing is inherited from an earlier run or left behind.
        let suite="TextTankSearchControllerChecks-"+UUID().uuidString
        let isolated=try requireValue(UserDefaults(suiteName:suite),"fixture: isolated defaults suite");defer{isolated.removePersistentDomain(forName:suite)}
        let standardBefore=UserDefaults.standard.data(forKey:"TextTank.Search.v1")
        let editor=TTEditor(frame:NSRect(x:0,y:0,width:600,height:400)),window=NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:400),styleMask:.titled,backing:.buffered,defer:false);window.contentView=editor
        let controller=SearchController(defaults:isolated);controller.currentEditor={editor};controller.openEditors={[editor]}
        @MainActor func finished()async{await waitUntil("the search to finish"){!controller.isSearching}}
        let fresh0=SearchOptions()
        check(controller.queryField.stringValue==fresh0.query && controller.caseButton.state==(fresh0.matchCase ? .on:.off) && controller.wordButton.state==(fresh0.wholeWord ? .on:.off) && controller.dotButton.state==(fresh0.dotMatchesNewline ? .on:.off) && controller.wrapButton.state==(fresh0.wrap ? .on:.off) && controller.mode.indexOfSelectedItem==fresh0.mode.rawValue,"controller on an empty defaults suite starts from default options, not from an earlier run")
        editor.text="🥑 one=12 two=34";editor.resetUndoHistory();editor.setSavePoint()
        var o=SearchOptions();o.query="([a-z]+)=(\\d+)";o.replacement="$1:$2";o.mode = .regularExpression;o.matchCase=true
        let original=editor.text,revision=editor.revision,report=try SearchCore.search(original,options:o)
        check(SearchController.apply(report.hits,text:original,revision:revision,to:editor),"regex replacement applied in native editor")
        check(editor.text=="🥑 one:12 two:34" && editor.modified,"exact captures and dirty state")
        editor.executeCommand("undo");check(editor.text==original && !editor.modified,"one Undo restores full original and save point")
        editor.text="changed";let changed=editor.text,current=editor.revision;_ = editor.setSelectionAnchor(1,caret:2)
        check(!SearchController.apply(report.hits,text:original,revision:revision,to:editor) && editor.text==changed && editor.revision==current && editor.selectionStart==1,"stale result preserves text/revision/selection")
        editor.text=original;editor.resetUndoHistory();editor.setSavePoint();let fresh=editor.revision
        editor.readOnly=true;_ = editor.setSelectionAnchor(4,caret:5)
        check(!SearchController.apply(report.hits,text:original,revision:fresh,to:editor) && editor.text==original && editor.selectionStart==4 && !editor.modified,"read-only replacement rejected without selection changes")
        editor.readOnly=false;window.contentView=nil
        check(!SearchController.apply(report.hits,text:original,revision:fresh,to:editor) && editor.text==original,"detached editor replacement rejected")
        window.contentView=editor;_ = editor.setSelectionAnchor(0,caret:0)
        try controller.playRecorded(options:o,action:"next",on:editor)
        check(editor.selectedText=="one=12","recorded regex find selects UTF8 mapped match")
        try controller.playRecorded(options:o,action:"replaceOne",on:editor)
        check(editor.text=="🥑 one:12 two=34","recorded regex selected replacement")
        editor.executeCommand("undo");check(editor.text==original,"recorded replacement one Undo")
        editor.text="ab";o.query="(?=.)|$";o.replacement="_";_ = editor.setSelectionAnchor(0,caret:0)
        try controller.playRecorded(options:o,action:"next",on:editor);check(editor.selectionCaret==0,"first zero match at start")
        try controller.playRecorded(options:o,action:"next",on:editor);check(editor.selectionCaret==1,"successive zero match advances")
        try controller.playRecorded(options:o,action:"replaceAll",on:editor);check(editor.text=="_a_b_","recorded zero-width replace all")
        check(controller.mode.numberOfItems==3 && controller.scope.numberOfItems==3 && controller.table.tableColumns.count==1,"native options and result controls wired")
        editor.text="one=12 two=34";editor.resetUndoHistory();editor.setSavePoint()
        controller.queryField.stringValue="([a-z]+)=(\\d+)";controller.replacementField.stringValue="old";controller.mode.selectItem(at:2)
        controller.window?.makeFirstResponder(controller.replacementField)
        try requireValue(controller.window?.firstResponder as? NSTextView,"fixture: replacement field editor is active").string="$1:$2"
        check(NSApp.sendAction(#selector(SearchController.replaceAll(_:)),to:controller,from:nil),"native replacement action dispatched while replacement field editing")
        await finished()
        check(editor.text=="one:12 two:34" && controller.queryField.stringValue=="([a-z]+)=(\\d+)","active shared field editor commits only replacement and preserves regex query")
        let persisted=isolated.data(forKey:"TextTank.Search.v1").flatMap{try? JSONDecoder().decode(SearchOptions.self,from:$0)}
        check(persisted?.query=="([a-z]+)=(\\d+)" && persisted?.replacement=="$1:$2" && persisted?.mode == .regularExpression,"a Find-window action saves its options in the injected defaults")
        check(UserDefaults.standard.data(forKey:"TextTank.Search.v1")==standardBefore,"a Find-window action leaves the standard defaults domain untouched")
        let reopened=SearchController(defaults:isolated)
        check(reopened.queryField.stringValue=="([a-z]+)=(\\d+)" && reopened.replacementField.stringValue=="$1:$2" && reopened.mode.indexOfSelectedItem==2,"a second controller on the same defaults restores the saved options")
        editor.executeCommand("undo");check(editor.text=="one=12 two=34","native focused-field replace all one Undo")
        editor.setSavePoint();editor.readOnly=true;_ = editor.setSelectionAnchor(0,caret:3)
        let markRevision=editor.revision,markSelection=editor.selectionRanges
        controller.mark(nil)
        await finished()
        check(controller.lastOutcome == .marked(matches:2,stale:0,zeroWidth:0) && editor.revision==markRevision && !editor.modified && editor.selectionRanges==markSelection,"native mark action works read-only without text dirty or selection change")
        controller.clearMarks(nil)
        check(controller.lastOutcome == .clearedHighlights(documents:1) && editor.revision==markRevision && !editor.modified && editor.selectionRanges==markSelection,"native clear marks preserves content and selection")
        editor.readOnly=false;controller.mark(nil);editor.text="changed during search";let changedRevision=editor.revision
        await finished()
        check(controller.lastOutcome == .marked(matches:0,stale:1,zeroWidth:0) && editor.text=="changed during search" && editor.revision==changedRevision,"stale asynchronous mark preserves new content")
        editor.text="a\r\na\ra\nend";editor.resetUndoHistory();editor.setSavePoint();_ = editor.setBookmarks([3])
        controller.queryField.stringValue="a";controller.mode.selectItem(at:0);controller.scope.selectItem(at:0)
        controller.bookmark(nil)
        await finished()
        check(editor.bookmarkLines.map{$0.intValue}==[0,1,2,3] && !editor.modified,"background bookmark lines preserve existing bookmarks and save point")
        _ = editor.setBookmarks([3]);controller.bookmark(nil);controller.cancel(nil)
        // A negative: nothing observable marks the end of a cancelled run, so wait a fixed
        // interval and then require that neither the markers nor the status were overwritten.
        try await Task.sleep(nanoseconds:50_000_000)
        check(editor.bookmarkLines.map{$0.intValue}==[3] && controller.lastOutcome == .cancelled && !controller.isSearching,"cancelled bookmark action preserves existing markers")
        controller.bookmark(nil);editor.text="new content";_ = editor.setBookmarks([0])
        await finished()
        check(controller.lastOutcome == .bookmarked(stale:1) && editor.bookmarkLines.map{$0.intValue}==[0],"stale bookmark completion preserves current markers")
        // G366: a recorded Next/Previous that finds nothing stops the macro instead of returning normally.
        func stops(_ work:()throws->Void)->String? {do{try work();return nil}catch{return error.localizedDescription}}
        var miss=SearchOptions();miss.query="TODO";miss.mode = .normal;miss.matchCase=true;miss.wrap=false
        editor.text="TODO one\nTODO two\ntail\n";editor.resetUndoHistory();editor.setSavePoint()
        let tail=editor.text.utf8.count;_ = editor.setSelectionAnchor(tail,caret:tail);let missRevision=editor.revision
        var message=stops{try controller.playRecorded(options:miss,action:"next",on:editor)}
        check(message?.contains("recorded search did not match")==true && editor.selectionAnchor==tail && editor.selectionCaret==tail && editor.text=="TODO one\nTODO two\ntail\n" && editor.revision==missRevision && !editor.modified,"recorded Next past the last match stops with selection, text and revision unchanged")
        _ = editor.setSelectionAnchor(0,caret:0)
        message=stops{try controller.playRecorded(options:miss,action:"previous",on:editor)}
        check(message?.contains("recorded search did not match")==true && editor.selectionAnchor==0 && editor.selectionCaret==0 && editor.revision==missRevision && !editor.modified,"recorded Previous before the first match stops with selection and revision unchanged")
        miss.wrap=true;_ = editor.setSelectionAnchor(tail,caret:tail)
        check(stops{try controller.playRecorded(options:miss,action:"next",on:editor)}==nil && editor.selectionStart==0 && editor.selectedText=="TODO","recorded Next with Wrap on still wraps to the first match")
        _ = editor.setSelectionAnchor(0,caret:0)
        check(stops{try controller.playRecorded(options:miss,action:"previous",on:editor)}==nil && editor.selectionStart==9 && editor.selectedText=="TODO","recorded Previous with Wrap on still wraps to the last match")
        miss.query="absent";_ = editor.setSelectionAnchor(3,caret:3)
        message=stops{try controller.playRecorded(options:miss,action:"next",on:editor)}
        check(message?.contains("recorded search did not match")==true && editor.selectionCaret==3 && editor.revision==missRevision,"recorded Next with Wrap on and no match anywhere stops")
        miss.replacement="x"
        check(stops{try controller.playRecorded(options:miss,action:"replaceAll",on:editor)}==nil && editor.revision==missRevision && !editor.modified && editor.selectionCaret==3,"recorded Replace All with no match is skipped without an edit")
        check(stops{try controller.playRecorded(options:miss,action:"replaceOne",on:editor)}==nil && editor.revision==missRevision && !editor.modified,"recorded Replace keeps its saved-macro semantics when the selection is not a match")
        // G366: the Find window records Next/Previous only when it actually moved to a match.
        let offscreen=OffscreenWindow(contentRect:NSRect(x:0,y:0,width:600,height:400),styleMask:.titled,backing:.buffered,defer:false);window.contentView=nil;offscreen.contentView=editor
        var recorded:[String]=[]
        controller.onCommand={_,action,_ in recorded.append(action)}
        func settle()async {await finished()}
        controller.queryField.stringValue="TODO";controller.replacementField.stringValue="";controller.mode.selectItem(at:0);controller.scope.selectItem(at:0);controller.wrapButton.state = .off;controller.caseButton.state = .on
        _ = editor.setSelectionAnchor(0,caret:0);controller.next(nil);await settle()
        check(recorded==["next"] && editor.selectionStart==0 && editor.selectedText=="TODO","Find-window Next that lands on a match is recorded")
        _ = editor.setSelectionAnchor(tail,caret:tail);controller.next(nil);await settle()
        check(recorded==["next"] && controller.lastOutcome == .noFurtherMatches && editor.selectionCaret==tail,"Find-window Next that finds nothing is not recorded")
        _ = editor.setSelectionAnchor(0,caret:0);controller.previous(nil);await settle()
        check(recorded==["next"] && controller.lastOutcome == .noFurtherMatches,"Find-window Previous that finds nothing is not recorded")
        _ = editor.setSelectionAnchor(tail,caret:tail);controller.previous(nil);await settle()
        check(recorded==["next","previous"] && editor.selectionStart==9,"Find-window Previous that lands on a match is recorded")
        // F34: single Replace on a many-hit buffer converts the hits once, and replaces only the selected hit.
        let hitLine="é needle 0123456789 0123456789 0123456\n",hitCount=20000,chosenHit=12345,hitBytes=hitLine.utf8.count
        let big=String(repeating:hitLine,count:hitCount);editor.text=big;editor.resetUndoHistory();editor.setSavePoint()
        controller.queryField.stringValue="needle";controller.replacementField.stringValue="pin";recorded=[]
        _ = editor.setSelectionAnchor(chosenHit*hitBytes+3,caret:chosenHit*hitBytes+9)
        let replaceStart=Date();controller.replaceOne(nil)
        await waitUntil(timeout:120,"the many-hit single Replace to finish"){!controller.isSearching}
        let replaceElapsed=Date().timeIntervalSince(replaceStart)
        let expectedBig=String(repeating:hitLine,count:chosenHit)+"é pin 0123456789 0123456789 0123456\n"+String(repeating:hitLine,count:hitCount-chosenHit-1)
        check(controller.lastOutcome == .replaced(changed:1,stale:0) && editor.text==expectedBig && recorded==["replaceOne"],"single Replace on a \(hitCount)-hit buffer replaces exactly the selected hit")
        check(replaceElapsed<10,"single Replace on a \(hitCount)-hit buffer stays within its time bound (\(String(format:"%.2f",replaceElapsed)) s)")
        editor.executeCommand("undo");check(editor.text==big && !editor.modified,"many-hit single Replace is one Undo back to the save point")
        _ = editor.setSelectionAnchor(chosenHit*hitBytes+3,caret:chosenHit*hitBytes+8);recorded=[];controller.replaceOne(nil)
        await waitUntil(timeout:120,"the many-hit single Replace to finish"){!controller.isSearching}
        check(controller.lastOutcome == .replaced(changed:0,stale:0) && editor.text==big && !editor.modified && recorded.isEmpty,"single Replace with a selection that is not exactly a hit changes and records nothing")
        // G404: the typed state is set with the status text, and the wording is the product's.
        controller.queryField.stringValue="";controller.findAll(nil)
        check(controller.lastOutcome == .needsInput && !controller.isSearching && controller.status.stringValue=="Enter a search expression.","an empty query is reported as needing input without starting a search")
        editor.text="aa bb aa";controller.queryField.stringValue="aa";controller.mode.selectItem(at:0);controller.findAll(nil)
        check(controller.isSearching && controller.lastOutcome == nil && controller.status.stringValue.hasPrefix("Searching"),"a started search reports that it is searching and has no outcome yet")
        await finished()
        check(controller.lastOutcome == .found(matches:2,documents:1,truncated:false) && controller.status.stringValue=="2 matches in 1 document(s)","a finished Find All reports its match and document counts")
        controller.queryField.stringValue="(";controller.mode.selectItem(at:2);controller.findAll(nil);await finished()
        if case .failed(let reason)? = controller.lastOutcome { check(!reason.isEmpty && controller.status.stringValue==reason,"an invalid expression is reported as a failure carrying the shown reason") } else { check(false,"an invalid expression is reported as a failure carrying the shown reason") }
        Checks.summary { "PASS SearchControllerChecks: \(Checks.count) assertions" }
        }
    }
}
