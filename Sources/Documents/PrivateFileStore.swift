// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

/// Path selection is computed and has no filesystem side effects. In particular, invalid
/// overrides never create a relative store, and checks can repoint the directory in process.
package enum AppStorage {
    package enum Location: String {
        case settings = "Settings.json", macros = "Macros.json", automations = "Automations.json"
        case languages = "LanguageProfiles.json", commands = "RunCommands.json", workspace = "WorkspaceBrowser.json"
        case recovery = "Recovery", reminders = "ReminderExports", lastSession = "LastSession.json"
        case find = "FindPreferences.json", folderSearch = "FolderSearchPreferences.json"
        case folderReplacements = "FolderReplacements"
        package var isDirectory: Bool { self == .recovery || self == .reminders || self == .folderReplacements }
    }
    static package func resolve(override: String?, fallback: URL) -> URL {
        guard let override, override.hasPrefix("/"), !override.contains("\0") else { return fallback }
        return URL(fileURLWithPath: override, isDirectory: true)
    }
    static package var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TextTank", isDirectory: true)
    }
    private static var override: String? { ProcessInfo.processInfo.environment["TEXTTANK_SUPPORT_DIRECTORY"] }
    static package var supportDirectory: URL { resolve(override: override, fallback: defaultDirectory) }
    /// An isolated/portable store never imports from the person's shared defaults implicitly.
    static package var permitsLegacyDefaults: Bool {
        guard let override else { return true }
        return !override.hasPrefix("/") || override.contains("\0")
    }
    /// Deferred so an isolated constructor never even asks for the shared defaults object.
    /// The caller owns any injected provider; Core holds no mutable process state.
    static package func legacyDefaults(providing provider: () -> UserDefaults = { UserDefaults.standard })
        -> UserDefaults?
    {
        permitsLegacyDefaults ? provider() : nil
    }
    static package func url(_ location: Location, under directory: URL? = nil) -> URL {
        (directory ?? supportDirectory).appendingPathComponent(location.rawValue, isDirectory: location.isDirectory)
    }
}

/// One latch for a failed store load. Save boundaries call requireWritable, not just UI callers.
/// Moving aside is an explicit operation on the entry itself, never a copy through a symlink.
final package class StoreLoadState {
    package let url: URL
    package let displayName: String
    package var error: Error?
    package init(url: URL, displayName: String) {
        self.url = url
        self.displayName = displayName
    }
    package func requireWritable() throws { if let error { throw error } }
    @discardableResult package func moveAside(allowSymbolicLink: Bool = true, tag: String = "previous") throws -> URL? {
        let directory = try PrivateFileStore.directoryDescriptor(for: url)
        defer { close(directory) }
        var info = stat()
        if fstatat(directory, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            let code = errno
            guard code == ENOENT else {
                throw FileOperationFailure(code, operation: "inspect saved entry", path: url.path)
            }
            error = nil
            return nil
        }
        let type = info.st_mode & S_IFMT
        guard type == S_IFREG || type == S_IFIFO || (type == S_IFLNK && allowSymbolicLink) else {
            throw PrivateFileError.unsafeLocation
        }
        let name =
            url.deletingPathExtension().lastPathComponent + "." + tag + "-" + UUID().uuidString + "."
            + url.pathExtension
        guard renameatx_np(directory, url.lastPathComponent, directory, name, UInt32(RENAME_EXCL)) == 0 else {
            throw FileOperationFailure(errno, operation: "move saved entry aside", path: url.path)
        }
        error = nil
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }
}

