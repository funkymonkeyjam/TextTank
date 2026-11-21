import TextTankCore
import EditorBridge
import NativeSearch
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import EventKit
import Darwin

struct ReminderDestination: Identifiable, Equatable {
    let id: String
    let title: String
    let source: String
    let writable: Bool
}
enum ReminderPermission { case notDetermined, denied, authorized }
enum ReminderRowStatus: String, Codable { case pending, confirmed, failed, uncertain }
struct ReminderRow: Codable, Identifiable {
    let id: UUID
    let title: String
    var status: ReminderRowStatus = .pending
    var reminderID: String?
    var message: String?
}
/// Persisted format, version 1; see "Persisted formats" in docs/architecture.md. A new field
/// must be Optional or decoded with decodeIfPresent in an extension, or old files stop loading.
struct ReminderBatch: Codable, Identifiable {
    var schemaVersion = 1
    let id: UUID
    let destinationID: String
    let destinationTitle: String
    let destinationSource: String
    var rows: [ReminderRow]
    let createdAt: Date
}
enum ReminderConnectorError: Error, LocalizedError {
    case permissionRequired, destinationUnavailable, invalidBatch, busy, knownFailure(String), uncertain(String)
    case noRows, tooManyRows(limit: Int), invalidRow(number: Int), journalTooLarge(limit: Int), unsafeLock

    /// The journal could not be updated after at least one item of this export had been handed to
    /// Reminders. The batch is the in-memory outcome; the file on disk was not touched again and
    /// may record the last attempted item as uncertain.
    case journalFailed(ReminderBatch, underlying: Error)
    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            return
                "TextTank does not have access to Reminders, so nothing was sent. Access may have been declined earlier, or it may be restricted on this Mac. To allow it, open System Settings > Privacy & Security > Reminders and turn on TextTank, then send again. The rest of TextTank works without it."
        case .destinationUnavailable:
            return "The selected Reminders list is missing or no longer writable. No items were sent."
        case .invalidBatch:
            return "The export journal is invalid, unsupported, or does not match this batch. It was preserved."
        case .unsafeLock: return "The export lock is not a regular file. No items were sent."
        case .noRows: return "There are no items to send. No items were sent."
        case .tooManyRows(let limit): return "Send at most \(limit) items at once. No items were sent."
        case .invalidRow(let number):
            return "Item \(number) must contain text and be at most 1 MiB. No items were sent."
        case .journalTooLarge(let limit):
            return "The export record exceeds the \(limit)-byte limit. The record was not written."
        case .busy: return "An export is already running."
        case .knownFailure(let message): return message
        case .uncertain(let message): return message
        case .journalFailed(let batch, let underlying):
            let confirmed = batch.rows.filter { $0.status == .confirmed }.count
            return
                "The export journal could not be confirmed (\(underlying.localizedDescription)). \(confirmed) of \(batch.rows.count) items were confirmed before sending stopped. Export History may show the last attempted item as uncertain; check Reminders before sending again."
        }
    }
}
/// A journal file that `scanBatches` could not read. The file is never changed or removed.
struct ReminderJournalIssue {
    let url: URL
    let message: String
}

/// Injectable boundary; tests never instantiate EventKit. All calls stay on the main actor.
@MainActor protocol ReminderStore {
    var permission: ReminderPermission { get }
    func requestAccess() async throws
    func destinations() throws -> [ReminderDestination]
    /// Throw knownFailure only when no write occurred. All other failures are uncertain.
    func save(title: String, destinationID: String) throws -> String
}

/// An isolated support directory never creates the owner's EventKit store implicitly.
@MainActor private final class UnavailableReminderStore: ReminderStore {
    var permission: ReminderPermission { .denied }
    func requestAccess() async throws { throw ReminderConnectorError.permissionRequired }
    func destinations() throws -> [ReminderDestination] { throw ReminderConnectorError.permissionRequired }
    func save(title: String, destinationID: String) throws -> String { throw ReminderConnectorError.permissionRequired }
}

