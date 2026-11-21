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
    package struct Snapshot {
        package let id: UUID
        package let created: Date
        package let entries: [(Entry, State)]
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
    private let id = UUID()
    private let created = Date()
    private var stream: Int32 = -1
    private var retained = 0
    private var stopped = false
    package init(store: URL = AppStorage.url(.folderReplacements)) {
        directory = store.appendingPathComponent(id.uuidString, isDirectory: true)
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
                    bytes, to: manifest, maximumBytes: Self.maximumManifestBytes, synchronizeDirectory: { fsync($0) },
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
        var lines = bytes.split(separator: 10, omittingEmptySubsequences: false)
        // The writer syncs each complete line before acting on it. Ignore an uncommitted tail.
        if !lines.isEmpty { lines.removeLast() }
        guard let first = lines.first else { throw PrivateFileError.unsafeLocation }
        let decoder = JSONDecoder()
        let header = try decoder.decode(Header.self, from: Data(first))
        guard header.version == 1, header.id.uuidString == manifest.deletingLastPathComponent().lastPathComponent
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
        return Snapshot(id: header.id, created: header.created, entries: entries.filter { $0.1 != .abandoned })
    }
}