/// A small value-store boundary used by preferences. It owns failed-load protection and byte
/// no-op detection, while each model owns its exact schema, decoder, encoder and field limits.
final package class JSONFileStore<Value> {
    package let state: StoreLoadState
    private(set) package var value: Value
    private(set) package var lastSaveError: Error?
    private let initial: Value, maximumBytes: Int
    private let encode: (Value) throws -> Data
    private var savedModelBytes: Data?
    package init(
        url: URL, displayName: String, maximumBytes: Int, initial: Value,
        decode: (Data) throws -> Value, encode: @escaping (Value) throws -> Data,
        legacyValue: (() throws -> Value?)? = nil
    ) {
        state = StoreLoadState(url: url, displayName: displayName)
        self.initial = initial
        self.value = initial
        self.maximumBytes = maximumBytes
        self.encode = encode
        do {
            let data = try PrivateFileStore.read(url, maximumBytes: maximumBytes)
            try PersistedFormat.check(data, context: displayName)
            value = try decode(data)
            savedModelBytes = try encode(value)
        } catch  where error.isFileNotFound {
            do { if let legacy = try legacyValue?() { value = legacy } } catch { state.error = error }
        } catch { state.error = error }
    }
    package func save(_ proposed: Value) throws {
        do {
            try state.requireWritable()
            let bytes = try encode(proposed)
            // Encoded bytes distinguish NFC/NFD and every field. Model/String equality cannot.
            if let savedModelBytes, savedModelBytes == bytes {
                lastSaveError = nil
                return
            }
            try PrivateFileStore.prepareDirectory(state.url.deletingLastPathComponent())
            try PrivateFileStore.write(
                bytes, to: state.url, maximumBytes: maximumBytes, temporaryPrefix: ".preferences-")
            value = proposed
            savedModelBytes = bytes
            lastSaveError = nil
        } catch {
            lastSaveError = error
            throw error
        }
    }
    @discardableResult package func reset() throws -> URL? {
        let priorError = state.error
        try PrivateFileStore.prepareDirectory(state.url.deletingLastPathComponent())
        let backup = try state.moveAside()
        savedModelBytes = nil
        do { try save(initial) } catch {
            if let backup { _ = renamex_np(backup.path, state.url.path, UInt32(RENAME_EXCL)) }
            state.error = priorError ?? error
            throw error
        }
        return backup
    }
}

package enum PrivateFileError: LocalizedError {
    case unsafeLocation, tooLarge(limit: Int, url: URL)
    package var errorDescription: String? {
        switch self {
        case .unsafeLocation:
            return "This action requires a regular local file in a real directory. The file was not changed."
        case .tooLarge(let limit, let url):
            return "“\(url.lastPathComponent)” exceeds this action’s limit of \(limit) bytes. The file was not changed."
        }
    }
}

/// Publication has already happened. A retry must not roll back or remove the visible file.
package struct PublishedFileSyncFailure: LocalizedError {
    let failure: FileOperationFailure
    package init(failure: FileOperationFailure) { self.failure = failure }
    package var errorDescription: String? {
        "The file is in place, but storage could not confirm the write. " + failure.localizedDescription
    }
}

