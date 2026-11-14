// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

struct SearchSpan: Equatable, Codable, Sendable {
    let location:Int
    let length:Int
}
struct FolderSearchRequest: Sendable {
    let directory:URL
    let query:String
    var matchCase=true
    var recursive=true
    var includeHidden=false
    /// Exact filename extensions, without dots; empty searches all regular files.
    var extensions:Set<String>=[]
    var maximumFiles=10000
    var maximumEntries=100000
    var maximumFileBytes=32*1024*1024
    var maximumTotalBytes=256*1024*1024
    var maximumResults=10000
    var previewUTF16Length=240
}
struct FolderSearchMatch: Equatable, Sendable {
    let url:URL
    /// One-based line and UTF-16 column, with CRLF counted as one line ending.
    let line:Int
    let columnUTF16:Int
    /// Offsets refer to decoded editor text, not original encoded/BOM file bytes.
    let utf16Range:SearchSpan
    let utf8Range:SearchSpan
    let preview:String
    let previewMatchRange:SearchSpan
    let isMatchTruncatedInPreview:Bool
}
enum FolderSearchSkipReason: Equatable, Sendable {
    case symbolicLink, hidden, nonRecursiveDirectory, extensionFiltered, notRegularFile, fileTooLarge
    case invalidEncoding(String), unreadable(String)
}
struct FolderSearchSkipped: Equatable, Sendable {
    let url:URL
    let reason:FolderSearchSkipReason
}
enum FolderSearchLimit:String, Sendable { case entries,files,totalBytes,results }
struct FolderSearchReport: Sendable {
    var matches:[FolderSearchMatch]=[]
    var skipped:[FolderSearchSkipped]=[]
    var entriesVisited=0
    var filesConsidered=0
    var filesSearched=0
    var bytesRead=0
    var wasCancelled=false
    var reachedLimit:FolderSearchLimit?
    /// Policy exclusions are expected; unreadable/oversized files make coverage incomplete.
    var isComplete:Bool { !wasCancelled && reachedLimit == nil && !skipped.contains { item in
        switch item.reason {
        case .invalidEncoding, .unreadable, .fileTooLarge:return true
        default:return false
        }
    } }
}
struct FolderSearchProgress: Sendable {
    let filesSearched:Int
    let bytesRead:Int
    let matches:Int
    let currentURL:URL
}
final class FolderSearchCancellation: @unchecked Sendable {
    private let lock=NSLock()
    private var cancelled=false
    func cancel(){lock.lock();cancelled=true;lock.unlock()}
    var isCancelled:Bool{lock.lock();defer{lock.unlock()};return cancelled}
}
enum FolderSearchError: LocalizedError {
    case invalidRequest(String)
    var errorDescription:String? { switch self {case .invalidRequest(let reason):return reason} }
}

