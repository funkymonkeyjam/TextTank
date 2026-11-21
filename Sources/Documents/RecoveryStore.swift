// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import os

/// Persisted format, version 1; see "Persisted formats" in docs/architecture.md. A new field
/// must be Optional or decoded with decodeIfPresent in an extension, or old files stop loading.
package struct RecoverySnapshot: Codable, Equatable, Sendable {
    package init(
        schemaVersion: Int = 1, id: UUID, text: String, format: FileFormat, originalURL: String?, revision: UInt64,
        savedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.text = text
        self.format = format
        self.originalURL = originalURL
        self.revision = revision
        self.savedAt = savedAt
    }

    package var schemaVersion: Int
    package let id: UUID
    package let text: String
    package let format: FileFormat
    /// Informational identity only. RecoveryStore never opens or writes this path.
    package let originalURL: String?
    package let revision: UInt64
    package var savedAt: Date
}

package struct RecoveryIssue {
    package init(url: URL, message: String) {
        self.url = url
        self.message = message
    }

    package let url: URL
    package let message: String
}
package struct RecoveryScan {
    package init(snapshots: [RecoverySnapshot], issues: [RecoveryIssue]) {
        self.snapshots = snapshots
        self.issues = issues
    }

    package let snapshots: [RecoverySnapshot]
    package let issues: [RecoveryIssue]
}

package enum RecoveryError: Error, LocalizedError {
    case invalidSnapshot, staleRevision, unsafeLocation, inUse, lockUnsupported, folderChanged
    static func lockFailure(_ code: Int32, directory: URL) -> Error {
        if code == EWOULDBLOCK || code == EAGAIN { return RecoveryError.inUse }
        if code == ENOTSUP || code == EOPNOTSUPP || code == ENOSYS { return RecoveryError.lockUnsupported }
        return FileOperationFailure(code, operation: "lock recovery folder", path: directory.path)
    }
    package var errorDescription: String? {
        switch self {
        case .invalidSnapshot:
            return "The recovery snapshot is invalid or uses an unsupported version. It has been left untouched."
        case .inUse:
            return
                "Another copy of TextTank is using this recovery folder. Continue in the running copy, or quit it and try again."
        case .lockUnsupported:
            return "This volume cannot lock the recovery folder. Use a local support folder that supports file locking."
        case .folderChanged:
            return "The recovery folder changed while TextTank was open. Restore the original folder and try again."
        case .staleRevision: return "A newer recovery snapshot already exists. It has been left untouched."
        case .unsafeLocation: return "The recovery location is not a regular local storage location."
        }
    }
}

/// Only active document operations have an entry. The short registry lock is never held
/// during a disk read, encoding, fsync or a wait for another operation on the same document.
private final class RecoveryDocumentLocks: Sendable {
    private struct Entry: Sendable {
        let lock: NSLock
        var users: Int
    }
    private let entries = OSAllocatedUnfairLock(initialState: [UUID: Entry]())
    func withDocument<T>(_ id: UUID, _ operation: () throws -> T) rethrows -> T {
        let lock = entries.withLock { table in
            var entry = table[id] ?? Entry(lock: NSLock(), users: 0)
            entry.users += 1
            table[id] = entry
            return entry.lock
        }
        lock.lock()
        defer {
            lock.unlock()
            entries.withLock { table in
                guard var entry = table[id] else { return }
                entry.users -= 1
                table[id] = entry.users == 0 ? nil : entry
            }
        }
        return try operation()
    }
}

