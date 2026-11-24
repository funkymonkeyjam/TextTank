// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

/// Path selection is computed and has no filesystem side effects. In particular, invalid
/// overrides never create a relative store, and checks can repoint the directory in process.
package enum AppStorage {
    package enum Location: String {
        case settings = "Settings.json", macros = "Macros.json", automations = "Automations.json"
        case languages = "LanguageProfiles.json", commands = "RunCommands.json", workspace = "WorkspaceBrowser.json"
        case recovery = "Recovery", reminders = "ReminderExports", pasteThroughChoice = "PasteThroughChoice.json", lastSession = "LastSession.json"
        case find = "FindPreferences.json", folderSearch = "FolderSearchPreferences.json"
        case folderReplacements = "FolderReplacements"
        case localHistory = "LocalHistory"
        package var isDirectory: Bool {
            self == .recovery || self == .reminders || self == .folderReplacements || self == .localHistory
        }
    }
    static package func resolve(override: String?, fallback: URL) -> URL {
        guard let override, override.hasPrefix("/"), !override.contains("\0") else { return fallback }
        return URL(fileURLWithPath: override, isDirectory: true)
    }
    static package var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TextTank", isDirectory: true)
    }
    private static let overrideKey = "TEXTTANK_SUPPORT_DIRECTORY"
    private static var override: String? { ProcessInfo.processInfo.environment[overrideKey] }

    /// Give a dedicated smoke process its own empty store before any application services start.
    static package func makeTemporarySupportDirectory() throws -> URL {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("TextTank-smoke-" + UUID().uuidString)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        guard setenv(overrideKey, directory.path, 1) == 0 else {
            let code = errno
            try? manager.removeItem(at: directory)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        return directory
    }
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
            return "“\(url.lastPathComponent)” exceeds this action’s limit of \(SizePolicy.describe(limit)). Use less data or choose a smaller file."
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
            return try regularFile(info)
        }
        guard errno == ENOENT else {
            throw FileOperationFailure(errno, operation: "inspect patch destination", path: name)
        }
        return .missing
    }
    fileprivate static func regularFile(_ info: stat) throws -> PreparedFileIdentity {
        guard info.st_mode & S_IFMT == S_IFREG else { throw PrivateFileError.unsafeLocation }
        return .regular(
            device: Int64(info.st_dev), inode: info.st_ino, length: info.st_size,
            modified: Int64(info.st_mtimespec.tv_sec), modifiedNS: Int64(info.st_mtimespec.tv_nsec),
            changed: Int64(info.st_ctimespec.tv_sec), changedNS: Int64(info.st_ctimespec.tv_nsec))
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
    /// Only a user-selected existing export supplies permissions. Staging stays private until publication.
    private func retainDestinationAccess() throws {
        let source = openat(directory, url.lastPathComponent, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else { throw PreparedOutputFailure.changed }
        defer { close(source) }
        var original = stat()
        guard fstat(source, &original) == 0, try PreparedFileIdentity.regularFile(original) == expected else {
            throw PreparedOutputFailure.changed
        }
        let staged = openat(directory, temporary, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        guard staged >= 0 else { throw PreparedOutputFailure.changed }
        defer { close(staged) }
        var attributes = stat()
        guard fstat(staged, &attributes) == 0,
            (original.st_uid == attributes.st_uid && original.st_gid == attributes.st_gid)
                || fchown(staged, original.st_uid, original.st_gid) == 0,
            fcopyfile(source, staged, nil, copyfile_flags_t(COPYFILE_ACL)) == 0,
            fchmod(staged, original.st_mode & 0o777) == 0
        else { throw FileOperationFailure(errno, operation: "retain patch permissions", path: url.path) }
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
        if expected != .missing { try retainDestinationAccess() }
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
        _ data: Data, to url: URL, maximumBytes: Int = SizePolicy.standard.privateOutput,
        expectedTarget: PreparedFileIdentity? = nil, isCancelled: @Sendable () -> Bool = { false },
        synchronize: @Sendable (Int32) -> Int32 = { fsync($0) },
        closeFile: @Sendable (Int32) -> Int32 = { close($0) },
        writeChunk: @Sendable (Int32, UnsafeRawPointer?, Int) -> Int = { Darwin.write($0, $1, $2) }
    ) throws -> PreparedPrivateFile {
        guard !isCancelled() else { throw PreparedOutputFailure.cancelled }
        let effectiveLimit = min(SizePolicy.standard.privateOutput, maximumBytes)
        guard effectiveLimit >= 0, data.count <= effectiveLimit else {
            throw PrivateFileError.tooLarge(limit: effectiveLimit, url: url)
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

// MARK: - Local history (owner decision DS-D10)

/// One earlier version of a file: the exact bytes of one save, kept privately.
/// Persisted format, version 1; see "Local history" in docs/architecture.md. A new field must be
/// Optional, or old manifests stop loading.
package struct LocalHistoryVersion: Codable, Equatable, Sendable {
    /// `saved` is what TextTank wrote at that save. `replaced` is what the file held just before
    /// a save, kept only when history did not already end with those bytes (the first save
    /// after opening, or a file changed by something else).
    package enum Kind: String, Codable, Sendable { case saved, replaced }
    package let id: UUID
    package let savedAt: Date
    package let byteCount: Int
    package let sha256: String
    package let kind: Kind
    /// How the bytes were encoded, when TextTank knew. Nil means detect when reading.
    package let format: FileFormat?
}

/// Owner decision B, 23 November 2026. `totalBytes` is decimal megabytes so the store never
/// exceeds the stated 200 MB; a file above `versionBytes` (the large-file threshold) is not kept.
package struct LocalHistoryLimits: Equatable, Sendable {
    package var versionsPerFile = 20
    package var maximumAge: TimeInterval = 30 * 24 * 60 * 60
    package var totalBytes = 200 * 1000 * 1000
    package var versionBytes = SizePolicy.standard.largeDocumentThreshold
    package init() {}
}

package struct LocalHistoryUsage: Equatable, Sendable {
    package let files: Int
    package let versions: Int
    package let bytes: Int
}

package enum LocalHistoryError: LocalizedError, Equatable {
    case missing, damaged
    package var errorDescription: String? {
        switch self {
        case .missing: return "That earlier version is no longer kept."
        case .damaged: return "That earlier version could not be read. It has been left untouched."
        }
    }
}

/// Private copies of what was saved, under `<support>/LocalHistory`, never beside the document.
/// One folder per file, named by the SHA-256 of the file's resolved path, holds `manifest.json`
/// and one `<version id>.bytes` per version; folders are 0700 and files 0600, written with the
/// same temporary-file, flush and rename sequence as every other private store. Nothing here is
/// sent anywhere and no other process is told.
///
/// Every operation runs on one serial utility queue, so a save never waits for the disk: the
/// document hands over bytes it already holds. Sendable boundary: the stored properties are
/// immutable and all file access is confined to `queue`.
final package class LocalHistoryStore: @unchecked Sendable {
    package let directory: URL
    package let limits: LocalHistoryLimits
    private let clock: @Sendable () -> Date
    private let queue = DispatchQueue(label: "TextTank.local-history", qos: .utility)
    private static let manifestName = "manifest.json", manifestBytes = 1024 * 1024
    private struct Manifest: Codable {
        var version: Int
        var path: String
        /// Oldest first.
        var versions: [LocalHistoryVersion]
    }
    package init(
        directory: URL, limits: LocalHistoryLimits = .init(), clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.limits = limits
        self.clock = clock
    }
    /// Keeps `bytes`, which were just written to the file at `path`, and before them `replaced`
    /// when the caller read what the save replaced. Bytes equal to the newest kept version are
    /// not stored again; bytes above `limits.versionBytes` are not stored. Retention runs after.
    package func record(
        path: String, bytes: Data, format: FileFormat? = nil, replaced: Data? = nil, replacedFormat: FileFormat? = nil,
        completion: (@Sendable (Error?) -> Void)? = nil
    ) {
        queue.async { [self] in
            do {
                try recordNow(path, [(replaced, .replaced, replacedFormat), (bytes, .saved, format)])
                completion?(nil)
            } catch { completion?(error) }
        }
    }
    /// A renamed or moved file takes its history with it. A history already at the new path is
    /// joined with it, in date order.
    package func relocate(from old: String, to new: String, completion: (@Sendable (Error?) -> Void)? = nil) {
        queue.async { [self] in
            do {
                try relocateNow(from: old, to: new)
                completion?(nil)
            } catch { completion?(error) }
        }
    }
    /// Newest first.
    package func versions(forPath path: String) throws -> [LocalHistoryVersion] {
        try queue.sync { Array((try manifest(in: folder(path))?.versions ?? []).reversed()) }
    }
    /// The SHA-256 of the newest kept version, or nil when none is kept.
    package func latestDigest(forPath path: String) -> String? {
        queue.sync { (try? manifest(in: folder(path)))?.versions.last?.sha256 }
    }
    /// The exact bytes of one version, checked against its recorded length and SHA-256.
    package func data(forPath path: String, version id: UUID) throws -> Data {
        try queue.sync {
            let home = folder(path)
            guard let listed = try manifest(in: home)?.versions.first(where: { $0.id == id }) else {
                throw LocalHistoryError.missing
            }
            let bytes: Data
            do { bytes = try PrivateFileStore.read(blob(home, id), maximumBytes: listed.byteCount) } catch {
                throw LocalHistoryError.damaged
            }
            guard bytes.count == listed.byteCount, WorkspaceStore.fingerprint(bytes) == listed.sha256 else {
                throw LocalHistoryError.damaged
            }
            return bytes
        }
    }
    package func usage(forPath path: String? = nil) -> LocalHistoryUsage {
        queue.sync {
            let all = path.map { [folder($0)] } ?? folders()
            let kept = all.compactMap { try? manifest(in: $0) }.filter { !$0.versions.isEmpty }
            return LocalHistoryUsage(
                files: kept.count, versions: kept.reduce(0) { $0 + $1.versions.count },
                bytes: kept.reduce(0) { $0 + $1.versions.reduce(0) { $0 + $1.byteCount } })
        }
    }
    /// Deletes the kept versions of one file, or of every file. Only folders this store made are
    /// removed; the documents themselves and everything else in the support folder are untouched.
    @discardableResult package func clear(path: String? = nil) throws -> LocalHistoryUsage {
        try queue.sync {
            var files = 0, versions = 0, bytes = 0
            for home in path.map({ [folder($0)] }) ?? folders() {
                let listed = (try? manifest(in: home))?.versions ?? []
                guard FileManager.default.fileExists(atPath: home.path) else { continue }
                try FileManager.default.removeItem(at: home)
                if !listed.isEmpty { files += 1 }
                versions += listed.count
                bytes += listed.reduce(0) { $0 + $1.byteCount }
            }
            return LocalHistoryUsage(files: files, versions: versions, bytes: bytes)
        }
    }
    /// Applies the age, per-file and total limits now. Also run after every `record`.
    package func prune(completion: (@Sendable (Error?) -> Void)? = nil) {
        queue.async { [self] in
            do {
                try pruneNow()
                completion?(nil)
            } catch { completion?(error) }
        }
    }
    /// Returns once everything submitted so far has finished.
    package func waitUntilIdle() { queue.sync {} }

    private func folder(_ path: String) -> URL {
        directory.appendingPathComponent(WorkspaceStore.fingerprint(Data(path.utf8)), isDirectory: true)
    }
    private func blob(_ home: URL, _ id: UUID) -> URL { home.appendingPathComponent(id.uuidString + ".bytes") }
    /// Only folders named as this store names them: 64 lowercase hexadecimal digits.
    private func folders() -> [URL] {
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        return entries.filter { entry in
            let name = entry.lastPathComponent
            var info = stat()
            return name.utf8.count == 64
                && name.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
                && lstat(entry.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private func manifest(in home: URL) throws -> Manifest? {
        let data: Data
        do {
            data = try PrivateFileStore.read(
                home.appendingPathComponent(Self.manifestName), maximumBytes: Self.manifestBytes)
        } catch let error as FileOperationFailure where error.errorNumber == ENOENT || error.errorNumber == ENOTDIR {
            return nil
        }
        try PersistedFormat.check(data, context: "Local history")
        let value = try JSONDecoder().decode(Manifest.self, from: data)
        guard value.version == 1, value.path.hasPrefix("/"),
            home.lastPathComponent == WorkspaceStore.fingerprint(Data(value.path.utf8))
        else { throw LocalHistoryError.damaged }
        return value
    }
    private func publish(_ value: Manifest, in home: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try PrivateFileStore.write(
            try encoder.encode(value), to: home.appendingPathComponent(Self.manifestName),
            maximumBytes: Self.manifestBytes, synchronize: PrivateFileStore.flushToStorage,
            synchronizeDirectory: PrivateFileStore.flushToStorage)
    }
    /// A file inside the store is never given a history of its own.
    private func isInsideStore(_ path: String) -> Bool {
        let root = directory.resolvingSymlinksInPath().path
        return path == root || path.hasPrefix(root + "/") || path.hasPrefix(directory.path + "/")
    }
    private func recordNow(_ path: String, _ items: [(Data?, LocalHistoryVersion.Kind, FileFormat?)]) throws {
        guard path.hasPrefix("/"), !isInsideStore(path) else { return }
        let home = folder(path)
        var value = try manifest(in: home) ?? Manifest(version: 1, path: path, versions: [])
        var changed = false
        for (data, kind, format) in items {
            guard let data, data.count <= limits.versionBytes else { continue }
            let digest = WorkspaceStore.fingerprint(data)
            if let last = value.versions.last, last.sha256 == digest, last.byteCount == data.count { continue }
            try PrivateFileStore.prepareDirectory(directory)
            try PrivateFileStore.prepareDirectory(home)
            let version = LocalHistoryVersion(
                id: UUID(), savedAt: clock(), byteCount: data.count, sha256: digest, kind: kind, format: format)
            // The bytes are published and flushed before the manifest names them.
            try PrivateFileStore.write(
                data, to: blob(home, version.id), maximumBytes: limits.versionBytes,
                synchronize: PrivateFileStore.flushToStorage, synchronizeDirectory: PrivateFileStore.flushToStorage)
            value.versions.append(version)
            changed = true
        }
        if changed { try publish(value, in: home) }
        try pruneNow()
    }
    private func relocateNow(from old: String, to new: String) throws {
        guard old != new, new.hasPrefix("/"), !isInsideStore(new) else { return }
        let source = folder(old), target = folder(new)
        guard var moving = try manifest(in: source), !moving.versions.isEmpty else { return }
        let existing = try manifest(in: target)
        try PrivateFileStore.prepareDirectory(target)
        for version in moving.versions {
            try FileManager.default.moveItem(at: blob(source, version.id), to: blob(target, version.id))
        }
        moving.path = new
        if let existing {
            // Stable by date; ties keep each history's own order.
            moving.versions = (existing.versions + moving.versions).enumerated().sorted {
                ($0.element.savedAt, $0.offset) < ($1.element.savedAt, $1.offset)
            }.map(\.element)
        }
        try publish(moving, in: target)
        try FileManager.default.removeItem(at: source)
        try pruneNow()
    }
    /// Thirty days, twenty versions a file, then 200 MB in all: the oldest go first. The
    /// manifest is rewritten before a version's bytes are deleted, so a manifest never names
    /// bytes that are gone; bytes no manifest names are removed here too.
    private func pruneNow() throws {
        let now = clock()
        var kept: [(home: URL, manifest: Manifest, changed: Bool)] = []
        for home in folders() {
            guard var value = try? manifest(in: home) else { continue }
            let count = value.versions.count
            value.versions.removeAll { now.timeIntervalSince($0.savedAt) > limits.maximumAge }
            value.versions = Array(value.versions.suffix(max(0, limits.versionsPerFile)))
            kept.append((home, value, value.versions.count != count))
        }
        var total = kept.reduce(0) { $0 + $1.manifest.versions.reduce(0) { $0 + $1.byteCount } }
        while total > limits.totalBytes {
            var oldest: (index: Int, date: Date)?
            for index in kept.indices {
                guard let first = kept[index].manifest.versions.first else { continue }
                if oldest == nil || first.savedAt < oldest!.date { oldest = (index, first.savedAt) }
            }
            guard let oldest else { break }
            total -= kept[oldest.index].manifest.versions.removeFirst().byteCount
            kept[oldest.index].changed = true
        }
        for entry in kept {
            if entry.manifest.versions.isEmpty {
                try FileManager.default.removeItem(at: entry.home)
                continue
            }
            if entry.changed { try publish(entry.manifest, in: entry.home) }
            let named = Set(entry.manifest.versions.map { $0.id.uuidString + ".bytes" })
            for file in try FileManager.default.contentsOfDirectory(atPath: entry.home.path)
            where file.hasSuffix(".bytes") && !named.contains(file) {
                try FileManager.default.removeItem(at: entry.home.appendingPathComponent(file))
            }
        }
    }
}
