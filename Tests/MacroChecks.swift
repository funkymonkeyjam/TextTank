// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if TEXTTANK_NATIVE_MACRO_TEST
import AppKit
#endif

@main struct MacroChecks {
    static var checks=0
    static func check(_ condition:@autoclosure ()throws->Bool,_ name:String)throws{guard try condition()else{fatalError("FAIL \(name)")};checks+=1}
    static func rejects(_ name:String,_ work:()throws->Void){do{try work();fatalError("FAIL expected rejection: \(name)")}catch{checks+=1}}
    static func main()throws{
        let id=UUID()
        var macro=RecordedMacro(id:id,name:"My edit",steps:[
            .init(kind:.insertText,text:"½ café 👩🏽‍💻\0\r\n"),
            .init(kind:.command,command:"charLeft"),
            .init(kind:.findLiteral,text:"$()",matchCase:true,backwards:true),
            .init(kind:.replaceSelection,text:"2 eggs")])
        let library=MacroLibrary(macros:[macro]);let data=try library.encoded()
        try check(MacroLibrary.decode(data)==library,"capture data exact Unicode/NUL and find params roundtrip")
        macro.name="Renamed";try check(MacroLibrary.decode(MacroLibrary(macros:[macro]).encoded()).macros[0].id==id,"rename retains stable ID")
        let json=String(data:data,encoding:.utf8)!
        rejects("unknown command cannot launch shell"){_ = try MacroLibrary.decode(Data(json.replacingOccurrences(of:"charLeft",with:"executeShell").utf8))}
        rejects("unknown step kind"){_ = try MacroLibrary.decode(Data(json.replacingOccurrences(of:"insertText",with:"reminders").utf8))}
        rejects("pointer step rejected"){_ = try MacroLibrary.decode(Data(json.replacingOccurrences(of:"charLeft",with:"SCI_SETDOCPOINTER").utf8))}
        var invalid=macro;invalid.version=2;rejects("unknown version"){try invalid.validate()}
        invalid=macro;invalid.steps=[.init(kind:.command,command:"undo")];rejects("undo command cannot escape grouped replay"){try invalid.validate()}
        invalid.steps=[.init(kind:.findLiteral,text:"",matchCase:false,backwards:false)];rejects("empty find"){try invalid.validate()}
        invalid.steps=[.init(kind:.findLiteral,text:"needle")];rejects("missing captured find parameters"){try invalid.validate()}
        invalid.steps=[.init(kind:.insertText,text:"x",command:"cut")];rejects("incompatible parameters"){try invalid.validate()}
        rejects("duplicate macro ID"){try MacroLibrary(macros:[macro,macro]).validate()}
        var other=macro;other.id=UUID();try check(MacroLibrary.decode(MacroLibrary(macros:[macro,other]).encoded()).macros.count==2,"same names different IDs remain distinct")
        #if TEXTTANK_NATIVE_MACRO_TEST
        let oldSupport=ProcessInfo.processInfo.environment["TEXTTANK_SUPPORT_DIRECTORY"]
        let testSupport=FileManager.default.temporaryDirectory.appendingPathComponent("TextTankMacroChecks-"+UUID().uuidString)
        setenv("TEXTTANK_SUPPORT_DIRECTORY",testSupport.path,1)
        defer { if let oldSupport {setenv("TEXTTANK_SUPPORT_DIRECTORY",oldSupport,1)}else{unsetenv("TEXTTANK_SUPPORT_DIRECTORY")};try? FileManager.default.removeItem(at:testSupport) }
        _ = NSApplication.shared
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:400),styleMask:[.titled],backing:.buffered,defer:false)
        let editor=TTEditor(frame:window.contentView!.bounds);window.contentView=editor
        let controller=MacroController(editorProvider:{editor})
        let original="café egg egg 👩🏽‍💻"
        editor.text=original;editor.resetUndoHistory();editor.setSavePoint()
        let edit=RecordedMacro(id:UUID(),name:"Literal replacement",steps:[.init(kind:.findLiteral,text:"egg",matchCase:true,backwards:false),.init(kind:.replaceSelection,text:"milk")])
        try controller.play(edit,on:editor,repeats:2)
        try check(editor.text=="café milk milk 👩🏽‍💻","native literal find/replace repeat captures parameters")
        editor.executeCommand("undo")
        try check(editor.text==original,"native repeated macro is one Undo group")
        editor.executeCommand("selectAll")
        let failing=RecordedMacro(id:UUID(),name:"Stop on missing search",steps:[.init(kind:.insertText,text:"changed"),.init(kind:.findLiteral,text:"absent",matchCase:false,backwards:false)])
        rejects("native missing search aborts"){try controller.play(failing,on:editor)}
        try check(editor.text=="changed","native earlier edit retained for explicit Undo")
        editor.executeCommand("undo");try check(editor.text==original,"native partial replay remains one Undo")
        controller.startRecording();editor.executeCommand("newLine")
        let captured=try controller.finishRecording()
        try check(captured?.steps.contains(where:{$0.kind == .insertText}) == true,"actual native newline recording remains saveable")
        controller.startRecording();editor.executeCommand("charRight")
        controller.willExecuteCommand("trimTrailing",on:editor);editor.executeCommand("trimTrailing")
        rejects("target-based trim cannot silently save partial recording"){_ = try controller.finishRecording()}
        let clone=TTEditor(frame:NSRect(x:0,y:0,width:300,height:400));clone.shareDocument(with:editor)
        controller.startRecording();editor.executeCommand("charRight")
        controller.editorDidFocus(clone);clone.executeCommand("newLine")
        rejects("clone focus switch invalidates incomplete recording"){_ = try controller.finishRecording()}
        controller.startRecording();editor.executeCommand("charRight")
        controller.invalidateRecording(reason:"Automation invoked")
        rejects("automation invocation invalidates incomplete recording"){_ = try controller.finishRecording()}
        controller.startRecording();editor.executeCommand("charRight")
        controller.editorWillReset(editor,reason:"Reloaded")
        rejects("reload cannot leave saveable partial macro"){_ = try controller.finishRecording()}
        controller.startRecording();editor.executeCommand("newLine");editor.executeCommand("undo")
        rejects("native Undo cannot silently save partial recording"){_ = try controller.finishRecording()}
        controller.startRecording();editor.executeCommand("charRight")
        controller.willExecuteCommand("zoomIn",on:editor);editor.executeCommand("zoomIn")
        try check(controller.finishRecording()?.steps.count == 1,"view-only zoom does not invalidate valid edit recording")
        editor.text = "a\nb\nc"; editor.resetUndoHistory(); _ = editor.setSelectionAnchor(0,caret:0)
        let advance = RecordedMacro(id:UUID(),name:"Advance",steps:[.init(kind:.command,command:"charRight")])
        try controller.play(advance,on:editor,untilEnd:true)
        try check(editor.selectionCaret == editor.text.utf8.count,"until-end playback reaches document boundary")
        _ = editor.setSelectionAnchor(0,caret:0)
        let stalled = RecordedMacro(id:UUID(),name:"No movement",steps:[.init(kind:.command,command:"home")])
        rejects("until-end no-progress guard") { try controller.play(stalled,on:editor,untilEnd:true) }
        editor.text = "original"; editor.resetUndoHistory(); _ = editor.setSelectionAnchor(0,caret:0)
        let typing = RecordedMacro(id:UUID(),name:"Typing",steps:[.init(kind:.insertText,text:"x")])
        var calls = 0
        rejects("cancel playback between steps") { try controller.play(typing,on:editor,repeats:100,shouldCancel:{ calls += 1; return calls > 3 }) }
        try check(editor.text == "xxxoriginal","cancel retains only completed steps")
        editor.executeCommand("undo"); try check(editor.text == "original","cancelled playback remains one Undo")
        let search = RecordedMacro.Search(query:"(egg)",replacement:"$1s",mode:2,matchCase:true,wholeWord:false,dotMatchesNewline:false,wrap:true,action:"replaceAll")
        let searchMacro = RecordedMacro(id:UUID(),name:"Captured search",steps:[.init(kind:.search,search:search)])
        try check(MacroLibrary.decode(MacroLibrary(macros:[searchMacro]).encoded()).macros[0] == searchMacro,"all regex parameters roundtrip")
        var observed:RecordedMacro.Search?
        controller.searchPlayback = { captured,target in observed = captured; target.replaceSelection("called") }
        try controller.play(searchMacro,on:editor)
        try check(observed == search,"search playback uses captured parameters through adapter")
        #endif
        print("PASS MacroChecks: \(checks) assertions; persistence/security checks; native integration only when TEXTTANK_NATIVE_MACRO_TEST is defined")
    }
}
