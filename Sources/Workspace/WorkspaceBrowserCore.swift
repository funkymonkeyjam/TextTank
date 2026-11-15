// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

/// Persisted format, version 1; see "Persisted formats" in docs/architecture.md. A new field
/// must be Optional or decoded with decodeIfPresent in an extension, or old files stop loading.
struct WorkspaceBrowserState: Codable, Equatable {
    var version = 1
    var folders: [URL] = []
    var recent: [URL] = []
    func validate() throws {
        guard version == 1, folders.count <= 100, recent.count <= 100 else {
            throw WorkspaceError.invalid("Unsupported workspace browser data.")
        }
        for urls in [folders, recent] {
            for url in urls { try WorkspaceStore.validateLocalURL(url) }
            guard Set(urls.map(Self.identity)).count == urls.count else {
                throw WorkspaceError.invalid("Duplicate workspace paths.")
            }
        }
    }
}
extension WorkspaceBrowserState {
    /// The one rule for "the same folder or file": the standardized path. A trailing slash
    /// or a `localhost` host is a different URL but not a different entry.
    static func identity(_ url: URL) -> String { url.standardizedFileURL.path }
}
struct WorkspaceBrowserEntry: Equatable {
    let url: URL
    let directory: Bool
}
struct WorkspaceDirectoryListing {
    var entries: [WorkspaceBrowserEntry] = []
    var skipped = 0
    var truncated = false
}

/// Persistent folder and recent-file identities only; loading never opens files,
/// interprets document content or executes extensions/processes.
final class WorkspaceBrowserStore {
    private(set) var state = WorkspaceBrowserState()
    private(set) var loadError: Error?
    let url: URL
    init(url: URL) {
        self.url = url
        do {
            let data = try WorkspaceStore.readRegularFile(url, maximumBytes: 1024 * 1024)
            let decoded = try JSONDecoder().decode(WorkspaceBrowserState.self, from: data)
            try decoded.validate()
            state = decoded
        } catch let error as POSIXError where error.code == .ENOENT {} catch { loadError = error }
    }
    func save(_ value: WorkspaceBrowserState) throws {
        guard loadError == nil else {
            throw WorkspaceError.invalid(
                "The saved workspace could not be read. Its original bytes are preserved; repair or move that configuration before saving workspace changes."
            )
        }
        try value.validate()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try WorkspaceStore.writePrivate(JSONEncoder().encode(value), to: url)
        state = value
        loadError = nil
    }
    func addFolder(_ folder: URL) throws {
        try WorkspaceStore.validateLocalURL(folder)
        // Only checks that the folder can be listed; nothing is enumerated.
        closedir(try Self.openDirectory(folder).stream)
        let path = folder.standardizedFileURL
        if contains(folder) { return }
        var next = state
        next.folders.append(path)
        try save(next)
    }
    /// Whether `folder` is one of the saved roots, by path.
    func contains(_ folder: URL) -> Bool {
        state.folders.contains { WorkspaceBrowserState.identity($0) == WorkspaceBrowserState.identity(folder) }
    }
    func removeFolder(_ folder: URL) throws {
        var next = state
        next.folders.removeAll { WorkspaceBrowserState.identity($0) == WorkspaceBrowserState.identity(folder) }
        try save(next)
    }
    func noteRecent(_ file: URL) throws {
        try WorkspaceStore.validateLocalURL(file)
        var next = state
        let file = file.standardizedFileURL
        next.recent.removeAll { WorkspaceBrowserState.identity($0) == WorkspaceBrowserState.identity(file) }
        next.recent.insert(file, at: 0)
        next.recent = Array(next.recent.prefix(100))
        try save(next)
    }
    /// Entries read from one directory before the scan stops. Sorting needs every name, so
    /// this, not the display limit, bounds the work.
    static let maximumScannedEntries = 20000
    /// Opens the folder itself, never through a symbolic link. The stream owns the descriptor.
    fileprivate static func openDirectory(_ folder: URL) throws -> (
        stream: UnsafeMutablePointer<DIR>, descriptor: Int32
    ) {
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            let code = errno
            var info = stat()
            if lstat(folder.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
                throw WorkspaceError.invalid(
                    "“\(folder.lastPathComponent)” is a symbolic link. Symbolic-link folders are not supported; choose the folder it points to instead."
                )
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        // fdopendir owns and closes this descriptor. Enumeration and metadata
        // checks share its identity even if a path is renamed during the scan.
        guard let dir = fdopendir(fd) else {
            let code = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return (dir, fd)
    }
    /// The first `limit` entries in display order: directories first, then by name. The
    /// whole directory is read (up to `maximumScannedEntries`) and sorted before the limit
    /// applies, so the entries shown do not depend on the order the filesystem returns them.
    /// `skipped` counts every hidden, symbolic-link or special entry that was read; those
    /// never count toward the limit.
    static func list(_ folder: URL, limit: Int = 2000, showHidden: Bool = false) throws -> WorkspaceDirectoryListing {
        try WorkspaceStore.validateLocalURL(folder)
        guard limit > 0 && limit <= 10000 else { throw WorkspaceError.invalid("Invalid directory listing limit.") }
        let (dir, fd) = try openDirectory(folder)
        defer { closedir(dir) }
        var result = WorkspaceDirectoryListing()
        var found: [(name: String, directory: Bool)] = []
        var seen = 0
        while true {
            errno = 0
            guard let entry = readdir(dir) else {
                if errno != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            seen += 1
            if seen > maximumScannedEntries {
                result.truncated = true
                break
            }
            if !showHidden && name.hasPrefix(".") {
                result.skipped += 1
                continue
            }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                result.skipped += 1
                continue
            }
            let type = info.st_mode & S_IFMT
            guard type == S_IFREG || type == S_IFDIR else {
                result.skipped += 1
                continue
            }
            found.append((name, type == S_IFDIR))
        }
        found.sort {
            if $0.directory != $1.directory { return $0.directory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        if found.count > limit { result.truncated = true }
        result.entries = found.prefix(limit).map {
            WorkspaceBrowserEntry(
                url: folder.appendingPathComponent($0.name, isDirectory: $0.directory), directory: $0.directory)
        }
        return result
    }
}
