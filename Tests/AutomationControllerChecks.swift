// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

final class AutomationToolbarHost: NSObject, NSToolbarDelegate {
    let controller: AutomationController
    init(_ controller: AutomationController) { self.controller = controller }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { controller.toolbarIdentifiers() }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { controller.toolbarIdentifiers() }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        controller.makeToolbarItem(identifier:identifier)
    }
}

@main struct AutomationControllerChecks {
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try condition() else { fatalError("FAIL: \(name)") }; checks += 1
        print("PASS: \(name)")
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TextTankAutomationControllerChecks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let old = ProcessInfo.processInfo.environment["TEXTTANK_SUPPORT_DIRECTORY"]
        setenv("TEXTTANK_SUPPORT_DIRECTORY",root.path,1)
        defer { if let old { setenv("TEXTTANK_SUPPORT_DIRECTORY",old,1) } else { unsetenv("TEXTTANK_SUPPORT_DIRECTORY") }; try? FileManager.default.removeItem(at:root) }
        _ = NSApplication.shared
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:500),styleMask:[.titled],backing:.buffered,defer:false)
        let editor = TTEditor(frame:window.contentView!.bounds); window.contentView = editor
        var newDocumentCalls = 0
        let controller = AutomationController(editorProvider:{editor},newDocument:{_ in newDocumentCalls += 1})
        let path = root.appendingPathComponent("Automations.json")
        var saved = try AutomationLibrary.decode(Data(contentsOf:path))
        try check(saved.workflows.count == 2,"new configuration seeds two ordinary saved workflows")
        try check(saved.workflows[0].output == .editor && saved.workflows[1].output == .reminders,"separate cleanup and send definitions")
        try check(controller.toolbarIdentifiers().count == 2,"two individual pinned toolbar buttons available")
        let source = "# Ingredients\n- **2 eggs**\n- ½ cup flour\n"
        editor.text = source; editor.resetUndoHistory(); editor.setSavePoint()
        try controller.runSavedAutomation(id:AutomationDefinition.example.id)
        try check(editor.text == "2 eggs\n½ cup flour\n","cleanup applies directly to actual editor without preview dialog")
        editor.executeCommand("undo")
        try check(editor.text == source,"direct cleanup is one Undo action")
        saved.workflows[0].name = "My recipe tidy"
        saved.workflows[0].shortcut = "k"
        saved.workflows[0].previewBeforeApply = nil
        try controller.persistLibrary(saved)
        let identifier = controller.toolbarIdentifiers()[0]
        let toolbarHost = AutomationToolbarHost(controller)
        let toolbar = NSToolbar(identifier:"TextTank.AutomationControllerChecks")
        toolbar.delegate = toolbarHost; window.toolbar = toolbar
        guard let button = toolbar.items.first(where: { $0.itemIdentifier == identifier })?.view as? NSButton else { fatalError("missing installed direct toolbar button") }
        try check(button.window === window,"named automation button is installed in native window toolbar")
        try check(button.title == "My recipe tidy","renaming updates individual toolbar button label")
        editor.text = source; editor.resetUndoHistory()
        try check(NSApp.sendAction(button.action!,to:button.target,from:button),"toolbar action reaches shared stable-ID dispatcher")
        try check(editor.text == "2 eggs\n½ cup flour\n","absent preview flag applies same saved definition directly")
        let browserInput = try String(contentsOfFile:"Tests/Fixtures/recipe-browser-plain-input.txt",encoding:.utf8)
        let browserExpected = try String(contentsOfFile:"Tests/Fixtures/recipe-browser-cleaned-expected.txt",encoding:.utf8)
        let windowCount = NSApp.windows.count
        editor.text = browserInput; editor.resetUndoHistory(); editor.setSavePoint()
        try check(NSApp.sendAction(button.action!,to:button.target,from:button),"observed browser recipe runs through actual named toolbar button")
        let cleanedRows = editor.text.components(separatedBy:.newlines).filter { !$0.isEmpty }
        try check(cleanedRows.count == 28,"observed full browser recipe produces all 28 ingredient rows")
        try check(editor.text == browserExpected,"native recipe output exactly preserves quantities options duplicates and copied spacing")
        try check(editor.window === window && window.contentView === editor && NSApp.windows.count == windowCount,"recipe cleanup stays in same editor and window")
        try check(newDocumentCalls == 0,"recipe cleanup never invokes new-document output")
        editor.executeCommand("undo")
        try check(editor.text == browserInput,"one native Undo restores exact original browser clipboard text")
        let ambiguous = browserInput + "\nunmarked ingredient continuation\n"
        editor.text = ambiguous; editor.resetUndoHistory(); editor.setSavePoint()
        let unchangedRevision = editor.revision
        var rejectedAmbiguous = false
        do { try controller.runSavedAutomation(id:AutomationDefinition.example.id) }
        catch { rejectedAmbiguous = true }
        try check(rejectedAmbiguous,"unknown unmarked recipe row rejects cleanup")
        try check(editor.text == ambiguous && editor.revision == unchangedRevision && !editor.modified,"ambiguous recipe rejection leaves original bytes undo and dirty state untouched")
        var slowPattern = saved
        slowPattern.workflows[0].steps = [.init(kind:.removeMatchingLines,find:"(a+)+$")]
        try controller.persistLibrary(slowPattern)
        let slowInput = String(repeating:"a",count:32) + "!"
        editor.text = slowInput; editor.resetUndoHistory(); editor.setSavePoint()
        let slowRevision = editor.revision, started = ProcessInfo.processInfo.systemUptime
        var rejectedSlow = false
        do { try controller.runSavedAutomation(id:AutomationDefinition.example.id) }
        catch { rejectedSlow = true }
        try check(rejectedSlow && ProcessInfo.processInfo.systemUptime - started < 2,"pathological user regex stops promptly before native apply")
        try check(editor.text == slowInput && editor.revision == slowRevision && !editor.modified,"regex timeout leaves exact native document and dirty state untouched")
        try controller.persistLibrary(saved)
        let beforeReload = try Data(contentsOf:path)
        let restarted = AutomationController(editorProvider:{editor},newDocument:{_ in fatalError("unexpected output")})
        try check(Data(contentsOf:path) == beforeReload,"existing named configuration is not replaced or rewritten by presets")
        try check(restarted.makeToolbarItem(identifier:identifier)?.label == "My recipe tidy","toolbar stable identity survives configuration reload")
        let menuItem = restarted.menu().items.first(where: { ($0.representedObject as? String) == AutomationDefinition.example.id.uuidString })!
        try check(menuItem.title == "My recipe tidy" && menuItem.keyEquivalent == "k","menu and shortcut use renamed saved definition")
        saved.workflows[0].input = .selection
        try restarted.persistLibrary(saved)
        let selectionSource = "before\n- 2 eggs\n- ½ cup flour\nafter"
        editor.text = selectionSource; editor.resetUndoHistory()
        try check(editor.find("- 2 eggs\n- ½ cup flour\n",matchCase:true,backwards:false),"selection test captures exact ingredient range")
        try restarted.runSavedAutomation(id:AutomationDefinition.example.id)
        try check(editor.text == "before\n2 eggs\n½ cup flour\nafter","configured selection cleanup preserves surrounding document")
        editor.executeCommand("undo")
        try check(editor.text == selectionSource,"selection cleanup undoes together")
        saved.workflows[0].pinToToolbar = false
        try restarted.persistLibrary(saved)
        try check(restarted.toolbarIdentifiers().count == 1,"toolbar pin setting hides only configured workflow")
        let now = Date()
        let confirmed = ReminderBatch(id:UUID(),destinationID:"list-a",destinationTitle:"Shopping",destinationSource:"Local",rows:[ReminderRow(id:UUID(),title:"2 eggs",status:.confirmed,reminderID:"fake-1")],createdAt:now)
        let uncertain = ReminderBatch(id:UUID(),destinationID:"list-a",destinationTitle:"Shopping",destinationSource:"Local",rows:[ReminderRow(id:UUID(),title:"2 eggs",status:.uncertain)],createdAt:now.addingTimeInterval(1))
        try check(AutomationController.matchingExport(rows:["2 eggs"],destinationID:"list-a",batches:[confirmed,uncertain])?.id == uncertain.id,"repeated identical export resolves existing durable uncertain batch")
        try check(AutomationController.matchingExport(rows:["3 eggs"],destinationID:"list-a",batches:[confirmed]) == nil,"changed content is distinct export")
        try check(AutomationController.matchingExport(rows:["2 eggs"],destinationID:"list-b",batches:[confirmed]) == nil,"different destination is distinct export")
        try check(AutomationController.matchingExport(rows:["2 eggs","2 eggs"],destinationID:"list-a",batches:[confirmed]) == nil,"intentional duplicate rows retain identity")
        withExtendedLifetime(toolbarHost) {}
        print("PASS AutomationControllerChecks: \(checks) native assertions; no Reminders access")
    }
}
