// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import Darwin

struct SessionSelection: Codable, Equatable {
    var anchorByte: Int
    var caretByte: Int
}

/// A retained snapshot, not an instruction to replace the referenced file.
/// Restore as an unsaved document unless the UI independently verifies disk identity.
struct SessionDocument: Codable, Equatable, Identifiable {
    var id: UUID
    var originalURL: URL?
    var text: String
    var format: FileFormat
    var isDirty: Bool
    var selection: SessionSelection
    var bookmarks: [Int] = []
    var language: String?
    /// Hash of the original disk bytes at capture, not of unsaved editor text.
    var originalSHA256: String?

    func validate() throws {
        if let originalURL { try WorkspaceStore.validateLocalURL(originalURL) }
        if let hash = originalSHA256 {
            guard originalURL != nil, hash.count == 64,
                hash.allSatisfy({ $0.isASCII && ("0123456789abcdef".contains($0)) })
            else { throw WorkspaceError.invalid("Invalid original-file fingerprint.") }
        }
        guard !(format.bom && [.latin1, .windows1252].contains(format.encoding)) else {
            throw WorkspaceError.invalid("Invalid encoding/BOM metadata.")
        }
        // Do not encode pending edits in the selected legacy format here: an unsaved
        // unrepresentable character must remain recoverable in the UTF-8 JSON snapshot.
        let bytes = Array(text.utf8)
        for position in [selection.anchorByte, selection.caretByte] {
            guard position >= 0, position <= bytes.count,
                position == bytes.count || bytes[position] & 0xC0 != 0x80
            else {
                throw WorkspaceError.invalid("Selection is outside the snapshot or splits a UTF-8 character.")
            }
        }
        var lines = 1
        for (index, byte) in bytes.enumerated() {
            if byte == 13 || (byte == 10 && (index == 0 || bytes[index - 1] != 13)) { lines += 1 }
        }
        guard Set(bookmarks).count == bookmarks.count, bookmarks.allSatisfy({ $0 >= 0 && $0 < lines }) else {
            throw WorkspaceError.invalid("Bookmark lines are invalid.")
        }
        if let language {
            guard !language.isEmpty, language.count <= 120, !language.contains("\0") else {
                throw WorkspaceError.invalid("Invalid language identifier.")
            }
        }
    }
}

/// Persisted format, version 1; see "Persisted formats" in docs/architecture.md. A new field
/// must be Optional or decoded with decodeIfPresent in an extension, or old files stop loading.
struct WorkspaceSession: Codable, Equatable, Identifiable {
    var schemaVersion: Int = 1
    var id: UUID
    var name: String
    var documents: [SessionDocument]
    var activeDocumentID: UUID?
    var savedAt: Date = Date()

    func validate() throws {
        guard schemaVersion == 1 else {
            throw WorkspaceError.invalid("Unsupported session schema version. The session has not been changed.")
        }
        // JSONEncoder and JSONDecoder already refuse a non-finite savedAt, so it needs no check here.
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 200, !name.contains("\0")
        else { throw WorkspaceError.invalid("Invalid session name.") }
        guard documents.count <= 1000, Set(documents.map(\.id)).count == documents.count else {
            throw WorkspaceError.invalid("Session document count or IDs are invalid.")
        }
        if let activeDocumentID {
            guard documents.contains(where: { $0.id == activeDocumentID }) else {
                throw WorkspaceError.invalid("The active document is absent from the session.")
            }
        }
        for document in documents { try document.validate() }
    }
    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
    static func decode(_ data: Data) throws -> Self {
        let result: Self
        do { result = try JSONDecoder().decode(Self.self, from: data) } catch {
            throw WorkspaceError.invalid(
                "The session is not valid TextTank session data: \(error.localizedDescription)")
        }
        try result.validate()
        return result
    }

