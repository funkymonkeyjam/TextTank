// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// Single-worker batch shared across the roots of one confirmed replacement.
/// Each synced line records a transition. Interrupted final lines have no authority.
package final class FolderReplacementBatch {
    package struct Entry: Codable, Sendable {
        package let id: UUID
        package let root: String
        package let path: String
        package let originalSHA256: String
        package let replacementSHA256: String
        package let originalMode: UInt16
        package var backupName: String { id.uuidString + ".original" }
    }
    package enum State: String, Codable, Sendable { case prepared, replaced, abandoned, restored }
    private struct Header: Codable {
        let version: Int
        let id: UUID
        let created: Date
    }
    private struct Transition: Codable {
        let id: UUID
        let state: State
        let entry: Entry?
    }
    package struct Snapshot: Sendable {
        package let id: UUID
        package let created: Date
        package let entries: [(Entry, State)]
        let manifestDigest: String
        let completeTail: Bool
    }

    static func canonicalPath(of store: URL) -> String {
        if let opened = try? FolderSearch.openCanonicalDirectory(store) {
            defer { close(opened.fd) }
            return opened.path
        }
        if let parent = try? FolderSearch.openCanonicalDirectory(store.deletingLastPathComponent()) {
            defer { close(parent.fd) }
            return URL(fileURLWithPath: parent.path).appendingPathComponent(store.lastPathComponent).path
        }
        return store.standardizedFileURL.path
    }
    static func contains(_ path: String, in store: String) -> Bool {
        path == store || path.utf8.starts(with: (store + "/").utf8)
    }
    static let manifestName = "manifest.jsonl"
    private static let maximumManifestBytes = 64 * 1024 * 1024
    package let directory: URL
    package var manifest: URL { directory.appendingPathComponent(Self.manifestName) }
    private let id: UUID
    private let created = Date()
    private var stream: Int32 = -1
    private var retained = 0
    private var stopped = false
    package init(store: URL = AppStorage.url(.folderReplacements)) {
        id = UUID()
        directory = store.appendingPathComponent(id.uuidString, isDirectory: true)
    }
    init(reopening manifest: URL, retired: Bool = false) throws {
        directory = manifest.deletingLastPathComponent()
        let name = directory.lastPathComponent
        let identity = retired && name.hasPrefix(".deleting-") ? String(name.dropFirst(".deleting-".count)) : name
        guard manifest.lastPathComponent == Self.manifestName, let uuid = UUID(uuidString: identity),
            name == (retired ? ".deleting-" : "") + uuid.uuidString,
            Self.canonicalPath(of: directory.deletingLastPathComponent())
                == Self.canonicalPath(of: AppStorage.url(.folderReplacements))
        else { throw PrivateFileError.unsafeLocation }
        id = uuid
        let storeFD = try Self.openStore()
        defer { close(storeFD) }
        let parent = try PrivateFileStore.directoryDescriptor(for: manifest)
        defer { close(parent) }
        let fd = openat(parent, Self.manifestName, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            throw FileOperationFailure(errno, operation: "open private recovery manifest", path: manifest.path)
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
            info.st_uid == getuid(), info.st_mode & 0o077 == 0,
            info.st_size > 0, info.st_size <= Self.maximumManifestBytes
        else {
            close(fd)
            throw PrivateFileError.unsafeLocation
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw FolderSearchError.invalidRequest("This folder replacement batch is still in use.")
        }
        stream = fd
    }
    func verifiesManifest(in directory: Int32) -> Bool {
        var locked = stat(), current = stat()
        return fstat(stream, &locked) == 0
            && fstatat(directory, Self.manifestName, &current, AT_SYMLINK_NOFOLLOW) == 0
            && locked.st_dev == current.st_dev && locked.st_ino == current.st_ino
    }
    func lockedSnapshot() throws -> Snapshot { try Self.decode(lockedBytes(), id: id) }
    private func lockedBytes() throws -> Data {
        var info = stat()
        guard fstat(stream, &info) == 0, info.st_size > 0, info.st_size <= Self.maximumManifestBytes,
            lseek(stream, 0, SEEK_SET) == 0
        else { throw PrivateFileError.unsafeLocation }
        return try FolderReplacement.read(
            stream, size: Int(info.st_size), cancellation: FolderSearchCancellation(), path: manifest.path)
    }
    /// Truncate only a torn, uncommitted final line, after every complete record parsed successfully.
    func snapshotForUndo(reviewed: Snapshot?) throws -> Snapshot {
        let bytes = try lockedBytes()
        let snapshot = try Self.decode(bytes, id: id)
        if let reviewed, snapshot.manifestDigest != reviewed.manifestDigest {
            throw FolderSearchError.invalidRequest(
                "The selected batch changed after review. Open Undo again to review its current files.")
        }
        guard let last = bytes.lastIndex(of: 10) else { throw PrivateFileError.unsafeLocation }
        let end = off_t(last + 1)
        guard (end == bytes.count || ftruncate(stream, end) == 0), lseek(stream, 0, SEEK_END) == end else {
            throw FileOperationFailure(errno, operation: "position private recovery manifest", path: manifest.path)
        }
        return snapshot
    }
    static func openStore() throws -> Int32 {
        let store = AppStorage.url(.folderReplacements)
        let fd = try PrivateFileStore.directoryDescriptor(for: store.appendingPathComponent(manifestName))
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            close(fd)
            throw PrivateFileError.unsafeLocation
        }
        return fd
    }
    package static func latestManifest() throws -> URL? {
        try manifests().first
    }
    package static func manifests() throws -> [URL] { try listing().map { $0.1 } }
    package static func listing() throws -> [(Date, URL)] {
        let store = AppStorage.url(.folderReplacements)
        let children: [URL]
        do {
            let storeFD = try openStore()
            defer { close(storeFD) }
            children = try FileManager.default.contentsOfDirectory(
                at: store, includingPropertiesForKeys: [.creationDateKey])
        } catch  where error.isFileNotFound { return [] }
        let candidates = children.filter { UUID(uuidString: $0.lastPathComponent) != nil }.map { child in
            let values = try? child.resourceValues(forKeys: [.creationDateKey, .isDirectoryKey, .isSymbolicLinkKey])
            // Unknown entries remain visible and take precedence in Last so it never
            // silently applies to an older batch when the newest cannot be verified.
            let date = values?.isDirectory == true && values?.isSymbolicLink == false ? values?.creationDate : nil
            return (date ?? Date.distantFuture, child)
        }
        return candidates.sorted {
            $0.0 == $1.0 ? $0.1.lastPathComponent > $1.1.lastPathComponent : $0.0 > $1.0
        }.map { ($0.0, $0.1.appendingPathComponent(manifestName)) }
    }
    deinit { if stream >= 0 { close(stream) } }
    private func openManifest() throws {
        guard !stopped else { throw FolderSearchError.invalidRequest("Private recovery storage needs attention.") }
        if stream >= 0 { return }
        let store = directory.deletingLastPathComponent()
        try PrivateFileStore.prepareDirectory(store)
        let support = try PrivateFileStore.directoryDescriptor(for: store)
        defer { close(support) }
        guard fsync(support) == 0 else {
            throw FileOperationFailure(errno, operation: "sync folder replacement storage", path: store.path)
        }
        let parent = try PrivateFileStore.directoryDescriptor(for: directory)
        defer { close(parent) }
        guard mkdirat(parent, id.uuidString, 0o700) == 0 else {
            throw FileOperationFailure(errno, operation: "create folder replacement batch", path: directory.path)
        }
        do {
            var bytes = try JSONEncoder().encode(Header(version: 1, id: id, created: created))
            bytes.append(10)
            guard
                let fd = try PrivateFileStore.write(
                    bytes, to: manifest, maximumBytes: Self.maximumManifestBytes,
                    synchronize: { fd in
                        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return -1 }
                        return fsync(fd)
                    }, synchronizeDirectory: { fsync($0) },
                    requireMissing: true, retainingDescriptor: true)
            else { throw PrivateFileError.unsafeLocation }
            stream = fd
            guard fsync(parent) == 0 else {
                throw FileOperationFailure(errno, operation: "sync folder replacement batch", path: store.path)
            }
        } catch {
            let published = stream >= 0 || error is PublishedFileSyncFailure
            if stream >= 0 {
                close(stream)
                stream = -1
            }
            if published { _ = unlink(manifest.path) }
            _ = unlinkat(parent, id.uuidString, AT_REMOVEDIR)
            throw error
        }
    }
    private func append(_ change: Transition) throws {
        guard !stopped else {
            throw FolderSearchError.invalidRequest("The private recovery manifest could not be confirmed.")
        }
        var bytes = try JSONEncoder().encode(change)
        bytes.append(10)
        var info = stat()
        guard fstat(stream, &info) == 0, info.st_size <= Self.maximumManifestBytes - bytes.count else {
            throw FolderSearchError.invalidRequest("The private recovery manifest exceeds its size limit.")
        }
        do {
            try FolderReplacement.write(bytes, to: stream, path: manifest.path)
            guard fsync(stream) == 0 else {
                throw FileOperationFailure(errno, operation: "sync folder replacement manifest", path: manifest.path)
            }
        } catch {
            stopped = true
            throw error
        }
    }
    func prepare(source: Int32, original: Data, entry: Entry) throws -> URL {
        try openManifest()
        let backup = directory.appendingPathComponent(entry.backupName)
        // Preserve xattrs separately from Unix permissions. The private copy stays 0600;
        // the original mode is recorded in the prepared manifest entry.
        var published = false
        do {
            try PrivateFileStore.write(
                original, to: backup, maximumBytes: 32 * 1024 * 1024,
                synchronize: { fd in
                    guard fcopyfile(source, fd, nil, copyfile_flags_t(COPYFILE_XATTR)) == 0 else { return -1 }
                    return fsync(fd)
                }, synchronizeDirectory: { fsync($0) }, requireMissing: true)
            published = true
            try append(.init(id: entry.id, state: .prepared, entry: entry))
            retained += 1
            return backup
        } catch {
            if published || error is PublishedFileSyncFailure {
                try FileManager.default.removeItem(at: backup)
            }
            try removeIfEmpty()
            throw error
        }
    }
    func mark(_ entry: Entry, _ state: State) throws {
        try append(.init(id: entry.id, state: state, entry: nil))
        if state == .abandoned {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(entry.backupName))
            retained -= 1
            try removeIfEmpty()
        }
    }
    private func removeIfEmpty() throws {
        guard retained == 0, !stopped, stream >= 0 else { return }
        close(stream)
        stream = -1
        guard unlink(manifest.path) == 0, rmdir(directory.path) == 0 else {
            stopped = true
            throw FileOperationFailure(errno, operation: "remove empty folder replacement batch", path: directory.path)
        }
    }
    package static func read(_ manifest: URL) throws -> Snapshot {
        let bytes = try PrivateFileStore.read(manifest, maximumBytes: maximumManifestBytes)
        guard let id = UUID(uuidString: manifest.deletingLastPathComponent().lastPathComponent) else {
            throw PrivateFileError.unsafeLocation
        }
        return try decode(bytes, id: id)
    }
    private static func decode(_ bytes: Data, id: UUID) throws -> Snapshot {
        var lines = bytes.split(separator: 10, omittingEmptySubsequences: false)
        // The writer syncs each complete line before acting on it. Ignore an uncommitted tail.
        if !lines.isEmpty { lines.removeLast() }
        guard let first = lines.first else { throw PrivateFileError.unsafeLocation }
        let decoder = JSONDecoder()
        let header = try decoder.decode(Header.self, from: Data(first))
        guard header.version == 1, header.id == id
        else {
            throw FolderSearchError.invalidRequest("The folder replacement manifest version or identity is invalid.")
        }
        var entries: [(Entry, State)] = []
        var indexes: [UUID: Int] = [:]
        for line in lines.dropFirst() {
            let transition = try decoder.decode(Transition.self, from: Data(line))
            if transition.state == .prepared, let entry = transition.entry, entry.id == transition.id,
                indexes[entry.id] == nil
            {
                indexes[entry.id] = entries.count
                entries.append((entry, .prepared))
            } else if let index = indexes[transition.id], transition.entry == nil,
                (entries[index].1 == .prepared && [.abandoned, .replaced, .restored].contains(transition.state))
                    || (entries[index].1 == .replaced && transition.state == .restored)
            {
                entries[index].1 = transition.state
            } else {
                throw FolderSearchError.invalidRequest(
                    "The folder replacement manifest contains an invalid transition.")
            }
        }
        return Snapshot(
            id: header.id, created: header.created, entries: entries.filter { $0.1 != .abandoned },
            manifestDigest: FolderSearch.sha256Hex(bytes), completeTail: bytes.last == 10)
    }
}
