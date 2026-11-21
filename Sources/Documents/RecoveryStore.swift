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

/// Version 2 stores exact editor bytes in a private file alongside this small commit record.
package struct RecoveryHeader: Codable, Equatable, Sendable {
    package let schemaVersion: Int
    let minimumReaderVersion: Int?
    package let id: UUID
    package let format: FileFormat
    package let originalURL: String?
    package let revision: UInt64
    package let savedAt: Date
    let generation: UUID?
    let previousGeneration: UUID?
    package let byteCount: Int?
    let sha256: String?
    init(
        _ snapshot: RecoverySnapshot, generation: UUID? = nil, previousGeneration: UUID? = nil, bytes: Data? = nil,
        legacyDigest: String? = nil
    ) {
        schemaVersion = generation == nil ? 1 : 2
        minimumReaderVersion = generation == nil ? nil : 2
        id = snapshot.id
        format = snapshot.format
        originalURL = snapshot.originalURL
        revision = snapshot.revision
        savedAt = snapshot.savedAt
        self.generation = generation
        self.previousGeneration = previousGeneration
        byteCount = bytes?.count
        sha256 = bytes.map(WorkspaceStore.fingerprint) ?? legacyDigest
    }
    fileprivate func snapshot(with text: String) -> RecoverySnapshot {
        .init(id: id, text: text, format: format, originalURL: originalURL, revision: revision, savedAt: savedAt)
    }
}
package struct RecoveryInventory: Sendable {
    package let headers: [RecoveryHeader]
    package let issues: [RecoveryIssue]
}

