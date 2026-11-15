// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import CryptoKit

struct FolderReplacementOutcome: Sendable {
    enum Status: String, Sendable { case replaced, unchanged, conflict, skipped, failed, cancelled }
    let url: URL, status: Status, message: String, backup: URL?
    var recoveryReport: URL? = nil
}
/// Explicit disk replacement of a completed folder-search snapshot. Each file has
/// its own byte-exact recovery copy. This is NOT an atomic multi-file transaction.
/// Descriptor traversal rejects symlink parents/leaves. Compare just before rename
/// detects ordinary external changes; noncooperating writers can still race the
/// final stat/rename interval. Open documents are excluded by the UI.
enum FolderReplacement {
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
    static func replace(
        directory: URL, matches: [FolderSearchMatch], options: SearchOptions, excluding: Set<URL> = [],
        cancellation: FolderSearchCancellation = FolderSearchCancellation(), beforeCommit: ((URL) -> Void)? = nil
    ) throws -> [FolderReplacementOutcome] {
        let root = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard root >= 0 else { throw Failure.unsafe }
        defer { close(root) }
        var canonical = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(root, F_GETPATH, &canonical) == 0 else { throw Failure.unsafe }
        let rootPath = String(cString: canonical), prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
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
                guard url.path.hasPrefix(prefix) else { throw Failure.unsafe }
                let parts = String(url.path.dropFirst(prefix.count)).split(separator: "/").map(String.init)
                guard !parts.isEmpty, parts.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
                    throw Failure.unsafe
                }
                var parent = dup(root)
                guard parent >= 0 else { throw Failure.unsafe }
                defer { close(parent) }
                for part in parts.dropLast() {
                    let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                    guard next >= 0 else { throw Failure.unsafe }
                    close(parent)
                    parent = next
                }
                let name = parts.last!, source = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                guard source >= 0 else { throw Failure.unsafe }
                defer { close(source) }
                var initial = stat()
                guard fstat(source, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG, initial.st_nlink == 1,
                    initial.st_mode & 0o222 != 0, initial.st_uid == getuid()
                else { throw Failure.unsafe }
                guard initial.st_size >= 0, initial.st_size <= 32 * 1024 * 1024 else { throw Failure.large }
                let original = try read(source, size: Int(initial.st_size), cancellation: cancellation)
                guard sha(original) == expected else { throw Failure.changed }
                let decoded = try FileCodec.decode(original)
                let found = try SearchCore.search(
                    decoded.text, options: options, cancellation: cancellation.engineToken, limit: 100000)
                guard !found.truncated else {
                    throw FolderSearchError.invalidRequest("Replacement result limit reached; file not changed.")
                }
                let output = try SearchCore.replacing(decoded.text, with: found.hits),
                    encoded = try FileCodec.encode(output, format: decoded.format)
                if encoded == original {
                    results.append(.init(url: url, status: .unchanged, message: "No byte changes.", backup: nil))
                    continue
                }
                guard encoded.count <= 64 * 1024 * 1024 else { throw Failure.large }
                let tempName = ".texttank-replacement-" + UUID().uuidString
                let temp = openat(parent, tempName, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode_t(0o600))
                guard temp >= 0 else { throw POSIXError(.EIO) }
                defer {
                    close(temp)
                    unlinkat(parent, tempName, 0)
                }
                try write(encoded, to: temp)
                // Copy permissions, ownership, ACLs, extended attributes and flags
                // from the still-open source descriptor, without copying its data.
                // COPYFILE_METADATA also copies the source's timestamps. The content is new, so
                // stamp the current time: build tools, backups and other editors detect changes
                // by modification time. The creation date and all other metadata are kept.
                guard fcopyfile(source, temp, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0, futimens(temp, nil) == 0,
                    fsync(temp) == 0
                else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                let backupName = ".texttank-backup-" + UUID().uuidString
                let copy = openat(parent, backupName, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode_t(0o600))
                guard copy >= 0 else { throw POSIXError(.EIO) }
                do {
                    try write(original, to: copy)
                    guard fsync(copy) == 0 else { throw POSIXError(.EIO) }
                    close(copy)
                } catch {
                    close(copy)
                    unlinkat(parent, backupName, 0)
                    throw error
                }
                backup = url.deletingLastPathComponent().appendingPathComponent(backupName)
                guard fsync(parent) == 0 else { throw POSIXError(.EIO) }
                let reportName = backupName + ".json"
                let journal: [String: String] = [
                    "version": "1", "state": "prepared", "file": name, "backup": backupName, "originalSHA256": expected,
                    "replacementSHA256": sha(encoded),
                    "note": "Prepared does not prove whether rename committed. Compare file hashes before restoring."
                ]
                try persistReport(journal, name: reportName, parent: parent)
                reportURL = url.deletingLastPathComponent().appendingPathComponent(reportName)
                beforeCommit?(url)
                if cancellation.isCancelled { throw Failure.cancelled }
                let current = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                guard current >= 0 else { throw Failure.changed }
                defer { close(current) }
                var latest = stat()
                guard fstat(current, &latest) == 0, latest.st_mode & S_IFMT == S_IFREG, latest.st_ino == initial.st_ino,
                    latest.st_dev == initial.st_dev, latest.st_size == initial.st_size,
                    latest.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
                    latest.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec, latest.st_nlink == 1,
                    latest.st_mode == initial.st_mode, latest.st_uid == initial.st_uid, latest.st_gid == initial.st_gid,
                    latest.st_flags == initial.st_flags, latest.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec,
                    latest.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec,
                    try read(current, size: Int(latest.st_size), cancellation: cancellation) == original
                else { throw Failure.changed }
                guard renameat(parent, tempName, parent, name) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                // Once renamed the file is changed even if directory durability fails.
                let durable = fsync(parent) == 0
                var committed = journal
                committed["state"] = "replaced"
                var journalConfirmed = true
                do { try persistReport(committed, name: reportName, parent: parent) } catch { journalConfirmed = false }
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
    private static func persistReport(_ report: [String: String], name: String, parent: Int32) throws {
        let temporary = ".texttank-report-" + UUID().uuidString
        let fd = openat(parent, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer {
            close(fd)
            unlinkat(parent, temporary, 0)
        }
        try write(JSONEncoder().encode(report), to: fd)
        guard fsync(fd) == 0, renameat(parent, temporary, parent, name) == 0, fsync(parent) == 0 else {
            throw POSIXError(.EIO)
        }
    }
    private static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func read(_ fd: Int32, size: Int, cancellation: FolderSearchCancellation) throws -> Data {
        var output = Data(), bytes = [UInt8](repeating: 0, count: 65536)
        while output.count < size {
            if cancellation.isCancelled { throw Failure.cancelled }
            let count = Darwin.read(fd, &bytes, min(bytes.count, size - output.count))
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw Failure.changed }
            output.append(contentsOf: bytes.prefix(count))
        }
        return output
    }
    private static func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
    }
}