@MainActor final class EventKitReminderStore: ReminderStore {
    private let store = EKEventStore()
    var permission: ReminderPermission {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }
    func requestAccess() async throws {
        // This is the only permission-requesting entry point; construction and import never request.
        let granted = try await store.requestFullAccessToReminders()
        guard granted else { throw ReminderConnectorError.permissionRequired }
    }
    func destinations() throws -> [ReminderDestination] {
        guard permission == .authorized else { throw ReminderConnectorError.permissionRequired }
        return store.calendars(for: .reminder).map {
            ReminderDestination(
                id: $0.calendarIdentifier, title: $0.title,
                source: $0.source.title, writable: $0.allowsContentModifications)
        }
    }
    func save(title: String, destinationID: String) throws -> String {
        guard permission == .authorized else {
            throw ReminderConnectorError.knownFailure("Reminders access was revoked before this item was sent.")
        }
        guard let calendar = store.calendar(withIdentifier: destinationID),
            calendar.allowedEntityTypes.contains(.reminder), calendar.allowsContentModifications
        else {
            throw ReminderConnectorError.knownFailure(
                "The selected list was deleted or became read-only before this item was sent.")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = calendar
        do { try store.save(reminder, commit: true) } catch {
            throw ReminderConnectorError.uncertain(
                "EventKit did not confirm whether this item was saved: \(error.localizedDescription)")
        }
        return reminder.calendarItemIdentifier
    }
}

/// Reads, lays out and updates one batch journal. Everything here is plain file work with no
/// main-actor state, so an export runs it on `ReminderJournalFile`, off the main thread.
enum ReminderJournal {
    static let maximumBytes = 32 * 1024 * 1024
    /// Bytes reserved after each row for its status, reminder identifier and message, so a row's
    /// outcome can be written in place. The barrier text and an EventKit identifier fit.
    static let slotWidth = 240
    /// A slot never crosses a multiple of this, so one in-place update touches one storage block.
    static let blockSize = 4096

    struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
    }
    struct Layout {
        var data: Data
        /// Byte range of each row's slot in `data`, in row order.
        var slots: [Range<Int>]
    }

