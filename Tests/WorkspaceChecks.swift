// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

@main struct WorkspaceChecks {
    static var checks=0
    static func check(_ condition:@autoclosure ()throws->Bool,_ name:String)throws {
        guard try condition() else { fatalError("FAIL: \(name)") }
        checks += 1
    }
    static func rejects(_ name:String,_ action:()throws->Void) {
        do { try action();fatalError("FAIL expected rejection: \(name)") }
        catch { checks += 1 }
    }
    static func main()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TextTankWorkspaceChecks-"+UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let original=root.appendingPathComponent("file with 'quotes' and $().txt")
        let disk=Data([0xEF,0xBB,0xBF])+Data("disk content\r\n".utf8)
        try disk.write(to:original)
        let text="\u{FEFF}½ café 🦋\0\r\n2 eggs\nlast\r"
        let id=UUID()
        let document=SessionDocument(id:id,originalURL:original,text:text,format:FileFormat(encoding:.windows1252,bom:false),isDirty:true,selection:SessionSelection(anchorByte:text.utf8.count,caretByte:0),bookmarks:[0,2],language:"cpp",originalSHA256:WorkspaceStore.fingerprint(disk))
        var session=WorkspaceSession(id:UUID(),name:"My $(not executable) session",documents:[document],activeDocumentID:id)
        let destination=root.appendingPathComponent("session.texttank-session")
        try WorkspaceStore.save(session,to:destination)
        try check(WorkspaceStore.load(from:destination)==session,"session roundtrips Unicode/NUL/FEFF, unsaved legacy-unrepresentable text, format, URL, reversed selection and bookmarks")
        try check(Data(contentsOf:original)==disk,"saving snapshot never modifies original document")
        try check((FileManager.default.attributesOfItem(atPath:destination.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600,"session content file is private0600")
        try check(session.inspectReferencedFiles().first?.status == .unchanged,"original fingerprint matches")
        let stableID=session.id;session.name="Renamed session"
        try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:destination.path)
        try WorkspaceStore.save(session,to:destination)
        try check(WorkspaceStore.load(from:destination).id==stableID,"rename preserves session identity")
        try check((FileManager.default.attributesOfItem(atPath:destination.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600,"atomic replacement keeps new private metadata")
        try Data("external changed bytes".utf8).write(to:original)
        try check(session.inspectReferencedFiles().first?.status == .changed,"outside changes explicitly classified, retained snapshot remains")
        try FileManager.default.removeItem(at:original)
        try check(session.inspectReferencedFiles().first?.status == .missing,"missing original explicitly classified without losing snapshot")
        try check(WorkspaceStore.load(from:destination).documents[0].text==text,"missing original does not prevent loading retained edits")
        var noHash=session;noHash.documents[0].originalSHA256=nil
        try disk.write(to:original)
        try check(noHash.inspectReferencedFiles()[0].status == .unverified,"absent fingerprint is not falsely unchanged")
        var untitled=session;untitled.documents[0].originalURL=nil;untitled.documents[0].originalSHA256=nil
        try check(untitled.inspectReferencedFiles()[0].status == .untitled,"untitled document remains typed snapshot")
        let encoded=try session.encoded();let json=String(data:encoded,encoding:.utf8)!
        rejects("unknown schema"){_ = try WorkspaceSession.decode(Data(json.replacingOccurrences(of:"\"schemaVersion\":1",with:"\"schemaVersion\":2").utf8))}
        rejects("corrupt JSON"){_ = try WorkspaceSession.decode(Data("{bad".utf8))}
        var bad=session;bad.documents.append(document)
        rejects("duplicate document IDs"){try bad.validate()}
        bad=session;bad.activeDocumentID=UUID();rejects("unknown active document"){try bad.validate()}
        bad=session;bad.documents[0].selection.caretByte = -1;rejects("negative position"){try bad.validate()}
        bad=session;bad.documents[0].selection.caretByte = text.utf8.count+1;rejects("position beyond buffer"){try bad.validate()}
        bad=session;bad.documents[0].selection.caretByte = 1;rejects("position splits FEFF UTF8 sequence"){try bad.validate()}
        bad=session;bad.documents[0].bookmarks=[100];rejects("bookmark out of line range"){try bad.validate()}
        bad=session;bad.documents[0].bookmarks=[0,0];rejects("duplicate bookmark"){try bad.validate()}
        bad=session;bad.documents[0].format.bom=true;rejects("legacy BOM invalid"){try bad.validate()}
        bad=session;bad.documents[0].originalURL=URL(string:"https://example.com/file")!;rejects("remote executable URL rejected"){try bad.validate()}
        bad=session;bad.documents[0].originalSHA256="bad";rejects("bad hash rejected"){try bad.validate()}
        let fifo=root.appendingPathComponent("fifo")
        guard mkfifo(fifo.path,mode_t(0o600)) == 0 else { fatalError("Cannot create FIFO fixture") }
        let fifoStart=ProcessInfo.processInfo.systemUptime
        rejects("FIFO load rejects without blocking") { _ = try WorkspaceStore.load(from:fifo) }
        var fifoReference=session;fifoReference.documents[0].originalURL=fifo
        if case .unreadable = fifoReference.inspectReferencedFiles()[0].status {checks+=1}else{fatalError("FAIL FIFO reference must be unreadable")}
        try check(ProcessInfo.processInfo.systemUptime-fifoStart < 2,"FIFO inspection bounded below two seconds")
        let before=try Data(contentsOf:destination)
        rejects("invalid snapshot cannot replace good session"){try WorkspaceStore.save(bad,to:destination)}
        try check(Data(contentsOf:destination)==before,"validation failure preserves previous session bytes")
        let link=root.appendingPathComponent("linked-session")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:destination)
        rejects("loading session symlink"){_ = try WorkspaceStore.load(from:link)}
        rejects("saving session symlink"){try WorkspaceStore.save(session,to:link)}
        try check(Data(contentsOf:destination)==before,"symlink destination not overwritten")
        let dangling=root.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at:dangling,withDestinationURL:root.appendingPathComponent("absent"))
        rejects("dangling symlink rejected"){try WorkspaceStore.save(session,to:dangling)}
        let linkedDirectory=root.appendingPathComponent("linked-directory")
        try FileManager.default.createSymbolicLink(at:linkedDirectory,withDestinationURL:root)
        rejects("symlink storage directory rejected"){try WorkspaceStore.save(session,to:linkedDirectory.appendingPathComponent("new-session"))}
        let referenceLink=root.appendingPathComponent("reference-link")
        try FileManager.default.createSymbolicLink(at:referenceLink,withDestinationURL:original)
        var linkedReference=session;linkedReference.documents[0].originalURL=referenceLink
        if case .unreadable = linkedReference.inspectReferencedFiles()[0].status {checks+=1}else{fatalError("FAIL reference symlink must be explicit unreadable")}
        rejects("directory is not session file"){_ = try WorkspaceStore.load(from:root)}
        rejects("read resource limit enforced"){_ = try WorkspaceStore.readRegularFile(destination,maximumBytes:2)}
        let badParent=root.appendingPathComponent("not-directory");try Data("keep".utf8).write(to:badParent)
        rejects("partial-write path failure"){try WorkspaceStore.save(session,to:badParent.appendingPathComponent("session"))}
        try check(Data(contentsOf:badParent)==Data("keep".utf8),"failed storage leaves obstruction untouched")
        try check(FileManager.default.contentsOfDirectory(atPath:root.path).filter{$0.hasPrefix(".texttank-session-")}.isEmpty,"no temporary snapshot leaks after writes")
        print("PASS WorkspaceChecks: \(checks) assertions; no original document writes or executable actions")
    }
}