/// Shared byte I/O only. Models keep their validation, load-failure latch and storage policy.
/// A selected import follows its parent path but never its final component; app-owned stores
/// and existing WorkspaceStore callers also refuse a symlinked immediate parent directory.
package enum PrivateFileStore {
    package enum ParentPolicy { case strict, selectedInput }
    static package func validateLocalURL(_ url: URL) throws {
        guard url.isFileURL, (url.host ?? "").isEmpty || url.host == "localhost",
            url.query == nil, url.fragment == nil, url.path.hasPrefix("/"), !url.path.contains("\0"),
            !url.pathComponents.contains(".."), !url.lastPathComponent.isEmpty
        else { throw PrivateFileError.unsafeLocation }
    }
    static package func directoryDescriptor(for url: URL) throws -> Int32 {
        try validateLocalURL(url)
        let descriptor = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw FileOperationFailure(errno, operation: "open file or containing folder", path: url.path)
        }
        return descriptor
    }
    static package func openRegularFile(
        _ url: URL, maximumBytes: Int, parent: ParentPolicy = .strict,
        closeDirectory: (Int32) -> Int32 = { close($0) }
    ) throws -> (descriptor: Int32, info: stat) {
        try validateLocalURL(url)
        guard maximumBytes >= 0 else { throw PrivateFileError.tooLarge(limit: maximumBytes, url: url) }
        let descriptor: Int32
        if parent == .strict {
            let directory = try directoryDescriptor(for: url)
            defer { _ = closeDirectory(directory) }
            descriptor = openat(directory, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            // Capture before the directory defer: cleanup is permitted to change errno.
            guard descriptor >= 0 else {
                throw FileOperationFailure(errno, operation: "open file for reading", path: url.path)
            }
        } else {
            descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw FileOperationFailure(errno, operation: "open file for reading", path: url.path)
            }
        }
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else {
                throw FileOperationFailure(errno, operation: "inspect file", path: url.path)
            }
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
    static package func read(
        _ url: URL, maximumBytes: Int, parent: ParentPolicy = .strict
    ) throws -> Data {
        try readSample(url, maximumBytes: maximumBytes, parent: parent).data
    }
    static package func readSample(
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
                throw FileOperationFailure(errno, operation: "read file", path: url.path)
            }
            if count == 0 { break }
            guard count <= remaining else { throw PrivateFileError.tooLarge(limit: maximumBytes, url: url) }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        return (data, opened.info, fstat(opened.descriptor, &after) == 0 ? after : nil)
    }
    /// Create/harden only a caller-declared app-owned directory. Never chmod its parent.
    static package func prepareDirectory(_ directory: URL) throws {
        try validateLocalURL(directory.appendingPathComponent(".storage-check"))
        var info = stat()
        if lstat(directory.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR else { throw PrivateFileError.unsafeLocation }
        } else if errno != ENOENT {
            throw FileOperationFailure(errno, operation: "inspect settings folder", path: directory.path)
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw FileOperationFailure(errno, operation: "open settings folder", path: directory.path)
        }
        defer { close(descriptor) }
        guard fchmod(descriptor, mode_t(0o700)) == 0 else {
            throw FileOperationFailure(errno, operation: "set private folder permissions", path: directory.path)
        }
    }
    /// Ask the device to flush. Filesystems without that operation retain POSIX fsync semantics.
    static package func flushToStorage(_ descriptor: Int32) -> Int32 {
        func retryInterrupted(_ call: () -> Int32) -> Int32 {
            var result = call()
            while result == -1 && errno == EINTR { result = call() }
            return result
        }
        let result = retryInterrupted { fcntl(descriptor, F_FULLFSYNC) }
        if result == -1 && [ENOTSUP, EOPNOTSUPP, EINVAL, ENOTTY, ENOSYS].contains(errno) {
            return retryInterrupted { fsync(descriptor) }
        }
        return result
    }
    /// A matching recovery revision may be a prior publication whose directory sync failed.
    static package func confirmExistingWrite(
        at url: URL, synchronize: (Int32) -> Int32 = flushToStorage, matches: (stat) -> Bool = { _ in true }
    ) throws {
        let directory = try directoryDescriptor(for: url)
        defer { close(directory) }
        let fd = openat(directory, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw FileOperationFailure(errno, operation: "open saved file", path: url.path) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, matches(info) else {
            throw PrivateFileError.unsafeLocation
        }
        for descriptor in [fd, directory] {
            guard synchronize(descriptor) == 0 else {
                throw PublishedFileSyncFailure(
                    failure: .init(errno, operation: "synchronize saved file or folder", path: url.path))
            }
        }
        var current = stat()
        guard fstatat(directory, url.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0,
            current.st_dev == info.st_dev, current.st_ino == info.st_ino
        else { throw PrivateFileError.unsafeLocation }
    }
    /// The file flush must succeed before rename. A subsequent directory flush can fail after publication.
    @discardableResult static package func write(
        _ data: Data, to url: URL, maximumBytes: Int, temporaryPrefix: String = ".texttank-",
        temporarySuffix: String = "", synchronize: (Int32) -> Int32 = { fsync($0) },
        synchronizeDirectory: ((Int32) -> Int32)? = nil,
        beforeCommit: () throws -> Void = {}, requireMissing: Bool = false, retainingDescriptor: Bool = false,
        setMode: (Int32, mode_t) -> Int32 = { fchmod($0, $1) }, closeFile: (Int32) -> Int32 = { close($0) }
    ) throws -> Int32? {
        guard data.count <= maximumBytes else { throw PrivateFileError.tooLarge(limit: maximumBytes, url: url) }
        guard !temporaryPrefix.contains("/"), !temporarySuffix.contains("/"),
            !temporaryPrefix.contains("\0"), !temporarySuffix.contains("\0")
        else { throw PrivateFileError.unsafeLocation }
        let directory = try directoryDescriptor(for: url)
        defer { close(directory) }
        var directoryInfo = stat()
        guard fstat(directory, &directoryInfo) == 0 else {
            throw FileOperationFailure(errno, operation: "inspect containing folder", path: url.path)
        }
        var info = stat()
        if fstatat(directory, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG else { throw PrivateFileError.unsafeLocation }
        } else if errno != ENOENT {
            throw FileOperationFailure(errno, operation: "inspect existing file", path: url.path)
        }
        let temporary = temporaryPrefix + UUID().uuidString + temporarySuffix
        let descriptor = openat(
            directory, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else {
            throw FileOperationFailure(errno, operation: "create temporary file beside", path: url.path)
        }
        var descriptorOpen = true
        defer {
            if descriptorOpen { close(descriptor) }
            unlinkat(directory, temporary, 0)
        }
        // open's mode is filtered by umask. Restore exactly owner read/write, never broader.
        guard setMode(descriptor, mode_t(0o600)) == 0 else {
            throw FileOperationFailure(errno, operation: "set private file permissions", path: url.path)
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw FileOperationFailure(errno, operation: "write private file", path: url.path)
                }
                guard count > 0 else {
                    throw FileOperationFailure(EIO, operation: "write private file", path: url.path)
                }
                offset += count
            }
        }
        guard synchronize(descriptor) == 0 else {
            throw FileOperationFailure(errno, operation: "synchronize private file", path: url.path)
        }
        if !retainingDescriptor {
            let result = closeFile(descriptor)
            descriptorOpen = false
            guard result == 0 else {
                throw FileOperationFailure(errno, operation: "close private file", path: url.path)
            }
        }
        try beforeCommit()
        var currentDirectory = stat()
        guard lstat(url.deletingLastPathComponent().path, &currentDirectory) == 0 else {
            throw FileOperationFailure(errno, operation: "revalidate containing folder", path: url.path)
        }
        guard currentDirectory.st_mode & S_IFMT == S_IFDIR,
            currentDirectory.st_dev == directoryInfo.st_dev, currentDirectory.st_ino == directoryInfo.st_ino
        else { throw PrivateFileError.unsafeLocation }
        let renamed =
            requireMissing
            ? renameatx_np(directory, temporary, directory, url.lastPathComponent, UInt32(RENAME_EXCL))
            : renameat(directory, temporary, directory, url.lastPathComponent)
        guard renamed == 0 else {
            throw FileOperationFailure(errno, operation: "replace file", path: url.path)
        }
        if let synchronizeDirectory, synchronizeDirectory(directory) != 0 {
            throw PublishedFileSyncFailure(
                failure: .init(
                    errno, operation: "synchronize containing folder", path: url.deletingLastPathComponent().path))
        }
        if retainingDescriptor {
            descriptorOpen = false // Ownership transfers to the slotted journal, which closes it.
            return descriptor
        }
        return nil
    }
}

