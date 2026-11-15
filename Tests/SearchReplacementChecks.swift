import Foundation
import Darwin
@main struct SearchReplacementChecks {
    static func main()async throws {
        setbuf(stdout,nil)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TextTankReplacement-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        var count=0
        func check(_ value:Bool,_ label:String){precondition(value,label);count+=1;print("PASS \(label)")}
        let a=root.appendingPathComponent("a.txt"),b=root.appendingPathComponent("b.txt"),c=root.appendingPathComponent("c.txt")
        let original=try FileCodec.encode("🥑 key=12\r\n",format:FileFormat(encoding:.utf16LE,bom:true))
        try original.write(to:a);try Data("key=34".utf8).write(to:b);try Data("key=56".utf8).write(to:c)
        chmod(a.path,0o640)
        let attribute=Data("metadata fixture".utf8)
        let setAttribute=attribute.withUnsafeBytes{setxattr(a.path,"app.texttank.test",$0.baseAddress,$0.count,0,0)}
        check(setAttribute==0,"test metadata installed")
        // F128: back-date the file so a fresh modification time is unambiguous.
        var oldTimes=[timeval(tv_sec:1_577_836_800,tv_usec:0),timeval(tv_sec:1_577_836_800,tv_usec:0)]
        check(utimes(a.path,&oldTimes)==0,"test file back-dated")
        var dated=stat();stat(a.path,&dated)
        check(dated.st_mtimespec.tv_sec==1_577_836_800,"back-dated modification time observed")
        // F20/G343: an extended replacement that decodes to an unpaired surrogate must not reach disk.
        let lone=root.appendingPathComponent("lone.txt");try Data("key lone".utf8).write(to:lone)
        var loneRequest=FolderSearchRequest(directory:root,query:"lone");loneRequest.mode = .extended;loneRequest.extensions=["txt"]
        let loneReport=try await FolderSearch.search(loneRequest)
        check(loneReport.matches.count==1,"fixture: one match for the surrogate replacement case")
        var loneOptions=SearchOptions();loneOptions.mode = .extended;loneOptions.query="lone";loneOptions.replacement="\\uD83D"
        let loneResult=try FolderReplacement.replace(directory:root,matches:loneReport.matches,options:loneOptions)
        check(loneResult.count==1 && loneResult[0].status == .failed && loneResult[0].backup==nil && loneResult[0].message.contains("surrogate"),"unpaired-surrogate replacement fails the file with an explanation")
        check(try Data(contentsOf:lone)==Data("key lone".utf8),"unpaired-surrogate replacement leaves file bytes identical")
        check(try FileManager.default.contentsOfDirectory(atPath:root.path).sorted()==["a.txt","b.txt","c.txt","lone.txt"],"unpaired-surrogate replacement leaves no backup, journal or temporary file")
        try FileManager.default.removeItem(at:lone)
        var request=FolderSearchRequest(directory:root,query:"key=(\\d+)");request.mode = .regularExpression
        let report=try await FolderSearch.search(request)
        var options=SearchOptions();options.mode = .regularExpression;options.query=request.query;options.replacement="value=$1"
        let result=try FolderReplacement.replace(directory:root,matches:report.matches,options:options,excluding:[c])
        if result.contains(where:{$0.status == .failed}){print(result.map{$0.message})}
        check(result.filter{$0.status == .replaced}.count==2,"two disk files replaced with individual outcomes")
        check(try FileCodec.decode(Data(contentsOf:a)).text=="🥑 value=12\r\n","UTF16 BOM Unicode and CRLF preserved")
        let aResult=result.first{$0.url.lastPathComponent=="a.txt"}!
        check(try Data(contentsOf:aResult.backup!)==original,"byte-exact original backup retained")
        let journal=try JSONDecoder().decode([String:String].self,from:Data(contentsOf:aResult.backup!.appendingPathExtension("json")))
        check(journal["file"]=="a.txt" && journal["state"]=="replaced" && journal["originalSHA256"] != nil,"durable recovery report identifies committed file and original hash")
        var info=stat();stat(a.path,&info);check(info.st_mode&0o777==0o640,"original permission mode retained")
        check(info.st_mtimespec.tv_sec>dated.st_mtimespec.tv_sec && abs(Int(info.st_mtimespec.tv_sec)-Int(Date().timeIntervalSince1970))<120,"replaced file has fresh modification time")
        check(info.st_birthtimespec.tv_sec<=dated.st_birthtimespec.tv_sec,"replaced file keeps its creation date")
        var metadata=[UInt8](repeating:0,count:100);let size=getxattr(a.path,"app.texttank.test",&metadata,metadata.count,0,0)
        check(size==attribute.count && Data(metadata.prefix(max(0,size)))==attribute,"extended metadata preserved")
        check(try String(contentsOf:c,encoding:.utf8)=="key=56" && result.first{$0.url.lastPathComponent=="c.txt"}?.status == .skipped,"open document excluded without disk edits")
        let again=try FolderReplacement.replace(directory:root,matches:report.matches,options:options)
        check(again.filter{$0.status == .conflict}.count==2,"old search fingerprints reject repeat after file change")
        var fresh=FolderSearchRequest(directory:root,query:"value=(\\d+)");fresh.mode = .regularExpression;fresh.extensions=["txt"]
        let before=try await FolderSearch.search(fresh);options.query=fresh.query;options.replacement="next=$1"
        let changed=try FolderReplacement.replace(directory:root,matches:before.matches,options:options,beforeCommit:{url in if url.lastPathComponent=="a.txt"{try! Data("external writer".utf8).write(to:url)}})
        check(try changed.first{$0.url.lastPathComponent=="a.txt"}?.status == .conflict && String(contentsOf:a,encoding:.utf8)=="external writer","external writer before commit not overwritten")
        check(changed.first{$0.url.lastPathComponent=="b.txt"}?.status == .replaced,"independent file completes despite other conflict")
        let token=FolderSearchCancellation();token.cancel();let cancelled=try FolderReplacement.replace(directory:root,matches:before.matches,options:options,cancellation:token)
        check(cancelled.allSatisfy{$0.status == .cancelled},"cancellation reports unsent files")
        let link=root.appendingPathComponent("link.txt");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:b)
        var fake=before.matches.first{$0.url.lastPathComponent=="b.txt"}!
        fake=FolderSearchMatch(url:link,line:fake.line,columnUTF16:fake.columnUTF16,utf16Range:fake.utf16Range,utf8Range:fake.utf8Range,preview:fake.preview,previewMatchRange:fake.previewMatchRange,isMatchTruncatedInPreview:false,sourceSHA256:fake.sourceSHA256)
        check(try FolderReplacement.replace(directory:root,matches:[fake],options:options).first?.status == .failed,"symlink leaf rejected")
        print("PASS SearchReplacementChecks: \(count) assertions")
    }
}
