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
    func inspectReferencedFiles() -> [SessionFileInspection] {
        documents.map { document in
            guard let url = document.originalURL else {
                return SessionFileInspection(documentID: document.id, status: .untitled)
            }
            do {
                let bytes = try WorkspaceStore.readRegularFile(url, maximumBytes: WorkspaceStore.maximumSessionBytes)
                let fingerprint = WorkspaceStore.fingerprint(bytes)
                guard let expected = document.originalSHA256 else {
                    return SessionFileInspection(documentID: document.id, status: .unverified)
                }
                return SessionFileInspection(
                    documentID: document.id, status: fingerprint == expected ? .unchanged : .changed)
            } catch let error as POSIXError where error.code == .ENOENT {
                return SessionFileInspection(documentID: document.id, status: .missing)
            } catch {
                return SessionFileInspection(documentID: document.id, status: .unreadable(error.localizedDescription))
            }
        }
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
    static func fingerprint(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
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
    static func readRegularFile(_ url: URL, maximumBytes: Int = maximumSessionBytes) throws -> Data {
        let dir = try directoryDescriptor(for: url)
        defer { close(dir) }
        let descriptor = openat(dir, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw WorkspaceError.unsafeLocation }
        guard info.st_size >= 0, info.st_size <= maximumBytes else { throw WorkspaceError.tooLarge }
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