/// flock belongs to an open file description. Keep one descriptor per actual directory in this
/// process so separate RecoveryStore instances share the same lease, including through aliases.
private final class RecoveryDirectoryOwnership {
    private struct Identity: Hashable {
        let device: dev_t, inode: ino_t
        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
        }
    }
    private struct Handle {
        let descriptor: Int32
        var references: Int
        let documents: RecoveryDocumentLocks
    }
    private static let handles = OSAllocatedUnfairLock(initialState: [Identity: Handle]())
    private let identity: Identity
    private let descriptor: Int32
    let documents: RecoveryDocumentLocks

    init(directory: URL) throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            if code == ENOTDIR || code == ELOOP { throw RecoveryError.unsafeLocation }
            throw FileOperationFailure(code, operation: "open recovery folder", path: directory.path)
        }
        var retained = false
        defer { if !retained { close(fd) } }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw FileOperationFailure(errno, operation: "identify recovery folder", path: directory.path)
        }
        let key = Identity(info)
        identity = key
        let acquired = try Self.handles.withLock { handles in
            if var handle = handles[key] {
                handle.references += 1
                handles[key] = handle
                return handle
            }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                throw RecoveryError.lockFailure(code, directory: directory)
            }
            let handle = Handle(descriptor: fd, references: 1, documents: RecoveryDocumentLocks())
            handles[key] = handle
            return handle
        }
        descriptor = acquired.descriptor
        documents = acquired.documents
        retained = descriptor == fd
    }
    func prepareForWriting(_ directory: URL) throws {
        guard fchmod(descriptor, 0o700) == 0 else {
            throw FileOperationFailure(errno, operation: "protect recovery folder", path: directory.path)
        }
    }
    func verify(_ directory: URL) throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0 else {
            throw FileOperationFailure(errno, operation: "recheck recovery folder", path: directory.path)
        }
        guard info.st_mode & S_IFMT == S_IFDIR, Identity(info) == identity else { throw RecoveryError.folderChanged }
    }
    deinit {
        let key = identity
        Self.handles.withLock { handles in
            guard var handle = handles[key] else { return }
            handle.references -= 1
            if handle.references == 0 {
                handles.removeValue(forKey: key)
                close(handle.descriptor)
            } else {
                handles[key] = handle
            }
        }
    }
}

