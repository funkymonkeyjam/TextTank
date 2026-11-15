// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

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
    let directory: URL
    private let lock = NSLock()
    init(directory: URL) { self.directory = directory }

    /// Save a monotonically increasing document revision; corrupt/newer records are never overwritten.
    func save(_ snapshot: RecoverySnapshot) throws {
        lock.lock()
        defer { lock.unlock() }
        try validate(snapshot)
        try prepareDirectory()
        let destination = url(for: snapshot.id)
        if FileManager.default.fileExists(atPath: destination.path) {
            let existing = try read(destination, expectedID: snapshot.id)
            guard existing.revision <= snapshot.revision else { throw RecoveryError.staleRevision }
            if existing.revision == snapshot.revision {
                guard existing.text == snapshot.text, existing.format == snapshot.format,
                    existing.originalURL == snapshot.originalURL
                else { throw RecoveryError.staleRevision }
                return
            }
        }
        let data = try JSONEncoder().encode(snapshot)
        try privateAtomicWrite(data, to: destination)
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
    func scan() throws -> RecoveryScan {
        lock.lock()
        defer { lock.unlock() }
        try checkDirectoryIfPresent()
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return RecoveryScan(snapshots: [], issues: [])
        }
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
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
    /// Invalid JSON entries cause an error, never silent deletion or fallback to an original file.
    func loadAll() throws -> [RecoverySnapshot] {
        lock.lock()
        defer { lock.unlock() }
        try checkDirectoryIfPresent()
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { file in
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else {
                throw RecoveryError.invalidSnapshot
            }
            return try read(file, expectedID: id)
        }
    }
    /// Remove only the revision explicitly acknowledged as saved/discarded, avoiding stale cleanup.
    func remove(id: UUID, throughRevision: UInt64) throws {
        lock.lock()
        defer { lock.unlock() }
        try checkDirectoryIfPresent()
        let file = url(for: id)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let snapshot = try read(file, expectedID: id)
        guard snapshot.revision <= throughRevision else { throw RecoveryError.staleRevision }
        try FileManager.default.removeItem(at: file)
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
    private func prepareDirectory() throws {
        try checkDirectoryIfPresent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try checkDirectoryIfPresent()
        // The injected directory is dedicated to recovery. Never change parent permissions.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    private func privateAtomicWrite(_ data: Data, to destination: URL) throws {
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".pending")
        // Create an empty private file before adding any document content. The containing
        // directory is already 0700, including during initial file creation.
        guard
            FileManager.default.createFile(
                atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else {
            throw CocoaError(.fileWriteNoPermission)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        if FileManager.default.fileExists(atPath: destination.path) {
            // Keep the new private metadata, rather than inheriting older broad permissions.
            _ = try FileManager.default.replaceItemAt(
                destination, withItemAt: temporary, options: .usingNewMetadataOnly)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
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
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true else {
            throw RecoveryError.unsafeLocation
        }
        let snapshot: RecoverySnapshot
        do { snapshot = try JSONDecoder().decode(RecoverySnapshot.self, from: Data(contentsOf: url)) } catch {
            throw RecoveryError.invalidSnapshot
        }
        guard snapshot.id == expectedID else { throw RecoveryError.invalidSnapshot }
        try validate(snapshot)
        return snapshot
    }
    private func validate(_ snapshot: RecoverySnapshot) throws {
        guard snapshot.schemaVersion == 1, snapshot.revision <= UInt64(Int64.max),
            snapshot.savedAt.timeIntervalSince1970.isFinite
        else { throw RecoveryError.invalidSnapshot }
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