package enum PreparedOutputFailure: Error, Sendable { case alreadyUsed, cancelled, changed }

/// Metadata only; no file contents are read. Missing and regular-file states are distinct.
package enum PreparedFileIdentity: Equatable, Sendable {
    case missing
    case regular(
        device: Int64, inode: UInt64, length: Int64, modified: Int64, modifiedNS: Int64,
        changed: Int64, changedNS: Int64)
    static func inspect(_ directory: Int32, _ name: String) throws -> PreparedFileIdentity {
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG else { throw PrivateFileError.unsafeLocation }
            return .regular(
                device: Int64(info.st_dev), inode: info.st_ino, length: info.st_size,
                modified: Int64(info.st_mtimespec.tv_sec), modifiedNS: Int64(info.st_mtimespec.tv_nsec),
                changed: Int64(info.st_ctimespec.tv_sec), changedNS: Int64(info.st_ctimespec.tv_nsec))
        }
        guard errno == ENOENT else {
            throw FileOperationFailure(errno, operation: "inspect patch destination", path: name)
        }
        return .missing
    }
    package static func capture(_ url: URL) throws -> PreparedFileIdentity {
        let directory = try PrivateFileStore.directoryDescriptor(for: url)
        defer { close(directory) }
        return try inspect(directory, url.lastPathComponent)
    }
}

/// Sole ownership of a staged temp and directory descriptor. No callbacks under its lock.
/// Runtime calls commit synchronously on MainActor immediately after its live-job guards.
package final class PreparedPrivateFile: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: Int32, device: dev_t, inode: ino_t
    private let url: URL, temporary: String, expected: PreparedFileIdentity
    private var terminal = false
    fileprivate init(directory: Int32, info: stat, url: URL, temporary: String, expected: PreparedFileIdentity) {
        self.directory = directory
        device = info.st_dev
        inode = info.st_ino
        self.url = url
        self.temporary = temporary
        self.expected = expected
    }
    deinit { cancel() }
    package func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal else { return }
        terminal = true
        unlinkat(directory, temporary, 0)
        close(directory)
    }
    /// All throwing checks precede rename. Success is committed; no fallible step follows it.
    package func commit() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal else { throw PreparedOutputFailure.alreadyUsed }
        terminal = true
        defer {
            unlinkat(directory, temporary, 0)
            close(directory)
        }
        var current = stat()
        guard lstat(url.deletingLastPathComponent().path, &current) == 0,
            current.st_mode & S_IFMT == S_IFDIR, current.st_dev == device, current.st_ino == inode,
            try PreparedFileIdentity.inspect(directory, url.lastPathComponent) == expected
        else {
            throw PreparedOutputFailure.changed
        }
        guard renameat(directory, temporary, directory, url.lastPathComponent) == 0 else {
            throw FileOperationFailure(errno, operation: "publish patch", path: url.path)
        }
    }
}

