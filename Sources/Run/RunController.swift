// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

final class RunController:NSObject {
    var editor:()->TTEditor?={nil},file:()->URL?={nil}
    private var commands:[ConfiguredRun]=[],loadError:Error?,execution:RunExecution?
    private let menu=NSMenu(title:"Run")
    private var resultWindow:NSWindow?
    private weak var applyButton:NSButton?
    private var pending:(TTEditor,UInt,String,Bool,Int,Int)?
    let storage:URL
    override init(){
        let support=ProcessInfo.processInfo.environment["TEXTTANK_SUPPORT_DIRECTORY"].map{URL(fileURLWithPath:$0)} ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("TextTank")
        storage=support.appendingPathComponent("RunCommands.json");super.init()
        do{commands=try JSONDecoder().decode([ConfiguredRun].self,from:WorkspaceStore.readRegularFile(storage,maximumBytes:1024*1024));try ConfiguredRun.validateLibrary(commands)}
        catch let e as NSError where e.domain==NSPOSIXErrorDomain && e.code==ENOENT{}
        catch{loadError=error;commands=[]}
    }
    func makeMenu()->NSMenu{rebuild();return menu}
    private func rebuild(){
        menu.removeAllItems()
        for (title,action) in [("Configure Command…",#selector(configure(_:))),("Add Sample Text Extension",#selector(addSample(_:))),("Cancel Running Command",#selector(cancel(_:)))] {let item=NSMenuItem(title:title,action:action,keyEquivalent:"");item.target=self;menu.addItem(item)}
        menu.addItem(.separator())
        for command in commands{let item=NSMenuItem(title:command.name,action:#selector(run(_:)),keyEquivalent:"");item.target=self;item.representedObject=command.id.uuidString;menu.addItem(item)}
    }
    private func persist(_ updated:[ConfiguredRun])throws {
        try ConfiguredRun.validateLibrary(updated)
        try FileManager.default.createDirectory(at:storage.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try WorkspaceStore.writePrivate(JSONEncoder().encode(updated),to:storage);commands=updated;loadError=nil;rebuild()
    }
    @objc private func addSample(_ sender:Any?){do{if let error=loadError{throw error};if !commands.contains(where:{$0.extensionMode && $0.executable=="/usr/bin/tr"}){try persist(commands+[.uppercaseSample])}}catch{NSAlert(error:error).runModal()}}
    @objc private func configure(_ sender:Any?){
        if let error=loadError{NSAlert(error:error).runModal();return}
        let alert=NSAlert();alert.messageText="Configure Run Command";alert.informativeText="Runs only when explicitly selected. Arguments stay separate; use {file}, {directory}, or {selection} as a complete argument. Shell mode deliberately executes the argument as shell code."
        let name=NSTextField(string:""),path=NSTextField(string:"/usr/bin/printf"),args=NSTextField(string:"[\"%s\\n\",\"{file}\"]")
        let shell=NSButton(checkboxWithTitle:"Intentional shell mode (/bin/zsh -c)",target:nil,action:nil)
        let ext=NSButton(checkboxWithTitle:"Version 1 text extension (stdin → preview → explicit Apply)",target:nil,action:nil)
        let stack=NSStackView(views:[NSTextField(labelWithString:"Name"),name,NSTextField(labelWithString:"Executable"),path,NSTextField(labelWithString:"Arguments as JSON array (or shell script in shell mode)"),args,shell,ext]);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=6;stack.frame=NSRect(x:0,y:0,width:550,height:250)
        alert.accessoryView=stack;alert.addButton(withTitle:"Save Command");alert.addButton(withTitle:"Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else{return}
        do{
            let shellMode=shell.state == .on
            let argv=shellMode ? ["-c",args.stringValue]:try JSONDecoder().decode([String].self,from:Data(args.stringValue.utf8))
            let command=ConfiguredRun(name:name.stringValue,executable:shellMode ? "/bin/zsh":path.stringValue,arguments:argv,shellMode:shellMode,extensionMode:ext.state == .on)
            try persist(commands+[command])
        }catch{NSAlert(error:error).runModal()}
    }
    @objc private func cancel(_ sender:Any?){execution?.cancel()}
    @objc private func run(_ sender:NSMenuItem){
        guard execution==nil,let id=sender.representedObject as? String,let configured=commands.first(where:{$0.id.uuidString==id}) else{return}
        pending=nil;applyButton?.isEnabled=false;resultWindow?.close();resultWindow=nil
        let target=editor(),selected=(target?.selectionStart != target?.selectionEnd),revision=target?.revision ?? 0
        let anchor=target?.selectionAnchor ?? 0,caret=target?.selectionCaret ?? 0
        do {
            if configured.extensionMode && (target==nil || target?.selectionCount != 1 || target?.readOnly == true){throw RunFailure.invalid}
            let command=try configured.resolved(file:file(),selection:target?.selectedText ?? "")
            let input=configured.extensionMode ? Data((selected ? (target?.selectedText ?? ""):(target?.text ?? "")).utf8):Data()
            let run=RunExecution();execution=run
            DispatchQueue.global(qos:.userInitiated).async{[weak self] in
                let outcome=Result{try run.execute(command,input:input)}
                DispatchQueue.main.async{self?.execution=nil;self?.show(outcome,command:command,target:target,revision:revision,selection:selected,anchor:anchor,caret:caret)}
            }
        }catch{NSAlert(error:error).runModal()}
    }
    func show(_ outcome:Result<RunResult,Error>,command:ConfiguredRun,target:TTEditor?,revision:UInt,selection:Bool,anchor:Int,caret:Int){
        pending=nil;applyButton?.isEnabled=false;resultWindow?.close();resultWindow=nil
        switch outcome{
        case .failure(let error):NSAlert(error:error).runModal()
        case .success(let result):
            let decoded=String(decoding:result.stdout,as:UTF8.self)
            let output:String?=decoded.utf8.elementsEqual(result.stdout) ? decoded:nil
            let status="Exit \(result.status) · \(result.cancelled ? "cancelled/timed out":"finished")\(result.truncated ? " · output truncated":"")"
            let view=NSTextView();view.isEditable=false;view.isRichText=false;view.font = .monospacedSystemFont(ofSize:12,weight:.regular)
            view.string=status+"\n\n"+(output ?? "Output is not valid UTF-8")+"\n\nStandard error:\n"+String(decoding:result.stderr,as:UTF8.self)
            let scroll=NSScrollView();scroll.documentView=view;scroll.hasVerticalScroller=true;view.autoresizingMask=[.width];view.isVerticallyResizable=true
            let button=NSButton(title:"Apply Extension Result",target:self,action:#selector(apply(_:)))
            applyButton=button;pending=nil
            if command.extensionMode,result.status==0,!result.cancelled,!result.truncated,let target,let output {pending=(target,revision,output,selection,anchor,caret)}
            button.isEnabled=pending != nil
            let stack=NSStackView(views:[scroll,button]);stack.orientation = .vertical;scroll.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true;scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:300).isActive=true
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:700,height:450),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false);window.title=command.name;window.isReleasedWhenClosed=false;window.contentView=stack;resultWindow=window;window.makeKeyAndOrderFront(nil)
        }
    }
    @objc func apply(_ sender:NSButton){
        guard sender === applyButton else{return}
        guard let(target,revision,output,selection,anchor,caret)=pending,target.window != nil,target.revision==revision,!target.readOnly,target.selectionCount==1,(!selection || (target.selectionAnchor==anchor && target.selectionCaret==caret)) else{pending=nil;sender.isEnabled=false;NSSound.beep();return}
        target.beginUndoGroup();defer{target.endUndoGroup()};if selection{target.replaceSelection(output)}else{target.text=output};pending=nil;sender.isEnabled=false
    }
}
