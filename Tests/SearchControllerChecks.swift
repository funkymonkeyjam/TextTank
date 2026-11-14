import AppKit
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
        print("PASS SearchControllerChecks: \(checks) assertions")
    }
}
