// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

enum PrivateFileError: LocalizedError {
    case unsafeLocation, tooLarge(limit: Int, url: URL)
    var errorDescription: String? {
        switch self {
        case .unsafeLocation: return "This action requires a regular local file in a real directory. The file was not changed."
        case .tooLarge(let limit, let url):
            return "“\(url.lastPathComponent)” exceeds this action’s limit of \(limit) bytes. The file was not changed."
        }
    }
}

/// Shared byte I/O only. Models keep their validation, load-failure latch and storage policy.
/// A selected import follows its parent path but never its final component; app-owned stores
/// and existing WorkspaceStore callers also refuse a symlinked immediate parent directory.
enum PrivateFileStore {
    enum ParentPolicy { case strict, selectedInput }
    static func validateLocalURL(_ url: URL) throws {
        guard url.isFileURL, (url.host ?? "").isEmpty || url.host == "localhost",
            url.query == nil, url.fragment == nil, url.path.hasPrefix("/"), !url.path.contains("\0"),
            !url.pathComponents.contains(".."), !url.lastPathComponent.isEmpty
        else { throw PrivateFileError.unsafeLocation }
    }
    static func directoryDescriptor(for url: URL) throws -> Int32 {
        try validateLocalURL(url)
        let descriptor = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return descriptor
    }
    static func openRegularFile(
        _ url: URL, maximumBytes: Int, parent: ParentPolicy = .strict
    ) throws -> (descriptor: Int32, info: stat) {
        try validateLocalURL(url)
        guard maximumBytes >= 0 else { throw PrivateFileError.tooLarge(limit: maximumBytes, url: url) }
        let descriptor: Int32
        if parent == .strict {
            let directory = try directoryDescriptor(for: url)
            defer { close(directory) }
            descriptor = openat(directory, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        } else {
            descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard info.st_mode & S_IFMT == S_IFREG else { throw PrivateFileError.unsafeLocation }
            guard info.st_size >= 0, info.st_size <= maximumBytes else {
                throw PrivateFileError.tooLarge(limit: maximumBytes, url: url)
            }
            return (descriptor, info)
        } catch {
            close(descriptor)
            throw error
        }
    }
    static func read(
        _ url: URL, maximumBytes: Int, parent: ParentPolicy = .strict
    ) throws -> Data {
        try readSample(url, maximumBytes: maximumBytes, parent: parent).data
    }
    static func readSample(
        _ url: URL, maximumBytes: Int, parent: ParentPolicy = .strict
    ) throws -> (data: Data, before: stat, after: stat?) {
        let opened = try openRegularFile(url, maximumBytes: maximumBytes, parent: parent)
        defer { close(opened.descriptor) }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let remaining = maximumBytes - data.count
            let request = min(buffer.count, remaining) + (remaining < buffer.count ? 1 : 0)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(opened.descriptor, $0.baseAddress, request) }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 { break }
            guard count <= remaining else { throw PrivateFileError.tooLarge(limit: maximumBytes, url: url) }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        return (data, opened.info, fstat(opened.descriptor, &after) == 0 ? after : nil)
    }
    /// Create/harden only a caller-declared app-owned directory. Never chmod its parent.
    static func prepareDirectory(_ directory: URL) throws {
        try validateLocalURL(directory.appendingPathComponent(".storage-check"))
        var info = stat()
        if lstat(directory.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR else { throw PrivateFileError.unsafeLocation }
        } else if errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard fchmod(descriptor, mode_t(0o700)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    /// The optional synchronizer is a narrow failure seam: a failed sync must not commit.
    /// Data and its 0600 metadata reach fsync before the same-directory atomic rename.
    static func write(
        _ data: Data, to url: URL, maximumBytes: Int, temporaryPrefix: String = ".texttank-",
        temporarySuffix: String = "", synchronize: (Int32) -> Int32 = { fsync($0) }
    ) throws {
        guard data.count <= maximumBytes else { throw PrivateFileError.tooLarge(limit: maximumBytes, url: url) }
        guard !temporaryPrefix.contains("/"), !temporarySuffix.contains("/"),
            !temporaryPrefix.contains("\0"), !temporarySuffix.contains("\0")
        else { throw PrivateFileError.unsafeLocation }
        let directory = try directoryDescriptor(for: url)
        defer { close(directory) }
        var info = stat()
        if fstatat(directory, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG else { throw PrivateFileError.unsafeLocation }
        } else if errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let temporary = temporaryPrefix + UUID().uuidString + temporarySuffix
        let descriptor = openat(directory, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer {
            close(descriptor)
            unlinkat(directory, temporary, 0)
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
        guard synchronize(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard renameat(directory, temporary, directory, url.lastPathComponent) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
