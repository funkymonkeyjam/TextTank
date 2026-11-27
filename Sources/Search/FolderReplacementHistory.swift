// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

package enum FolderReplacementHistory {
    package enum Retention: Int, CaseIterable, Sendable { case keep = 0, week = 7, month = 30, quarter = 90 }
    private struct Policy: Codable {
        let version: Int
        let days: Int
    }
    private static var store: URL { AppStorage.url(.folderReplacements) }
    private static var policy: URL { store.appendingPathComponent("Retention.json") }

    private static func readPolicy() throws -> Data? {
        do {
            return try PrivateFileStore.read(policy, maximumBytes: SizePolicy.standard.folderRetentionSettings)
        } catch  where error.isFileNotFound {
            return nil
        }
    }
    private static func decodePolicy(_ bytes: Data?) throws -> Retention {
        guard let bytes else { return .keep }
        let saved = try JSONDecoder().decode(Policy.self, from: bytes)
        guard saved.version == 1, let value = Retention(rawValue: saved.days),
            let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            Set(object.keys) == ["version", "days"]
        else {
            throw FolderSearchError.invalidRequest(
                "Unknown folder replacement retention setting. Existing batches were kept.")
        }
        return value
    }
    package static func retention() throws -> Retention { try decodePolicy(readPolicy()) }
    package static func setRetention(_ value: Retention, replacing expected: Retention) throws {
        let previous = try readPolicy()
        guard try decodePolicy(previous) == expected else { throw changed() }
        if value == expected { return }
        try PrivateFileStore.prepareDirectory(store)
        let bytes = try JSONEncoder().encode(Policy(version: 1, days: value.rawValue))
        try PrivateFileStore.write(
            bytes, to: policy, maximumBytes: SizePolicy.standard.folderRetentionSettings,
            beforeCommit: {
                guard try readPolicy() == previous else { throw changed() }
            }, requireMissing: previous == nil)
    }
    private static func changed() -> FolderSearchError {
        .invalidRequest("The saved recovery information changed. Refresh and review it again.")
    }

    /// Move the confirmed directory out of the live set atomically. Keep its manifest
    /// until all known originals have been removed, so an interruption can be resumed.
    package static func delete(_ manifest: URL, reviewed: FolderReplacementBatch.Snapshot) throws {
        try remove(manifest, reviewed: reviewed)
    }
    private static func remove(
        _ manifest: URL, reviewed: FolderReplacementBatch.Snapshot, beforeRename: () throws -> Void = {}
    ) throws {
        let batch = try FolderReplacementBatch(reopening: manifest)
        try withExtendedLifetime(batch) {
            let current = try batch.lockedSnapshot()
            guard current.id == reviewed.id, current.manifestDigest == reviewed.manifestDigest else { throw changed() }
            let directory = manifest.deletingLastPathComponent()
            let retired = store.appendingPathComponent(".deleting-" + current.id.uuidString)
            let parent = try PrivateFileStore.directoryDescriptor(for: directory)
            defer { close(parent) }
            let pinned = try PrivateFileStore.directoryDescriptor(for: manifest)
            defer { close(pinned) }
            let members = try knownMembers(in: directory, snapshot: current)
            try beforeRename()
            guard batch.verifiesManifest(in: pinned), sameDirectory(directory, descriptor: pinned) else {
                throw changed()
            }
            guard
                renameatx_np(
                    parent, directory.lastPathComponent, parent, retired.lastPathComponent, UInt32(RENAME_EXCL)) == 0
            else {
                throw FileOperationFailure(errno, operation: "retire selected replacement batch", path: directory.path)
            }
            try finishRemoval(retired, pinned: pinned, members: members)
        }
    }
    private static func knownMembers(in directory: URL, snapshot: FolderReplacementBatch.Snapshot) throws -> [String] {
        let members = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let allowed = Set(snapshot.entries.map { $0.0.backupName } + [FolderReplacementBatch.manifestName])
        guard members.allSatisfy(allowed.contains) else {
            throw FolderSearchError.invalidRequest(
                "The recovery directory contains an unrecognized item. Its contents were kept.")
        }
        let fd = try PrivateFileStore.directoryDescriptor(
            for: directory.appendingPathComponent(FolderReplacementBatch.manifestName))
        defer { close(fd) }
        for leaf in members {
            var info = stat()
            guard fstatat(fd, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG,
                info.st_nlink == 1, info.st_uid == getuid()
            else { throw PrivateFileError.unsafeLocation }
        }
        return members.filter { $0 != FolderReplacementBatch.manifestName }
    }
    private static func sameDirectory(_ directory: URL, descriptor: Int32) -> Bool {
        var pinned = stat(), current = stat()
        return fstat(descriptor, &pinned) == 0 && lstat(directory.path, &current) == 0
            && current.st_mode & S_IFMT == S_IFDIR && pinned.st_dev == current.st_dev && pinned.st_ino == current.st_ino
    }
    private static func finishRemoval(_ retired: URL, pinned fd: Int32, members: [String]) throws {
        let manifest = FolderReplacementBatch.manifestName
        guard sameDirectory(retired, descriptor: fd) else { throw changed() }
        for leaf in members + [manifest] {
            guard unlinkat(fd, leaf, 0) == 0 || errno == ENOENT else {
                throw FileOperationFailure(errno, operation: "remove private recovery file", path: retired.path)
            }
        }
        guard sameDirectory(retired, descriptor: fd) else { throw changed() }
        guard rmdir(retired.path) == 0 else {
            throw FileOperationFailure(errno, operation: "remove retired batch", path: retired.path)
        }
    }
    package struct PruneReport: Sendable {
        package var removed = 0
        package var needsReview = 0
    }
    private static func finishInterruptedRemovals(report: inout PruneReport) throws {
        let storeFD: Int32
        do { storeFD = try FolderReplacementBatch.openStore() } catch  where error.isFileNotFound { return }
        defer { close(storeFD) }
        let children: [URL]
        do { children = try FileManager.default.contentsOfDirectory(at: store, includingPropertiesForKeys: nil) } catch
            where error.isFileNotFound
        { return }
        for child in children where child.lastPathComponent.hasPrefix(".deleting-") {
            let name = String(child.lastPathComponent.dropFirst(".deleting-".count))
            guard let id = UUID(uuidString: name), name == id.uuidString else { continue }
            // An empty directory is the last crash window after deleting the manifest.
            guard sameDirectory(store, descriptor: storeFD) else { throw changed() }
            if unlinkat(storeFD, child.lastPathComponent, AT_REMOVEDIR) == 0 || errno == ENOENT { continue }
            do {
                let batch = try FolderReplacementBatch(
                    reopening: child.appendingPathComponent(FolderReplacementBatch.manifestName), retired: true)
                try withExtendedLifetime(batch) {
                    let snapshot = try batch.lockedSnapshot()
                    let pinned = try PrivateFileStore.directoryDescriptor(
                        for: child.appendingPathComponent(FolderReplacementBatch.manifestName))
                    defer { close(pinned) }
                    guard batch.verifiesManifest(in: pinned) else { throw changed() }
                    try finishRemoval(child, pinned: pinned, members: knownMembers(in: child, snapshot: snapshot))
                }
            } catch { report.needsReview += 1 }
        }
    }
    @discardableResult package static func prune(now: Date = Date()) throws -> PruneReport {
        var result = PruneReport()
        try finishInterruptedRemovals(report: &result)
        let age = try retention()
        guard age != .keep else { return result }
        let cutoff = now.addingTimeInterval(-Double(age.rawValue) * 86400)
        for (created, manifest) in try FolderReplacementBatch.listing() {
            guard created != .distantFuture else {
                result.needsReview += 1
                continue
            }
            guard created < cutoff else { continue }
            do {
                let review = try FolderReplacementBatch.read(manifest)
                guard review.created < cutoff, review.completeTail, !review.entries.isEmpty,
                    !review.entries.contains(where: { $0.1 == .prepared })
                else { continue }
                try remove(manifest, reviewed: review) {
                    guard try retention() == age else { throw changed() }
                }
                result.removed += 1
            } catch {
                if try retention() != age { break }
                result.needsReview += 1
            }
        }
        return result
    }
}