    static func identity(of descriptor: Int32) -> Identity? {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return nil }
        return Identity(device: info.st_dev, inode: info.st_ino)
    }
    /// The file the path names now, without following a final symbolic link; nil when nothing is there.
    static func identity(atPath path: String) throws -> Identity? {
        var info = stat()
        if lstat(path, &info) == 0 { return Identity(device: info.st_dev, inode: info.st_ino) }
        if errno == ENOENT { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    /// Strict read of one journal: a regular file within the size limit that decodes to schema
    /// version 1 under the expected identifier. Never blocks on a FIFO and never follows a link.
    static func read(_ url: URL, id: UUID) throws -> (batch: ReminderBatch, identity: Identity) {
        let sample: (data: Data, before: stat, after: stat?)
        do { sample = try PrivateFileStore.readSample(url, maximumBytes: maximumBytes) } catch PrivateFileError
            .unsafeLocation
        { throw ReminderConnectorError.invalidBatch } catch PrivateFileError.tooLarge {
            throw ReminderConnectorError.invalidBatch
        }
        let data = sample.data, info = sample.before
        let batch = try JSONDecoder().decode(ReminderBatch.self, from: data)
        // Preserve the reader's concrete DecodingError for malformed journals; the envelope
        // gate still runs before a decoded batch can be accepted or used.
        try PersistedFormat.check(data, context: "Reminders export record")
        guard batch.schemaVersion == 1, batch.id == id, Set(batch.rows.map(\.id)).count == batch.rows.count,
            batch.rows.allSatisfy({ $0.status != .confirmed || !($0.reminderID ?? "").isEmpty })
        else { throw ReminderConnectorError.invalidBatch }
        return (batch, Identity(device: info.st_dev, inode: info.st_ino))
    }

    /// The mutable part of a row as JSON members: `"status":…` and, when present, the reminder
    /// identifier and the message. Absent optionals are omitted, as the synthesized encoder does.
    static func slot(_ row: ReminderRow, encoder: JSONEncoder) throws -> Data {
        var data = Data("\"status\":\"\(row.status.rawValue)\"".utf8)
        if let reminderID = row.reminderID {
            data.append(Data(",\"reminderID\":".utf8))
            data.append(try encoder.encode(reminderID))
        }
        if let message = row.message {
            data.append(Data(",\"message\":".utf8))
            data.append(try encoder.encode(message))
        }
        return data
    }

    /// The journal as version 1 JSON, one row per line, each row ending in a space-padded slot.
    /// JSON allows that whitespace, so the file decodes exactly like the compact form. The size is
    /// bounded while the bytes are assembled, before a complete journal is allocated.
    static func layout(_ batch: ReminderBatch, slotWidth: Int = slotWidth) throws -> Layout {
        let encoder = JSONEncoder()
        var data = Data(), slots: [Range<Int>] = []
        slots.reserveCapacity(batch.rows.count)
        func add(_ piece: Data) throws {
            guard piece.count <= maximumBytes - data.count else {
                throw ReminderConnectorError.journalTooLarge(limit: maximumBytes)
            }
            data.append(piece)
        }
        func add(_ text: String) throws { try add(Data(text.utf8)) }
        try add("{\"schemaVersion\":\(batch.schemaVersion),\"id\":")
        try add(encoder.encode(batch.id))
        try add(",\"destinationID\":")
        try add(encoder.encode(batch.destinationID))
        try add(",\"destinationTitle\":")
        try add(encoder.encode(batch.destinationTitle))
        try add(",\"destinationSource\":")
        try add(encoder.encode(batch.destinationSource))
        try add(",\"createdAt\":")
        try add(encoder.encode(batch.createdAt))
        try add(",\"rows\":[")
        for (index, row) in batch.rows.enumerated() {
            try add(index == 0 ? "\n{\"id\":" : ",\n{\"id\":")
            try add(encoder.encode(row.id))
            try add(",\"title\":")
            try add(encoder.encode(row.title))
            try add(",")
            let content = try slot(row, encoder: encoder)
            let width = max(slotWidth, content.count)
            if width <= blockSize, data.count / blockSize != (data.count + width - 1) / blockSize {
                try add(Data(repeating: 0x20, count: blockSize - data.count % blockSize))
            }
            let start = data.count
            try add(content)
            try add(Data(repeating: 0x20, count: width - content.count))
            slots.append(start..<start + width)
            try add("}")
        }
        try add("\n]}")
        return Layout(data: data, slots: slots)
    }
}

/// The open journal of one running export. The first write replaces the file atomically
/// (private temporary file, fsync, rename) in the slotted layout; after that a row's outcome is
/// one in-place write and fsync into that row's slot, so the cost of a row does not grow with the
/// batch. An outcome that does not fit its slot falls back to another atomic replacement. Before
/// every write the journal path must still name the file that was validated or written here, so a
/// journal directory that was moved or replaced is reported instead of written elsewhere.
actor ReminderJournalFile {
    private let url: URL
    private let id: UUID
    private var descriptor: Int32 = -1
    private var identity: ReminderJournal.Identity?
    private var slots: [Range<Int>] = []
    private let encoder = JSONEncoder()

    init(directory: URL, id: UUID) {
        self.id = id
        url = directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }
    deinit { if descriptor >= 0 { close(descriptor) } }

    /// Validates the journal already on disk, once per export. Nil when there is none.
    func load() throws -> ReminderBatch? {
        guard try ReminderJournal.identity(atPath: url.path) != nil else { return nil }
        let stored = try ReminderJournal.read(url, id: id)
        identity = stored.identity
        return stored.batch
    }

    /// A previous run may have published every acknowledgement and then failed to sync its directory.
    func confirmLoadedFile() throws {
        guard let identity else { throw ReminderConnectorError.invalidBatch }
        try PrivateFileStore.confirmExistingWrite(at: url) { info in
            info.st_dev == identity.device && info.st_ino == identity.inode
        }
    }
    /// Makes the batch durable with row `index` as it is now. Returns after the bytes are synced.
    func record(_ batch: ReminderBatch, row index: Int? = nil) throws {
        guard descriptor >= 0, let index, slots.indices.contains(index) else { return try replace(with: batch) }
        let content = try ReminderJournal.slot(batch.rows[index], encoder: encoder)
        let slot = slots[index]
        guard content.count <= slot.count else { return try replace(with: batch) }
        guard try ReminderJournal.identity(atPath: url.path) == identity else {
            throw ReminderConnectorError.invalidBatch
        }
        var bytes = content
        bytes.append(Data(repeating: 0x20, count: slot.count - content.count))
        try Self.write(bytes, to: descriptor, at: slot.lowerBound)
        guard fsync(descriptor) == 0 else {
            throw PublishedFileSyncFailure(
                failure: .init(errno, operation: "synchronize updated export record", path: url.path))
        }
    }

    private func replace(with batch: ReminderBatch) throws {
        let layout: ReminderJournal.Layout
        do { layout = try ReminderJournal.layout(batch) } catch ReminderConnectorError.journalTooLarge {
            // A batch too close to the size limit for padded slots keeps the compact layout.
            layout = try ReminderJournal.layout(batch, slotWidth: 0)
        }
        // Keep the live descriptor for slotted pwrite/fsync updates after the atomic replace.
        // The journal's own identity guard remains immediately before commit.
        let expectedIdentity = identity
        guard
            let created = try PrivateFileStore.write(
                layout.data, to: url, maximumBytes: ReminderJournal.maximumBytes,
                temporaryPrefix: "", temporarySuffix: ".pending", synchronize: PrivateFileStore.flushToStorage,
                synchronizeDirectory: PrivateFileStore.flushToStorage,
                beforeCommit: {
                    guard try ReminderJournal.identity(atPath: self.url.path) == expectedIdentity else {
                        throw ReminderConnectorError.invalidBatch
                    }
                }, retainingDescriptor: true)
        else { throw FileOperationFailure(EIO, operation: "retain export record", path: url.path) }
        if descriptor >= 0 { close(descriptor) }
        descriptor = created
        identity = ReminderJournal.identity(of: created)
        slots = layout.slots
    }

    private static func write(_ data: Data, to descriptor: Int32, at offset: Int) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var done = 0
            while done < buffer.count {
                let count = pwrite(descriptor, buffer.baseAddress! + done, buffer.count - done, off_t(offset + done))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                done += count
            }
        }
    }
}