/// The leased directory shares its document locks across RecoveryStore instances and aliases.
/// A short per-store lock protects lease acquisition and the cache, independently of document I/O.
final package class RecoveryStore: @unchecked Sendable {
    /// Recovery has no smaller product ceiling than an addressable Data value. Do not import
    /// the session store's 512 MiB cap: large pending documents were already recoverable.
    static package let maximumSnapshotBytes = Int.max
    package let directory: URL
    private let lock = NSLock()
    private var ownership: RecoveryDirectoryOwnership?
    /// What this instance last wrote for each id, with the identity of the file it left on disk.
    /// While the file still has that identity, save and remove compare revisions from memory
    /// instead of reading and decoding the whole previous snapshot. Any difference (another
    /// writer, a corrupt overwrite, a symbolic link) falls back to the full validated read.
    private struct Written {
        let revision: UInt64
        let device: dev_t, inode: ino_t, size: off_t, modified: timespec, changed: timespec
    }
    private var written: [UUID: Written] = [:]
    /// How many snapshot files this instance has read and decoded in full; for checks and diagnosis.
    private var snapshotReadCount = 0
    package var snapshotReads: Int {
        lock.lock()
        defer { lock.unlock() }
        return snapshotReadCount
    }
    /// Temporary files older than this belong to an earlier process that died during a write.
    static package let processStart: Date = {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else { return Date() }
        let started = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000)
    }()
    package init(directory: URL) { self.directory = directory }

    /// Normal launches establish exclusive recovery ownership before any document can open.
    package func claimOwnership() throws { _ = try ownedDirectory(createIfMissing: true) }
    private func ownedDirectory(createIfMissing: Bool) throws -> RecoveryDirectoryOwnership? {
        lock.lock()
        defer { lock.unlock() }
        if let ownership {
            try ownership.verify(directory)
            if createIfMissing { try ownership.prepareForWriting(directory) }
            return ownership
        }
        guard directory.isFileURL else { throw RecoveryError.unsafeLocation }
        try PrivateFileStore.validateLocalURL(directory.appendingPathComponent(".recovery-check"))
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            let code = errno
            guard code == ENOENT else {
                throw FileOperationFailure(code, operation: "inspect recovery folder", path: directory.path)
            }
            guard createIfMissing else { return nil }
            let parent = directory.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: parent.path) {
                try FileManager.default.createDirectory(
                    at: parent, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            if mkdir(directory.path, 0o700) != 0 {
                let failure = errno
                guard failure == EEXIST else {
                    throw FileOperationFailure(failure, operation: "create recovery folder", path: directory.path)
                }
            }
        }
        let acquired = try RecoveryDirectoryOwnership(directory: directory)
        try acquired.verify(directory)
        if createIfMissing { try acquired.prepareForWriting(directory) }
        ownership = acquired
        return acquired
    }
    /// Save a monotonically increasing document revision; corrupt/newer records are never overwritten.
    package func save(_ snapshot: RecoverySnapshot) throws {
        try save(snapshot, beforeCommit: {})
    }
    package func save(_ snapshot: RecoverySnapshot, beforeCommit: () throws -> Void) throws {
        try validate(snapshot)
        guard let lease = try ownedDirectory(createIfMissing: true) else { throw RecoveryError.folderChanged }
        try lease.documents.withDocument(snapshot.id) {
            try lease.verify(directory)
            try saveLocked(snapshot) {
                try beforeCommit()
                try lease.verify(directory)
            }
        }
    }
    private func saveLocked(_ snapshot: RecoverySnapshot, beforeCommit: () throws -> Void) throws {
        let destination = url(for: snapshot.id)
        if let known = knownRevision(of: snapshot.id), known != snapshot.revision {
            guard known < snapshot.revision else { throw RecoveryError.staleRevision }
        } else if FileManager.default.fileExists(atPath: destination.path) {
            let existing = try read(destination, expectedID: snapshot.id)
            guard existing.revision <= snapshot.revision else { throw RecoveryError.staleRevision }
            if existing.revision == snapshot.revision {
                guard existing.text.utf8.elementsEqual(snapshot.text.utf8), existing.format == snapshot.format,
                    existing.originalURL.map({ Data($0.utf8) }) == snapshot.originalURL.map({ Data($0.utf8) })
                else { throw RecoveryError.staleRevision }
                if knownRevision(of: snapshot.id) != snapshot.revision {
                    try PrivateFileStore.confirmExistingWrite(at: destination)
                }
                remember(snapshot.id, revision: snapshot.revision)
                return
            }
        }
        let data = try JSONEncoder().encode(snapshot)
        lock.withLock { written[snapshot.id] = nil }
        try privateAtomicWrite(data, to: destination, beforeCommit: beforeCommit)
        remember(snapshot.id, revision: snapshot.revision)
    }
    /// Read exactly one identified snapshot, validating its filename identity and schema.
    package func load(id: UUID) throws -> RecoverySnapshot {
        guard let lease = try ownedDirectory(createIfMissing: false) else {
            throw FileOperationFailure(ENOENT, operation: "open recovery snapshot", path: url(for: id).path)
        }
        return try lease.documents.withDocument(id) {
            try lease.verify(directory)
            return try read(url(for: id), expectedID: id)
        }
    }
    /// Recover valid entries while keeping corrupt/unknown entries visible and untouched.
    /// Directory-level failures still throw because no reliable inventory was possible.
    /// The one thing a scan deletes is a temporary `.pending` file left by a process that died
    /// during a write: it is an unfinished private copy of a document's text that nothing reads.
    package func scan() throws -> RecoveryScan {
        guard let lease = try ownedDirectory(createIfMissing: false) else {
            return RecoveryScan(snapshots: [], issues: [])
        }
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        removeOrphanedTemporaries(in: contents)
        let entries = contents.filter { $0.pathExtension == "json" }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
        var snapshots: [RecoverySnapshot] = []
        var issues: [RecoveryIssue] = []
        for file in entries {
            do {
                guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else {
                    throw RecoveryError.invalidSnapshot
                }
                let snapshot = try lease.documents.withDocument(id) {
                    try lease.verify(directory)
                    return try read(file, expectedID: id)
                }
                snapshots.append(snapshot)
            } catch  where error.posixCode == .ENOENT {
                // A save or acknowledged close may have removed this entry since enumeration.
                try lease.verify(directory)
            } catch { issues.append(RecoveryIssue(url: file, message: error.localizedDescription)) }
        }
        return RecoveryScan(snapshots: snapshots, issues: issues)
    }
    /// Every snapshot, or an error if any entry is unreadable: scan() with its issues made fatal.
    /// Invalid entries are never deleted and there is no fallback to an original file.
    package func loadAll() throws -> [RecoverySnapshot] {
        let result = try scan()
        guard result.issues.isEmpty else { throw RecoveryError.invalidSnapshot }
        return result.snapshots
    }
    /// Remove only the revision explicitly acknowledged as saved/discarded, avoiding stale cleanup.
    package func remove(id: UUID, throughRevision: UInt64) throws {
        guard let lease = try ownedDirectory(createIfMissing: false) else { return }
        try lease.documents.withDocument(id) {
            try lease.verify(directory)
            try removeLocked(id: id, throughRevision: throughRevision)
        }
    }
    private func removeLocked(id: UUID, throughRevision: UInt64) throws {
        let file = url(for: id)
        guard FileManager.default.fileExists(atPath: file.path) else {
            lock.withLock { written[id] = nil }
            return
        }
        let revision = try knownRevision(of: id) ?? read(file, expectedID: id).revision
        guard revision <= throughRevision else { throw RecoveryError.staleRevision }
        try FileManager.default.removeItem(at: file)
        lock.withLock { written[id] = nil }
    }
    /// Explicit user discard of snapshots listed by an earlier scan. Each item goes through
    /// remove(id:throughRevision:), so only the listed identities at the scanned revision are
    /// deleted: a snapshot that advanced since the scan, a corrupt file or an unlisted
    /// neighbour is left untouched. Returns one issue per snapshot that was not removed.
    package func discard(_ snapshots: [RecoverySnapshot]) -> [RecoveryIssue] {
        snapshots.compactMap { snapshot in
            do {
                try remove(id: snapshot.id, throughRevision: snapshot.revision)
                return nil
            } catch { return RecoveryIssue(url: fileURL(for: snapshot.id), message: error.localizedDescription) }
        }
    }
    /// Location only, for reporting and Reveal in Finder. The store never follows it blindly.
    package func fileURL(for id: UUID) -> URL { url(for: id) }
    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }
    private func identity(of id: UUID) -> stat? {
        var info = stat()
        guard lstat(url(for: id).path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return info
    }
    private func remember(_ id: UUID, revision: UInt64) {
        guard let info = identity(of: id) else { return }
        let value = Written(
            revision: revision, device: info.st_dev, inode: info.st_ino, size: info.st_size,
            modified: info.st_mtimespec, changed: info.st_ctimespec)
        lock.withLock { written[id] = value }
    }
    /// The revision this instance wrote, only while the file on disk is still that write.
    private func knownRevision(of id: UUID) -> UInt64? {
        guard let known = lock.withLock({ written[id] }), let info = identity(of: id), info.st_dev == known.device,
            info.st_ino == known.inode, info.st_size == known.size,
            info.st_mtimespec.tv_sec == known.modified.tv_sec, info.st_mtimespec.tv_nsec == known.modified.tv_nsec,
            info.st_ctimespec.tv_sec == known.changed.tv_sec, info.st_ctimespec.tv_nsec == known.changed.tv_nsec
        else { return nil }
        return known.revision
    }
    /// Only regular files named `<UUID>.pending` that were last written before this process
    /// started. A `.json` entry is never deleted here, and a failed delete is left for the next scan.
    private func removeOrphanedTemporaries(in contents: [URL]) {
        for file in contents where file.pathExtension == "pending" {
            guard UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil else { continue }
            var info = stat()
            guard lstat(file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            let modified = Date(
                timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                    + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
            if modified < Self.processStart { try? FileManager.default.removeItem(at: file) }
        }
    }
    private func privateAtomicWrite(_ data: Data, to destination: URL, beforeCommit: () throws -> Void) throws {
        do {
            try PrivateFileStore.write(
                data, to: destination, maximumBytes: Self.maximumSnapshotBytes,
                temporaryPrefix: "", temporarySuffix: ".pending", synchronize: PrivateFileStore.flushToStorage,
                synchronizeDirectory: PrivateFileStore.flushToStorage, beforeCommit: beforeCommit)
        } catch PrivateFileError.unsafeLocation { throw RecoveryError.unsafeLocation }
    }
    private func read(_ url: URL, expectedID: UUID) throws -> RecoverySnapshot {
        let data: Data
        do { data = try PrivateFileStore.read(url, maximumBytes: Self.maximumSnapshotBytes) } catch PrivateFileError
            .unsafeLocation
        { throw RecoveryError.unsafeLocation } catch  where error.posixCode == .ELOOP {
            throw RecoveryError.unsafeLocation
        }
        lock.withLock { snapshotReadCount += 1 }
        let snapshot: RecoverySnapshot
        do {
            try PersistedFormat.check(data, context: "Recovery snapshot")
            snapshot = try JSONDecoder().decode(RecoverySnapshot.self, from: data)
        } catch {
            throw RecoveryError.invalidSnapshot
        }
        guard snapshot.id == expectedID else { throw RecoveryError.invalidSnapshot }
        try validate(snapshot)
        return snapshot
    }
    private func validate(_ snapshot: RecoverySnapshot) throws {
        // JSONEncoder and JSONDecoder already refuse a non-finite savedAt, so it needs no check here.
        guard snapshot.schemaVersion == 1, snapshot.revision <= UInt64(Int64.max) else {
            throw RecoveryError.invalidSnapshot
        }
        // Pending edits may be unrepresentable in the selected disk encoding; retain those
        // exact edits for recovery rather than refusing to protect them. Validate only metadata.
        if snapshot.format.bom && [.latin1, .windows1252].contains(snapshot.format.encoding) {
            throw RecoveryError.invalidSnapshot
        }
        if let original = snapshot.originalURL {
            guard let url = URL(string: original), url.isFileURL else { throw RecoveryError.invalidSnapshot }
        }
    }
}
