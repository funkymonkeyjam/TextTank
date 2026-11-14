// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

struct WorkspaceBrowserState: Codable, Equatable {
    var version=1
    var folders:[URL]=[]
    var recent:[URL]=[]
    func validate()throws {
        guard version == 1,folders.count<=100,recent.count<=100 else { throw WorkspaceError.invalid("Unsupported workspace browser data.") }
        for urls in [folders,recent] {
            for url in urls { try WorkspaceStore.validateLocalURL(url) }
            guard Set(urls.map { $0.standardizedFileURL.path }).count == urls.count else { throw WorkspaceError.invalid("Duplicate workspace paths.") }
        }
    }
}
struct WorkspaceBrowserEntry: Equatable {
    let url:URL
    let directory:Bool
}
struct WorkspaceDirectoryListing {
    var entries:[WorkspaceBrowserEntry]=[]
    var skipped=0
    var truncated=false
}

/// Persistent folder and recent-file identities only; loading never opens files,
/// interprets document content or executes extensions/processes.
final class WorkspaceBrowserStore {
    private(set) var state=WorkspaceBrowserState()
    private(set) var loadError:Error?
    let url:URL
    init(url:URL) {
        self.url=url
        do {
            let data=try WorkspaceStore.readRegularFile(url,maximumBytes:1024*1024)
            let decoded=try JSONDecoder().decode(WorkspaceBrowserState.self,from:data);try decoded.validate();state=decoded
        } catch let error as POSIXError where error.code == .ENOENT { }
        catch { loadError=error }
    }
    func save(_ value:WorkspaceBrowserState)throws {
        guard loadError == nil else { throw WorkspaceError.invalid("The saved workspace could not be read. Its original bytes are preserved; repair or move that configuration before saving workspace changes.") }
        try value.validate()
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try WorkspaceStore.writePrivate(JSONEncoder().encode(value),to:url)
        state=value;loadError=nil
    }
    func addFolder(_ folder:URL)throws {
        _ = try Self.list(folder,limit:1)
        let path=folder.standardizedFileURL
        if state.folders.contains(path) { return }
        var next=state;next.folders.append(path);try save(next)
    }
    func removeFolder(_ folder:URL)throws { var next=state;next.folders.removeAll{$0.standardizedFileURL.path==folder.standardizedFileURL.path};try save(next) }
    func noteRecent(_ file:URL)throws {
        try WorkspaceStore.validateLocalURL(file)
        var next=state;let file=file.standardizedFileURL;next.recent.removeAll{$0==file};next.recent.insert(file,at:0);next.recent=Array(next.recent.prefix(100));try save(next)
    }
    static func list(_ folder:URL,limit:Int=2000,showHidden:Bool=false)throws->WorkspaceDirectoryListing {
        try WorkspaceStore.validateLocalURL(folder)
        guard limit>0 && limit<=10000 else { throw WorkspaceError.invalid("Invalid directory listing limit.") }
        let fd=open(folder.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_NONBLOCK)
        guard fd>=0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        // fdopendir owns and closes this descriptor. Enumeration and metadata
        // checks share its identity even if a path is renamed during the scan.
        guard let dir=fdopendir(fd) else { close(fd);throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        defer { closedir(dir) }
        var result=WorkspaceDirectoryListing();var seen=0
        while true {
            errno=0
            guard let entry=readdir(dir) else { if errno != 0 { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) };break }
            let name=withUnsafePointer(to:&entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to:CChar.self,capacity:Int(entry.pointee.d_namlen)+1) { String(cString:$0) }
            }
            if name == "." || name == ".." { continue }
            seen += 1
            if seen>limit { result.truncated=true;break }
            if !showHidden && name.hasPrefix(".") { result.skipped += 1;continue }
            var info=stat()
            guard fstatat(fd,name,&info,AT_SYMLINK_NOFOLLOW)==0 else { result.skipped += 1;continue }
            let type=info.st_mode & S_IFMT
            guard type == S_IFREG || type == S_IFDIR else { result.skipped += 1;continue }
            result.entries.append(WorkspaceBrowserEntry(url:folder.appendingPathComponent(name,isDirectory:type == S_IFDIR),directory:type == S_IFDIR))
        }
        result.entries.sort {
            if $0.directory != $1.directory { return $0.directory }
            return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
        return result
    }
}