extension PrivateFileStore {
    /// Worker-only staging. Legacy write stays unchanged; callers own the short final commit.
    package static func prepareOutput(
        _ data: Data, to url: URL, maximumBytes: Int = 32 * 1024 * 1024,
        expectedTarget: PreparedFileIdentity? = nil, isCancelled: @Sendable () -> Bool = { false },
        synchronize: @Sendable (Int32) -> Int32 = { fsync($0) },
        closeFile: @Sendable (Int32) -> Int32 = { close($0) },
        writeChunk: @Sendable (Int32, UnsafeRawPointer?, Int) -> Int = { Darwin.write($0, $1, $2) }
    ) throws -> PreparedPrivateFile {
        guard !isCancelled() else { throw PreparedOutputFailure.cancelled }
        guard maximumBytes >= 0, data.count <= min(32 * 1024 * 1024, maximumBytes) else {
            throw PrivateFileError.tooLarge(limit: maximumBytes, url: url)
        }
        let directory = try directoryDescriptor(for: url)
        var transferred = false
        defer { if !transferred { close(directory) } }
        var info = stat()
        guard fstat(directory, &info) == 0 else { throw PrivateFileError.unsafeLocation }
        let expected = try PreparedFileIdentity.inspect(directory, url.lastPathComponent)
        if let expectedTarget, expectedTarget != expected { throw PreparedOutputFailure.changed }
        let temporary = ".texttank-patch-" + UUID().uuidString
        let descriptor = openat(
            directory, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw FileOperationFailure(errno, operation: "stage patch", path: url.path) }
        var descriptorOpen = true
        defer {
            if descriptorOpen { close(descriptor) }
            if !transferred { unlinkat(directory, temporary, 0) }
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else { throw PrivateFileError.unsafeLocation }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard !isCancelled() else { throw PreparedOutputFailure.cancelled }
                let size = min(65_536, bytes.count - offset)
                let count = writeChunk(descriptor, bytes.baseAddress!.advanced(by: offset), size)
                if count < 0 && errno == EINTR { continue }
                guard count > 0, count <= size else {
                    throw FileOperationFailure(count < 0 ? errno : EIO, operation: "stage patch bytes", path: url.path)
                }
                offset += count
            }
        }
        guard !isCancelled() else { throw PreparedOutputFailure.cancelled }
        guard synchronize(descriptor) == 0 else {
            throw FileOperationFailure(errno, operation: "synchronize patch", path: url.path)
        }
        let closed = closeFile(descriptor)
        descriptorOpen = false
        guard closed == 0 else { throw FileOperationFailure(errno, operation: "close patch", path: url.path) }
        guard !isCancelled() else { throw PreparedOutputFailure.cancelled }
        let ticket = PreparedPrivateFile(
            directory: directory, info: info, url: url, temporary: temporary, expected: expected)
        transferred = true
        return ticket
    }
}

/// Codable model comparisons use deterministic bytes, including exact Unicode spelling.
/// Failed encodes are conservatively unequal; the caller's validation reports the real error.
package enum PersistedValue {
    static package func equal<Value: Encodable>(_ lhs: Value, _ rhs: Value) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let left = try? encoder.encode(lhs), let right = try? encoder.encode(rhs) else { return false }
        return left == right
    }
}

/// Optional envelope metadata supplements, never replaces, each model's required schema version.
/// Writers of the unchanged version-1 formats omit it; absent means reader 1. Do not inspect
/// arbitrary nested dictionaries: names and user payloads remain data, not behavior selectors.
package enum PersistedFormat {
    static package let readerVersion = 1
    private struct Metadata: Decodable {
        enum CodingKeys: String, CodingKey { case minimumReaderVersion }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            guard values.contains(.minimumReaderVersion) else { return }
            let minimum = try values.decode(Int.self, forKey: .minimumReaderVersion)
            guard minimum >= 1 else { throw PersistedFormatError.invalidMinimumReader }
            guard minimum <= PersistedFormat.readerVersion else { throw PersistedFormatError.needsReader(minimum) }
        }
    }
    static package func check(_ data: Data, context: String, array: Bool = false) throws {
        if array {
            _ = try JSONInputFailure.decode([Metadata].self, from: data, context: context)
        } else {
            _ = try JSONInputFailure.decode(Metadata.self, from: data, context: context)
        }
    }
}
package enum PersistedFormatError: LocalizedError {
    case needsReader(Int), invalidMinimumReader
    package var errorDescription: String? {
        switch self {
        case .needsReader(let version):
            return
                "This saved data requires TextTank reader version \(version). This build supports reader version 1. The original file has not been changed."
        case .invalidMinimumReader:
            return "Saved minimumReaderVersion must be a positive integer. The original file has not been changed."
        }
    }
}