package struct RecoveryIssue: Sendable {
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
        let header: RecoveryHeader
        let metadata: PreparedFileIdentity
        let payload: PreparedFileIdentity?
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
    package func save(
        _ snapshot: RecoverySnapshot,
        synchronizeHeaderDirectory: @escaping (Int32) -> Int32 = PrivateFileStore.flushToStorage,
        beforeCommit: () throws -> Void
    ) throws {
        try validate(snapshot)
        guard let lease = try ownedDirectory(createIfMissing: true) else { throw RecoveryError.folderChanged }
        try lease.documents.withDocument(snapshot.id) {
            try lease.verify(directory)
            try saveLocked(
                snapshot, synchronizeHeaderDirectory: synchronizeHeaderDirectory,
                verify: { try lease.verify(directory) }
            ) {
                try beforeCommit()
                try lease.verify(directory)
            }
        }
    }
    private func saveLocked(
        _ snapshot: RecoverySnapshot, synchronizeHeaderDirectory: @escaping (Int32) -> Int32, verify: () throws -> Void,
        beforeCommit: () throws -> Void
    ) throws {
        let destination = url(for: snapshot.id)
        let cached = knownHeader(for: snapshot.id)
        var previous = cached
        if let cached, cached.revision != snapshot.revision {
            guard cached.revision < snapshot.revision else { throw RecoveryError.staleRevision }
        } else if FileManager.default.fileExists(atPath: destination.path) {
            let record = try readRecord(destination, expectedID: snapshot.id)
            previous = record.header
            let existing = try materialize(record)
            guard existing.revision <= snapshot.revision else { throw RecoveryError.staleRevision }
            if existing.revision == snapshot.revision {
                guard existing.text.utf8.elementsEqual(snapshot.text.utf8), existing.format == snapshot.format,
                    existing.originalURL.map({ Data($0.utf8) }) == snapshot.originalURL.map({ Data($0.utf8) })
                else { throw RecoveryError.staleRevision }
                if cached == nil {
                    if let body = payloadURL(for: record.header) { try PrivateFileStore.confirmExistingWrite(at: body) }
                    try PrivateFileStore.confirmExistingWrite(at: destination)
                }
                try removePreviousBody(of: record.header)
                remember(record.header)
                return
            }
        }
        let bytes = Data(snapshot.text.utf8)
        let header = RecoveryHeader(
            snapshot, generation: UUID(), previousGeneration: previous?.generation, bytes: bytes)
        let headerBytes = try JSONEncoder().encode(header)
        guard let body = payloadURL(for: header) else { throw RecoveryError.invalidSnapshot }
        // Publish a fresh immutable body before switching the header. A failed directory
        // sync after the switch may have exposed the new header, so retain both bodies.
        try privateAtomicWrite(bytes, to: body, beforeCommit: verify)
        do {
            try privateAtomicWrite(
                headerBytes, to: destination, synchronizeDirectory: synchronizeHeaderDirectory,
                beforeCommit: beforeCommit)
        } catch let error as PublishedFileSyncFailure {
            throw error
        } catch {
            try? FileManager.default.removeItem(at: body)
            throw error
        }
        remember(header)
        try removePreviousBody(of: header)
        if let previous { try removePreviousBody(of: previous) }
    }
    /// Read exactly one identified snapshot, validating its filename identity and schema.
    package func load(id: UUID) throws -> RecoverySnapshot {
        guard let lease = try ownedDirectory(createIfMissing: false) else {
            throw FileOperationFailure(ENOENT, operation: "open recovery snapshot", path: url(for: id).path)
        }
        return try lease.documents.withDocument(id) {
            try lease.verify(directory)
            return try materialize(readRecord(url(for: id), expectedID: id))
        }
    }
    /// Recover valid entries while keeping corrupt/unknown entries visible and untouched.
    /// Directory-level failures still throw because no reliable inventory was possible.
    /// The one thing a scan deletes is a temporary `.pending` file left by a process that died
    /// during a write: it is an unfinished private copy of a document's text that nothing reads.
    private func inventory<T>(_ read: (URL, UUID) throws -> T) throws -> ([T], [RecoveryIssue]) {
        guard let lease = try ownedDirectory(createIfMissing: false) else { return ([], []) }
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        removeOrphanedTemporaries(in: contents)
        let entries = contents.filter { $0.pathExtension == "json" }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
        var records: [T] = [], issues: [RecoveryIssue] = []
        for file in entries {
            do {
                guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else {
                    throw RecoveryError.invalidSnapshot
                }
                records.append(
                    try lease.documents.withDocument(id) {
                        try lease.verify(directory)
                        return try read(file, id)
                    })
            } catch  where error.posixCode == .ENOENT {
                try lease.verify(directory)
            } catch { issues.append(RecoveryIssue(url: file, message: error.localizedDescription)) }
        }
        for file in contents where file.pathExtension == "utf8" {
            let fields = file.lastPathComponent.split(separator: ".")
            guard fields.count == 3, let id = UUID(uuidString: String(fields[0])),
                let generation = UUID(uuidString: String(fields[1]))
            else { continue }
            do {
                try lease.documents.withDocument(id) {
                    try lease.verify(directory)
                    guard FileManager.default.fileExists(atPath: file.path) else { return }
                    let current = try? readHeaderGeneration(id)
                    if current != generation {
                        issues.append(
                            .init(
                                url: file,
                                message:
                                    "A recovery text file is outside the active snapshot. It has been retained for review."
                            ))
                    }
                }
            } catch { issues.append(.init(url: file, message: error.localizedDescription)) }
        }
        return (records, issues)
    }
    package func scan() throws -> RecoveryScan {
        let (snapshots, issues) = try inventory { try materialize(readRecord($0, expectedID: $1)) }
        return RecoveryScan(snapshots: snapshots, issues: issues)
    }
    /// A v2 header is validated against the body file's type and length without reading text.
    /// Embedded v1 text still needs its historical full-file decode.
    package func scanHeaders() throws -> RecoveryInventory {
        let (headers, issues) = try inventory { try readRecord($0, expectedID: $1).header }
        return .init(headers: headers, issues: issues)
    }
    package func scanForLaunch(
        completion: @escaping @MainActor @Sendable (Result<RecoveryInventory, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async { [self] in
            let result = Result { try scanHeaders() }
            DispatchQueue.main.async { completion(result) }
        }
    }
    package func load(listed: RecoveryHeader) throws -> RecoverySnapshot {
        guard let lease = try ownedDirectory(createIfMissing: false) else { throw RecoveryError.staleRevision }
        return try lease.documents.withDocument(listed.id) {
            try lease.verify(directory)
            let record = try readRecord(url(for: listed.id), expectedID: listed.id)
            guard record.header == listed else { throw RecoveryError.staleRevision }
            return try materialize(record)
        }
    }
    /// Keep the review decision bound to the same published generation across the prompt.
    package func discard(listed headers: [RecoveryHeader]) -> [RecoveryIssue] {
        headers.compactMap { header in
            do {
                guard let lease = try ownedDirectory(createIfMissing: false) else { return nil }
                try lease.documents.withDocument(header.id) {
                    try lease.verify(directory)
                    let target = url(for: header.id)
                    guard FileManager.default.fileExists(atPath: target.path) else { return }
                    let record = try readRecord(target, expectedID: header.id)
                    guard record.header == header else { throw RecoveryError.staleRevision }
                    try removeLocked(id: header.id, throughRevision: header.revision)
                }
                return nil
            } catch { return .init(url: fileURL(for: header.id), message: error.localizedDescription) }
        }
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
        let header: RecoveryHeader
        if let cached = knownHeader(for: id) {
            header = cached
        } else {
            let record = try readRecord(file, expectedID: id)
            _ = try materialize(record)
            header = record.header
        }
        guard header.revision <= throughRevision else { throw RecoveryError.staleRevision }
        let directory = try PrivateFileStore.directoryDescriptor(for: file)
        defer { close(directory) }
        guard unlinkat(directory, file.lastPathComponent, 0) == 0 else {
            throw FileOperationFailure(errno, operation: "remove recovery header", path: file.path)
        }
        if let body = payloadURL(for: header) {
            // A crash must not restore an older header pointing to an already deleted body.
            guard PrivateFileStore.flushToStorage(directory) == 0 else {
                throw FileOperationFailure(errno, operation: "confirm recovery header removal", path: file.path)
            }
            try FileManager.default.removeItem(at: body)
            try removePreviousBody(of: header)
        }
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
    private func readHeaderGeneration(_ id: UUID) throws -> UUID? {
        let file = url(for: id)
        struct Generation: Decodable {
            let id: UUID
            let generation: UUID?
        }
        let data = try PrivateFileStore.read(file, maximumBytes: Self.maximumSnapshotBytes)
        let header = try JSONDecoder().decode(Generation.self, from: data)
        return header.id == id ? header.generation : nil
    }
    private func removePreviousBody(of header: RecoveryHeader) throws {
        guard let previous = header.previousGeneration, previous != header.generation else { return }
        let obsolete = directory.appendingPathComponent(header.id.uuidString + "." + previous.uuidString + ".utf8")
        switch try PreparedFileIdentity.capture(obsolete) {
        case .missing: break
        case .regular: try FileManager.default.removeItem(at: obsolete)
        }
    }
    private func payloadURL(for header: RecoveryHeader) -> URL? {
        header.generation.map {
            directory.appendingPathComponent(header.id.uuidString + "." + $0.uuidString + ".utf8")
        }
    }
    private func remember(_ header: RecoveryHeader) {
        do {
            let value = try Written(
                header: header, metadata: PreparedFileIdentity.capture(url(for: header.id)),
                payload: payloadURL(for: header).map(PreparedFileIdentity.capture))
            guard case .regular = value.metadata else { return }
            if header.generation != nil { guard case .some(.regular) = value.payload else { return } }
            lock.withLock { written[header.id] = value }
        } catch { lock.withLock { written[header.id] = nil } }
    }
    private func knownHeader(for id: UUID) -> RecoveryHeader? {
        guard let known = lock.withLock({ written[id] }) else { return nil }
        do {
            guard try PreparedFileIdentity.capture(url(for: id)) == known.metadata,
                try payloadURL(for: known.header).map(PreparedFileIdentity.capture) == known.payload
            else { return nil }
            return known.header
        } catch { return nil }
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
    private func privateAtomicWrite(
        _ data: Data, to destination: URL,
        synchronizeDirectory: @escaping (Int32) -> Int32 = PrivateFileStore.flushToStorage,
        beforeCommit: () throws -> Void
    ) throws {
        do {
            try PrivateFileStore.write(
                data, to: destination, maximumBytes: Self.maximumSnapshotBytes,
                temporaryPrefix: "", temporarySuffix: ".pending", synchronize: PrivateFileStore.flushToStorage,
                synchronizeDirectory: synchronizeDirectory, beforeCommit: beforeCommit)
        } catch PrivateFileError.unsafeLocation { throw RecoveryError.unsafeLocation }
    }
    private struct Record {
        let header: RecoveryHeader
        let legacy: RecoverySnapshot?
    }
    private func readRecord(_ url: URL, expectedID: UUID) throws -> Record {
        let data: Data
        do { data = try PrivateFileStore.read(url, maximumBytes: Self.maximumSnapshotBytes) } catch PrivateFileError
            .unsafeLocation
        { throw RecoveryError.unsafeLocation } catch  where error.posixCode == .ELOOP {
            throw RecoveryError.unsafeLocation
        }
        struct Version: Decodable { let schemaVersion: Int }
        let version: Int
        do { version = try JSONDecoder().decode(Version.self, from: data).schemaVersion } catch {
            throw RecoveryError.invalidSnapshot
        }
        if version == 1 {
            let legacy: RecoverySnapshot
            do {
                try PersistedFormat.check(data, context: "Recovery snapshot")
                legacy = try JSONDecoder().decode(RecoverySnapshot.self, from: data)
            } catch { throw RecoveryError.invalidSnapshot }
            guard legacy.id == expectedID else { throw RecoveryError.invalidSnapshot }
            try validate(legacy)
            lock.withLock { snapshotReadCount += 1 }
            return Record(
                header: RecoveryHeader(legacy, legacyDigest: WorkspaceStore.fingerprint(data)), legacy: legacy)
        }
        guard version == 2 else { throw RecoveryError.invalidSnapshot }
        let decoded: RecoveryHeader
        do { decoded = try JSONDecoder().decode(RecoveryHeader.self, from: data) } catch {
            throw RecoveryError.invalidSnapshot
        }
        guard decoded.id == expectedID, decoded.minimumReaderVersion == 2,
            let count = decoded.byteCount, count >= 0, let hash = decoded.sha256, hash.utf8.count == 64,
            hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
            decoded.previousGeneration != decoded.generation, let body = payloadURL(for: decoded)
        else { throw RecoveryError.invalidSnapshot }
        try validate(decoded.snapshot(with: ""))
        let opened: (descriptor: Int32, info: stat)
        do { opened = try PrivateFileStore.openRegularFile(body, maximumBytes: count) } catch {
            throw RecoveryError.invalidSnapshot
        }
        defer { close(opened.descriptor) }
        guard opened.info.st_size == count else { throw RecoveryError.invalidSnapshot }
        return Record(header: decoded, legacy: nil)
    }
    private func materialize(_ record: Record) throws -> RecoverySnapshot {
        if let legacy = record.legacy { return legacy }
        let header = record.header
        guard let body = payloadURL(for: header), let count = header.byteCount else {
            throw RecoveryError.invalidSnapshot
        }
        let bytes: Data
        do { bytes = try PrivateFileStore.read(body, maximumBytes: count) } catch {
            throw RecoveryError.invalidSnapshot
        }
        lock.withLock { snapshotReadCount += 1 }
        guard bytes.count == count, WorkspaceStore.fingerprint(bytes) == header.sha256,
            let text = bytes.withUnsafeBytes(FileCodec.decodeUTF8Content)
        else { throw RecoveryError.invalidSnapshot }
        return header.snapshot(with: text)
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
