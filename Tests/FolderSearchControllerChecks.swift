import AppKit
@main struct FolderSearchControllerChecks {
    @MainActor static func main() throws {
        let support=FileManager.default.temporaryDirectory.appendingPathComponent("TextTankFolderUIChecks-"+UUID().uuidString)
        setenv("TEXTTANK_SUPPORT_DIRECTORY",support.path,1)
        defer { try? FileManager.default.removeItem(at:support) }
        _ = NSApplication.shared
        var checks=0
        func check(_ value:Bool,_ label:String){precondition(value,label);checks+=1;print("PASS \(label)")}
        let url=URL(fileURLWithPath:"/tmp/isolated-folder-result.txt")
        let match=FolderSearchMatch(url:url,line:1,columnUTF16:4,utf16Range:.init(location:3,length:4),utf8Range:.init(location:5,length:4),preview:"🥑 Test",previewMatchRange:.init(location:3,length:4),isMatchTruncatedInPreview:false)
        check(FolderSearchController.validatedRange(match,text:"🥑 Test",query:"Test",matchCase:true)==NSRange(location:5,length:4),"Unicode UTF8 selection validated")
        check(FolderSearchController.validatedRange(match,text:"🥑 TEST",query:"Test",matchCase:false) != nil,"case insensitive live match validated")
        check(FolderSearchController.validatedRange(match,text:"🥑 changed",query:"Test",matchCase:true)==nil,"changed buffer result rejected")
        check(FolderSearchController.validatedRange(match,text:"x",query:"Test",matchCase:true)==nil,"shorter buffer result rejected")
        let document=TextDocument();document.editor.text="🥑 changed";let revision=document.editor.revision
        _ = FolderSearchController.validatedRange(match,text:document.editor.text,query:"Test",matchCase:true)
        check(document.isDocumentEdited && document.editor.revision==revision && document.editor.text=="🥑 changed","stale validation preserves dirty document")
        document.editor.text="🥑 Test";document.makeWindowControllers()
        let beforeNavigation=document.editor.revision
        check(FolderSearchController.selectResult(match,in:document,query:"Test",matchCase:true),"result navigates current native buffer")
        check(document.editor.selectedText=="Test","native selection uses validated UTF8 byte range")
        check(document.editor.revision==beforeNavigation && document.isDocumentEdited,"navigation preserves dirty content and revision")
        document.editor.text="🥑 changed";_ = document.editor.setSelectionAnchor(0,caret:4)
        check(!FolderSearchController.selectResult(match,in:document,query:"Test",matchCase:true) && document.editor.selectionAnchor==0 && document.editor.selectionCaret==4,"stale result leaves native selection unchanged")
        let controller=FolderSearchController()
        check(controller.window?.title=="Find in Folder" && controller.status.stringValue.contains("Boost regex"),"native title and status expose search modes")
        check(controller.table.tableColumns.count==3 && controller.details.isSelectable,"native results and skip details selectable")
        controller.windowWillClose(Notification(name:NSWindow.willCloseNotification))
        controller.retainReplacementOutcomes([FolderReplacementOutcome(url:url,status:.replaced,message:"committed before close",backup:URL(fileURLWithPath:"/tmp/review-backup"),recoveryReport:URL(fileURLWithPath:"/tmp/review-backup.json"))])
        controller.showReplacementReport(nil)
        check(controller.lastReplacementOutcomes.count==1 && controller.details.string.contains("committed before close") && controller.details.string.contains("review-backup.json"),"replacement completion retained after close with durable report path")
        document.close()
        print("PASS FolderSearchControllerChecks: \(checks) assertions")
    }
}
