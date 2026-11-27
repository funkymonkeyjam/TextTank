// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import Darwin

package struct SessionSelection: Codable, Equatable, Sendable {
    package init(anchorByte: Int, caretByte: Int) {
        self.anchorByte = anchorByte
        self.caretByte = caretByte
    }

    package var anchorByte: Int
    package var caretByte: Int
}

/// A retained snapshot, not an instruction to replace the referenced file.
/// Restore as an unsaved document unless the UI independently verifies disk identity.
package struct SessionDocument: Codable, Equatable, Identifiable, Sendable {
    package init(
        id: UUID, originalURL: URL? = nil, text: String, format: FileFormat, isDirty: Bool, selection: SessionSelection,
        bookmarks: [Int] = [], language: String? = nil, originalSHA256: String? = nil
    ) {
        self.id = id
        self.originalURL = originalURL
        self.text = text
        self.format = format
        self.isDirty = isDirty
        self.selection = selection
        self.bookmarks = bookmarks
        self.language = language
        self.originalSHA256 = originalSHA256
    }

    package var id: UUID
    package var originalURL: URL?
    package var text: String
    package var format: FileFormat
    package var isDirty: Bool
    package var selection: SessionSelection
    package var bookmarks: [Int]
    package var language: String?
    /// Hash of the original disk bytes at capture, not of unsaved editor text.
    package var originalSHA256: String?

    package func validate() throws {
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
package struct WorkspaceSession: Codable, Equatable, Identifiable, Sendable {
    package init(
        schemaVersion: Int = 1, id: UUID, name: String, documents: [SessionDocument], activeDocumentID: UUID? = nil,
        savedAt: Date = Date(), layoutState: WorkspaceLayoutState? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.documents = documents
        self.activeDocumentID = activeDocumentID
        self.savedAt = savedAt
        self.layoutState = layoutState
    }

    package var schemaVersion: Int
    package var id: UUID
    package var name: String
    package var documents: [SessionDocument]
    package var activeDocumentID: UUID?
    package var savedAt: Date
    package var layoutState: WorkspaceLayoutState?
    private var layoutDecodingFailed = false
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, documents, activeDocumentID, savedAt, layoutState
    }
    package enum LayoutStatus: Equatable, Sendable { case absent, valid(WorkspaceLayoutState), invalid }
    package var layoutStatus: LayoutStatus {
        guard !layoutDecodingFailed else { return .invalid }
        guard let layoutState else { return .absent }
        do {
            try layoutState.validate()
            let referenced = Set(layoutState.groups.flatMap(\.tabs).map(\.documentID))
            guard referenced == Set(documents.map { DocumentID($0.id) }) else { return .invalid }
            return .valid(layoutState)
        } catch { return .invalid }
    }

    package func validate() throws {
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
    package func encoded() throws -> Data {
        try validate()
        guard layoutStatus != .invalid else { throw WorkspaceError.invalid("The saved session layout is invalid.") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
    static package func decode(_ data: Data) throws -> Self {
        let result: Self
        do {
            try PersistedFormat.check(data, context: "Session snapshot")
            result = try JSONDecoder().decode(Self.self, from: data)
        } catch {
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
    package func inspectReferencedFiles(isCancelled: () -> Bool = { false }) -> [SessionFileInspection] {
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
            } catch  where error.isFileNotFound {
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
    package func restorePrompt(
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
            String(
                format: documents.count == 1
                    ? Strings.text("session.restore.one", "Restore %@ Document from %@?")
                    : Strings.text("session.restore.other", "Restore %@ Documents from %@?"),
                Strings.number(documents.count), name),
            (savedLabel.map { "Saved \($0). " } ?? "")
                + "Snapshots open as new unsaved documents. Existing tabs and original files are kept."
                + (inspections == nil
                    ? " The original files have not been read; Check Originals compares them with this session." : "")
                + "\n\n" + lines.joined(separator: "\n")
        )
    }
}

extension WorkspaceSession {
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        documents = try c.decode([SessionDocument].self, forKey: .documents)
        activeDocumentID = try c.decodeIfPresent(UUID.self, forKey: .activeDocumentID)
        savedAt = try c.decode(Date.self, forKey: .savedAt)
        do { layoutState = try c.decodeIfPresent(WorkspaceLayoutState.self, forKey: .layoutState) } catch {
            layoutState = nil
            layoutDecodingFailed = true
        }
    }
}

package enum SessionFileStatus: Equatable, Sendable {
    case untitled, unchanged, changed, missing, unverified, unreadable(String)
    package var description: String {
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
package struct SessionFileInspection: Equatable, Sendable {
    package init(documentID: UUID, status: SessionFileStatus) {
        self.documentID = documentID
        self.status = status
    }

    package let documentID: UUID
    package let status: SessionFileStatus
}
/// What `fstat` says about one state of a regular file. Two equal signatures name the same
/// bytes only when the earlier one was settled; see `isSettled`.
package struct FileSignature: Equatable, Sendable {
    package var device: Int64
    package var inode: UInt64
    package var size: Int64
    package var modifiedSeconds: Int64
    package var modifiedNanoseconds: Int64
    package var changedSeconds: Int64
    package var changedNanoseconds: Int64
    package init(_ info: stat) {
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
    static package let settleSeconds: Int64 = 2
    package func isSettled(at now: Int64) -> Bool {
        now - max(modifiedSeconds, changedSeconds) > Self.settleSeconds
    }
}
/// A streamed SHA-256 of a file. `signature` is present only when the metadata was the same
/// before and after the read and was settled, so it can stand in for the digest later.
package struct FileSample: Equatable, Sendable {
    package init(digest: String, signature: FileSignature?) {
        self.digest = digest
        self.signature = signature
    }

    package let digest: String
    package let signature: FileSignature?
}
/// Descriptor-derived read metadata. A modification date is presentation metadata, not a
/// settled signature that allows skipping the next fingerprint check.
package struct CapturedFileRead {
    package init(data: Data, sample: FileSample, modificationDate: Date?) {
        self.data = data
        self.sample = sample
        self.modificationDate = modificationDate
    }

    package let data: Data
    package let sample: FileSample
    package let modificationDate: Date?
}
package enum WorkspaceError: LocalizedError {
    case invalid(String), unsafeLocation, tooLarge
    case fileTooLarge(limit: Int, url: URL)
    package var errorDescription: String? {
        switch self {
        case .invalid(let reason): return reason
        case .unsafeLocation:
            return "This action requires a regular local file in a real directory, not a symbolic link."
        case .fileTooLarge(let limit, let url):
            return
                "“\(url.lastPathComponent)” exceeds this action’s limit of \(SizePolicy.describe(limit)). Use less data or choose a smaller file."
        case .tooLarge:
            return
                "The session or referenced file exceeds the \(SizePolicy.describe(SizePolicy.standard.workspaceSession)) inspection limit. Use a smaller session or file."
        }
    }
}

/// Explicit file-panel URL in/out. No shell, plugin, workflow, or source-file writes.
/// The session requests a device flush before rename and another for its containing folder afterward.
/// Filesystems without device-flush support use POSIX fsync.
package enum WorkspaceStore {
    static package let maximumSessionBytes = SizePolicy.standard.workspaceSession
    /// The one extension TextTank proposes for session snapshots and declares in Info.plist as
    /// `app.texttank.session`. Reading never depends on it: a snapshot loads under any name.
    static package let sessionFileExtension = "texttanksession"
    static package func fingerprint(_ bytes: Data) -> String { hex(SHA256.hash(data: bytes)) }
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
    static package func currentSecond() -> Int64 {
        var now = timespec()
        clock_gettime(CLOCK_REALTIME, &now)
        return Int64(now.tv_sec)
    }
    private static func mappedFileError(_ error: Error) -> Error {
        switch error {
        case PrivateFileError.unsafeLocation: return WorkspaceError.unsafeLocation
        case PrivateFileError.tooLarge(let limit, let url): return WorkspaceError.fileTooLarge(limit: limit, url: url)
        case let failure as FileOperationFailure:
            return POSIXError(POSIXErrorCode(rawValue: failure.errorNumber) ?? .EIO)
        default: return error
        }
    }
    static package func validateLocalURL(_ url: URL) throws {
        do { try PrivateFileStore.validateLocalURL(url) } catch { throw mappedFileError(error) }
    }
    private static func openRegularFile(_ url: URL, maximumBytes: Int) throws -> (descriptor: Int32, info: stat) {
        do { return try PrivateFileStore.openRegularFile(url, maximumBytes: maximumBytes) } catch {
            throw mappedFileError(error)
        }
    }
    /// Metadata only: opens, checks and closes the file, and reads none of it.
    static package func signature(ofRegularFileAt url: URL, maximumBytes: Int = maximumSessionBytes) throws
        -> FileSignature
    {
        let opened = try openRegularFile(url, maximumBytes: maximumBytes)
        close(opened.descriptor)
        return FileSignature(opened.info)
    }
    /// Hashes the file in 64 KiB steps without holding it in memory. `now` is the wall-clock
    /// second the signature is judged settled against; it is taken before the file is opened.
    static package func sample(
        ofRegularFileAt url: URL, maximumBytes: Int = maximumSessionBytes, now: Int64? = nil,
        matching expected: FileSignature? = nil, isCancelled: () -> Bool = { false }
    ) throws -> FileSample {
        try readChunks(
            of: url, maximumBytes: maximumBytes, now: now, matching: expected, requireStableRead: false,
            isCancelled: isCancelled
        ) { _ in }
    }
    /// The consumer and digest see the same descriptor bytes. Initial import requires stable identity and length.
    static package func readChunks(
        of url: URL, maximumBytes: Int, now: Int64? = nil, matching expected: FileSignature?,
        requireStableRead: Bool = true, isCancelled: () -> Bool, consume: (UnsafeRawBufferPointer) throws -> Void
    ) throws -> FileSample {
        let now = now ?? currentSecond()
        let opened = try openRegularFile(url, maximumBytes: maximumBytes)
        defer { close(opened.descriptor) }
        func changed() -> NSError {
            NSError(
                domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                userInfo: [NSLocalizedDescriptionKey: "The file changed while opening. Open it again."])
        }
        if let expected, FileSignature(opened.info) != expected {
            if requireStableRead { throw changed() }
            throw WorkspaceError.invalid("The file changed before its contents could be verified.")
        }
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
            if requireStableRead, let expected, total > expected.size { throw changed() }
            guard total <= maximumBytes else { throw WorkspaceError.fileTooLarge(limit: maximumBytes, url: url) }
            try buffer.withUnsafeBytes {
                let bytes = UnsafeRawBufferPointer(rebasing: $0[0..<count])
                hasher.update(bufferPointer: bytes)
                try consume(bytes)
            }
        }
        var after = stat()
        guard fstat(opened.descriptor, &after) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let signature = FileSignature(after)
        let stable = signature == FileSignature(opened.info) && signature.size == Int64(total)
        if requireStableRead, let expected {
            guard stable, signature == expected,
                try Self.signature(ofRegularFileAt: url, maximumBytes: maximumBytes) == expected
            else { throw changed() }
        }
        return FileSample(
            digest: hex(hasher.finalize()), signature: stable && signature.isSettled(at: now) ? signature : nil)
    }
    static package func fingerprint(
        ofRegularFileAt url: URL, maximumBytes: Int = maximumSessionBytes, isCancelled: () -> Bool = { false }
    ) throws -> String {
        try sample(ofRegularFileAt: url, maximumBytes: maximumBytes, isCancelled: isCancelled).digest
    }
    /// The bytes together with their sample, for a caller that needs both from one descriptor.
    static package func readRegularFileSample(_ url: URL, maximumBytes: Int = maximumSessionBytes, now: Int64? = nil)
        throws
        -> (data: Data, sample: FileSample)
    {
        let read = try captureRegularFile(url, maximumBytes: maximumBytes, now: now)
        return (read.data, read.sample)
    }
    /// One bounded no-follow descriptor read, retaining its stable modification date even
    /// while its metadata is too recent to stand in for a fingerprint.
    static package func captureRegularFile(_ url: URL, maximumBytes: Int = maximumSessionBytes, now: Int64? = nil)
        throws
        -> CapturedFileRead
    {
        do {
            let now = now ?? currentSecond()
            let read = try PrivateFileStore.readSample(url, maximumBytes: maximumBytes)
            let stable = read.after.flatMap { after -> FileSignature? in
                let signature = FileSignature(after)
                return signature == FileSignature(read.before) && signature.size == Int64(read.data.count)
                    ? signature : nil
            }
            let date = stable.map {
                // Add fractional seconds in Foundation's reference epoch. Adding them in the
                // larger Unix epoch first can round again during Date's epoch conversion and
                // trigger a false NSDocument external-change review for unchanged file bytes.
                Date(
                    timeIntervalSinceReferenceDate: Double($0.modifiedSeconds)
                        - Date.timeIntervalBetween1970AndReferenceDate + Double($0.modifiedNanoseconds) / 1_000_000_000)
            }
            return CapturedFileRead(
                data: read.data,
                sample: FileSample(
                    digest: fingerprint(read.data), signature: stable.flatMap { $0.isSettled(at: now) ? $0 : nil }),
                modificationDate: date)
        } catch { throw mappedFileError(error) }
    }
    static package func readRegularFile(_ url: URL, maximumBytes: Int = maximumSessionBytes) throws -> Data {
        var signature: FileSignature?
        return try readRegularFile(url, maximumBytes: maximumBytes, signature: &signature)
    }
    /// `signature` is set only when the metadata was the same before and after the read.
    private static func readRegularFile(_ url: URL, maximumBytes: Int, signature: inout FileSignature?) throws -> Data {
        do {
            let read = try PrivateFileStore.readSample(url, maximumBytes: maximumBytes)
            if let after = read.after, FileSignature(after) == FileSignature(read.before),
                Int(after.st_size) == read.data.count
            {
                signature = FileSignature(after)
            }
            return read.data
        } catch { throw mappedFileError(error) }
    }
    static package func load(from url: URL) throws -> WorkspaceSession {
        try WorkspaceSession.decode(readRegularFile(url))
    }
    static package func save(_ session: WorkspaceSession, to url: URL) throws {
        try writePrivate(try session.encoded(), to: url)
    }
    static package func writePrivate(_ data: Data, to url: URL) throws {
        do {
            try PrivateFileStore.write(
                data, to: url, maximumBytes: maximumSessionBytes, temporaryPrefix: ".texttank-session-",
                synchronize: PrivateFileStore.flushToStorage, synchronizeDirectory: PrivateFileStore.flushToStorage)
        } catch { throw mappedFileError(error) }
    }
}

/// The automatic launch file describes disk originals and their presentations. Recovery
/// and explicitly saved session snapshots keep their own identity and content formats.
package struct LastSessionLayout: Codable, Equatable, Sendable {
    package struct File: Codable, Equatable, Sendable {
        package let id: DocumentID
        package let path: String
        package let encoding: FileEncoding?
        package init(id: DocumentID, url: URL, encoding: FileEncoding? = nil) throws {
            guard url.isFileURL, ["", "localhost"].contains(url.host?.lowercased() ?? "") else {
                throw WorkspaceError.invalid("Invalid local path.")
            }
            self.id = id
            self.path = url.standardizedFileURL.path
            self.encoding = encoding
        }
        package var url: URL { URL(fileURLWithPath: path) }
    }
    /// An untitled document whose unsaved text is kept across a quit (DS-D9). The record holds
    /// no text: the text, encoding and byte-order mark are the recovery copy with the same id.
    package struct Untitled: Codable, Equatable, Sendable {
        package let id: DocumentID
        /// The language profile the tab showed; nil reads as plain text.
        package let language: String?
        /// `LineEnding` raw value the editor inserts for new lines; nil reads as detected from the text.
        package let lineEnding: String?
        package init(id: DocumentID, language: String? = nil, lineEnding: String? = nil) {
            self.id = id
            self.language = language
            self.lineEnding = lineEnding
        }
    }
    package static let maximumBytes = SizePolicy.standard.workspaceLayout
    /// 1 while only files are listed, so such a file is byte-for-byte what earlier builds wrote.
    /// 2 exactly when `untitled` is present; an earlier build refuses that file and leaves it alone.
    package let version: Int
    package let files: [File]
    package let untitled: [Untitled]?
    package let layout: WorkspaceLayoutState

    package init(files: [File], untitled: [Untitled] = [], layout: WorkspaceLayoutState) throws {
        self.version = untitled.isEmpty ? 1 : 2
        self.files = files
        self.untitled = untitled.isEmpty ? nil : untitled
        self.layout = Self.filter(layout, retaining: Set(files.map(\.id)).union(untitled.map(\.id)))
        try validate()
    }
    /// The same record without its files, for a launch that is set to start with a new document:
    /// kept untitled text is still restored.
    package func untitledOnly() throws -> Self { try Self(files: [], untitled: untitled ?? [], layout: layout) }
    package static func filter(_ original: WorkspaceLayoutState, retaining ids: Set<DocumentID>) -> WorkspaceLayoutState
    {
        var state = original
        for index in state.groups.indices {
            let group = state.groups[index]
            let kept = group.tabs.indices.filter { ids.contains(group.tabs[$0].documentID) }
            state.groups[index].tabs = kept.map { group.tabs[$0] }
            state.groups[index].activeTabIndex =
                kept.firstIndex { $0 >= (group.activeTabIndex ?? 0) } ?? kept.indices.last
        }
        if let focused = state.groups.first(where: { $0.slot == state.focusedGroup }), focused.tabs.isEmpty,
            let occupied = state.groups.first(where: { !$0.tabs.isEmpty })
        {
            state.focusedGroup = occupied.slot
        }
        return state
    }
    private func validate() throws {
        try layout.validate()
        let kept = untitled ?? []
        let ids = Set(files.map(\.id)).union(kept.map(\.id))
        guard version == (untitled == nil ? 1 : 2), untitled?.isEmpty != true,
            files.count + kept.count <= 4096, ids.count == files.count + kept.count,
            kept.allSatisfy({ item in
                (item.language?.utf8.count ?? 1) <= 200 && item.language?.isEmpty != true
                    && item.lineEnding.map { LineEnding(rawValue: $0) != nil } != false
            }),
            Set(files.map(\.path)).count == files.count,
            files.allSatisfy({ $0.path.hasPrefix("/") && !$0.path.contains("\0") && $0.path.utf8.count <= 4096 }),
            Set(layout.groups.flatMap(\.tabs).map(\.documentID)) == ids
        else { throw WorkspaceError.invalid("The automatic session contains invalid paths or tabs.") }
    }
    package static func readBytes(_ url: URL) throws -> Data? {
        do { return try PrivateFileStore.read(url, maximumBytes: maximumBytes) } catch let error as FileOperationFailure
            where error.errorNumber == ENOENT
        { return nil }
    }
    package static func decode(_ data: Data) throws -> Self {
        try PersistedFormat.check(data, context: "Automatic session")
        let state = try JSONDecoder().decode(Self.self, from: data)
        try state.validate()
        return state
    }
    package static func read(_ url: URL) throws -> Self? { try readBytes(url).map(decode) }
    package func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
    package func write(_ url: URL) throws {
        try PrivateFileStore.write(
            try encoded(), to: url, maximumBytes: Self.maximumBytes,
            synchronize: PrivateFileStore.flushToStorage, synchronizeDirectory: PrivateFileStore.flushToStorage)
    }
}