/// One durable batch identity spans invocation/retry/restart. Names and titles are data.
/// A journal row becomes uncertain before touching EventKit. Only confirmed writes become
/// confirmed; uncertain rows require manual reconciliation and are never automatically resent.
@MainActor final class RemindersConnector {
    private let store: ReminderStore
    private let storageURL: URL
    private var busy = false
    init(storageURL: URL) {
        self.storageURL = storageURL
        self.store = AppStorage.permitsLegacyDefaults ? EventKitReminderStore() : UnavailableReminderStore()
    }
    init(storageURL: URL, store: ReminderStore) {
        self.storageURL = storageURL
        self.store = store
    }
    func requestAccess() async throws {
        switch store.permission {
        case .authorized: return
        case .notDetermined: try await store.requestAccess()
        case .denied: throw ReminderConnectorError.permissionRequired
        }
    }
    func destinations() throws -> [ReminderDestination] {
        guard store.permission == .authorized else { throw ReminderConnectorError.permissionRequired }
        return try store.destinations()
    }
    /// Strict listing: any journal file that cannot be read fails the whole call. `scanBatches`
    /// is the tolerant sibling.
    func storedBatches() throws -> [ReminderBatch] {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return [] }
        try checkDirectory()
        return try journalFiles().map { url in
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
                throw ReminderConnectorError.invalidBatch
            }
            return try load(id)
        }
    }
    /// Tolerant listing: every readable batch, plus one issue per `.json` file that is not a
    /// readable journal. A failure of the directory itself still throws. Nothing is changed.
    func scanBatches() throws -> (batches: [ReminderBatch], issues: [ReminderJournalIssue]) {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return ([], []) }
        try checkDirectory()
        var batches: [ReminderBatch] = [], issues: [ReminderJournalIssue] = []
        for url in try journalFiles() {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
                issues.append(.init(url: url, message: "The file name is not an export batch identifier."))
                continue
            }
            do { batches.append(try ReminderJournal.read(url, id: id).batch) } catch {
                issues.append(.init(url: url, message: Self.issueMessage(error)))
            }
        }
        return (batches, issues)
    }
    private static func issueMessage(_ error: Error) -> String {
        if case ReminderConnectorError.invalidBatch = error {
            return "It is not a regular journal file of a supported version for this batch identifier."
        }
        if error is DecodingError { return "Its contents are not a readable export journal." }
        return error.localizedDescription
    }
    /// Removes the journals of the named batches whose every row is confirmed, and returns the
    /// identifiers removed. A batch with a pending, failed or uncertain row, a file that cannot be
    /// read and any file not named are left as they are. Reminders itself is never touched.
    func deleteConfirmedBatches(ids: [UUID]) throws -> [UUID] {
        guard !busy else { throw ReminderConnectorError.busy }
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return [] }
        try checkDirectory()
        // The export lock keeps a resume, here or in another process, from running meanwhile.
        let lock = try acquireLock()
        defer {
            flock(lock, LOCK_UN)
            close(lock)
        }
        var removed: [UUID] = []
        for id in ids {
            // Revalidated under the lock; unlink never follows a symbolic link.
            guard let stored = try? ReminderJournal.read(path(id), id: id),
                !stored.batch.rows.isEmpty, stored.batch.rows.allSatisfy({ $0.status == .confirmed }),
                (try? ReminderJournal.identity(atPath: path(id).path)) == stored.identity,
                unlink(path(id).path) == 0
            else { continue }
            removed.append(id)
        }
        return removed
    }
    func export(
        rows: [String], destinationID: String, batchID: UUID, retryFailed: Bool = false,
        progress: ((Int, Int) -> Void)? = nil
    ) async throws -> ReminderBatch {
        guard !busy else { throw ReminderConnectorError.busy }
        guard !rows.isEmpty else { throw ReminderConnectorError.noRows }
        guard rows.count <= 10000 else { throw ReminderConnectorError.tooManyRows(limit: 10000) }
        for (index, row) in rows.enumerated() {
            guard !row.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, row.utf8.count <= 1048576 else {
                throw ReminderConnectorError.invalidRow(number: index + 1)
            }
        }
        busy = true
        defer { busy = false }
        // A process lock covers retries across connector instances and app processes.
        // Never wait for it on the UI actor; a competing request is reported as busy.
        try checkDirectory()
        try preparePrivateDirectory()
        let descriptor = try acquireLock()
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        let selected = try destinations().first { $0.id == destinationID && $0.writable }
        guard let selected else { throw ReminderConnectorError.destinationUnavailable }
        // Journal reads and writes run on the journal actor, off the main thread. Each await
        // returns only after the bytes are synced, and lets the UI service Stop Sending meanwhile.
        let journal = ReminderJournalFile(directory: storageURL, id: batchID)
        var batch: ReminderBatch
        if let stored = try await journal.load() {
            batch = stored
            guard batch.destinationID == destinationID, batch.rows.map(\.title) == rows else {
                throw ReminderConnectorError.invalidBatch
            }
            if batch.rows.allSatisfy({ $0.status == .confirmed }) { try await journal.confirmLoadedFile() }
        } else {
            batch = ReminderBatch(
                id: batchID, destinationID: destinationID, destinationTitle: selected.title,
                destinationSource: selected.source, rows: rows.map { ReminderRow(id: UUID(), title: $0) },
                createdAt: Date())
            try await journal.record(batch)
        }
        progress?(batch.rows.filter { $0.status != .pending }.count, batch.rows.count)
        var attempted = false
        for index in batch.rows.indices {
            if Task.isCancelled { break } // Unsent pending rows remain resumable under this batch ID.
            guard batch.rows[index].status == .pending || (retryFailed && batch.rows[index].status == .failed) else {
                continue
            }
            // A durable uncertainty barrier precedes each nontransactional external write.
            let before = batch.rows[index]
            batch.rows[index].status = .uncertain
            batch.rows[index].message =
                "Export started but confirmation may be missing. Check the destination before sending another copy."
            do { try await journal.record(batch, row: index) } catch {
                // This item was not handed to Reminders. Earlier items of this run were, so their
                // outcomes travel with the error; with none, nothing happened and the error is plain.
                guard attempted else { throw error }
                batch.rows[index] = before
                throw ReminderConnectorError.journalFailed(batch, underlying: error)
            }
            attempted = true
            do {
                let identifier = try store.save(title: batch.rows[index].title, destinationID: destinationID)
                batch.rows[index].status = .confirmed
                batch.rows[index].reminderID = identifier
                batch.rows[index].message = nil
            } catch ReminderConnectorError.knownFailure(let message) {
                batch.rows[index].status = .failed
                batch.rows[index].message = message
            } catch {
                batch.rows[index].status = .uncertain
                batch.rows[index].message = error.localizedDescription
            }
            // After an acknowledgement failure, the visible record may be uncertain or updated. The
            // write is not retried; the in-memory outcome travels with the error.
            do { try await journal.record(batch, row: index) } catch {
                throw ReminderConnectorError.journalFailed(batch, underlying: error)
            }
            progress?(index + 1, batch.rows.count)
            await Task.yield() // Allow UI cancellation without releasing the batch journal lock.
        }
        return batch
    }
    private func path(_ id: UUID) -> URL {
        storageURL.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }
    private func journalFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: storageURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private func acquireLock() throws -> Int32 {
        let lockPath = storageURL.appendingPathComponent(".export.lock").path
        let descriptor = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, mode_t(0o600))
        guard descriptor >= 0 else { throw FileOperationFailure(errno, operation: "open export lock", path: lockPath) }
        var lockInfo = stat()
        guard fstat(descriptor, &lockInfo) == 0 else {
            let failure = FileOperationFailure(errno, operation: "inspect export lock", path: lockPath)
            close(descriptor)
            throw failure
        }
        guard lockInfo.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            throw ReminderConnectorError.unsafeLock
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN { throw ReminderConnectorError.busy }
            throw FileOperationFailure(code, operation: "acquire export lock", path: lockPath)
        }
        return descriptor
    }
    private func checkDirectory() throws {
        guard storageURL.isFileURL else { throw ReminderConnectorError.invalidBatch }
        if FileManager.default.fileExists(atPath: storageURL.path) {
            let values = try FileManager.default.attributesOfItem(atPath: storageURL.path)
            guard values[.type] as? FileAttributeType == .typeDirectory else {
                throw ReminderConnectorError.invalidBatch
            }
        }
    }
    static let maximumJournalBytes = ReminderJournal.maximumBytes
    private func load(_ id: UUID) throws -> ReminderBatch {
        try checkDirectory()
        return try ReminderJournal.read(path(id), id: id).batch
    }
    private func preparePrivateDirectory() throws {
        try checkDirectory()
        do { try PrivateFileStore.prepareDirectory(storageURL) } catch PrivateFileError.unsafeLocation {
            throw ReminderConnectorError.invalidBatch
        }
        try checkDirectory()
    }
    /// The compact encoding of a journal, as written before slotted journals. It is the same
    /// version 1 format; persistence fixtures pin it so that old files keep loading.
    static func encodedJournal(_ batch: ReminderBatch) throws -> Data {
        // Bound aggregate row encoding before allocating a complete journal.
        let encoder = JSONEncoder()
        var rowBytes = 0
        for row in batch.rows {
            let count = try encoder.encode(row).count
            guard count <= maximumJournalBytes - rowBytes else {
                throw ReminderConnectorError.journalTooLarge(limit: maximumJournalBytes)
            }
            rowBytes += count
        }
        let data = try encoder.encode(batch)
        guard data.count <= maximumJournalBytes else {
            throw ReminderConnectorError.journalTooLarge(limit: maximumJournalBytes)
        }
        return data
    }
}
