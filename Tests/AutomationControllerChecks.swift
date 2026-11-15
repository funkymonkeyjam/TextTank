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
    static func descendants(_ view:NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func typeKeys(_ text:String, in window:NSWindow) {
        for character in text {
            let value=String(character)
            let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:value,charactersIgnoringModifiers:value,isARepeat:false,keyCode:0)!
            window.sendEvent(event)
        }
    }
    static func ruleKeyboardCheck() -> (Bool,Bool,AutomationDefinition.Step?) {
        var actionSent=false, fieldsEnabled=false, acted=false
        let deadline=Date().addingTimeInterval(5)
        let timer=Timer(timeInterval:0.1,repeats:true) { _ in
            guard let modal=NSApp.modalWindow,let content=modal.contentView else{return}
            if Date()>deadline { NSApp.abortModal();return }
            guard !acted else{return}
            let views=descendants(content)
            guard let popup=views.compactMap({$0 as? NSPopUpButton}).first,
                  let save=views.compactMap({$0 as? NSButton}).first(where:{$0.title=="Save Rule"}) else{return}
            acted=true
            popup.selectItem(at:AutomationDefinition.Step.Kind.allCases.firstIndex(of:.replaceLiteral)!)
            if let action=popup.action { actionSent=NSApp.sendAction(action,to:popup.target,from:popup) }
            let fields=views.compactMap{$0 as? NSTextField}.filter{$0.isEditable}
            guard fields.count==2 else { NSApp.abortModal();return }
            fieldsEnabled=fields.allSatisfy{$0.isEnabled}
            guard fieldsEnabled else { NSApp.abortModal();return }
            fields[0].selectText(nil);typeKeys("[salt]",in:modal)
            fields[1].selectText(nil);typeKeys("2 eggs",in:modal)
            save.performClick(nil)
        }
        RunLoop.main.add(timer,forMode:.modalPanel)
        let result=AutomationStepEditor.editStep(.init(kind:.removeBlankLines))
        timer.invalidate()
        return (actionSent,fieldsEnabled,result)
    }
    static func modalKeyboardChecks(_ controller:AutomationController) throws {
        var stage=0, nameAccepted=false, sampleAccepted=false, reentryBlocked=false, timedOut=false
        var nestedRule:(Bool,Bool,AutomationDefinition.Step?) = (false,false,nil)
        let deadline=Date().addingTimeInterval(8)
        let timer=Timer(timeInterval:0.1,repeats:true) { _ in
            guard let modal=NSApp.modalWindow,let content=modal.contentView else{return}
            let views=descendants(content), buttons=views.compactMap{$0 as? NSButton}
            if Date() > deadline { timedOut=true;NSApp.abortModal();return }
            if stage==0,let create=buttons.first(where:{$0.title=="Create Automation…"}) {
                stage=1;create.performClick(nil)
            } else if stage==1,let name=views.compactMap({$0 as? NSTextField}).first(where:{$0.stringValue=="My Automation" && $0.isEditable}) {
                stage=2
                name.selectText(nil)
                typeKeys("Keyboard Recipe",in:modal)
                modal.makeFirstResponder(nil)
                nameAccepted=name.stringValue=="Keyboard Recipe" && name.isEditable
                // A guarded management call must return without creating another modal.
                // A nested watchdog closes a regression-created alert so the test never hangs.
                var openedNested=false
                let guardTimer=Timer(timeInterval:0.1,repeats:false) { _ in
                    if NSApp.modalWindow !== modal { openedNested=true;NSApp.abortModal() }
                }
                RunLoop.main.add(guardTimer,forMode:.modalPanel)
                controller.manage()
                guardTimer.invalidate()
                reentryBlocked = !openedNested && NSApp.modalWindow === modal
            } else if stage==2,let cancel=buttons.first(where:{$0.title=="Cancel"}),let sample=views.compactMap({$0 as? NSTextView}).first(where:{$0.accessibilityLabel()=="Sample input"}) {
                stage=3
                modal.makeFirstResponder(sample)
                typeKeys("2 eggs",in:modal)
                sampleAccepted=sample.string=="2 eggs" && modal.firstResponder === sample
                nestedRule=ruleKeyboardCheck()
                cancel.performClick(nil)
            }
        }
        RunLoop.main.add(timer,forMode:.modalPanel)
        controller.manage()
        timer.invalidate()
        try check(!timedOut && stage==3,"native Create Automation and Rules modal chain completed")
        try check(nameAccepted,"Create Automation name accepts dispatched keyboard events")
        try check(sampleAccepted,"Sample Input accepts dispatched keyboard events")
        try check(reentryBlocked,"management cannot open another dialog during Create Automation")
        try check(nestedRule.0,"nested rule popup dispatch reaches retained controller target")
        try check(nestedRule.1,"changing rule kind enables find and replacement fields")
        try check(nestedRule.2?.kind == .replaceLiteral && nestedRule.2?.find == "[salt]" && nestedRule.2?.replacement == "2 eggs","nested Save Rule commits keyboard-entered find and replacement")
    }
    static func horizontalDialogChecks() throws {
        let alert = TTAlert()
        alert.messageText = "Horizontal action regression"
        let field = NSTextField(frame:NSRect(x:0,y:0,width:420,height:28))
        field.stringValue = "Draft survives reopening"
        alert.accessoryView = field
        for title in ["Save", "Cancel", "Reset Defaults"] { alert.addButton(withTitle:title) }
        for index in [2, 1, 0] {
            var aligned = false
            let timer = Timer(timeInterval:0.1,repeats:false) { _ in
                let frames = alert.buttons.map { $0.convert($0.bounds,to:alert.window.contentView) }
                aligned = frames.allSatisfy { abs($0.midY-frames[0].midY)<1 } && frames[2].maxX<frames[1].minX && frames[1].maxX<frames[0].minX
                alert.buttons[index].performClick(nil)
            }
            RunLoop.main.add(timer,forMode:.modalPanel)
            let response = alert.runModal(); timer.invalidate()
            try check(response.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue+index,"horizontal dialog preserves response index \(index)")
            try check(aligned,"horizontal dialog actions remain side by side on presentation \(index)")
            try check(field.stringValue == "Draft survives reopening","horizontal dialog preserves accessory on presentation \(index)")
        }
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TextTankAutomationControllerChecks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let old = ProcessInfo.processInfo.environment["TEXTTANK_SUPPORT_DIRECTORY"]
        setenv("TEXTTANK_SUPPORT_DIRECTORY",root.path,1)
        defer { if let old { setenv("TEXTTANK_SUPPORT_DIRECTORY",old,1) } else { unsetenv("TEXTTANK_SUPPORT_DIRECTORY") }; try? FileManager.default.removeItem(at:root) }
        _ = NSApplication.shared
        try horizontalDialogChecks()
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
        let multiSource = "- 2 eggs | - ½ cup flour"
        editor.text = multiSource; editor.resetUndoHistory(); editor.setSavePoint()
        try check(editor.setSelectionRanges([["anchor":NSNumber(value:0),"caret":NSNumber(value:8)],["anchor":NSNumber(value:multiSource.utf8.count),"caret":NSNumber(value:11)]]),"set separate reversed Unicode selections")
        try restarted.runSavedAutomation(id:AutomationDefinition.example.id)
        try check(editor.text == "2 eggs | ½ cup flour","automation transforms each captured selection independently")
        editor.executeCommand("undo")
        try check(editor.text == multiSource,"multiple automation selections undo together")
        saved.workflows[0].steps = [.init(kind:.removeMatchingLines,find:"(a+)+$")]
        try restarted.persistLibrary(saved)
        let multiFailure = "safe | " + String(repeating:"a",count:32) + "!"
        editor.text = multiFailure; editor.resetUndoHistory(); editor.setSavePoint()
        _ = editor.setSelectionRanges([["anchor":NSNumber(value:0),"caret":NSNumber(value:4)],["anchor":NSNumber(value:7),"caret":NSNumber(value:multiFailure.utf8.count)]])
        do { try restarted.runSavedAutomation(id:AutomationDefinition.example.id); fatalError("expected second-selection timeout") } catch {}
        try check(editor.text == multiFailure && !editor.modified,"later selection failure preserves all earlier selections")
        saved.workflows[0].steps = AutomationDefinition.example.steps
        _ = editor.setSelectionAnchor(0,caret:0)
        saved.workflows[0].input = .document; saved.workflows[0].output = .newDocument
        var capturedNewDocument:String?
        let outputController = AutomationController(editorProvider:{editor},newDocument:{ capturedNewDocument = $0 })
        try outputController.persistLibrary(saved)
        editor.text = "- eggs\n- flour"; editor.resetUndoHistory(); editor.setSavePoint()
        _ = editor.setSelectionRanges([["anchor":NSNumber(value:0),"caret":NSNumber(value:6)],["anchor":NSNumber(value:7),"caret":NSNumber(value:14)]])
        try outputController.runSavedAutomation(id:AutomationDefinition.example.id)
        try check(editor.text == "- eggs\n- flour" && !editor.modified && capturedNewDocument == "eggs\nflour","document input external output never mutates multi-selection editor")
        saved.workflows[0].output = .editor; try restarted.persistLibrary(saved)
        _ = editor.setSelectionAnchor(0,caret:0); editor.readOnly = true
        do { try restarted.runSavedAutomation(id:AutomationDefinition.example.id); fatalError("read-only expected rejection") } catch {}
        try check(editor.text == "- eggs\n- flour" && !editor.modified,"read-only automation explicitly rejects without changes")
        editor.readOnly = false
        saved.workflows[0].pinToToolbar = false
        try restarted.persistLibrary(saved)
        try check(restarted.toolbarIdentifiers().count == 1,"toolbar pin setting hides only configured workflow")
        // Four literal user examples run through a persisted named automation.
        // No connector or new-document output is invoked by recipe cleanup.
        let preservedWorkflow=saved.workflows[0]
        saved.workflows[0].name="My ingredient cleanup"
        saved.workflows[0].input = .document; saved.workflows[0].output = .editor
        saved.workflows[0].previewBeforeApply=false
        saved.workflows[0].steps=AutomationDefinition.shoppingRecipeSteps
        try restarted.persistLibrary(saved)
        let sampleWindows=NSApp.windows.count
        for sample in 1...4 {
            let input=try String(contentsOfFile:"Tests/Fixtures/recipe-user-sample\(sample)-input.txt",encoding:.utf8)
            let expected=try String(contentsOfFile:"Tests/Fixtures/recipe-user-sample\(sample)-expected.txt",encoding:.utf8)
            editor.text=input;editor.resetUndoHistory();editor.setSavePoint()
            _ = editor.setSelectionAnchor(0,caret:0)
            try restarted.runSavedAutomation(id:preservedWorkflow.id)
            try check(editor.text.utf8.elementsEqual(expected.utf8),"sample \(sample) native exact literal expected bytes")
            try check(editor.window === window && window.contentView === editor && NSApp.windows.count==sampleWindows,"sample \(sample) uses same editor and window")
            editor.executeCommand("undo")
            try check(editor.text.utf8.elementsEqual(input.utf8) && !editor.modified,"sample \(sample) one Undo restores original bytes and savepoint")
        }
        try check(newDocumentCalls==0,"all four samples avoid new-document output")
        saved.workflows[0]=preservedWorkflow;try restarted.persistLibrary(saved)
        let now = Date()
        let confirmed = ReminderBatch(id:UUID(),destinationID:"list-a",destinationTitle:"Shopping",destinationSource:"Local",rows:[ReminderRow(id:UUID(),title:"2 eggs",status:.confirmed,reminderID:"fake-1")],createdAt:now)
        let uncertain = ReminderBatch(id:UUID(),destinationID:"list-a",destinationTitle:"Shopping",destinationSource:"Local",rows:[ReminderRow(id:UUID(),title:"2 eggs",status:.uncertain)],createdAt:now.addingTimeInterval(1))
        try check(AutomationController.matchingExport(rows:["2 eggs"],destinationID:"list-a",batches:[confirmed,uncertain])?.id == uncertain.id,"repeated identical export resolves existing durable uncertain batch")
        try check(AutomationController.matchingExport(rows:["3 eggs"],destinationID:"list-a",batches:[confirmed]) == nil,"changed content is distinct export")
        try check(AutomationController.matchingExport(rows:["2 eggs"],destinationID:"list-b",batches:[confirmed]) == nil,"different destination is distinct export")
        try check(AutomationController.matchingExport(rows:["2 eggs","2 eggs"],destinationID:"list-a",batches:[confirmed]) == nil,"intentional duplicate rows retain identity")
        let beforeModal=try Data(contentsOf:path)
        try modalKeyboardChecks(restarted)
        try check(try Data(contentsOf:path)==beforeModal,"Cancel from keyboard-edited rule draft preserves saved definitions")
        withExtendedLifetime(toolbarHost) {}
        print("PASS AutomationControllerChecks: \(checks) native assertions; no Reminders access")
    }
}