    /// Explicit inspection only; a missing/unreadable/changed original never discards
    /// its retained snapshot. Callers must show the status and restore without overwriting.
    /// Each original is hashed in 64 KiB steps through the no-follow regular-file open, so no
    /// file is held in memory. `isCancelled` is asked between files and between steps; once it
    /// answers true the remaining documents are reported as not inspected.
    func inspectReferencedFiles(isCancelled: () -> Bool = { false }) -> [SessionFileInspection] {
        documents.map { document in
            guard let url = document.originalURL else {
                return SessionFileInspection(documentID: document.id, status: .untitled)
            }
            do {
                let fingerprint = try WorkspaceStore.fingerprint(
                    ofRegularFileAt: url, maximumBytes: WorkspaceStore.maximumSessionBytes, isCancelled: isCancelled)
                guard let expected = document.originalSHA256 else {
                    return SessionFileInspection(documentID: document.id, status: .unverified)
                }
                return SessionFileInspection(
                    documentID: document.id, status: fingerprint == expected ? .unchanged : .changed)
            } catch let error as POSIXError where error.code == .ENOENT {
                return SessionFileInspection(documentID: document.id, status: .missing)
            } catch is CancellationError {
                return SessionFileInspection(documentID: document.id, status: .unreadable("the check was cancelled"))
            } catch {
                return SessionFileInspection(documentID: document.id, status: .unreadable(error.localizedDescription))
            }
        }
    }
    /// The restore prompt. It is built from the session alone and touches no file: without
    /// `inspections` it names the documents, and with them it adds each original's status.
    /// `savedLabel` (when the snapshot was saved, already formatted) and `showsDirtyState` (whether
    /// each document had unsaved edits when captured) add what the session itself records.
    func restorePrompt(
        inspections: [SessionFileInspection]? = nil, savedLabel: String? = nil, showsDirtyState: Bool = false
    ) -> (message: String, detail: String) {
        let names = documents.map { $0.originalURL?.lastPathComponent ?? "Untitled" }
        var lines: [String]
        if let inspections {
            lines = zip(names, inspections).map { "\($0.0): \($0.1.status.description)" }
        } else {
            lines = names
        }
        if showsDirtyState {
            lines = zip(lines, documents).map { $0.0 + ($0.1.isDirty ? " · had unsaved edits" : " · no unsaved edits") }
        }
        return (
            "Restore \(documents.count) Documents from \(name)?",
            (savedLabel.map { "Saved \($0). " } ?? "")
                + "Snapshots open as new unsaved documents. Existing tabs and original files are kept."
                + (inspections == nil
                    ? " The original files have not been read; Check Originals compares them with this session." : "")
                + "\n\n" + lines.joined(separator: "\n")
        )
    }
}

