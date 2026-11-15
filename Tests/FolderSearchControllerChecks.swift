import AppKit
@main struct FolderSearchControllerChecks {
    @MainActor static func main() async {
        await Checks.run("FolderSearchControllerChecks") {
        let isolatedSupport=try IsolatedSupportDirectory("TextTankFolderUIChecks"),support=isolatedSupport.url
        defer { isolatedSupport.restore() }
        _ = NSApplication.shared
        let url=URL(fileURLWithPath:"/tmp/isolated-folder-result.txt")
        let match=FolderSearchMatch(url:url,line:1,columnUTF16:4,utf16Range:.init(location:3,length:4),utf8Range:.init(location:5,length:4),preview:"🥑 Test",previewMatchRange:.init(location:3,length:4),isMatchTruncatedInPreview:false)
        check(FolderSearchController.validatedRange(match,text:"🥑 Test",query:"Test",matchCase:true)==NSRange(location:5,length:4),"Unicode UTF8 selection validated")
        check(FolderSearchController.validatedRange(match,text:"🥑 TEST",query:"Test",matchCase:false) != nil,"case insensitive live match validated")
        check(FolderSearchController.validatedRange(match,text:"🥑 changed",query:"Test",matchCase:true)==nil,"changed buffer result rejected")
        check(FolderSearchController.validatedRange(match,text:"x",query:"Test",matchCase:true)==nil,"shorter buffer result rejected")
        let document=TextDocument();document.editor.text="🥑 Test";document.makeWindowControllers()
        let beforeNavigation=document.editor.revision
        check(FolderSearchController.selectResult(match,in:document,query:"Test",matchCase:true),"result navigates current native buffer")
        check(document.editor.selectedText=="Test","native selection uses validated UTF8 byte range")
        check(document.editor.revision==beforeNavigation && document.isDocumentEdited,"navigation preserves dirty content and revision")
        document.editor.text="🥑 changed";_ = document.editor.setSelectionAnchor(0,caret:4)
        check(!FolderSearchController.selectResult(match,in:document,query:"Test",matchCase:true) && document.editor.selectionAnchor==0 && document.editor.selectionCaret==4,"stale result leaves native selection unchanged")
        let suite="TextTankFolderNative-"+UUID().uuidString
        let isolated=try requireValue(UserDefaults(suiteName:suite),"fixture: isolated defaults suite");defer{isolated.removePersistentDomain(forName:suite)}
        let controller=FolderSearchController(defaults:isolated)
        check(controller.window?.title=="Find in Folder" && controller.status.stringValue.contains("Boost regex"),"native title and status expose search modes")
        check(controller.table.tableColumns.count==3 && controller.details.isSelectable,"native results and skip details selectable")
        controller.windowWillClose(Notification(name:NSWindow.willCloseNotification))
        controller.retainReplacementOutcomes([FolderReplacementOutcome(url:url,status:.replaced,message:"committed before close",backup:URL(fileURLWithPath:"/tmp/review-backup"),recoveryReport:URL(fileURLWithPath:"/tmp/review-backup.json"))])
        controller.showReplacementReport(nil)
        check(controller.lastReplacementOutcomes.count==1 && controller.details.string.contains("committed before close") && controller.details.string.contains("review-backup.json"),"replacement completion retained after close with durable report path")
        controller.filterField.stringValue="*.txt !+\\build";controller.extensionField.stringValue="txt";controller.queryField.stringValue="needle";controller.replacementField.stringValue="replacement";controller.mode.selectItem(at:1);controller.scope.selectItem(at:1);controller.hiddenButton.state = .on;controller.recursiveButton.state = .off
        try controller.saveSettings()
        let restored=FolderSearchController(defaults:isolated)
        check(restored.filterField.stringValue=="*.txt !+\\build" && restored.extensionField.stringValue=="txt" && restored.queryField.stringValue=="needle" && restored.replacementField.stringValue=="replacement" && restored.mode.indexOfSelectedItem==1 && restored.scope.indexOfSelectedItem==1 && restored.hiddenButton.state == .on && restored.recursiveButton.state == .off,"native restart restores all folder search controls")
        let first=support.appendingPathComponent("workspace-one"),second=support.appendingPathComponent("workspace-two")
        try FileManager.default.createDirectory(at:first,withIntermediateDirectories:true);try FileManager.default.createDirectory(at:second,withIntermediateDirectories:true)
        try Data("needle".utf8).write(to:first.appendingPathComponent("one.txt"));try Data("needle".utf8).write(to:second.appendingPathComponent("two.txt"));try Data("needle".utf8).write(to:second.appendingPathComponent("skip.log"))
        restored.workspaceRoots={ [first,second] };restored.mode.selectItem(at:0)
        check(NSApp.sendAction(restored.queryField.action!,to:restored.queryField.target,from:restored.queryField),"native workspace search action dispatched")
        check(restored.isSearching && restored.lastOutcome == nil,"a started folder search reports that it is searching")
        await waitUntil("the workspace search to finish"){!restored.isSearching}
        var searchedTwo=false
        if case .searched(matches:2,filesSearched:2,skipped:_,cancelled:false,limitReached:false)? = restored.lastOutcome { searchedTwo=true } else { print("NOTE folder outcome \(String(describing:restored.lastOutcome))") }
        check(searchedTwo && restored.numberOfRows(in:restored.table)==2,"native saved workspace roots search respects filename filters")
        let corrupt=Data("invalid settings".utf8);isolated.set(corrupt,forKey:"TextTank.FolderSearch.v1")
        let invalid=FolderSearchController(defaults:isolated);invalid.queryField.stringValue="new";try invalid.saveSettings()
        check(isolated.data(forKey:"TextTank.FolderSearch.v1")==corrupt,"native corrupt settings stay preserved after attempted save")
        document.close()
        Checks.summary { "PASS FolderSearchControllerChecks: \(Checks.count) assertions" }
        }
    }
}
