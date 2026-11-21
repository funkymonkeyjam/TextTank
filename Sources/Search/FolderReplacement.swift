// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

package struct FolderReplacementOutcome: Sendable {
    package init(url: URL, status: Status, message: String, backup: URL?, recoveryReport: URL? = nil) {
        self.url = url
        self.status = status
        self.message = message
        self.backup = backup
        self.recoveryReport = recoveryReport
    }

    package enum Status: String, Sendable {
        case replaced, unchanged, conflict, skipped, failed, cancelled
        package var displayName: String {
            switch self {
            case .replaced: return Strings.text("replacement.replaced", "Replaced")
            case .unchanged: return Strings.text("replacement.unchanged", "Unchanged")
            case .conflict: return Strings.text("replacement.conflict", "Changed since search")
            case .skipped: return Strings.text("replacement.skipped", "Skipped")
            case .failed: return Strings.text("replacement.failed", "Failed")
            case .cancelled: return Strings.text("replacement.cancelled", "Cancelled")
            }
        }
    }
    package let url: URL, status: Status, message: String, backup: URL?
    package var recoveryReport: URL?
}
/// Explicit disk replacement of a completed folder-search snapshot. Each file has
/// its own byte-exact recovery copy. This is NOT an atomic multi-file transaction.
/// Descriptor traversal rejects symlink parents/leaves. Compare just before rename
/// detects ordinary external changes; noncooperating writers can still race the
/// final stat/rename interval. Open documents are excluded by the UI.
package enum FolderReplacement {
    private enum Failure: LocalizedError {
        case unsafe, changed, large, cancelled
        var errorDescription: String? {
            switch self {
            case .unsafe: return "Not a writable single-link regular file inside the chosen directory."
            case .changed: return "File changed since search; search again before replacing."
            case .large: return "File exceeds the 32 MiB replacement limit."
            case .cancelled: return "Cancelled before committing this file."
            }
        }
    }
    static package func replace(
        directory: URL, matches: [FolderSearchMatch], options: SearchOptions, excluding: Set<URL> = [],
        cancellation: FolderSearchCancellation = FolderSearchCancellation(),
        batch: FolderReplacementBatch = FolderReplacementBatch(), beforeCommit: ((URL) -> Void)? = nil
    ) throws -> [FolderReplacementOutcome] {
        guard let opened = try? FolderSearch.openCanonicalDirectory(directory) else { throw Failure.unsafe }
        let root = opened.fd, rootPath = opened.path, prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        defer { close(root) }
        let privateRoot = FolderReplacementBatch.canonicalPath(of: batch.directory.deletingLastPathComponent())
        let excluded = Set(excluding.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
        let grouped = Dictionary(grouping: matches, by: { $0.url })
        var results: [FolderReplacementOutcome] = []
        for url in grouped.keys.sorted(by: { $0.path < $1.path }) {
            if cancellation.isCancelled {
                results.append(
                    .init(url: url, status: .cancelled, message: "Not processed after cancellation.", backup: nil))
                continue
            }
            if excluded.contains(url.resolvingSymlinksInPath().standardizedFileURL.path) {
                results.append(
                    .init(
                        url: url, status: .skipped,
                        message: "File is open in TextTank; use All Open Documents replacement and Save.", backup: nil))
                continue
            }
            guard let fingerprints = grouped[url].map({ Set($0.compactMap(\.sourceSHA256)) }), fingerprints.count == 1,
                let expected = fingerprints.first
            else {
                results.append(
                    .init(
                        url: url, status: .conflict,
                        message: "Search snapshot has no unique source fingerprint; search again.", backup: nil))
                continue
            }
            var backup: URL?, reportURL: URL?
            do {
                // The matches are the caller's, so this is the guard that keeps a recovery copy,
                // journal or temporary file from ever being rewritten.
                guard let parts = FolderSearch.relativeComponents(of: url.path, under: prefix),
                    !FolderSearch.isRecoveryArtifact(parts[parts.count - 1]),
                    !FolderReplacementBatch.contains(url.path, in: privateRoot)
                else { throw Failure.unsafe }
                let parent = try openParent(root: root, parts: parts)
                defer { close(parent) }
                let name = parts.last!, source = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                guard source >= 0 else { throw Failure.unsafe }
                defer { close(source) }
                var initial = stat()
                guard fstat(source, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG, initial.st_nlink == 1,
                    initial.st_mode & 0o222 != 0, initial.st_uid == getuid()
                else { throw Failure.unsafe }
                guard initial.st_size >= 0, initial.st_size <= 32 * 1024 * 1024 else { throw Failure.large }
                let original = try read(source, size: Int(initial.st_size), cancellation: cancellation, path: url.path)
                guard sha(original) == expected else { throw Failure.changed }
                let decoded = try FileCodec.decode(original)
                let found = try SearchCore.search(
                    decoded.text, options: options, cancellation: cancellation.engineToken, limit: 100000)
                guard !found.truncated else {
                    throw FolderSearchError.invalidRequest("Replacement result limit reached; file not changed.")
                }
                let output: String
                do {
                    output = try SearchCore.replacing(
                        decoded.text, with: found.hits, cancellation: cancellation.engineToken)
                } catch {
                    if cancellation.isCancelled { throw Failure.cancelled }
                    throw error
                }
                let encoded = try FileCodec.encode(output, format: decoded.format)
                if encoded == original {
                    results.append(.init(url: url, status: .unchanged, message: "No byte changes.", backup: nil))
                    continue
                }
                guard encoded.count <= 64 * 1024 * 1024 else { throw Failure.large }
                let stage = try StagingFile(for: url, parent: parent)
                let temp = stage.file
                try write(encoded, to: temp, path: url.path)
                // Copy permissions, ownership, ACLs, extended attributes and flags
                // from the still-open source descriptor, without copying its data.
                // COPYFILE_METADATA also copies the source's timestamps. The content is new, so
                // stamp the current time: build tools, backups and other editors detect changes
                // by modification time. The creation date and all other metadata are kept.
                guard fcopyfile(source, temp, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0, futimens(temp, nil) == 0,
                    fsync(temp) == 0
                else {
                    throw FileOperationFailure(
                        errno, operation: "update file metadata or replacement beside", path: url.path)
                }
                let entry = FolderReplacementBatch.Entry(
                    id: UUID(), root: rootPath, path: url.path, originalSHA256: expected,
                    replacementSHA256: sha(encoded), originalMode: UInt16(initial.st_mode & 0o7777))
                backup = try batch.prepare(source: source, original: original, entry: entry)
                reportURL = batch.manifest
                var renameAttempted = false
                do {
                    beforeCommit?(url)
                    if cancellation.isCancelled { throw Failure.cancelled }
                    try verifyCurrent(
                        parent: parent, name: name, initial: initial, bytes: original,
                        cancellation: cancellation, path: url.path)
                    renameAttempted = true
                    guard renameat(stage.folder, StagingFile.name, parent, name) == 0 else {
                        throw FileOperationFailure(
                            errno, operation: "update file metadata or replacement beside", path: url.path)
                    }
                } catch {
                    if !renameAttempted {
                        try batch.mark(entry, .abandoned)
                        backup = nil
                        reportURL = nil
                    }
                    throw error
                }
                // Once renamed the file is changed even if directory durability fails.
                let durable = fsync(parent) == 0
                var journalConfirmed = true
                do { try batch.mark(entry, .replaced) } catch {
                    journalConfirmed = false
                }
                results.append(
                    .init(
                        url: url, status: .replaced,
                        message: "Replaced \(found.hits.count) match(es)."
                            + (durable && journalConfirmed
                                ? ""
                                : " Completion journal/directory synchronization failed; prepared recovery report retained."),
                        backup: backup, recoveryReport: reportURL))
            } catch Failure.changed {
                results.append(
                    .init(
                        url: url, status: .conflict, message: Failure.changed.localizedDescription, backup: backup,
                        recoveryReport: reportURL))
            } catch Failure.cancelled {
                results.append(
                    .init(
                        url: url, status: .cancelled, message: Failure.cancelled.localizedDescription, backup: backup,
                        recoveryReport: reportURL))
            } catch {
                results.append(
                    .init(
                        url: url, status: .failed, message: error.localizedDescription, backup: backup,
                        recoveryReport: reportURL))
            }
        }
        return results
    }
    package enum UndoStatus: String, Sendable {
        case restored, alreadyOriginal, skipped, changed, failed, cancelled
    }
    package struct UndoOutcome: Sendable {
        package let url: URL
        package let status: UndoStatus
        package let message: String
    }
    static package func undo(
        manifest: URL, reviewed: FolderReplacementBatch.Snapshot? = nil, excluding openFiles: Set<URL> = [],
        cancellation: FolderSearchCancellation = FolderSearchCancellation(), beforeCommit: ((URL) -> Void)? = nil
    ) throws -> [UndoOutcome] {
        let batch = try FolderReplacementBatch(reopening: manifest)
        let snapshot = try batch.snapshotForUndo(reviewed: reviewed)
        let excluded = Set(openFiles.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
        return snapshot.entries.map { entry, state in
            let url = URL(fileURLWithPath: entry.path)
            if state == .restored {
                return .init(url: url, status: .alreadyOriginal, message: "Already processed by Undo.")
            }
            if cancellation.isCancelled {
                return .init(url: url, status: .cancelled, message: "Cancelled before restoring this file.")
            }
            if excluded.contains(url.resolvingSymlinksInPath().standardizedFileURL.path) {
                return .init(url: url, status: .skipped, message: "File is open in TextTank.")
            }
            do {
                return try restore(entry: entry, batch: batch, cancellation: cancellation, beforeCommit: beforeCommit)
            } catch Failure.changed {
                return .init(
                    url: url, status: .changed,
                    message: "File changed since replacement. Kept current file and recovery copy.")
            } catch Failure.cancelled {
                return .init(url: url, status: .cancelled, message: "Cancelled before restoring this file.")
            } catch { return .init(url: url, status: .failed, message: error.localizedDescription) }
        }
    }

    private static func restore(
        entry: FolderReplacementBatch.Entry, batch: FolderReplacementBatch,
        cancellation: FolderSearchCancellation, beforeCommit: ((URL) -> Void)?
    ) throws -> UndoOutcome {
        let url = URL(fileURLWithPath: entry.path)
        let root = try FolderSearch.openCanonicalDirectory(URL(fileURLWithPath: entry.root))
        defer { close(root.fd) }
        guard root.path.utf8.elementsEqual(entry.root.utf8), entry.originalMode <= 0o7777,
            let parts = FolderSearch.relativeComponents(
                of: entry.path, under: root.path == "/" ? "/" : root.path + "/"),
            let leaf = parts.last, !FolderSearch.isRecoveryArtifact(leaf),
            !FolderReplacementBatch.contains(
                entry.path, in: FolderReplacementBatch.canonicalPath(of: AppStorage.url(.folderReplacements)))
        else { throw Failure.unsafe }
        let parent = try openParent(root: root.fd, parts: parts)
        defer { close(parent) }
        let current = openat(parent, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard current >= 0 else { throw FileOperationFailure(errno, operation: "open file for Undo", path: url.path) }
        defer { close(current) }
        var initial = stat()
        guard fstat(current, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG, initial.st_nlink == 1,
            initial.st_uid == getuid(), initial.st_mode & 0o222 != 0,
            initial.st_size >= 0, initial.st_size <= 64 * 1024 * 1024
        else { throw Failure.unsafe }
        let currentBytes = try read(current, size: Int(initial.st_size), cancellation: cancellation, path: url.path)
        let currentDigest = sha(currentBytes)
        guard currentDigest == entry.replacementSHA256 || currentDigest == entry.originalSHA256 else {
            throw Failure.changed
        }
        if currentDigest == entry.originalSHA256 {
            // Includes a crash before forward rename, or after restoring but before the journal mark.
            try verifyCurrent(
                parent: parent, name: leaf, initial: initial, bytes: currentBytes, cancellation: cancellation,
                path: url.path)
            guard fsync(parent) == 0 else {
                throw FileOperationFailure(errno, operation: "confirm original file directory", path: url.path)
            }
            try batch.mark(entry, .restored)
            return .init(url: url, status: .alreadyOriginal, message: "File already contains its original bytes.")
        }
        let backup = batch.directory.appendingPathComponent(entry.backupName)
        let saved = try PrivateFileStore.openRegularFile(backup, maximumBytes: 32 * 1024 * 1024)
        defer { close(saved.descriptor) }
        guard saved.info.st_nlink == 1, saved.info.st_uid == getuid(), saved.info.st_mode & 0o077 == 0 else {
            throw Failure.unsafe
        }
        let bytes = try read(
            saved.descriptor, size: Int(saved.info.st_size), cancellation: cancellation, path: backup.path)
        guard sha(bytes) == entry.originalSHA256 else {
            throw FolderSearchError.invalidRequest(
                "Private original failed its content check. The current file was kept.")
        }
        let stage = try StagingFile(for: url, parent: parent)
        try write(bytes, to: stage.file, path: url.path)
        // Use the current file's creation date and ACL. Use only the saved original for xattrs and mode.
        guard fcopyfile(current, stage.file, nil, copyfile_flags_t(COPYFILE_STAT | COPYFILE_ACL)) == 0,
            fcopyfile(saved.descriptor, stage.file, nil, copyfile_flags_t(COPYFILE_XATTR)) == 0,
            fchmod(stage.file, mode_t(entry.originalMode)) == 0, futimens(stage.file, nil) == 0, fsync(stage.file) == 0
        else {
            throw FileOperationFailure(errno, operation: "prepare original file for Undo", path: url.path)
        }
        beforeCommit?(url)
        if cancellation.isCancelled { throw Failure.cancelled }
        try verifyCurrent(
            parent: parent, name: leaf, initial: initial, bytes: currentBytes, cancellation: cancellation,
            path: url.path)
        guard renameat(stage.folder, StagingFile.name, parent, leaf) == 0 else {
            throw FileOperationFailure(errno, operation: "restore original file", path: url.path)
        }
        let durable = fsync(parent) == 0
        do {
            // An unconfirmed rename keeps its previous recovery entry available for a safe retry.
            if durable { try batch.mark(entry, .restored) }
        } catch {
            return .init(
                url: url, status: .restored,
                message: "Original restored. The private manifest update could not be confirmed.")
        }
        return .init(
            url: url, status: .restored,
            message: durable
                ? "Original bytes, mode and extended attributes restored."
                : "Original restored. Directory synchronization could not be confirmed.")
    }
    private final class StagingFile {
        static let name = "replacement"
        let directory: URL
        let folder: Int32
        let file: Int32
        init(for url: URL, parent: Int32) throws {
            guard faccessat(parent, ".", W_OK, 0) == 0 else {
                throw FileOperationFailure(errno, operation: "create replacement in", path: url.path)
            }
            directory = try FileManager.default.url(
                for: .itemReplacementDirectory, in: .userDomainMask,
                appropriateFor: url, create: true)
            do {
                folder = try PrivateFileStore.directoryDescriptor(for: directory.appendingPathComponent(Self.name))
            } catch {
                _ = rmdir(directory.path)
                throw error
            }
            file = openat(folder, Self.name, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if file < 0 {
                let failure = FileOperationFailure(errno, operation: "create replacement for", path: url.path)
                close(folder)
                _ = rmdir(directory.path)
                throw failure
            }
        }
        deinit {
            close(file)
            _ = unlinkat(folder, Self.name, 0)
            close(folder)
            _ = rmdir(directory.path)
        }
    }
    private static func openParent(root: Int32, parts: [String]) throws -> Int32 {
        var parent = dup(root)
        guard parent >= 0 else { throw Failure.unsafe }
        for part in parts.dropLast() {
            let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else {
                close(parent)
                throw Failure.unsafe
            }
            close(parent)
            parent = next
        }
        return parent
    }
    private static func verifyCurrent(
        parent: Int32, name: String, initial: stat, bytes: Data,
        cancellation: FolderSearchCancellation, path: String
    ) throws {
        let current = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard current >= 0 else { throw Failure.changed }
        defer { close(current) }
        var latest = stat()
        guard fstat(current, &latest) == 0, latest.st_mode & S_IFMT == S_IFREG,
            latest.st_ino == initial.st_ino, latest.st_dev == initial.st_dev,
            latest.st_size == initial.st_size, latest.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
            latest.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec, latest.st_nlink == 1,
            latest.st_mode == initial.st_mode, latest.st_uid == initial.st_uid,
            latest.st_gid == initial.st_gid, latest.st_flags == initial.st_flags,
            latest.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec,
            latest.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec,
            try read(current, size: Int(latest.st_size), cancellation: cancellation, path: path)
                == bytes
        else { throw Failure.changed }
    }
    private static func sha(_ data: Data) -> String { FolderSearch.sha256Hex(data) }
    static func read(_ fd: Int32, size: Int, cancellation: FolderSearchCancellation, path: String) throws
        -> Data
    {
        var output = Data(), bytes = [UInt8](repeating: 0, count: 65536)
        while output.count < size {
            if cancellation.isCancelled { throw Failure.cancelled }
            let count = Darwin.read(fd, &bytes, min(bytes.count, size - output.count))
            if count < 0 && errno == EINTR { continue }
            if count < 0 { throw FileOperationFailure(errno, operation: "read", path: path) }
            guard count > 0 else { throw Failure.changed }
            output.append(contentsOf: bytes.prefix(count))
        }
        return output
    }
    static func write(_ data: Data, to fd: Int32, path: String) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else {
                    throw FileOperationFailure(count < 0 ? errno : EIO, operation: "write", path: path)
                }
                offset += count
            }
        }
    }
}