enum SessionFileStatus: Equatable {
    case untitled, unchanged, changed, missing, unverified, unreadable(String)
    var description: String {
        switch self {
        case .untitled: return "Untitled snapshot"
        case .unchanged: return "Original file matches its saved fingerprint"
        case .changed: return "Original file changed; retained snapshot must not overwrite it"
        case .missing: return "Original file is missing; retained snapshot is available"
        case .unverified: return "Original file has no saved fingerprint; restore as unsaved text"
        case .unreadable(let reason): return "Original file cannot be inspected: \(reason)"
        }
    }
}
struct SessionFileInspection: Equatable {
    let documentID: UUID
    let status: SessionFileStatus
}
/// What `fstat` says about one state of a regular file. Two equal signatures name the same
/// bytes only when the earlier one was settled; see `isSettled`.
struct FileSignature: Equatable {
    var device: Int64
    var inode: UInt64
    var size: Int64
    var modifiedSeconds: Int64
    var modifiedNanoseconds: Int64
    var changedSeconds: Int64
    var changedNanoseconds: Int64
    init(_ info: stat) {
        device = Int64(info.st_dev)
        inode = UInt64(info.st_ino)
        size = Int64(info.st_size)
        modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        changedSeconds = Int64(info.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
    }
    /// Timestamps can be as coarse as two seconds. A write that lands in the same tick as the
    /// recorded times could leave them unchanged, so a signature only stands for the bytes
    /// once both times are older than that at the moment it was taken.
    static let settleSeconds: Int64 = 2
    func isSettled(at now: Int64) -> Bool {
        now - max(modifiedSeconds, changedSeconds) > Self.settleSeconds
    }
}
/// A streamed SHA-256 of a file. `signature` is present only when the metadata was the same
/// before and after the read and was settled, so it can stand in for the digest later.
struct FileSample: Equatable {
    let digest: String
    let signature: FileSignature?
}
enum WorkspaceError: LocalizedError {
    case invalid(String), unsafeLocation, tooLarge
    var errorDescription: String? {
        switch self {
        case .invalid(let reason): return reason
        case .unsafeLocation:
            return "Session storage requires a regular local file in a real directory, not a symbolic link."
        case .tooLarge:
            return
                "The session or referenced file exceeds the 512 MiB inspection limit. Its bytes have not been changed."
        }
    }
}

/// Explicit file-panel URL in/out. No shell, plugin, workflow, or source-file writes.
/// Same-directory rename is atomic; bytes are fsynced before replacement. This is
/// not a claim of power-loss durability for the containing filesystem/directory.
enum WorkspaceStore {
    static let maximumSessionBytes = 512 * 1024 * 1024
    /// The one extension TextTank proposes for session snapshots and declares in Info.plist as
    /// `app.texttank.session`. Reading never depends on it: a snapshot loads under any name.
    static let sessionFileExtension = "texttanksession"
    static func fingerprint(_ bytes: Data) -> String { hex(SHA256.hash(data: bytes)) }
    private static let hexDigits = Array("0123456789abcdef".utf8)
    private static func hex(_ digest: SHA256.Digest) -> String {
        var text = [UInt8]()
        text.reserveCapacity(64)
        for byte in digest {
            text.append(hexDigits[Int(byte >> 4)])
            text.append(hexDigits[Int(byte & 15)])
        }
        return String(decoding: text, as: UTF8.self)
    }
    /// Wall-clock seconds, the clock file timestamps use.
    static func currentSecond() -> Int64 {
        var now = timespec()
        clock_gettime(CLOCK_REALTIME, &now)
        return Int64(now.tv_sec)
    }
    static func validateLocalURL(_ url: URL) throws {
        guard url.isFileURL, (url.host ?? "").isEmpty || url.host == "localhost",
            url.query == nil, url.fragment == nil, url.path.hasPrefix("/"), !url.path.contains("\0"),
            !url.pathComponents.contains(".."), !url.lastPathComponent.isEmpty
        else { throw WorkspaceError.unsafeLocation }
    }
    private static func directoryDescriptor(for url: URL) throws -> Int32 {
        try validateLocalURL(url)
        let directory = url.deletingLastPathComponent()
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return fd
    }
    /// The one way a document or session file is opened for reading: its directory and the
    /// file itself without following a link, without blocking on a FIFO, a regular file only,
    /// and within the size limit. The caller closes the descriptor.
    private static func openRegularFile(_ url: URL, maximumBytes: Int) throws -> (descriptor: Int32, info: stat) {
        let dir = try directoryDescriptor(for: url)
        defer { close(dir) }
        let descriptor = openat(dir, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard (info.st_mode & S_IFMT) == S_IFREG else { throw WorkspaceError.unsafeLocation }
            guard info.st_size >= 0, info.st_size <= maximumBytes else { throw WorkspaceError.tooLarge }
            return (descriptor, info)
        } catch {
            close(descriptor)
            throw error
        }
    }
    /// Metadata only: opens, checks and closes the file, and reads none of it.
    static func signature(ofRegularFileAt url: URL, maximumBytes: Int = maximumSessionBytes) throws -> FileSignature {
        let opened = try openRegularFile(url, maximumBytes: maximumBytes)
        close(opened.descriptor)
        return FileSignature(opened.info)
    }
    /// Hashes the file in 64 KiB steps without holding it in memory. `now` is the wall-clock
    /// second the signature is judged settled against; it is taken before the file is opened.
    static func sample(
        ofRegularFileAt url: URL, maximumBytes: Int = maximumSessionBytes, now: Int64? = nil,
        isCancelled: () -> Bool = { false }
    ) throws -> FileSample {
        let now = now ?? currentSecond()
        let opened = try openRegularFile(url, maximumBytes: maximumBytes)
        defer { close(opened.descriptor) }
        var hasher = SHA256()
        var total = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if isCancelled() { throw CancellationError() }
            let count = buffer.withUnsafeMutableBytes { read(opened.descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 { break }
            total += count
            guard total <= maximumBytes else { throw WorkspaceError.tooLarge }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
        }
        var after = stat()
        guard fstat(opened.descriptor, &after) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let signature = FileSignature(after)
        let stable = signature == FileSignature(opened.info) && signature.size == Int64(total)
        return FileSample(
            digest: hex(hasher.finalize()), signature: stable && signature.isSettled(at: now) ? signature : nil)
    }
    static func fingerprint(
        ofRegularFileAt url: URL, maximumBytes: Int = maximumSessionBytes, isCancelled: () -> Bool = { false }
    ) throws -> String {
        try sample(ofRegularFileAt: url, maximumBytes: maximumBytes, isCancelled: isCancelled).digest
    }
    /// The bytes together with their sample, for a caller that needs both from one descriptor.
    static func readRegularFileSample(_ url: URL, maximumBytes: Int = maximumSessionBytes, now: Int64? = nil) throws
        -> (data: Data, sample: FileSample)
    {
        let now = now ?? currentSecond()
        var signature: FileSignature?
        let data = try readRegularFile(url, maximumBytes: maximumBytes, signature: &signature)
        return (
            data,
            FileSample(digest: fingerprint(data), signature: signature.flatMap { $0.isSettled(at: now) ? $0 : nil })
        )
    }
    static func readRegularFile(_ url: URL, maximumBytes: Int = maximumSessionBytes) throws -> Data {
        var signature: FileSignature?
        return try readRegularFile(url, maximumBytes: maximumBytes, signature: &signature)
    }
    /// `signature` is set only when the metadata was the same before and after the read.
    private static func readRegularFile(_ url: URL, maximumBytes: Int, signature: inout FileSignature?) throws -> Data {
        let (descriptor, info) = try openRegularFile(url, maximumBytes: maximumBytes)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var data = Data()
        while true {
            let chunk =
                try handle.read(
                    upToCount: min(64 * 1024, maximumBytes - data.count)
                        + (maximumBytes - data.count < 64 * 1024 ? 1 : 0)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
            guard data.count <= maximumBytes else { throw WorkspaceError.tooLarge }
        }
        var after = stat()
        if fstat(descriptor, &after) == 0, FileSignature(after) == FileSignature(info), Int(after.st_size) == data.count
        {
            signature = FileSignature(after)
        }
        return data
    }
    static func load(from url: URL) throws -> WorkspaceSession { try WorkspaceSession.decode(readRegularFile(url)) }
    static func save(_ session: WorkspaceSession, to url: URL) throws {
        try writePrivate(try session.encoded(), to: url)
    }
    static func writePrivate(_ data: Data, to url: URL) throws {
        guard data.count <= maximumSessionBytes else { throw WorkspaceError.tooLarge }
        let dir = try directoryDescriptor(for: url)
        defer { close(dir) }
        let destination = url.lastPathComponent
        var existing = stat()
        if fstatat(dir, destination, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard (existing.st_mode & S_IFMT) == S_IFREG else { throw WorkspaceError.unsafeLocation }
        } else if errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let temporary = ".texttank-session-" + UUID().uuidString
        let descriptor = openat(dir, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            unlinkat(dir, temporary, 0)
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard renameat(dir, temporary, dir, destination) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
