// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

/// Persisted format, version 1; see "Persisted formats" in docs/architecture.md. A new field
/// must be Optional or decoded with decodeIfPresent in an extension, or old files stop loading.
struct RecoverySnapshot: Codable, Equatable {
    var schemaVersion: Int = 1
    let id: UUID
    let text: String
    let format: FileFormat
    /// Informational identity only. RecoveryStore never opens or writes this path.
    let originalURL: String?
    let revision: UInt64
    var savedAt: Date = Date()
}

struct RecoveryIssue {
    let url: URL
    let message: String
}
struct RecoveryScan {
    let snapshots: [RecoverySnapshot]
    let issues: [RecoveryIssue]
}

enum RecoveryError: Error, LocalizedError {
    case invalidSnapshot, staleRevision, unsafeLocation
    var errorDescription: String? {
        switch self {
        case .invalidSnapshot:
            return "The recovery snapshot is invalid or uses an unsupported version. It has been left untouched."
        case .staleRevision: return "A newer recovery snapshot already exists. It has been left untouched."
        case .unsafeLocation: return "The recovery location is not a regular local storage location."
        }
    }
}

/// Inject a dedicated app-owned directory. Methods are serialized within this instance.
/// Atomic replacement preserves the previous complete snapshot if writing fails.
/// Does not restore to an original file: callers must present recovered text for review.
final class RecoveryStore {
    /// Recovery has no smaller product ceiling than an addressable Data value. Do not import
    /// the session store's 512 MiB cap: large pending documents were already recoverable.
    static let maximumSnapshotBytes = Int.max
    let directory: URL
    private let lock = NSLock()
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
    private(set) var snapshotReads = 0
    /// Temporary files older than this belong to an earlier process that died during a write.
    static let processStart: Date = {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else { return Date() }
        let started = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000)
    }()
    init(directory: URL) { self.directory = directory }

    /// Save a monotonically increasing document revision; corrupt/newer records are never overwritten.
    func save(_ snapshot: RecoverySnapshot) throws {
        lock.lock()
        defer { lock.unlock() }
        try validate(snapshot)
        try prepareDirectory()
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
                remember(snapshot.id, revision: snapshot.revision)
                return
            }
        }
        let data = try JSONEncoder().encode(snapshot)
        written[snapshot.id] = nil
        try privateAtomicWrite(data, to: destination)
        remember(snapshot.id, revision: snapshot.revision)
    }
    /// Read exactly one identified snapshot, validating its filename identity and schema.
    func load(id: UUID) throws -> RecoverySnapshot {
        lock.lock()
        defer { lock.unlock() }
        try checkDirectoryIfPresent()
        return try read(url(for: id), expectedID: id)
    }
    /// Recover valid entries while keeping corrupt/unknown entries visible and untouched.
    /// Directory-level failures still throw because no reliable inventory was possible.
    /// The one thing a scan deletes is a temporary `.pending` file left by a process that died
    /// during a write: it is an unfinished private copy of a document's text that nothing reads.
    func scan() throws -> RecoveryScan {
        lock.lock()
        defer { lock.unlock() }
        try checkDirectoryIfPresent()
        guard FileManager.default.fileExists(atPath: directory.path) else {
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
                snapshots.append(try read(file, expectedID: id))
            } catch { issues.append(RecoveryIssue(url: file, message: error.localizedDescription)) }
        }
        return RecoveryScan(snapshots: snapshots, issues: issues)
    }
    /// Every snapshot, or an error if any entry is unreadable: scan() with its issues made fatal.
    /// Invalid entries are never deleted and there is no fallback to an original file.
    func loadAll() throws -> [RecoverySnapshot] {
        let result = try scan()
        guard result.issues.isEmpty else { throw RecoveryError.invalidSnapshot }
        return result.snapshots
    }
    /// Remove only the revision explicitly acknowledged as saved/discarded, avoiding stale cleanup.
    func remove(id: UUID, throughRevision: UInt64) throws {
        lock.lock()
        defer { lock.unlock() }
        try checkDirectoryIfPresent()
        let file = url(for: id)
        guard FileManager.default.fileExists(atPath: file.path) else {
            written[id] = nil
            return
        }
        let revision = try knownRevision(of: id) ?? read(file, expectedID: id).revision
        guard revision <= throughRevision else { throw RecoveryError.staleRevision }
        try FileManager.default.removeItem(at: file)
        written[id] = nil
    }
    /// Explicit user discard of snapshots listed by an earlier scan. Each item goes through
    /// remove(id:throughRevision:), so only the listed identities at the scanned revision are
    /// deleted: a snapshot that advanced since the scan, a corrupt file or an unlisted
    /// neighbour is left untouched. Returns one issue per snapshot that was not removed.
    func discard(_ snapshots: [RecoverySnapshot]) -> [RecoveryIssue] {
        snapshots.compactMap { snapshot in
            do {
                try remove(id: snapshot.id, throughRevision: snapshot.revision)
                return nil
            } catch { return RecoveryIssue(url: fileURL(for: snapshot.id), message: error.localizedDescription) }
        }
    }
    /// Location only, for reporting and Reveal in Finder. The store never follows it blindly.
    func fileURL(for id: UUID) -> URL { url(for: id) }
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
        written[id] = Written(
            revision: revision, device: info.st_dev, inode: info.st_ino, size: info.st_size,
            modified: info.st_mtimespec, changed: info.st_ctimespec)
    }
    /// The revision this instance wrote, only while the file on disk is still that write.
    private func knownRevision(of id: UUID) -> UInt64? {
        guard let known = written[id], let info = identity(of: id), info.st_dev == known.device,
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
    private func prepareDirectory() throws {
        try checkDirectoryIfPresent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try checkDirectoryIfPresent()
        // The injected directory is dedicated to recovery. Never change parent permissions.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    private func privateAtomicWrite(_ data: Data, to destination: URL) throws {
        do {
            try PrivateFileStore.write(
                data, to: destination, maximumBytes: Self.maximumSnapshotBytes,
                temporaryPrefix: "", temporarySuffix: ".pending")
        } catch PrivateFileError.unsafeLocation { throw RecoveryError.unsafeLocation }
    }
    private func checkDirectoryIfPresent() throws {
        guard directory.isFileURL else { throw RecoveryError.unsafeLocation }
        if FileManager.default.fileExists(atPath: directory.path) {
            let properties = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard properties.isDirectory == true, properties.isSymbolicLink != true else {
                throw RecoveryError.unsafeLocation
            }
        }
    }
    private func read(_ url: URL, expectedID: UUID) throws -> RecoverySnapshot {
        let data: Data
        do { data = try PrivateFileStore.read(url, maximumBytes: Self.maximumSnapshotBytes) } catch PrivateFileError
            .unsafeLocation
        { throw RecoveryError.unsafeLocation } catch  where error.posixCode == .ELOOP {
            throw RecoveryError.unsafeLocation
        }
        snapshotReads += 1
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