/// Read-only literal search. This does not implement Boost/Notepad++ regex semantics,
/// replacement, glob syntax, word boundaries or automatic legacy-encoding guessing.
/// Foundation case-insensitive literal matching is explicitly a Mac behavior here.
/// Cancellation is cooperative between bounded reads and during scalar mapping;
/// FileCodec decode and Foundation literal matching finish their current operation
/// first. A default-limit 32 MiB decode can delay cancellation by about two seconds.
/// Progress executes on the background worker; UI consumers must dispatch to MainActor.
enum FolderSearch {
    static func search(_ request:FolderSearchRequest,cancellation:FolderSearchCancellation=FolderSearchCancellation(),progress:(@Sendable(FolderSearchProgress)->Void)?=nil)async throws->FolderSearchReport {
        if Task.isCancelled{cancellation.cancel()}
        let work=Task.detached(priority:.userInitiated){try run(request,cancellation:cancellation,progress:progress)}
        return try await withTaskCancellationHandler(operation:{try await work.value},onCancel:{cancellation.cancel()})
    }
    private static func validate(_ request:FolderSearchRequest)throws {
        guard request.directory.isFileURL,(request.directory.host ?? "").isEmpty || request.directory.host == "localhost",!request.directory.path.contains("\0"),!request.query.isEmpty else {throw FolderSearchError.invalidRequest("Choose a local directory and nonempty literal search text.")}
        guard request.maximumFiles>0,request.maximumEntries>0,request.maximumFileBytes>0,request.maximumTotalBytes>0,request.maximumResults>0,(16...8192).contains(request.previewUTF16Length) else {throw FolderSearchError.invalidRequest("Search limits must be positive and preview length must be 16–8192 UTF-16 units.")}
        guard request.extensions.allSatisfy({!$0.isEmpty && !$0.contains("/") && !$0.contains("\\") && !$0.contains("\0") && !$0.contains(".")}) else {throw FolderSearchError.invalidRequest("Extension filters must be exact extensions without dots or path separators.")}
    }
    private static func run(_ request:FolderSearchRequest,cancellation:FolderSearchCancellation,progress:(@Sendable(FolderSearchProgress)->Void)?)throws->FolderSearchReport {
        try validate(request)
        let rootFD=open(request.directory.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW)
        guard rootFD>=0 else {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
        defer{close(rootFD)}
        // Normalize platform aliases only after rejecting a symlink root itself.
        var canonicalPath=[CChar](repeating:0,count:Int(MAXPATHLEN))
        guard fcntl(rootFD,F_GETPATH,&canonicalPath)==0 else {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
        let root=URL(fileURLWithPath:String(cString:canonicalPath),isDirectory:true)
        var report=FolderSearchReport()
        if cancellation.isCancelled{report.wasCancelled=true;return report}
        var enumerationErrors:[FolderSearchSkipped]=[]
        let keys:Set<URLResourceKey>=[.isSymbolicLinkKey,.isDirectoryKey,.isRegularFileKey,.isHiddenKey,.fileSizeKey]
        guard let iterator=FileManager.default.enumerator(at:root,includingPropertiesForKeys:Array(keys),options:[],errorHandler:{url,error in
            enumerationErrors.append(FolderSearchSkipped(url:url,reason:.unreadable(error.localizedDescription)));return !cancellation.isCancelled
        }) else {throw FolderSearchError.invalidRequest("The selected directory could not be enumerated.")}
        let extensionFilter=Set(request.extensions.map{$0.lowercased()})
        searchLoop: while let url=iterator.nextObject() as? URL {
            if cancellation.isCancelled{report.wasCancelled=true;break}
            if report.entriesVisited>=request.maximumEntries{report.reachedLimit = .entries;break}
            report.entriesVisited+=1
            let values:URLResourceValues
            do{values=try url.resourceValues(forKeys:keys)}catch{report.skipped.append(.init(url:url,reason:.unreadable(error.localizedDescription)));continue}
            if values.isSymbolicLink == true{report.skipped.append(.init(url:url,reason:.symbolicLink));continue}
            if !request.includeHidden && (values.isHidden == true || url.lastPathComponent.hasPrefix(".")){if values.isDirectory == true{iterator.skipDescendants()};report.skipped.append(.init(url:url,reason:.hidden));continue}
            if values.isDirectory == true {
                if !request.recursive{iterator.skipDescendants();report.skipped.append(.init(url:url,reason:.nonRecursiveDirectory))}
                continue
            }
            guard values.isRegularFile == true else{report.skipped.append(.init(url:url,reason:.notRegularFile));continue}
            if !extensionFilter.isEmpty && !extensionFilter.contains(url.pathExtension.lowercased()){report.skipped.append(.init(url:url,reason:.extensionFiltered));continue}
            if report.filesConsidered>=request.maximumFiles{report.reachedLimit = .files;break}
            report.filesConsidered+=1
            if (values.fileSize ?? 0)>request.maximumFileBytes{report.skipped.append(.init(url:url,reason:.fileTooLarge));continue}
            let remaining=request.maximumTotalBytes-report.bytesRead
            if remaining<=0 || (values.fileSize ?? 0)>remaining{report.reachedLimit = .totalBytes;break}
            let bytes:Data
            do {
                bytes=try readFile(url,root:root,rootFD:rootFD,maximumBytes:min(request.maximumFileBytes,remaining),cancellation:cancellation,onBytes:{report.bytesRead += $0})
            }catch ReadFailure.cancelled{report.wasCancelled=true;break}
            catch ReadFailure.tooLarge{
                if remaining<request.maximumFileBytes{report.reachedLimit = .totalBytes;break}
                report.skipped.append(.init(url:url,reason:.fileTooLarge));continue
            }catch{report.skipped.append(.init(url:url,reason:.unreadable(error.localizedDescription)));continue}
            let decoded:DecodedFile
            do{decoded=try FileCodec.decode(bytes)}catch{report.skipped.append(.init(url:url,reason:.invalidEncoding(error.localizedDescription)));continue}
            if cancellation.isCancelled{report.wasCancelled=true;break}
            report.filesSearched+=1
            let text=decoded.text as NSString
            var cursor=UTFPositionCursor(decoded.text)
            var offset=0
            let options:NSString.CompareOptions=request.matchCase ? [.literal] : [.literal,.caseInsensitive]
            while offset<text.length {
                if cancellation.isCancelled{report.wasCancelled=true;break searchLoop}
                let match=text.range(of:request.query,options:options,range:NSRange(location:offset,length:text.length-offset))
                if match.location == NSNotFound{break}
                guard match.length>0,cursor.advance(to:match.location,cancellation:cancellation) else {if cancellation.isCancelled{report.wasCancelled=true;break searchLoop};throw FolderSearchError.invalidRequest("Literal matching produced an invalid Unicode range.")}
                let startByte=cursor.byteOffset,line=cursor.line,column=cursor.columnUTF16
                guard cursor.advance(to:NSMaxRange(match),cancellation:cancellation) else {if cancellation.isCancelled{report.wasCancelled=true;break searchLoop};throw FolderSearchError.invalidRequest("Literal matching split a Unicode character.")}
                let snippet=preview(text,match:match,maximum:request.previewUTF16Length)
                report.matches.append(.init(url:url,line:line,columnUTF16:column,utf16Range:.init(location:match.location,length:match.length),utf8Range:.init(location:startByte,length:cursor.byteOffset-startByte),preview:snippet.text,previewMatchRange:snippet.range,isMatchTruncatedInPreview:snippet.truncated))
                if report.matches.count>=request.maximumResults{report.reachedLimit = .results;break searchLoop}
                offset=NSMaxRange(match)
            }
            progress?(.init(filesSearched:report.filesSearched,bytesRead:report.bytesRead,matches:report.matches.count,currentURL:url))
        }
        if cancellation.isCancelled{report.wasCancelled=true}
        report.skipped.append(contentsOf:enumerationErrors)
        report.matches.sort{$0.url.path == $1.url.path ? $0.utf16Range.location<$1.utf16Range.location : $0.url.path<$1.url.path}
        return report
    }
    private enum ReadFailure:LocalizedError{
        case cancelled,tooLarge,notRegular,invalidRelativePath,changed
        var errorDescription:String?{
            switch self{
            case .cancelled:return "Search cancelled."
            case .tooLarge:return "File exceeds the configured read limit."
            case .notRegular:return "The entry is not a regular file."
            case .invalidRelativePath:return "The entry is outside the selected directory."
            case .changed:return "File changed while being read; retry to search its new contents."
            }
        }
    }
    /// Open each relative directory component with O_NOFOLLOW, anchored to the chosen
    /// root descriptor. A renamed/symlink-swapped descendant cannot escape the scope.
    private static func readFile(_ url:URL,root:URL,rootFD:Int32,maximumBytes:Int,cancellation:FolderSearchCancellation,onBytes:(Int)->Void)throws->Data {
        let prefix=root.path.hasSuffix("/") ? root.path : root.path+"/"
        guard url.path.hasPrefix(prefix) else{throw ReadFailure.invalidRelativePath}
        let components=String(url.path.dropFirst(prefix.count)).split(separator:"/").map(String.init)
        guard !components.isEmpty,components.allSatisfy({$0 != ".." && $0 != "." && !$0.contains("\0")}) else{throw ReadFailure.invalidRelativePath}
        var directoryFD=dup(rootFD)
        guard directoryFD>=0 else{throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
        defer{close(directoryFD)}
        for component in components.dropLast(){
            let next=openat(directoryFD,component,O_RDONLY|O_DIRECTORY|O_NOFOLLOW)
            guard next>=0 else{throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
            close(directoryFD);directoryFD=next
        }
        let fd=openat(directoryFD,components.last!,O_RDONLY|O_NOFOLLOW|O_NONBLOCK)
        guard fd>=0 else{throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true);defer{try? handle.close()}
        var info=stat();guard fstat(fd,&info)==0 else{throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
        guard (info.st_mode&S_IFMT)==S_IFREG else{throw ReadFailure.notRegular}
        guard info.st_size>=0,info.st_size<=maximumBytes else{throw ReadFailure.tooLarge}
        var result=Data()
        while result.count<Int(info.st_size){
            if cancellation.isCancelled{throw ReadFailure.cancelled}
            let chunk=try handle.read(upToCount:min(64*1024,Int(info.st_size)-result.count)) ?? Data()
            if chunk.isEmpty{throw ReadFailure.changed}
            result.append(chunk);onBytes(chunk.count)
        }
        var after=stat();guard fstat(fd,&after)==0 else{throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
        guard after.st_size==info.st_size,after.st_mtimespec.tv_sec==info.st_mtimespec.tv_sec,after.st_mtimespec.tv_nsec==info.st_mtimespec.tv_nsec else{throw ReadFailure.changed}
        return result
    }
    private static func preview(_ text:NSString,match:NSRange,maximum:Int)->(text:String,range:SearchSpan,truncated:Bool){
        var start=max(0,match.location-min(80,maximum/3))
        if start>0 && (0xDC00...0xDFFF).contains(text.character(at:start)){start-=1}
        var end=min(text.length,start+maximum)
        if end<text.length && end>start && (0xDC00...0xDFFF).contains(text.character(at:end)){end-=1}
        let matchedEnd=min(end,NSMaxRange(match))
        return(text.substring(with:NSRange(location:start,length:end-start)),.init(location:match.location-start,length:max(0,matchedEnd-match.location)),NSMaxRange(match)>end)
    }
    /// Monotonic matches permit streaming scalar conversion: no full UTF-16-to-byte
    /// table and no repeated whole-buffer prefix copies for each result.
    private struct UTFPositionCursor {
        let text:String
        var index:String.UnicodeScalarView.Index
        var utf16Offset=0
        var byteOffset=0
        var line=1
        var columnUTF16=1
        init(_ text:String){self.text=text;index=text.unicodeScalars.startIndex}
        mutating func advance(to target:Int,cancellation:FolderSearchCancellation)->Bool{
            var count=0
            guard target>=utf16Offset else{return false}
            while utf16Offset<target && index<text.unicodeScalars.endIndex{
                if count % 4096 == 0 && cancellation.isCancelled{return false};count+=1
                let scalar=text.unicodeScalars[index],value=scalar.value
                let width=value>0xFFFF ? 2:1
                if utf16Offset+width>target{return false}
                let next=text.unicodeScalars.index(after:index)
                utf16Offset+=width;byteOffset+=value<0x80 ? 1 : (value<0x800 ? 2 : (value<0x10000 ? 3:4))
                if value==10 || (value==13 && (next==text.unicodeScalars.endIndex || text.unicodeScalars[next].value != 10)){line+=1;columnUTF16=1}else{columnUTF16+=width}
                index=next
            }
            return utf16Offset==target
        }
    }
}
