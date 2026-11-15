import AppKit
/// Find-window navigation fronts the document window; checks must never put one on screen.
final class OffscreenWindow:NSWindow {override func makeKeyAndOrderFront(_ sender:Any?){}}
@main struct SearchControllerChecks {
    @MainActor static func main()async throws {
        _=NSApplication.shared
        var checks=0
        func check(_ b:Bool,_ message:String){precondition(b,message);checks+=1;print("PASS \(message)")}
        let editor=TTEditor(frame:NSRect(x:0,y:0,width:600,height:400)),window=NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:400),styleMask:.titled,backing:.buffered,defer:false);window.contentView=editor
        let controller=SearchController();controller.currentEditor={editor};controller.openEditors={[editor]}
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
        if let fieldEditor=controller.window?.firstResponder as? NSTextView { fieldEditor.string="$1:$2" } else { fatalError("Replacement field editor not active") }
        check(NSApp.sendAction(#selector(SearchController.replaceAll(_:)),to:controller,from:nil),"native replacement action dispatched while replacement field editing")
        for _ in 0..<200 {if !controller.status.stringValue.hasPrefix("Searching"){break};try await Task.sleep(nanoseconds:10_000_000)}
        check(editor.text=="one:12 two:34" && controller.queryField.stringValue=="([a-z]+)=(\\d+)","active shared field editor commits only replacement and preserves regex query")
        editor.executeCommand("undo");check(editor.text=="one=12 two=34","native focused-field replace all one Undo")
        editor.setSavePoint();editor.readOnly=true;_ = editor.setSelectionAnchor(0,caret:3)
        let markRevision=editor.revision,markSelection=editor.selectionRanges
        controller.mark(nil)
        for _ in 0..<200 {if !controller.status.stringValue.hasPrefix("Searching"){break};try await Task.sleep(nanoseconds:10_000_000)}
        check(controller.status.stringValue.hasPrefix("Marked 2 matches") && editor.revision==markRevision && !editor.modified && editor.selectionRanges==markSelection,"native mark action works read-only without text dirty or selection change")
        controller.clearMarks(nil)
        check(controller.status.stringValue.hasPrefix("Cleared search highlights") && editor.revision==markRevision && !editor.modified && editor.selectionRanges==markSelection,"native clear marks preserves content and selection")
        editor.readOnly=false;controller.mark(nil);editor.text="changed during search";let changedRevision=editor.revision
        for _ in 0..<200 {if !controller.status.stringValue.hasPrefix("Searching"){break};try await Task.sleep(nanoseconds:10_000_000)}
        check(controller.status.stringValue.contains("1 changed/closed") && editor.text=="changed during search" && editor.revision==changedRevision,"stale asynchronous mark preserves new content")
        editor.text="a\r\na\ra\nend";editor.resetUndoHistory();editor.setSavePoint();_ = editor.setBookmarks([3])
        controller.queryField.stringValue="a";controller.mode.selectItem(at:0);controller.scope.selectItem(at:0)
        controller.bookmark(nil)
        for _ in 0..<200 {if !controller.status.stringValue.hasPrefix("Searching"){break};try await Task.sleep(nanoseconds:10_000_000)}
        check(editor.bookmarkLines.map{$0.intValue}==[0,1,2,3] && !editor.modified,"background bookmark lines preserve existing bookmarks and save point")
        _ = editor.setBookmarks([3]);controller.bookmark(nil);controller.cancel(nil)
        try await Task.sleep(nanoseconds:50_000_000)
        check(editor.bookmarkLines.map{$0.intValue}==[3],"cancelled bookmark action preserves existing markers")
        controller.bookmark(nil);editor.text="new content";_ = editor.setBookmarks([0])
        for _ in 0..<200 {if !controller.status.stringValue.hasPrefix("Searching"){break};try await Task.sleep(nanoseconds:10_000_000)}
        check(controller.status.stringValue.contains("1 changed") && editor.bookmarkLines.map{$0.intValue}==[0],"stale bookmark completion preserves current markers")
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
        func settle()async throws {for _ in 0..<1000 {if !controller.status.stringValue.hasPrefix("Searching"){break};try await Task.sleep(nanoseconds:10_000_000)}}
        controller.queryField.stringValue="TODO";controller.replacementField.stringValue="";controller.mode.selectItem(at:0);controller.scope.selectItem(at:0);controller.wrapButton.state = .off;controller.caseButton.state = .on
        _ = editor.setSelectionAnchor(0,caret:0);controller.next(nil);try await settle()
        check(recorded==["next"] && editor.selectionStart==0 && editor.selectedText=="TODO","Find-window Next that lands on a match is recorded")
        _ = editor.setSelectionAnchor(tail,caret:tail);controller.next(nil);try await settle()
        check(recorded==["next"] && controller.status.stringValue=="No further matches." && editor.selectionCaret==tail,"Find-window Next that finds nothing is not recorded")
        _ = editor.setSelectionAnchor(0,caret:0);controller.previous(nil);try await settle()
        check(recorded==["next"] && controller.status.stringValue=="No further matches.","Find-window Previous that finds nothing is not recorded")
        _ = editor.setSelectionAnchor(tail,caret:tail);controller.previous(nil);try await settle()
        check(recorded==["next","previous"] && editor.selectionStart==9,"Find-window Previous that lands on a match is recorded")
        // F34: single Replace on a many-hit buffer converts the hits once, and replaces only the selected hit.
        let hitLine="é needle 0123456789 0123456789 0123456\n",hitCount=20000,chosenHit=12345,hitBytes=hitLine.utf8.count
        let big=String(repeating:hitLine,count:hitCount);editor.text=big;editor.resetUndoHistory();editor.setSavePoint()
        controller.queryField.stringValue="needle";controller.replacementField.stringValue="pin";recorded=[]
        _ = editor.setSelectionAnchor(chosenHit*hitBytes+3,caret:chosenHit*hitBytes+9)
        let replaceStart=Date();controller.replaceOne(nil)
        for _ in 0..<60000 {if !controller.status.stringValue.hasPrefix("Searching"){break};try await Task.sleep(nanoseconds:10_000_000)}
        let replaceElapsed=Date().timeIntervalSince(replaceStart)
        let expectedBig=String(repeating:hitLine,count:chosenHit)+"é pin 0123456789 0123456789 0123456\n"+String(repeating:hitLine,count:hitCount-chosenHit-1)
        check(controller.status.stringValue.hasPrefix("Replaced 1 matches; 0 changed") && editor.text==expectedBig && recorded==["replaceOne"],"single Replace on a \(hitCount)-hit buffer replaces exactly the selected hit")
        check(replaceElapsed<10,"single Replace on a \(hitCount)-hit buffer stays within its time bound (\(String(format:"%.2f",replaceElapsed)) s)")
        editor.executeCommand("undo");check(editor.text==big && !editor.modified,"many-hit single Replace is one Undo back to the save point")
        _ = editor.setSelectionAnchor(chosenHit*hitBytes+3,caret:chosenHit*hitBytes+8);recorded=[];controller.replaceOne(nil)
        for _ in 0..<60000 {if !controller.status.stringValue.hasPrefix("Searching"){break};try await Task.sleep(nanoseconds:10_000_000)}
        check(controller.status.stringValue.hasPrefix("Replaced 0 matches") && editor.text==big && !editor.modified && recorded.isEmpty,"single Replace with a selection that is not exactly a hit changes and records nothing")
        print("PASS SearchControllerChecks: \(checks) assertions")
    }
}
